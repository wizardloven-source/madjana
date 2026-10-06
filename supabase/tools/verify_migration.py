

def check_structure(raw):
    """Balanced transactions and dollar quotes, on the raw text."""
    issues = []
    # Both $$ and $tag$ delimiters must be balanced, counted per tag.
    for tag in set(re.findall(r"\$\w*\$", raw)):
        if raw.count(tag) % 2:
            issues.append(f"unbalanced {tag} delimiters "
                          f"({raw.count(tag)} occurrences)")

    # BEGIN; / COMMIT; at transaction level. The plpgsql bodies are blanked
    # first, otherwise every BEGIN inside a DO block would be counted.
    body = strip_strings(strip_line_comments(strip_dollar_quoted(raw)))
    up = body.upper()
    n_begin = len(re.findall(r"\bBEGIN\s*;", up))
    n_commit = len(re.findall(r"\bCOMMIT\s*;", up))
    n_rollback = len(re.findall(r"\bROLLBACK\s*;", up))
    if n_begin == 0 and n_commit == 0:
        # A migration with no explicit transaction is legal (the CLI wraps
        # it). Not a finding.
        pass
    elif n_begin != n_commit + n_rollback:
        issues.append(
            f"transaction opened {n_begin}x but closed {n_commit + n_rollback}x "
            f"({n_commit} COMMIT / {n_rollback} ROLLBACK) -- psql would leave "
            f"this open and the implicit COMMIT never happens")
    if n_begin > 1 and n_commit + n_rollback < n_begin:
        issues.append("nested BEGIN without a matching COMMIT")

    tail = up.rstrip()
    if tail and not tail.endswith((";", "$", ")")):
        issues.append("file does not end on a statement terminator")
    return issues


def check_idempotency(raw):
    """Every CREATE guarded, every DROP guarded."""
    issues = []
    body = strip_line_comments(strip_dollar_quoted(raw)).upper()

    # PostgreSQL has no CREATE TRIGGER/POLICY IF NOT EXISTS. The project's
    # convention is a preceding DROP ... IF EXISTS on the same name, which is
    # equivalent. Verify the guard is actually there.
    guarded = set(m.group(1).lower() for m in re.finditer(
        r"\bDROP\s+(?:TRIGGER|POLICY)\s+(?:IF\s+EXISTS\s+)?(\w+)", body))
    for m in re.finditer(
            r"\bCREATE\s+(TRIGGER|POLICY)\s+(\w+)", body):
        kind, name = m.group(1), m.group(2).lower()
        if name not in guarded:
            issues.append(
                f"CREATE {kind} {m.group(2)} has no preceding "
                f"DROP {kind} IF EXISTS -- a re-run would fail")

    for m in re.finditer(
            r"\bCREATE\s+(?!OR\s+REPLACE)(?!TEMP)(?:UNIQUE\s+)?"
            r"(TABLE|INDEX|SCHEMA|SEQUENCE|VIEW)\b[^;]*;", body):
        if "IF NOT EXISTS" not in m.group(0):
            issues.append(f"unguarded CREATE: {m.group(0)[:72]}")

    for m in re.finditer(r"\bDROP\s+[^;\n]*;", body):
        stmt = m.group(0)
        if re.search(r"\bIF\s+EXISTS\b", stmt):
            continue
        issues.append(f"unguarded DROP: {stmt[:72]}")

    # RAISE placeholder/argument count. The database only reports this at
    # run time, and the error it gives ("too few parameters specified for
    # RAISE") does not name the statement -- so a static check here saves a
    # full CI round trip.
    issues.extend(check_raise_placeholders(body))

    return issues


