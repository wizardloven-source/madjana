# supabase/_archive — Archive (NOT migrations)

This directory is **not** part of the migration chain. The Supabase CLI
reads `supabase/migrations/` only; nothing in here is ever applied, and
nothing here should ever be "restored" into `migrations/` by hand.

## What is in here

Hand-made backup copies of a migration that was being edited in place:

| File | Origin |
|---|---|
| `UPGRADE_currency_carton.sql.bak_20260920_163547` | auto-backup during the 2026-09-20 edit session |
| `UPGRADE_currency_carton.sql.bak_20260920_163826` | ditto, later in the same session |
| `UPGRADE_currency_carton.sql.bak_utf8_20260920_163636` | UTF-8 re-encode attempt |
| `UPGRADE_currency_carton.sql.orig_before_fix 20260920_163443` | copy taken before a fix |

## Why they were moved (2026-09-27, W0.3)

`supabase/tools/verify_schema_drift.py` flagged all four as drift. Three
problems with leaving them in `migrations/`:

1. **Misleading history** — four near-identical files make it impossible to
   tell which version of `UPGRADE_currency_carton.sql` is the real one.
2. **`supabase db reset` noise** — some CLI versions warn on unexpected
   files in the migrations directory; a stray file can abort a reset.
3. **Search pollution** — `git grep` and any repo-wide SQL scan returns
   four stale copies of the same statements, so a later reader cannot tell
   a live definition from a dead one.

They were **moved with `git mv`, not deleted**, so the history is intact and
this directory is the single place to look when asking "what did the
currency/carton migration look like on 2026-09-20?".

## Rules

- Never add a file here that is not a historical copy of something in
  `migrations/`.
- Never copy anything *out* of here into `migrations/`. If a change is
  needed, write a new timestamped migration.
- `verify_schema_drift.py` fails the build if any `.bak`/`.orig` file
  reappears inside `migrations/`.
