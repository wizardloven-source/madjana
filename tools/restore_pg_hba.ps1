# =============================================================================
#  restore_pg_hba.ps1  --  run this in an ADMINISTRATOR PowerShell
# =============================================================================
#  Undoes setup_test_pg.ps1: puts pg_hba.conf back to password-only auth so the
#  local cluster is no longer accepting password-less connections.
#
#  Do this when the regression work is done. Until then the trust lines are
#  load-bearing: supabase/tests/*.py connect as `postgres` with no password.
#
#  Usage:
#    .\restore_pg_hba.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

$PGDATA = "C:\Program Files\PostgreSQL\15\data"
$hba    = Join-Path $PGDATA "pg_hba.conf"
$bak    = Join-Path $PGDATA "pg_hba.conf.bak_madjana"

if (-not (Test-Path $bak)) {
    throw "no pristine backup at $bak -- refusing to guess. Inspect $hba by hand."
}

Write-Host "`n=== 1. restoring $bak ===" -ForegroundColor Cyan

# The backup was taken before we ever added trust lines, so it already has the
# original scram-sha-256 rules. Copy it back verbatim.
Copy-Item $bak $hba -Force

# A BOM here means PostgreSQL cannot load the file at all, and the failure mode
# ("could not load pg_hba.conf") looks like a server crash rather than a config
# problem -- so strip it if the backup happened to carry one.
$raw = [System.IO.File]::ReadAllText($hba).TrimStart([char]0xFEFF)
[System.IO.File]::WriteAllText($hba, $raw, (New-Object System.Text.UTF8Encoding($false)))

$first = [System.IO.File]::ReadAllBytes($hba)[0..2]
if ($first[0] -eq 0xEF -and $first[1] -eq 0xBB -and $first[2] -eq 0xBF) {
    throw "still has a BOM after restore; PostgreSQL will refuse to start."
}
Write-Host "  restored (no BOM)"

Write-Host "`n=== 2. reloading ===" -ForegroundColor Cyan
& (Join-Path "C:\Program Files\PostgreSQL\15\bin" "pg_ctl.exe") -D $PGDATA reload | Out-Null
Start-Sleep 3

Write-Host "`n=== 3. verifying no trust lines remain ===" -ForegroundColor Cyan
$left = Select-String -Path $hba -Pattern "^\s*host\s+all\s+all\s+(127\.0\.0\.1/32|::1/128)\s+trust"
if ($left) {
    $left | ForEach-Object { Write-Host "  still present: $($_.Line)" -ForegroundColor Red }
    throw "trust lines survived the restore; inspect $hba manually."
}
Write-Host "  none -- password auth is back in force"

Write-Host "`nDONE. Password-less local access is disabled." -ForegroundColor Green