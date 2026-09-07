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
# Build comprehensive replacement map
# ====================================================================
# Strategy: For each unique mojibake string in UNIFIED, find the correct
# version from originals by matching ASCII signature.

# First, collect all unique mojibake strings from UNIFIED
$mojibakeStrings = @{}  # mojibake -> count
$unifiedLines = $unified -split "`n"
for ($i = 0; $i -lt $unifiedLines.Length; $i++) {
    $line = $unifiedLines[$i]
    if (Test-HasMojibake $line) {
        # Extract individual mojibake segments (strings in quotes, or entire comment lines)
        if ($line -match "RAISE EXCEPTION\s*'([^']*)'") {
            $msg = $Matches[1]
            if (Test-HasMojibake $msg) {
                if (-not $mojibakeStrings.ContainsKey($msg)) { $mojibakeStrings[$msg] = 0 }
                $mojibakeStrings[$msg]++
            }
        }
        if ($line.Trim() -match "^--" -and (Test-HasMojibake $line)) {
            $trimmed = $line.Trim()
            if (-not $mojibakeStrings.ContainsKey($trimmed)) { $mojibakeStrings[$trimmed] = 0 }
            $mojibakeStrings[$trimmed]++
        }
    }
}

Write-Host "Unique mojibake strings: $($mojibakeStrings.Count)"

# Now build the mapping: for each mojibake string, find the correct version
# from originals by matching ASCII signature
$replacementMap = @{}  # mojibake -> correct

foreach ($mojibake in $mojibakeStrings.Keys) {
    $sig = Get-AsciiSignature $mojibake
    if ($sig.Length -lt 2) { continue }
    
    # Search in originals
    $bestMatch = $null
    $bestScore = 0
    
    foreach ($f in $origFiles) {
        $text = $origTexts[$f]
        $origLines = $text -split "`n"
        
        for ($i = 0; $i -lt $origLines.Length; $i++) {
            $origLine = $origLines[$i]
            if (-not [regex]::IsMatch($origLine, "[\u0600-\u06FF]")) { continue }
            
            # Check if this is a RAISE EXCEPTION or comment
            $origMsg = ""
            $isRaise = $false
            $isComment = $false
            
            if ($origLine -match "RAISE EXCEPTION\s*'([^']*)'") {
                $origMsg = $Matches[1]
                $isRaise = $true
            } elseif ($origLine.Trim() -match "^--" -and $origLine.Trim().Length -gt 3) {
                $origMsg = $origLine.Trim()
                $isComment = $true
            }
            
            if ($origMsg -eq "") { continue }
            
            $origSig = Get-AsciiSignature $origMsg
            if ($origSig -eq $sig) {
                $score = $origSig.Length
                if ($score -gt $bestScore) {
                    $bestScore = $score
                    $bestMatch = $origMsg
                }
            }
        }
    }
    
    if ($bestMatch -ne $null) {
        $replacementMap[$mojibake] = $bestMatch
    }
}

Write-Host "Replacement map: $($replacementMap.Count) entries"

# Apply replacements
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
# Additional: specific medicine catalog replacements
# ====================================================================
# The medicine catalog lines have format: ('Arabic name (English)', 'type', days, 'Arabic note')
# Match by the English parts and type/days which are ASCII

$origMedLines = @()
$origText = $origTexts["20250101000000_initial_schema.sql"]
$origOLines = $origText -split "`n"
$inMed = $false
for ($i = 0; $i -lt $origOLines.Length; $i++) {
    if ($origOLines[$i] -match "INSERT INTO medicines_catalog") { $inMed = $true }
    if ($inMed -and $origOLines[$i] -match "^\('") {
        $origMedLines += $origOLines[$i].Trim()
    }
    if ($inMed -and $origOLines[$i] -match "^\);") { break }
}

# Find and replace medicine catalog in UNIFIED
$unifiedMedLines = @()
for ($i = 0; $i -lt $unifiedLines.Length; $i++) {
    if ($unifiedLines[$i] -match "INSERT INTO medicines_catalog") {
        # Found the start - now replace the VALUES block
        $j = $i + 1
        while ($j -lt $unifiedLines.Length -and -not ($unifiedLines[$j] -match "^\);")) {
            $j++
        }
        # $j is now at the ); line
        # Replace lines i+1 through j-1 with original med lines
        $newLines = @()
        $newLines += $unifiedLines[0..$i]
        foreach ($ml in $origMedLines) {
            $newLines += "    $ml"
        }
        $newLines += $unifiedLines[$j..($unifiedLines.Length-1)]
        $unifiedLines = $newLines
        $corrected = $unifiedLines -join "`n"
        Write-Host "Medicine catalog replaced (lines $($i+1) to $($j))"
        break
    }
}

# Write the corrected file
Write-Host "`nWriting corrected UNIFIED_schema.sql..."
[System.IO.File]::WriteAllText($unifiedPath, $corrected, $utf8)

# ====================================================================
# Verification
# ====================================================================
$verify = [System.IO.File]::ReadAllText($unifiedPath, $utf8)
Write-Host "`n=== Verification ==="
Write-Host "Length: $($verify.Length)"
Write-Host "Functions: $([regex]::Matches($verify, 'CREATE OR REPLACE FUNCTION').Count)"
Write-Host "Tables: $([regex]::Matches($verify, 'CREATE TABLE').Count)"
Write-Host "Policies: $([regex]::Matches($verify, 'CREATE POLICY').Count)"
Write-Host "Triggers: $([regex]::Matches($verify, 'CREATE TRIGGER').Count)"

# Count $$ pairs properly - only count $$ that appear on their own line or at start/end of function body
$lineCount = [regex]::Matches($verify, '(?m)^\s*\$\$\s*$').Count
Write-Host "Line-only `$\$` occurrences: $lineCount"

# Count remaining mojibake
$verifyLines = $verify -split "`n"
$remainingMojibake = 0
for ($i = 0; $i -lt $verifyLines.Length; $i++) {
    if (Test-HasMojibake $verifyLines[$i]) {
        $remainingMojibake++
        if ($remainingMojibake -le 30) {
            Write-Host "  REMAINING L$($i+1): $($verifyLines[$i].Trim().Substring(0, [Math]::Min(120, $verifyLines[$i].Trim().Length)))"
        }
    }
}
Write-Host "Total remaining mojibake: $remainingMojibake"

# Arabic chars
$arabicCount = ([regex]::Matches($verify, "[\u0600-\u06FF]")).Count
Write-Host "Arabic characters: $arabicCount"

# Duplicate functions
$funcNames = [regex]::Matches($verify, 'CREATE OR REPLACE FUNCTION\s+(?:public\.)?(\w+)') | ForEach-Object { $_.Groups[1].Value }
$uniqueFuncs = $funcNames | Sort-Object -Unique
Write-Host "Functions: $($uniqueFuncs.Count) unique / $($funcNames.Count) total"

Write-Host "`n=== DONE ==="
