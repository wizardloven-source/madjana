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
        if dollar_tag is not None:
            if sql.startswith(dollar_tag, i):
                buf.append(dollar_tag)
                i += len(dollar_tag)
                dollar_tag = None
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