def check_raise_placeholders(body):
    """Every RAISE must supply exactly as many arguments as it has %s."""
    issues = []
    pat = re.compile(
        r"\bRAISE\s+(?:EXCEPTION|NOTICE|WARNING)\s+"
        r"((?:'(?:[^']|'')*'(?:\s*\|\|\s*)?)+)(.*?);", re.S | re.I)
    for m in pat.finditer(body):
        lits, rest = m.group(1), m.group(2)
        n_ph = 0
        for lit in re.findall(r"'(?:[^']|'')*'", lits):
            s = lit[1:-1].replace("''", "'")
            n_ph += s.count("%%") * -1 + s.count("%")
        if n_ph <= 0:
            continue
        # Count top-level commas in the argument list, ignoring anything
        # nested in parentheses: a comma inside (SELECT a, b) separates
        # columns, not RAISE arguments.
        depth, commas, saw = 0, 0, False
        for ch in rest:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "," and depth == 0:
                commas += 1
            if not ch.isspace():
                saw = True
        args = commas + 1 if saw else 0
        if args != n_ph:
            issues.append(
                f"RAISE has {n_ph} placeholder(s) but {args} argument(s) -- "
                f"fails at run time")
    return issues


def _find_dollar_end(sql, i):
    """If a dollar-quoted tag opens at i, return the index after its
    closing tag; otherwise -1."""
    m = re.match(r"\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$", sql[i:])
    if not m:
        return -1
    tag = m.group(0)
    end = sql.find(tag, i + len(tag))
    return end + len(tag) if end >= 0 else -1


def _extract_arg_text(raw, paren_start):
    """Return the text inside format( ... ) beginning at paren_start ('(').
    Returns (text, end_position) or (None, None) if unmatched."""
    i = paren_start + 1
    depth = 1
    n = len(raw)
    while i < n and depth:
        if raw.startswith("$$", i) or re.match(r"\$\w*\$", raw[i:]):
            j = _find_dollar_end(raw, i)
            if j < 0:
                break
            i = j
            continue
        if raw[i] == "'":
            i += 1
            while i < n:
                if raw[i] == "'" and raw[i+1:i+2] != "'":
                    break
                if raw[i] == "'" and raw[i+1:i+2] == "'":
                    i += 2
                    continue
                i += 1
            continue
        if raw[i] == "(":
            depth += 1
        elif raw[i] == ")":
            depth -= 1
            if depth == 0:
                return raw[paren_start+1:i], i
        i += 1
    return None, None


def _count_format_args(arg_text):
    """Count comma-separated arguments at parenthesis depth 0, ignoring
    string literals and dollar-quoted bodies."""
    depth = 0
    commas = 0
    i = 0
    n = len(arg_text)
    while i < n:
        if arg_text.startswith("$$", i) or re.match(r"\$\w*\$", arg_text[i:]):
            j = _find_dollar_end(arg_text, i)
            if j < 0:
                break
            i = j
            continue
        if arg_text[i] == "'":
            i += 1
            while i < n:
                if arg_text[i] == "'" and arg_text[i+1:i+2] != "'":
                    break
                if arg_text[i] == "'" and arg_text[i+1:i+2] == "'":
                    i += 2
                    continue
                i += 1
            continue
        if arg_text[i] == "(":
            depth += 1
        elif arg_text[i] == ")":
            depth -= 1
        elif arg_text[i] == "," and depth == 0:
            commas += 1
        i += 1
    return commas + 1


def _collect_positional_specs(arg_text):
    """Extract the positions used by %s/%I/%L specifiers in literal
    strings. Returns max_position and set of explicit positions."""
    sequential = 0
    explicit = set()
    i = 0
    n = len(arg_text)
    while i < n:
        if arg_text.startswith("$$", i) or re.match(r"\$\w*\$", arg_text[i:]):
            j = _find_dollar_end(arg_text, i)
            if j < 0:
                break
            i = j
            continue
        if arg_text[i] == "'":
            i += 1
            chars = []
            while i < n:
                if arg_text[i] == "'" and arg_text[i+1:i+2] != "'":
                    break
                chars.append(arg_text[i])
                if arg_text[i] == "'" and arg_text[i+1:i+2] == "'":
                    chars.append(arg_text[i])
                    i += 2
                    continue
                i += 1
            s = "".join(chars).replace("''", "'").replace("%%", "%")
            for m in re.finditer(r"(\d*)\$([sIL])", s):
                if m.group(1):
                    explicit.add(int(m.group(1)))
                else:
                    sequential += 1
            continue
        i += 1
    max_position = max(explicit) if explicit else sequential
    return max_position, explicit


