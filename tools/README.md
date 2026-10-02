# tools/

Local development helpers. Nothing here talks to Supabase — these only touch the
scratch PostgreSQL cluster on this machine.

## setup_test_pg.ps1

Prepares the local cluster that `supabase/tests/` builds against.

    .\tools\setup_test_pg.ps1          # run in an ADMINISTRATOR PowerShell

Four things it has to get right, each of which cost a round of debugging:

1. **The server runs as a service.** Backends crash with `0xC0000142`
   (`STATUS_DLL_INIT_FAILED`) when spawned from a normal user session on this
   machine, so the tests can only run against the already-running service.

2. **The `trust` lines go at the top of `pg_hba.conf`.** First match wins. An
   earlier attempt appended them at the bottom, where the existing
   `scram-sha-256` rule for `127.0.0.1` already matched — so trust silently
   never took effect and every connection failed with a password prompt.

3. **No BOM.** PowerShell 5.1's `Set-Content -Encoding UTF8` and
   `Add-Content -Encoding UTF8` both write a byte-order mark, and PostgreSQL
   cannot parse one — the server reports `could not load pg_hba.conf`, which
   reads like a crash rather than a config error. The script writes with an
   explicit `UTF8Encoding($false)` and then asserts the first three bytes.

4. **Port 5433**, which is this install's configured port, not the 5432 default
   the first draft assumed.

The `trust` rules are scoped to `127.0.0.1`/`::1` and exist only so the suites
can connect as `test_runner` without a password — which matters, because
`test_runner` does not have `BYPASSRLS`. Running those suites as the superuser
`postgres` makes every RLS isolation assertion pass vacuously.

## restore_pg_hba.ps1

Puts password authentication back.

    .\tools\restore_pg_hba.ps1         # run in an ADMINISTRATOR PowerShell

Restores `pg_hba.conf.bak_madjana`, which `setup_test_pg.ps1` writes before it
touches anything, so this is an exact revert rather than a guess. Run it when
the regression work is done — until then the trust lines are load-bearing and
`supabase/tests/*.py` cannot connect.

## The test database itself

Neither script creates the schema. That is `supabase/tests/run_all.py`:

    python supabase\tests\run_all.py            # rebuild + all suites
    python supabase\tests\run_all.py --no-build # reuse what is there