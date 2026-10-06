"""Split a SQL file into individual statements.

Needed because psycopg2 sends a multi-statement string to the server as ONE
implicit transaction: a single failure rolls back everything that ran before it.
The snapshot files in this repo fail at line ~1129 (ALTER TABLE ... sync_conflicts)
while creating that table at line ~2175, so nothing before the failure could be
kept. Executing statement-by-statement lets the rest of the file apply.

Handles dollar-quoted bodies ($$, $fn$, $function$, $tag$), single-quoted
literals with '' escapes, double-quoted identifiers, line comments, and nested
block comments.
"""
import re


def split_statements(sql):
    """Yield each top-level statement, comments and whitespace stripped."""
    stmts = []
    buf = []
    i = 0
    n = len(sql)
    # dollar-quote tag currently open, if any
    dollar_tag = None

    while i < n:
        ch = sql[i]

        # ── dollar-quoted body ────────────────────────────────────────────────
        # ── closing a dollar quote ──────────────────────────────────────────
        if dollar_tag is not None:
            if sql.startswith(dollar_tag, i):
                buf.append(dollar_tag)
                i += len(dollar_tag)
                dollar_tag = None
                # A dollar-quoted body is a complete unit. When it closes at
                # the end of a statement, the ';' that follows belongs to
                # THAT statement, not to a new empty one. Consuming it here
                # stops the splitter from emitting the whole block and then
                # a stray '$$;' as the head of the next statement -- which is
                # what made a following DO block look like it had run empty.
                j = i
                while j < n and sql[j] in " \t\r\n":
                    j += 1
                if j < n and sql[j] == ";":
                    buf.append(sql[i:j])
                    i = j + 1
                    stmt = "".join(buf).strip()
                    if stmt:
                        stmts.append(stmt)
                    buf = []
                    continue
                continue
            buf.append(ch)
            i += 1
            continue

        # ── opening a dollar quote? $tag$ ... $tag$ ────────────────────────────
        if ch == "$":
            m = re.match(r"\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$", sql[i:])
            if m:
                dollar_tag = m.group(0)
                buf.append(dollar_tag)
                i += len(dollar_tag)
                continue

        # ── line comment ──────────────────────────────────────────────────────
        if sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j == -1 else j + 1
            continue

        # ── block comment (nestable in postgres) ──────────────────────────────
        if sql.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth:
                if sql.startswith("/*", i):
                    depth += 1
                    i += 2
                elif sql.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue

        # ── single-quoted literal ('' escapes) ────────────────────────────────
        if ch == "'":
            buf.append(ch)
            i += 1
            while i < n:
                if sql[i] == "'":
                    if i + 1 < n and sql[i + 1] == "'":
                        buf.append("''")
                        i += 2
                        continue
                    buf.append("'")
                    i += 1
                    break
                buf.append(sql[i])
                i += 1
            continue

        # ── double-quoted identifier ("" escapes) ─────────────────────────────
        if ch == '"':
            buf.append(ch)
            i += 1
            while i < n:
                if sql[i] == '"':
                    if i + 1 < n and sql[i + 1] == '"':
                        buf.append('""')
                        i += 2
                        continue
                    buf.append('"')
                    i += 1
                    break
                buf.append(sql[i])
                i += 1
            continue

        # ── statement terminator ──────────────────────────────────────────────
        if ch == ";":
            stmt = "".join(buf).strip()
            if stmt:
                stmts.append(stmt)
            buf = []
            i += 1
            continue

        buf.append(ch)
        i += 1

    tail = "".join(buf).strip()
    if tail:
        stmts.append(tail)
    return stmts


def strip_tx(sql):
    """Drop the file-level BEGIN/COMMIT; the driver owns transactions here.

    The pattern is anchored to a single line and the leading indent is
    matched with [ \\t]*, never \\s*: \\s also matches newlines, so a
    `\\s*` before BEGIN would let the pattern reach across a blank line and
    delete a `BEGIN` that belongs to a PL/pgSQL block inside a DO body.
    That silently corrupted every DO block in the migrations.
    """
    return re.sub(r"(?im)^[ \t]*(BEGIN|COMMIT|START TRANSACTION)[ \t]*;[ \t]*$",
                  "", sql)


def strip_dollar_quoted(sql):
    """Replaces every dollar-quoted body ($$ ... $$ AND $tag$ ... $tag$) with a
    single space, so keyword scanning sees only real DDL and never the PL/pgSQL
    source inside a function or DO block. Tagged quotes matter: init.sql and
    the 00800/00801 migrations use $func$, not $$. """
    out, i = [], 0
    pat = re.compile(r"\$(\w*)\$")
    while True:
        m = pat.search(sql, i)
        if not m:
            out.append(sql[i:])
            break
        tag = m.group(0)
        k = sql.find(tag, m.end())
        if k < 0:
            out.append(sql[i:])
            break
        out.append(sql[i:m.start()])
        out.append(" ")
        i = k + len(tag)
    return "".join(out)


def strip_tx(sql):
    """Drop the file-level BEGIN/COMMIT/START TRANSACTION.

    Dollar-quoted PL/pgSQL bodies (DO $tag$ ... END; $tag$) are preserved
    entirely — we only strip BEGIN/COMMIT that appear at the start of a line
    OUTSIDE any dollar quote. Without this, file-level stripping would delete
    BEGIN/COMMIT inside DO blocks and silently corrupt every migration. """
    out = []
    in_dollar = False
    for ln in sql.split("\n"):
        if in_dollar:
            # inside a dollar-quoted block: preserve the line as-is
            if re.search(r"\$\w*\$", ln):
                # closing tag seen -> block ends
                in_dollar = False
            out.append(ln)
            continue

        # outside dollar quotes: strip file-level transaction keywords
        new = re.sub(r"^[ \t]*(BEGIN|COMMIT|START TRANSACTION)[ \t]*;[ \t]*$", "", ln)
        out.append(new)

        # does this line open a dollar quote (that is not self-closed)?
        m = re.search(r"\$\w*\$", new)
        if m:
            tag = m.group(0)
            if new[m.end():].find(tag) < 0:
                in_dollar = True

    return "\n".join(out)


if __name__ == "__main__":
    import io
    import sys
    text = io.open(sys.argv[1], encoding="utf-8-sig", errors="replace").read()
    parts = split_statements(strip_tx(text))
    print(f"{len(parts)} statements")
    if len(sys.argv) > 2:
        lo, hi = int(sys.argv[2]), int(sys.argv[3])
        for k in range(lo, min(hi, len(parts))):
            print(f"--- [{k}] ---")
            print(parts[k][:400])