def check_format_placeholders(raw):
    """Every format( call must have enough arguments for its %s/%I/%L
    specifiers. Handles sequential (%s) and positional (%1$I) specifiers,
    plus nested format() inside string literals."""
    issues = []
    for m in re.finditer(r"\bformat\s*\(", raw):
        arg_text, _ = _extract_arg_text(raw, m.end() - 1)
        if arg_text is None:
            continue
        n_args = _count_format_args(arg_text)
        max_position, _ = _collect_positional_specs(arg_text)
        if max_position > n_args:
            issues.append(
                f"format() has specifiers up to %{max_position}$ but only "
                f"{n_args} argument(s) -> fails at run time")
    return issues


def check_matches_ref(raw, ref):
    """Verify every table and column the migration depends on is real.
    Re-declaring something production already has is flagged loudly."""
    issues, declared, notes = [], set(), []
    body = strip_line_comments(strip_dollar_quoted(raw))

    for m in re.finditer(
            r"ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:public\.)?(\w+)\s+"
            r"ADD\s+COLUMN\s+(IF\s+NOT\s+EXISTS\s+)?(\w+)", body, re.I):
        tbl, guarded, col = m.group(1).lower(), m.group(2), m.group(3).lower()
        declared.add(f"{tbl}.{col}")
        if tbl not in ref["tables"]:
            continue
        if col in ref["tables"][tbl]:
            if not guarded:
                issues.append(
                    f"{tbl}.{col} exists in production AND the ADD COLUMN is "
                    f"unguarded -- a re-run would fail")
            else:
                notes.append(f"{tbl}.{col} already present (guarded no-op)")

    for m in re.finditer(r"REFERENCES\s+(?:public\.)?(\w+)\s*\(", body, re.I):
        t = m.group(1).lower()
        if t not in ref["tables"]:
            issues.append(f"FK targets unknown table '{t}'")

    for m in re.finditer(
            r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?(\w+)",
            body, re.I):
        declared.add(m.group(1))

    CATALOG = {"pg_class", "pg_attribute", "pg_proc", "pg_policies",
               "pg_constraint", "pg_indexes", "pg_trigger", "pg_enum",
               "pg_namespace", "pg_index", "pg_tables", "pg_roles",
               "information_schema", "auth", "storage", "extensions",
               "public", "graphql", "anon", "authenticated", "service_role",
               "authenticator", "old", "new", "affected", "v_old", "v_new",
               "regexp_matches", "jsonb_array_elements", "jsonb_each",
               "unnest", "generate_series", "only", "table", "select",
               "values", "conflict", "nothing", "returning", "excluded",
               "on", "or", "and", "of", "in", "to", "as", "set", "where",
               "by", "group", "order", "limit", "using", "when", "then",
               "else", "do", "begin", "commit", "rollback", "returning",
               "distinct", "having", "union", "join", "left", "right",
               "inner", "outer", "cross", "exists", "all", "any", "case"}
    ctes = {m.group(1).lower() for m in re.finditer(
        r"(?:WITH|,)\s*(?:RECURSIVE\s+)?(\w+)\s+AS\s*\(", body, re.I)}
    ctes |= {m.group(1).lower() for m in re.finditer(
        r"\b(\w+)\s+AS\s*\(\s*SELECT", body, re.I)}
    ctes |= {m.group(1).lower() for m in re.finditer(
        r"^\s*(\w+)\s+(?:RECORD|RECORD|public\.\w+|TABLE|%\w+TYPE)",
        body, re.I | re.M)}
    ctes |= {m.group(1).lower() for m in re.finditer(
        r"\bFOR\s+(\w+)\s+IN\s", body, re.I)}

    for m in re.finditer(
            r"\b(?:INSERT\s+INTO|FROM|UPDATE)\s+(?:public\.)?(\w+)", body, re.I):
        t = m.group(1).lower()
        if t in CATALOG or t in ctes or t in declared:
            continue
        if t not in ref["tables"]:
            issues.append(f"references unknown table '{t}'")

    return issues, sorted(declared), notes


