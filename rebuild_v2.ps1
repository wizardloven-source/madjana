$ErrorActionPreference = "Stop"
$basePath = "C:\Users\MTC\Desktop\madjana\supabase\migrations"
$utf8 = [System.Text.Encoding]::UTF8

# ====================================================================
# STEP 1: Read all original files
# ====================================================================
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
    Write-Host "Loaded $f : $($origTexts[$f].Length) chars"
}

# Read UNIFIED
$unifiedPath = Join-Path $basePath "UNIFIED_schema.sql"
$unified = [System.IO.File]::ReadAllText($unifiedPath, $utf8)
Write-Host "Loaded UNIFIED_schema.sql : $($unified.Length) chars"

# ====================================================================
# STEP 2: Build replacement map from originals
# ====================================================================

# Helper: check if a string contains Arabic-like characters (U+0600-U+06FF)
function Test-HasArabic($s) {
    return [regex]::IsMatch($s, "[\u0600-\u06FF]")
}

# Helper: check if a string has mojibake (Latin chars mixed with Arabic range chars
# in a way that looks corrupted)
function Test-IsMojibake($s) {
    # Mojibake from this specific corruption has chars like ظ ط mixed with Latin
    if ($s -match '[\u00B0-\u00FF\u2018-\u2026].*[\u0600-\u06FF]' -or
        $s -match '[\u0600-\u06FF].*[\u00B0-\u00FF\u2018-\u2026]') {
        return $true
    }
    return $false
}

# Extract all RAISE EXCEPTION messages from originals
$raisePattern = "(RAISE EXCEPTION\s*')([^']+)("
$origExceptions = @{}
foreach ($f in $origFiles) {
    $text = $origTexts[$f]
    $matches = [regex]::Matches($text, "RAISE EXCEPTION\s*'([^']*)'")
    foreach ($m in $matches) {
        $msg = $m.Groups[1].Value
        if (Test-HasArabic $msg) {
            $key = $msg
            if (-not $origExceptions.ContainsKey($key)) {
                $origExceptions[$key] = $msg
            }
        }
    }
}
Write-Host "`nUnique Arabic RAISE EXCEPTION messages in originals: $($origExceptions.Count)"

# Extract all comment lines with Arabic from originals
$origComments = @{}
foreach ($f in $origFiles) {
    $lines = $origTexts[$f] -split "`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("--") -and $trimmed.Length -gt 5) {
            if (Test-HasArabic $trimmed) {
                # Use first 40 chars as key for matching
                $key = $trimmed
                if (-not $origComments.ContainsKey($key)) {
                    $origComments[$key] = $trimmed
                }
            }
        }
    }
}
Write-Host "Unique Arabic comment lines in originals: $($origComments.Count)"

# ====================================================================
# STEP 3: Apply replacements to UNIFIED
# ====================================================================

# Count replacements
$exceptionReplacements = 0
$commentReplacements = 0

# Replace RAISE EXCEPTION messages in UNIFIED
# For each RAISE EXCEPTION in UNIFIED with mojibake, try to find matching original
$unifiedLines = $unified -split "`n"
$newLines = @()

# Build a map: try to match mojibake RAISE EXCEPTION by the error code prefix
$unifiedRaisePattern = "RAISE EXCEPTION\s*'([^']*)'"

# First, let's identify which RAISE EXCEPTION messages in UNIFIED are mojibake
$mojibakeExceptions = @()
for ($i = 0; $i -lt $unifiedLines.Length; $i++) {
    $line = $unifiedLines[$i]
    if ($line -match $unifiedRaisePattern) {
        $msg = $Matches[1]
        # Check if it has the mojibake pattern (Arabic-like chars that are actually corrupted)
        # Mojibake has chars in U+0600-U+06FF range mixed with Latin chars like B8, A7, etc.
        # But we need to detect CORRECT Arabic vs MOJIBAKE Arabic
        # Correct Arabic: pure Arabic chars + spaces + punctuation
        # Mojibake: Arabic chars mixed with random Latin/special chars
        
        # Simple heuristic: if the message has chars outside normal Arabic range
        # (like U+00B0-U+00FF, U+2018-U+2026, etc.), it's mojibake
        $hasLatin = [regex]::IsMatch($msg, "[\u00B0-\u00FF\u2018-\u2026\u2013\u2014]")
        $hasArabic = [regex]::IsMatch($msg, "[\u0600-\u06FF]")
        
        if ($hasArabic -and $hasLatin) {
            # Likely mojibake
            $mojibakeExceptions += @{ Line = $i; Msg = $msg; Full = $line }
        } elseif ($hasArabic -and -not $hasLatin) {
            # Could be correct Arabic - check if it exists in originals
            $found = $false
            foreach ($origKey in $origExceptions.Keys) {
                if ($origKey -eq $msg) { $found = $true; break }
            }
            if (-not $found) {
                # Not in originals, might still be mojibake
                $mojibakeExceptions += @{ Line = $i; Msg = $msg; Full = $line }
            }
        }
    }
}
Write-Host "`nMojibake RAISE EXCEPTION in UNIFIED: $($mojibakeExceptions.Count)"

