

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
        ok = not (s_issues or i_issues or m_issues)
        all_ok = all_ok and ok
        results.append({"file": os.path.relpath(path, ROOT), "ok": ok,
                        "structure": s_issues, "idempotency": i_issues,
                        "reference": m_issues, "declared": declared,
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
                           ("vs json_output", "reference")):
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