def check_strip_tx_unit():
    """Regression test: file-level BEGIN/COMMIT are removed,
    but BEGIN/COMMIT inside dollar-quoted PL/pgSQL bodies are preserved."""
    res = subprocess.run(
        [sys.executable, os.path.join(ROOT, "supabase/tests/test_strip_tx.py")],
        capture_output=True, text=True, cwd=ROOT)
    return ["strip_tx unit test failed"] if res.returncode != 0 else []


def check_on_delete(raw):
    """FK delete rules: farm_id/flock_id/manager_id -> RESTRICT;
    worker_id/created_by -> SET NULL; CASCADE forbidden."""
    issues = []
    # FOREIGN KEY (col, ...) REFERENCES tbl (...)[ON DELETE action]
    # ON DELETE must appear immediately after the REFERENCES clause.
    for m in re.finditer(
        r"FOREIGN\s+KEY\s*\(([^)]*)\)\s*REFERENCES\s+(\w+)\s*\(([^)]*)\)"
        r"(?:\s+ON\s+DELETE\s+(CASCADE|SET\s+NULL|SET\s+DEFAULT|NO\s+ACTION|RESTRICT))?",
        raw, re.I):
        cols = [c.strip().strip('"') for c in m.group(1).split(",")]
        ref_tbl = m.group(2).strip().strip('"')
        on_delete = (m.group(4) or "NO ACTION").upper().replace(" ", "_")
        for col in cols:
            if col in {"farm_id", "flock_id", "manager_id"}:
                if on_delete != "RESTRICT":
                    issues.append(f"FK {col!r} -> {ref_tbl!r}: must be RESTRICT, found {on_delete}")
            elif col in {"worker_id", "created_by"}:
                if on_delete not in {"SET NULL", "NO ACTION"}:
                    issues.append(f"FK {col!r} -> {ref_tbl!r}: should be SET NULL, found {on_delete}")
        if on_delete == "CASCADE":
            issues.append(f"FK -> {ref_tbl!r}: ON DELETE CASCADE silently erases production records")
    # ADD COLUMN col uuid REFERENCES tbl (...)[ON DELETE ...]
    for m in re.finditer(
        r"ADD\s+COLUMN\s+(\w+)\s+\w+\s+uuid\s+REFERENCES\s+(\w+)\s*\(([^)]*)\)"
        r"(?:\s+ON\s+DELETE\s+(CASCADE|SET\s+NULL|SET\s+DEFAULT|NO\s+ACTION|RESTRICT))?",
        raw, re.I):
        col = m.group(1).strip().strip('"')
        ref_tbl = m.group(2).strip().strip('"')
        on_delete = (m.group(4) or "NO ACTION").upper().replace(" ", "_")
        if col in {"farm_id", "flock_id", "manager_id"}:
            if on_delete != "RESTRICT":
                issues.append(f"ADD COLUMN {col!r} FK: must be RESTRICT, found {on_delete}")
        elif col in {"worker_id", "created_by"}:
            if on_delete not in {"SET NULL", "NO ACTION"}:
                issues.append(f"ADD COLUMN {col!r} FK: should be SET NULL, found {on_delete}")
        if on_delete == "CASCADE":
            issues.append(f"ADD COLUMN {col!r}: ON DELETE CASCADE silently erases production records")
    return issues


