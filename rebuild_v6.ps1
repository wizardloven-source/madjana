$ErrorActionPreference = "Stop"
$basePath = "C:\Users\MTC\Desktop\madjana\supabase\migrations"
$utf8 = [System.Text.Encoding]::UTF8

function Test-HasMojibake($s) {
    $hasArabic = [regex]::IsMatch($s, "[\u0600-\u06FF]")
    $hasLatinSpecial = [regex]::IsMatch($s, "[\u00B0-\u00FF\u2018-\u2026\u2013\u2014\u201C\u201D\u2020\u2021\u0152\u0153]")
    return ($hasArabic -and $hasLatinSpecial)
}

function Get-AsciiSignature($s) {
    $result = [regex]::Replace($s, "[^\x00-\x7F]", "")
    $result = $result -replace "\s+", " "
    return $result.Trim()
}

# Read all files
$origFiles = @(
    "20250101000000_initial_schema.sql",
    "20260902_001_system_admin.sql",
    "20260902_002_rls_system_admin.sql",
    "20260902_003_mortality_atomicity.sql",
    "20260904_004_inventory_payments_version.sql",
    "20260904_005_sync_permissions_and_health.sql"
)

$origTexts = @{}
foreach ($f in $origFiles) {
    $path = Join-Path $basePath $f
    $origTexts[$f] = [System.IO.File]::ReadAllText($path, $utf8)
}

$unifiedPath = Join-Path $basePath "UNIFIED_schema.sql"
$unified = [System.IO.File]::ReadAllText($unifiedPath, $utf8)
Write-Host "UNIFIED length: $($unified.Length)"

# ====================================================================
# Step 1: Collect ALL unique Arabic-containing strings from originals
# ====================================================================
$origArabicStrings = @{}  # signature -> correct string

foreach ($f in $origFiles) {
    $lines = $origTexts[$f] -split "`n"
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if (-not [regex]::IsMatch($line, "[\u0600-\u06FF]")) { continue }
        
        # Extract RAISE EXCEPTION messages
        if ($line -match "(RAISE EXCEPTION\s*'[^']+')") {
            $match = $Matches[1]
            $sig = Get-AsciiSignature $match
            if ($sig.Length -ge 3 -and -not $origArabicStrings.ContainsKey($sig)) {
                $origArabicStrings[$sig] = $match
            }
        }
        
        # Extract comment lines
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("--") -and $trimmed.Length -gt 5) {
            $sig = Get-AsciiSignature $trimmed
            if ($sig.Length -ge 3 -and -not $origArabicStrings.ContainsKey($sig)) {
                $origArabicStrings[$sig] = $trimmed
            }
        }
        
        # Extract individual quoted strings (for INSERT data etc.)
        $quotedMatches = [regex]::Matches($line, "'([^']*[\u0600-\u06FF][^']*)'")
        foreach ($qm in $quotedMatches) {
            $qstr = $qm.Value
            $sig = Get-AsciiSignature $qstr
            if ($sig.Length -ge 3 -and -not $origArabicStrings.ContainsKey($sig)) {
                $origArabicStrings[$sig] = $qstr
            }
        }
        
        # Extract inline comments after SQL (e.g., NULL; -- comment)
        if ($line -match "--\s*(.+[\u0600-\u06FF].+)$") {
            $comment = $Matches[1].Trim()
            $sig = Get-AsciiSignature $comment
            if ($sig.Length -ge 3 -and -not $origArabicStrings.ContainsKey($sig)) {
                $origArabicStrings[$sig] = $comment
            }
        }
    }
}

Write-Host "Original Arabic string signatures: $($origArabicStrings.Count)"

# ====================================================================
# Step 2: Find all mojibake strings in UNIFIED and build replacement map
# ====================================================================
$replacementMap = @{}  # mojibake -> correct

# Collect all mojibake segments from UNIFIED
$unifiedLines = $unified -split "`n"
$mojibakeSegments = @()

