"""Regression test for sqlsplit.strip_tx.

File-level BEGIN / COMMIT are removed, but BEGIN / COMMIT inside dollar-quoted
PL/pgSQL bodies (DO $tag$ ... END; $tag$) must be preserved.
"""
import re
import sys

sys.path.insert(0, "supabase/tests")

from sqlsplit import strip_tx

cases = [
    # Inline transaction keywords are NOT stripped (pattern requires EOL)
    ("BEGIN; CREATE TABLE y (id int); COMMIT;",
     None),  # expected: unchanged

    # File-level transaction keywords ARE stripped
    ("BEGIN;\nCREATE TABLE y (id int);\nCOMMIT;\n",
     "\nCREATE TABLE y (id int);\n"),

    # DO block: BEGIN/END preserved
    ("DO $$ BEGIN CREATE TABLE x (id int); END $$;\n",
     "DO $$ BEGIN CREATE TABLE x (id int); END $$;\n"),

    # $fix$ block (20260927000000): BEGIN/END MUST survive
    ("DO $fix$\nDECLARE v record;\nBEGIN\n    FOR v IN 1..2 LOOP END LOOP;\nEND;\n$$;\n",
     "DO $fix$\nDECLARE v record;\nBEGIN\n    FOR v IN 1..2 LOOP END LOOP;\nEND;\n$$;\n"),

    # START TRANSACTION / COMMIT
    ("START TRANSACTION;\nSELECT 1;\nCOMMIT;\n",
     "\nSELECT 1;\n"),

    # Transaction wrapping a DO block
    ("BEGIN;\nDO $$ BEGIN RAISE NOTICE 'x'; END $$;\nCOMMIT;\n",
     "\nDO $$ BEGIN RAISE NOTICE 'x'; END $$;\n"),
]

def _norm(s):
    return re.sub(r"\s+", " ", s)


fails = 0
for raw, expected in cases:
    result = strip_tx(raw)
    if expected is None:
        ok = ("BEGIN" in result and "COMMIT" in result)
        print(("PASS" if ok else "FAIL"), "(inline: kept)" if ok else "(inline: CHANGED!)")
    else:
        ok = _norm(result) == _norm(expected)
        if not ok:
            fails += 1
            print(("PASS" if ok else "FAIL"), "(expected) ", repr(raw)[:40])
            print("   got:     ", repr(result)[:80])
            print("   expect:  ", repr(expected)[:80])
        else:
            print(("PASS" if ok else "FAIL"), "(expected)")

print("\nfails:", fails)
sys.exit(1 if fails else 0)