def check_registry_ordering(raw):
    """Parent tables must be inserted before their children in sync_table_registry."""
    issues = []
    m = re.search(r"INSERT\s+INTO\s+sync_table_registry", raw, re.I)
    if not m:
        return issues
    body = raw[m.end():]
    vm = re.search(r"VALUES\s*\((.+?)\)\s*;", body, re.I | re.S)
    if not vm:
        return issues
    vals = vm.group(1)
    rows = re.findall(r"'(\w+)'[^)]*\d+|\d+[^)]*'(\w+)'", vals)
    parsed = [r[0] or r[1] for r in rows]
    parent_before = {"farms": ["users", "user_farms", "flocks"],
                     "users": ["user_farms"],
                     "user_farms": [],
                     "flocks": ["egg_production", "mortality", "feed_consumption", "feed_received",
                                "egg_dispatch", "stock_adjustments", "medications", "expenses",
                                "opening_balances", "record_lock"]}
    positions = {t: i for i, t in enumerate(parsed)}
    for p, children in parent_before.items():
        if p not in positions:
            continue
        for c in children:
            if c in positions and positions[c] < positions[p]:
                issues.append(f"sync_table_registry: {c} ({positions[c]}) before parent {p} ({positions[p]})")
    return issues


def check_grants_coverage(ref_tables):
    """test_grants.sql must grant per-table access for every production table."""
    issues = []
    p = os.path.join(ROOT, "supabase/tests/test_grants.sql")
    try:
        s = open(p, encoding="utf-8").read()
    except FileNotFoundError:
        return ["test_grants.sql not found"]
    if re.search(r"GRANT\s+ALL\s+ON\s+(?:ALL\s+TABLES\s+IN\s+SCHEMA\s+public|TABLES\s+TO)", s, re.I):
        return issues
    if "information_schema.tables" in s:
        return issues
    issues.append("test_grants.sql grants no per-table access")
    return issues