for ($i = 0; $i -lt $unifiedLines.Length; $i++) {
    $line = $unifiedLines[$i]
    if (-not (Test-HasMojibake $line)) { continue }
    
    # Extract RAISE EXCEPTION messages
    if ($line -match "(RAISE EXCEPTION\s*'([^']+)')") {
        $full = $Matches[1]
        $msg = $Matches[2]
        if (Test-HasMojibake $msg) {
            $sig = Get-AsciiSignature $msg
            if ($sig.Length -ge 3) {
                $mojibakeSegments += @{ Type="raise"; Line=$i; Mojibake=$msg; Sig=$sig; Full=$full }
            }
        }
    }
    
    # Extract comment lines
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith("--") -and $trimmed.Length -gt 5 -and (Test-HasMojibake $trimmed)) {
        $sig = Get-AsciiSignature $trimmed
        if ($sig.Length -ge 3) {
            $mojibakeSegments += @{ Type="comment"; Line=$i; Mojibake=$trimmed; Sig=$sig; Full=$trimmed }
        }
    }
    
    # Extract quoted strings
    $quotedMatches = [regex]::Matches($line, "'([^']*[\u0600-\u06FF][^']*)'")
    foreach ($qm in $quotedMatches) {
        $qstr = $qm.Value
        $inner = $Matches[1]
        if (Test-HasMojibake $inner) {
            $sig = Get-AsciiSignature $inner
            if ($sig.Length -ge 3) {
                $mojibakeSegments += @{ Type="quoted"; Line=$i; Mojibake=$inner; Sig=$sig; Full=$qstr }
            }
        }
    }
    
    # Extract inline comments
    if ($line -match "--\s*(.+)$" -and (Test-HasMojibake $line)) {
        $comment = $Matches[1].Trim()
        if (Test-HasMojibake $comment) {
            $sig = Get-AsciiSignature $comment
            if ($sig.Length -ge 3) {
                $mojibakeSegments += @{ Type="inline"; Line=$i; Mojibake=$comment; Sig=$sig; Full=$comment }
            }
        }
    }
}

Write-Host "Mojibake segments found: $($mojibakeSegments.Count)"

# Build replacement map
foreach ($seg in $mojibakeSegments) {
    if ($replacementMap.ContainsKey($seg.Mojibake)) { continue }
    
    if ($origArabicStrings.ContainsKey($seg.Sig)) {
        $replacementMap[$seg.Mojibake] = $origArabicStrings[$seg.Sig]
    }
}

Write-Host "Replacement map: $($replacementMap.Count) entries"

# ====================================================================
# Step 3: Apply replacements (string.Replace on the whole file)
# ====================================================================
$corrected = $unified
$applied = 0
foreach ($mojibake in $replacementMap.Keys) {
    $correct = $replacementMap[$mojibake]
    if ($corrected.Contains($mojibake)) {
        $corrected = $corrected.Replace($mojibake, $correct)
        $applied++
    }
}
Write-Host "Applied $applied replacements"

# ====================================================================
# Step 4: Write and verify
# ====================================================================
Write-Host "`nWriting corrected UNIFIED_schema.sql..."
[System.IO.File]::WriteAllText($unifiedPath, $corrected, $utf8)
Write-Host "Written $($corrected.Length) chars"

$verify = [System.IO.File]::ReadAllText($unifiedPath, $utf8)
Write-Host "`n=== Verification ==="
Write-Host "Functions: $([regex]::Matches($verify, 'CREATE OR REPLACE FUNCTION').Count)"
Write-Host "Tables: $([regex]::Matches($verify, 'CREATE TABLE').Count)"
Write-Host "Policies: $([regex]::Matches($verify, 'CREATE POLICY').Count)"
Write-Host "Triggers: $([regex]::Matches($verify, 'CREATE TRIGGER').Count)"

# Count remaining mojibake
$verifyLines = $verify -split "`n"
$remainingMojibake = 0
for ($i = 0; $i -lt $verifyLines.Length; $i++) {
    if (Test-HasMojibake $verifyLines[$i]) {
        $remainingMojibake++
        if ($remainingMojibake -le 30) {
            $preview = $verifyLines[$i].Trim().Substring(0, [Math]::Min(120, $verifyLines[$i].Trim().Length))
            Write-Host "  REMAINING L$($i+1): $preview"
        }
    }
}
Write-Host "Total remaining mojibake: $remainingMojibake"

$arabicCount = ([regex]::Matches($verify, "[\u0600-\u06FF]")).Count
Write-Host "Arabic characters: $arabicCount"

Write-Host "`n=== DONE ==="
