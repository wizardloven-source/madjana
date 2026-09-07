$ErrorActionPreference = "Stop"
$basePath = "C:\Users\MTC\Desktop\madjana\supabase\migrations"

# Read all original files with UTF-8 encoding
$files = @(
    "20250101000000_initial_schema.sql",
    "20260902_001_system_admin.sql",
    "20260902_002_rls_system_admin.sql",
    "20260902_003_mortality_atomicity.sql",
    "20260904_004_inventory_payments_version.sql",
    "20260904_005_sync_permissions_and_health.sql"
)

Write-Host "=== Reading original migration files ==="
$originals = @{}
foreach ($f in $files) {
    $path = Join-Path $basePath $f
    $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $originals[$f] = $content
    Write-Host "$f : $($content.Length) chars"
}

# Read the current UNIFIED file (structure reference)
$unifiedPath = Join-Path $basePath "UNIFIED_schema.sql"
$unified = [System.IO.File]::ReadAllText($unifiedPath, [System.Text.Encoding]::UTF8)
Write-Host "`nUNIFIED_schema.sql : $($unified.Length) chars"

# Extract all RAISE EXCEPTION messages from originals
Write-Host "`n=== RAISE EXCEPTION messages in originals ==="
$raisePattern = "RAISE EXCEPTION\s*'([^']*)'"
foreach ($f in $files) {
    $matches = [regex]::Matches($originals[$f], $raisePattern)
    foreach ($m in $matches) {
        $msg = $m.Groups[1].Value
        # Check if it contains Arabic
        $hasArabic = [regex]::IsMatch($msg, "[\u0600-\u06FF]")
        if ($hasArabic) {
            Write-Host "[$f] $msg"
        }
    }
}

# Extract all RAISE EXCEPTION messages from unified
Write-Host "`n=== RAISE EXCEPTION messages in unified ==="
$unifiedRaises = [regex]::Matches($unified, $raisePattern)
foreach ($m in $unifiedRaises) {
    $msg = $m.Groups[1].Value
    $hasArabic = [regex]::IsMatch($msg, "[\u0600-\u06FF]")
    if ($hasArabic) {
        Write-Host "[UNIFIED] ARABIC: $msg"
    } else {
        # Check if it looks garbled
        $hasQuestionMarks = $msg -match '\?{2,}'
        $hasReplacementChar = $msg -match '\uFFFD'
        if ($hasQuestionMarks -or $hasReplacementChar) {
            Write-Host "[UNIFIED] GARBLED: $msg"
        }
    }
}

# Extract all comment lines with Arabic from originals
Write-Host "`n=== Comment lines with Arabic in originals ==="
$commentPattern = "^--\s*(.*)$"
foreach ($f in $files) {
    $lines = $originals[$f] -split "`n"
    foreach ($line in $lines) {
        if ($line -match "^--\s*" -and [regex]::IsMatch($line, "[\u0600-\u06FF]")) {
            Write-Host "[$f] $($line.Trim())"
        }
    }
}

# Extract comment lines with Arabic from unified
Write-Host "`n=== Comment lines in unified ==="
$unifiedLines = $unified -split "`n"
$garbledComments = @()
$okComments = @()
foreach ($line in $unifiedLines) {
    if ($line -match "^--\s*" -and $line.Trim().Length -gt 3) {
        $trimmed = $line.Trim()
        if ([regex]::IsMatch($trimmed, "[\u0600-\u06FF]")) {
            $okComments += $trimmed
        } elseif ($trimmed -match "\?{2,}" -or $trimmed -match "\uFFFD") {
            $garbledComments += $trimmed
        }
    }
}
Write-Host "OK Arabic comments: $($okComments.Count)"
Write-Host "Garbled comments: $($garbledComments.Count)"
foreach ($c in $garbledComments) {
    Write-Host "  GARBLED: $c"
}

# Now build a mapping of garbled -> correct for RAISE EXCEPTION messages
Write-Host "`n=== Building replacement map ==="

# Collect all RAISE EXCEPTION messages from originals indexed by a normalized key
$messageMap = @{}
foreach ($f in $files) {
    $matches = [regex]::Matches($originals[$f], $raisePattern)
    foreach ($m in $matches) {
        $msg = $m.Groups[1].Value
        if ([regex]::IsMatch($msg, "[\u0600-\u06FF]")) {
            # Use the function context as a key too
            $funcMatches = [regex]::Matches($originals[$f], "(?:CREATE OR REPLACE FUNCTION|function\s+)(\w+)")
            $fullMatch = $m
            $idx = $m.Index
            # Find which function this is in
            $funcName = ""
            foreach ($fm in $funcMatches) {
                if ($fm.Index -lt $idx) {
                    $funcName = $fm.Groups[1].Value
                }
            }
            $key = "${funcName}::${msg}"
            $messageMap[$key] = $msg
            Write-Host "  MAP: $funcName -> $msg"
        }
    }
}