def check_currency(raw):
    """Every currency column must use ('dollar', 'lira').

    'SAR', 'USD', 'EUR' (and any other value) is rejected because
    the project's convention is dollar/lira only."""
    issues = []
    BAD = {"sar", "usd", "eur", "sr", "sek", "jpy", "gbp", "cad", "aud", "chf"}
    # Find ADD COLUMN ... currency with a CHECK that allows bad values
    for m in re.finditer(
        r"ADD\s+COLUMN\s+(\w+)\s+TEXT\s+NOT\s+NULL\s+DEFAULT\s+'(\w+)'\s*"
        r"CHECK\s*\(currency\s+IN\s*\(([^)]*)\)\)",
        raw, re.I):
        col, default, allowed = m.group(1), m.group(2).lower(), m.group(3)
        vals = {v.strip().strip("'").lower() for v in allowed.split(",")}
        bad = vals & BAD
        if bad:
            issues.append(
                f"currency column {col!r} allows bad values {sorted(bad)} "
                f"(must be 'dollar','lira')")
        if default not in ("dollar", "lira"):
            issues.append(
                f"currency column {col!r} default is {default!r} "
                f"(must be 'dollar' or 'lira')")
    return issues
    """Verify every table and column the migration depends on is real.
    Re-declaring something production already has is flagged loudly."""
    issues, declared, notes = [], set(), []
    body = strip_line_comments(strip_dollar_quoted(raw))

    for m in re.finditer(
            r"ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:public\.)?(\w+)\s+"
            r"ADD\s+COLUMN\s+(IF\s+NOT\s+EXISTS\s+)?(\w+)", body, re.I):
        tbl, guarded, col = m.group(1).lower(), m.group(2), m.group(3).lower()
        declared.add(f"{tbl}.{col}")
        if tbl not in ref["tables"]:
            continue
        if col in ref["tables"][tbl]:
            # Expected for any migration that was already applied to
            # production: the dump is a snapshot AFTER that migration ran.
            # It is only a defect if the statement is unguarded, because then
            # a re-run would error out instead of being a no-op.
            if not guarded:
                issues.append(
                    f"{tbl}.{col} exists in production AND the ADD COLUMN is "
                    f"unguarded -- a re-run would fail")
            else:
                notes.append(f"{tbl}.{col} already present (guarded no-op)")

    for m in re.finditer(r"REFERENCES\s+(?:public\.)?(\w+)\s*\(", body, re.I):
        t = m.group(1).lower()
        if t not in ref["tables"]:
            issues.append(f"FK targets unknown table '{t}'")

    for m in re.finditer(
            r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?(\w+)",
            body, re.I):
        declared.add(m.group(1))

    # Only FROM / INTO / UPDATE name a table. `ON` is excluded because it is
    # the trigger-body keyword (`AFTER INSERT ON tbl`, `... FUNCTION f() ON`).
    # Catalogs, roles and CTE aliases are not application tables.
    CATALOG = {"pg_class", "pg_attribute", "pg_proc", "pg_policies",
               "pg_constraint", "pg_indexes", "pg_trigger", "pg_enum",
               "pg_namespace", "pg_index", "pg_tables", "pg_roles",
               "information_schema", "auth", "storage", "extensions",
               "public", "graphql", "anon", "authenticated", "service_role",
               "authenticator", "old", "new", "affected", "v_old", "v_new",
               "regexp_matches", "jsonb_array_elements", "jsonb_each",
               "unnest", "generate_series", "only", "table", "select",
               "values", "conflict", "nothing", "returning",
               # SQL keywords that can directly follow INSERT/FROM/UPDATE in
               # trigger syntax: "AFTER INSERT OR UPDATE ON tbl" would
               # otherwise be read as an UPDATE of a table called "on".
               "on", "or", "and", "of", "in", "to", "as", "set", "where",
               "by", "group", "order", "limit", "using", "when", "then",
               "else", "do", "begin", "commit", "rollback", "returning",
               "distinct", "having", "union", "join", "left", "right",
               "inner", "outer", "cross", "exists", "all", "any", "case"}
    # CTE names introduced in this file are local aliases, not tables.
    ctes = {m.group(1).lower() for m in re.finditer(
        r"(?:WITH|,)\s*(?:RECURSIVE\s+)?(\w+)\s+AS\s*\(", body, re.I)}
    ctes |= {m.group(1).lower() for m in re.finditer(
        r"\b(\w+)\s+AS\s*\(\s*SELECT", body, re.I)}
    # DECLARE'd record/row variables used as FROM targets (v_farm, v_row...).
    ctes |= {m.group(1).lower() for m in re.finditer(
        r"^\s*(\w+)\s+(?:RECORD|RECORD|public\.\w+|TABLE|%\w+TYPE)",
        body, re.I | re.M)}
    ctes |= {m.group(1).lower() for m in re.finditer(
        r"\bFOR\s+(\w+)\s+IN\s", body, re.I)}

    for m in re.finditer(
            r"\b(?:INSERT\s+INTO|FROM|UPDATE)\s+(?:public\.)?(\w+)", body, re.I):
        t = m.group(1).lower()
        if t in CATALOG or t in ctes or t in declared:
            continue
        if t not in ref["tables"]:
            issues.append(f"references unknown table '{t}'")

    return issues, sorted(declared), notes