# Now try to match each mojibake exception with an original
# Strategy: extract the error code prefix (e.g., AUTHORIZATION_DENIED, VALIDATION_ERROR)
# and match by context (function name, etc.)
$replacementMap = @{}

foreach ($exc in $mojibakeExceptions) {
    $msg = $exc.Msg
    $lineIdx = $exc.Line
    
    # Extract error code prefix
    $errorCode = ""
    if ($msg -match "^([A-Z_]+):") {
        $errorCode = $Matches[1]
    }
    
    # Find the function this line is in by looking backwards
    $funcName = ""
    for ($j = $lineIdx; $j -ge 0; $j--) {
        if ($unifiedLines[$j] -match "(?:CREATE OR REPLACE FUNCTION|function\s+)(\w+)") {
            $funcName = $Matches[1]
            break
        }
    }
    
    # Try to find matching original by error code + function context
    $bestMatch = $null
    $bestScore = 0
    
    foreach ($origKey in $origExceptions.Keys) {
        $origMsg = $origExceptions[$origKey]
        
        # Match by error code
        $origCode = ""
        if ($origMsg -match "^([A-Z_]+):") {
            $origCode = $Matches[1]
        }
        
        if ($errorCode -ne "" -and $origCode -eq $errorCode) {
            # Same error code - check if function context matches
            # Find which original function this message is in
            $origFuncName = ""
            $origText = $null
            foreach ($f in $origFiles) {
                $idx = $origTexts[$f].IndexOf($origMsg)
                if ($idx -ge 0) {
                    $origText = $origTexts[$f]
                    # Find function
                    for ($k = $idx; $k -ge 0; $k--) {
                        $charBefore = if ($k -gt 0) { $origText[$k-1] } else { "`n" }
                        if ($k -ge 29 -and $origText.Substring($k - 29, 30) -match "(?:CREATE OR REPLACE FUNCTION|function\s+)(\w+)") {
                            $origFuncName = $Matches[1]
                            break
                        }
                    }
                    break
                }
            }
            
            $score = 1
            if ($origFuncName -eq $funcName) { $score = 10 }
            
            if ($score -gt $bestScore) {
                $bestScore = $score
                $bestMatch = $origMsg
            }
        }
    }
    
    if ($bestMatch -ne $null) {
        $replacementMap[$msg] = $bestMatch
        Write-Host "  MAP: $funcName/$errorCode -> $bestMatch"
    } else {
        Write-Host "  NO MATCH: $funcName/$errorCode : $msg"
    }
}

Write-Host "`nReplacement map size: $($replacementMap.Count)"

# Apply the replacement map
foreach ($mojibake in $replacementMap.Keys) {
    $correct = $replacementMap[$mojibake]
    $unified = $unified.Replace($mojibake, $correct)
    $exceptionReplacements++
}
Write-Host "Exception replacements applied: $exceptionReplacements"

# Now handle comment lines
# For each comment in UNIFIED that has mojibake, find matching original comment
$mojibakeComments = @()
$commentLines = $unified -split "`n"
for ($i = 0; $i -lt $commentLines.Length; $i++) {
    $line = $commentLines[$i].Trim()
    if ($line.StartsWith("--") -and $line.Length -gt 5) {
        # Check if it has mojibake pattern
        $hasLatin = [regex]::IsMatch($line, "[\u00B0-\u00FF\u2018-\u2026\u2013\u2014]")
        $hasArabic = [regex]::IsMatch($line, "[\u0600-\u06FF]")
        
        if ($hasArabic -and $hasLatin) {
            $mojibakeComments += @{ Line = $i; Text = $line }
        }
    }
}
Write-Host "`nMojibake comment lines in UNIFIED: $($mojibakeComments.Count)"

# Try to match mojibake comments with originals
$commentReplacements2 = 0
foreach ($mc in $mojibakeComments) {
    $mText = $mc.Text
    
    # Try to find a matching original comment
    # Strategy: extract the section number or key English words
    $sectionNum = ""
    if ($mText -match "^\s*--\s*(\d+)") {
        $sectionNum = $Matches[1]
    }
    
    # Try to find match by looking for comments with same structure
    $bestMatch = $null
    $bestScore = 0
    
    foreach ($origKey in $origComments.Keys) {
        $origComment = $origComments[$origKey]
        
        # Compare structure: same section number, similar length
        $origSection = ""
        if ($origComment -match "^\s*--\s*(\d+)") {
            $origSection = $Matches[1]
        }
        
        $score = 0
        if ($sectionNum -ne "" -and $origSection -eq $sectionNum) { $score += 5 }
        
        # Check if the non-Arabic parts match (English words, numbers, etc.)
        $mEnglish = [regex]::Replace($mText, "[\u0600-\u06FF\u00B0-\u00FF\u2018-\u2026]", "")
        $oEnglish = [regex]::Replace($origComment, "[\u0600-\u06FF\u00B0-\u00FF\u2018-\u2026]", "")
        
        if ($mEnglish -eq $oEnglish) { $score += 20 }
        
        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestMatch = $origComment
        }
    }
    
    if ($bestMatch -ne $null -and $bestScore -ge 5) {
        # Replace this comment line
        $indent = ""
        if ($mc.Text -match "^(\s*)--") { $indent = $Matches[1] }
        $newLine = "$indent$bestMatch"
        $unified = $unified.Replace($mc.Text, $newLine)
        $commentReplacements2++
    }
}
Write-Host "Comment replacements applied: $commentReplacements2"

