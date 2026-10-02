# =============================================================================
#  setup_test_pg.ps1  --  run this in an ADMINISTRATOR PowerShell
# =============================================================================
#  Prepares the LOCAL scratch cluster (port 5433) that supabase/tests/*.py build
#  and run against. It touches ONLY the local test cluster -- never Supabase.
#
#  Why a script at all
#    1. Every local PostgreSQL backend crashes with 0xC0000142
#       (STATUS_DLL_INIT_FAILED) when spawned from the normal user session, so
#       the server must already be running as a service account.
#    2. The regression suites connect as `test_runner` with no password. That
#       needs two `trust` lines for 127.0.0.1 only, and pg_hba.conf is
#       FIRST-MATCH-WINS -- so they must go at the TOP, not appended at the
#       bottom (an earlier attempt appended them, where the scram-sha-256 rule
#       above already matched, so trust never took effect).
#    3. PowerShell 5.1's `Set-Content -Encoding UTF8` / `Add-Content -Encoding
#       UTF8` write a BOM, and PostgreSQL cannot parse a BOM in pg_hba.conf
#       ("could not load pg_hba.conf"). So the file is written with an
#       explicit no-BOM UTF8Encoding. This is the single most important detail.
#    4. The trust lines are reversible: the original file is kept as
#       pg_hba.conf.bak_madjana, and `restore_pg_hba.ps1` puts it back.
#
#  Usage:
#    .\setup_test_pg.ps1          # prepare / repair the local test cluster
#    .\restore_pg_hba.ps1         # put password auth back (do this at the end)
# =============================================================================

param(
    [int]$Port = 5433
)

$ErrorActionPreference = "Stop"

$PGBIN  = "C:\Program Files\PostgreSQL\15\bin"
$PGDATA = "C:\Program Files\PostgreSQL\15\data"
$hba    = Join-Path $PGDATA "pg_hba.conf"
$pgctl  = Join-Path $PGBIN  "pg_ctl.exe"
$psql   = Join-Path $PGBIN  "psql.exe"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Step($n, $msg) {
    Write-Host "`n=== $n. $msg ===" -ForegroundColor Cyan
}

if (-not (Test-Path $hba)) { throw "pg_hba.conf not found at $hba" }

# ── 1. make sure the server is up ───────────────────────────────────────────
Write-Step 1 "starting the service"
Get-Service postgresql-x64-15 -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ($_.Status -ne "Running") { Start-Service postgresql-x64-15 }
    }
Start-Sleep 4

# ── 2. pg_hba.conf: trust rules at the TOP, no BOM ──────────────────────────
Write-Step 2 "writing pg_hba.conf (trust at the top, no BOM)"

# Keep whatever we last backed up as the pristine copy so restore is exact.
if (-not (Test-Path "$hba.bak_madjana")) {
    Copy-Item $hba "$hba.bak_madjana" -Force
    Write-Host "  pristine backup written: pg_hba.conf.bak_madjana"
}

# Strip any previously-added madjana trust block and any trust lines we own, so
# this script is idempotent and re-runnable.
$lines = [System.IO.File]::ReadAllText($hba) -split "`r?`n"
$clean  = @($lines | Where-Object {
    $_ -notmatch "madjana TEST" -and
    $_ -notmatch "added by setup_test_pg" -and
    $_ -notmatch "^\s*host\s+all\s+all\s+(127\.0\.0\.1/32|::1/128)\s+trust"
})

$head = @(
    "# --- madjana TEST (local only; FIRST match wins, so this stays on top) ---",
    "host    all             all             127.0.0.1/32            trust",
    "host    all             all             ::1/128                 trust"
)
[System.IO.File]::WriteAllText($hba, (($head + $clean) -join "`r`n"), $utf8NoBom)

$first = [System.IO.File]::ReadAllBytes($hba)[0..2]
$hasBom = ($first[0] -eq 0xEF -and $first[1] -eq 0xBB -and $first[2] -eq 0xBF)
Write-Host ("  first bytes: {0}   BOM present: {1}" -f ($first -join ","), $hasBom)
if ($hasBom) { throw "pg_hba.conf still has a BOM; PostgreSQL will refuse to load it." }

& $pgctl -D $PGDATA reload | Out-Null
Start-Sleep 3

# ── 3. the madjana_test database ────────────────────────────────────────────
Write-Step 3 "ensuring madjana_test exists"
$exists = & $psql -h 127.0.0.1 -p $Port -U postgres -d postgres -w -tAc `
    "SELECT 1 FROM pg_database WHERE datname='madjana_test'"
if ("$exists" -eq "1") {
    Write-Host "  already exists -- reusing"
} else {
    & $psql -h 127.0.0.1 -p $Port -U postgres -d postgres -w -c "CREATE DATABASE madjana_test"
}

# ── 4. verify a backend can actually start and trust works ──────────────────
Write-Step 4 "verifying"
$v = & $psql -h 127.0.0.1 -p $Port -U postgres -d madjana_test -w -tAc "SELECT version()"
if ($LASTEXITCODE -ne 0 -or -not $v) {
    Write-Host "  STILL FAILING -- a backend cannot start." -ForegroundColor Red
    Write-Host "  Check: $PGDATA\logfile" -ForegroundColor Red
    exit 1
}

Write-Host "OK. Local test cluster ready." -ForegroundColor Green
Write-Host "  host      : 127.0.0.1"
Write-Host "  port      : $Port"
Write-Host "  user      : postgres        (no password needed here)"
Write-Host "  database  : madjana_test"
Write-Host ""
Write-Host "Next:"
Write-Host "  python supabase\tests\run_all.py     # rebuild + every suite"
Write-Host ""
Write-Host "When finished, run restore_pg_hba.ps1 to put password auth back." -ForegroundColor DarkGray