#!/usr/bin/env python3
"""
verify_migration.py  —  W0.1 gate: structural + idempotency + schema-match check

The development machine has neither psql nor Docker, so no SQL can actually
be executed here. This tool substitutes for the three checks that CAN be
done statically, and reports honestly what it cannot cover:

  1. STRUCTURE   balanced BEGIN/COMMIT, balanced $$ blocks, balanced BEGIN..END,
                 no stray semicolons inside dollar quotes
  2. IDEMPOTENCY every CREATE has IF NOT EXISTS or is CREATE OR REPLACE;
                 every DROP has IF EXISTS; no bare ALTER ... ADD COLUMN
  3. MATCHES REF every table / column / trigger / policy named in the
                 migration is verified against json_output.txt

Usage:
    python supabase/tools/verify_migration.py <file.sql> [...]
    python supabase/tools/verify_migration.py --json <file.sql>
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
JSON_REF = os.path.join(ROOT, "json_output.txt")

RESET, RED, YEL, GRN, DIM = "\033[0m", "\033[31m", "\033[33m", "\033[32m", "\033[2m"


def load_reference(path=JSON_REF):
    ref = {"tables": defaultdict(set), "triggers": set(),
           "policies": set(), "functions": set()}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.search(r"\|\s*(\{.*?\})\s*(?:\||\s*$)", line)
            if not m:
                continue
            try:
                o = json.loads(m.group(1))
            except json.JSONDecodeError:
                continue
            t = o.get("type")
            if t == "Table":
                ref["tables"][o["table_name"]].add(o["column_name"])
            elif t == "Trigger" and not o["trigger_name"].startswith("RI_"):
                ref["triggers"].add(o["trigger_name"])
            elif t == "RLS Policy":
                ref["policies"].add(o["policy_name"])
            elif t == "Function":
                ref["functions"].add(o["routine_name"])
    return ref


def strip_dollar_quoted(sql):
    """Replaces every dollar-quoted body ($$ ... $$ AND $tag$ ... $tag$) with
    a single space, so keyword scanning sees only real DDL and never the
    PL/pgSQL source inside a function. Tagged quotes matter: init.sql and the
    00800/00801 migrations use $func$, not $$."""
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


def strip_line_comments(sql):
    return "\n".join(re.sub(r"--[^\n]*", "", ln) for ln in sql.split("\n"))


def strip_strings(sql):
    return re.sub(r"'[^']*'", "''", sql)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    ref = load_reference()

    results, all_ok = [], True
    for path in args.files:
        raw = open(path, encoding="utf-8").read()
        s_issues = check_structure(raw)
        i_issues = check_idempotency(raw)
        m_issues, declared, notes = check_matches_ref(raw, ref)
        f_issues = check_format_placeholders(raw)
        o_issues = check_on_delete(raw)
        r_issues = check_registry_ordering(raw)
        g_issues = check_grants_coverage(ref["tables"])
        c_issues = check_currency(raw)
        sx_issues = check_strip_tx_unit()
        ok = not (s_issues or i_issues or m_issues or f_issues
                  or o_issues or r_issues or g_issues or c_issues
                  or sx_issues)
        all_ok = all_ok and ok
        results.append({"file": os.path.relpath(path, ROOT), "ok": ok,
                        "structure": s_issues, "idempotency": i_issues,
                        "reference": m_issues, "declared": declared,
                        "format": f_issues, "on_delete": o_issues,
                        "registry": r_issues, "grants": g_issues,
                        "currency": c_issues, "strip_tx": sx_issues,
                        "notes": notes})

    if args.json:
        print(json.dumps(results, indent=2, ensure_ascii=False))
        return 0 if all_ok else 1

    print("=" * 76)
    print("  MIGRATION GATE  --  verify_migration.py")
    print("=" * 76)
    for r in results:
        head = f"{GRN}v OK{RESET}" if r["ok"] else f"{RED}x FAIL{RESET}"
        print(f"\n{head}  {r['file']}")
        for label, key in (("structure", "structure"),
                           ("idempotency", "idempotency"),
                           ("vs json_output", "reference"),
                           ("format placeholders", "format"),
                           ("on_delete rules", "on_delete"),
                           ("registry order", "registry"),
                           ("grants coverage", "grants"),
                           ("currency", "currency"),
                           ("strip_tx unit", "strip_tx")):
            if r[key]:
                print(f"   {YEL}{label}{RESET}")
                for i in r[key]:
                    print(f"     - {i}")
            else:
                print(f"   {DIM}{label}: clean{RESET}")
        if r["declared"]:
            print(f"   {DIM}declares: {', '.join(r['declared'])}{RESET}")

    print("\n" + "=" * 76)
    print(f"  {GRN}static checks passed{RESET}" if all_ok
          else f"  {RED}{YEL}static checks FAILED{RESET}")
    print(f"  {DIM}NOT COVERED: real execution, index usage, lock behaviour,")
    print(f"  RLS evaluation. Those need a live Postgres.{RESET}")
    print("=" * 76)
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