# ====================================================================
# STEP 4: Handle remaining mojibake patterns
# ====================================================================
# There may be remaining mojibake in inline strings, variable comments, etc.
# Let's check for remaining mojibake patterns

$remainingLines = $unified -split "`n"
$remainingMojibake = 0
for ($i = 0; $i -lt $remainingLines.Length; $i++) {
    $line = $remainingLines[$i]
    $hasLatin = [regex]::IsMatch($line, "[\u00B0-\u00FF\u2018-\u2026\u2013\u2014]")
    $hasArabic = [regex]::IsMatch($line, "[\u0600-\u06FF]")
    if ($hasArabic -and $hasLatin) {
        $remainingMojibake++
        if ($remainingMojibake -le 20) {
            Write-Host "  REMAINING L$($i+1): $($line.Trim().Substring(0, [Math]::Min(120, $line.Trim().Length)))"
        }
    }
}
Write-Host "`nRemaining mojibake lines: $remainingMojibake"

# ====================================================================
# STEP 5: Write the corrected file
# ====================================================================
Write-Host "`n=== Writing corrected UNIFIED_schema.sql ==="
[System.IO.File]::WriteAllText($unifiedPath, $unified, $utf8)
Write-Host "Written $($unified.Length) chars"

# ====================================================================
# STEP 6: Verification
# ====================================================================
$verify = [System.IO.File]::ReadAllText($unifiedPath, $utf8)
Write-Host "`n=== Verification ==="
Write-Host "Functions: $([regex]::Matches($verify, 'CREATE OR REPLACE FUNCTION').Count)"
Write-Host "Tables: $([regex]::Matches($verify, 'CREATE TABLE').Count)"
Write-Host "Policies: $([regex]::Matches($verify, 'CREATE POLICY').Count)"
Write-Host "Triggers: $([regex]::Matches($verify, 'CREATE TRIGGER').Count)"
$ dollarPairs = [regex]::Matches($verify, '\$').Count
Write-Host "`$ pairs: $($dollarPairs / 2)"

# Check for garbled text
$garbled = [regex]::Matches($verify, '[\u2018\u2019\u201C\u201D]')
Write-Host "Smart quotes found: $($garbled.Count)"

# Check for remaining mojibake
$finalLines = $verify -split "`n"
$finalMojibake = 0
for ($i = 0; $i -lt $finalLines.Length; $i++) {
    $line = $finalLines[$i]
    $hasLatin = [regex]::IsMatch($line, "[\u00B0-\u00FF\u2018-\u2026\u2013\u2014]")
    $hasArabic = [regex]::IsMatch($line, "[\u0600-\u06FF]")
    if ($hasArabic -and $hasLatin) {
        $finalMojibake++
    }
}
Write-Host "Remaining mojibake lines: $finalMojibake"

# Check Arabic char count
$arabicCount = ([regex]::Matches($verify, "[\u0600-\u06FF]")).Count
Write-Host "Arabic characters: $arabicCount"

# Verify no duplicate functions
$funcNames = [regex]::Matches($verify, 'CREATE OR REPLACE FUNCTION (\w+)') | ForEach-Object { $_.Groups[1].Value }
$uniqueFuncs = $funcNames | Sort-Object -Unique
Write-Host "Unique functions: $($uniqueFuncs.Count) / Total: $($funcNames.Count)"
if ($funcNames.Count -ne $uniqueFuncs.Count) {
    Write-Host "WARNING: Duplicate functions detected!"
    $funcNames | Sort-Object | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object {
        Write-Host "  DUPLICATE: $($_.Name) (x$($_.Count))"
    }
}

# Check key functions are complete
$bootstrap = $verify.IndexOf("bootstrap_create_farm_and_manager")
if ($bootstrap -ge 0) {
    $nearby = $verify.Substring([Math]::Max(0, $bootstrap - 200), [Math]::Min(500, $verify.Length - [Math]::Max(0, $bootstrap - 200)))
    $dollarCount = ([regex]::Matches($nearby, '\$')).Count
    Write-Host "bootstrap_create_farm_and_manager nearby `$ count: $dollarCount"
}

$calcDispatch = $verify.IndexOf("calc_dispatch_total")
if ($calcDispatch -ge 0) {
    $nearby2 = $verify.Substring([Math]::Max(0, $calcDispatch - 200), [Math]::Min(500, $verify.Length - [Math]::Max(0, $calcDispatch - 200)))
    $dollarCount2 = ([regex]::Matches($nearby2, '\$')).Count
    Write-Host "calc_dispatch_total nearby `$ count: $dollarCount2"
}
