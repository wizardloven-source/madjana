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

# ====================================================================
# STEP 1: Read all files
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
}

$unifiedPath = Join-Path $basePath "UNIFIED_schema.sql"
$unified = [System.IO.File]::ReadAllText($unifiedPath, $utf8)
Write-Host "Loaded all files. UNIFIED length: $($unified.Length)"

# ====================================================================
# STEP 2: Replace RAISE EXCEPTION messages
# ====================================================================
$origRaise = @()
foreach ($f in $origFiles) {
    $text = $origTexts[$f]
    $lines = $text -split "`n"
    $currentFunc = ""
    $funcRaiseCount = @{}
    
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line -match "CREATE OR REPLACE FUNCTION\s+(?:public\.)?(\w+)") {
            $currentFunc = $Matches[1]
            if (-not $funcRaiseCount.ContainsKey($currentFunc)) { $funcRaiseCount[$currentFunc] = 0 }
        }
        if ($line -match "RAISE EXCEPTION\s*'([^']*)'") {
            $msg = $Matches[1]
            if ([regex]::IsMatch($msg, "[\u0600-\u06FF]")) {
                $pos = $funcRaiseCount[$currentFunc]
                $funcRaiseCount[$currentFunc] = $pos + 1
                $errorCode = ""
                if ($msg -match "^([A-Z_]+):") { $errorCode = $Matches[1] }
                $origRaise += @{ FuncName=$currentFunc; Position=$pos; Message=$msg; ErrorCode=$errorCode; File=$f }
            }
        }
    }
}

$unifiedLines = $unified -split "`n"
$currentFunc = ""
$funcRaiseCount = @{}
$replaced = 0

for ($i = 0; $i -lt $unifiedLines.Length; $i++) {
    $line = $unifiedLines[$i]
    if ($line -match "CREATE OR REPLACE FUNCTION\s+(?:public\.)?(\w+)") {
        $currentFunc = $Matches[1]
        if (-not $funcRaiseCount.ContainsKey($currentFunc)) { $funcRaiseCount[$currentFunc] = 0 }
    }
    if ($line -match "RAISE EXCEPTION\s*'([^']*)'") {
        $msg = $Matches[1]
        if (Test-HasMojibake $msg) {
            $pos = $funcRaiseCount[$currentFunc]
            $funcRaiseCount[$currentFunc] = $pos + 1
            $errorCode = ""
            if ($msg -match "^([A-Z_]+):") { $errorCode = $Matches[1] }
            
            $match = $origRaise | Where-Object { $_.FuncName -eq $currentFunc -and $_.Position -eq $pos } | Select-Object -First 1
            if ($match -eq $null -and $errorCode -ne "") {
                $match = $origRaise | Where-Object { $_.FuncName -eq $currentFunc -and $_.ErrorCode -eq $errorCode } | Select-Object -First 1
            }
            
            if ($match -ne $null) {
                $unifiedLines[$i] = $line.Replace($msg, $match.Message)
                $replaced++
            }
        } elseif ([regex]::IsMatch($msg, "[\u0600-\u06FF]")) {
            $pos = $funcRaiseCount[$currentFunc]
            $funcRaiseCount[$currentFunc] = $pos + 1
        }
    }
}
Write-Host "RAISE EXCEPTION replacements: $replaced"

# ====================================================================
# STEP 3: Direct replacements for medicine catalog and known patterns
# ====================================================================
$directReplacements = 0

# Medicine catalog: read from original
$medOrig = $origTexts["20250101000000_initial_schema.sql"]
$medOrigLines = $medOrig -split "`n"
$medOrigBlock = ""
$inMed = $false
for ($i = 0; $i -lt $medOrigLines.Length; $i++) {
    if ($medOrigLines[$i] -match "INSERT INTO medicines_catalog") { $inMed = $true }
    if ($inMed) {
        $medOrigBlock += $medOrigLines[$i] + "`n"
        if ($medOrigLines[$i] -match "^\);") { break }
    }
}

# Replace the UNIFIED medicines block
$unifiedBlock = ""
$inMed = $false
$medStartLine = -1
$medEndLine = -1
for ($i = 0; $i -lt $unifiedLines.Length; $i++) {
    if ($unifiedLines[$i] -match "INSERT INTO medicines_catalog") { 
        $inMed = $true
        $medStartLine = $i
    }
    if ($inMed) {
        $unifiedBlock += $unifiedLines[$i] + "`n"
        if ($unifiedLines[$i] -match "^\);") {
            $medEndLine = $i
            break
        }
    }
}

if ($medStartLine -ge 0 -and $medEndLine -ge 0) {
    $newMedLines = $medOrigBlock.TrimEnd() -split "`n"
    $newArray = @()
    for ($i = 0; $i -lt $unifiedLines.Length; $i++) {
        if ($i -ge $medStartLine -and $i -le $medEndLine) {
            if ($i -lt $medStartLine + $newMedLines.Length) {
                $newArray += $newMedLines[$i - $medStartLine]
            }
        } else {
            $newArray += $unifiedLines[$i]
        }
    }
    $unifiedLines = $newArray
    $directReplacements++
    Write-Host "Medicine catalog block replaced"
}

# ====================================================================
# STEP 4: Replace comment lines with mojibake
# ====================================================================
# Build original comment lookup by ASCII signature
$origCommentsBySig = @{}
$origCommentOrder = @()
foreach ($f in $origFiles) {
    $lines = $origTexts[$f] -split "`n"
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed.StartsWith("--") -and $trimmed.Length -gt 3 -and [regex]::IsMatch($trimmed, "[\u0600-\u06FF]")) {
            $sig = Get-AsciiSignature $trimmed
            if ($sig.Length -ge 2) {
                if (-not $origCommentsBySig.ContainsKey($sig)) {
                    $origCommentsBySig[$sig] = $trimmed
                    $origCommentOrder += $sig
                }
            }
        }
    }
}

Write-Host "Original comment signatures: $($origCommentsBySig.Count)"

$commentReplaced = 0
for ($i = 0; $i -lt $unifiedLines.Length; $i++) {
    $line = $unifiedLines[$i].Trim()
    if ($line.StartsWith("--") -and $line.Length -gt 3 -and (Test-HasMojibake $line)) {
        $sig = Get-AsciiSignature $line
        
        if ($origCommentsBySig.ContainsKey($sig)) {
            $origComment = $origCommentsBySig[$sig]
            $indent = ""
            if ($unifiedLines[$i] -match "^(\s*)") { $indent = $Matches[1] }
            $unifiedLines[$i] = "$indent$origComment"
            $commentReplaced++
        }
    }
}
Write-Host "Comment replacements: $commentReplaced"

# ====================================================================
# STEP 5: Direct string replacements for known remaining mojibake
# ====================================================================
# For remaining mojibake that couldn't be matched by signature,
# try direct string replacement from known originals

# Find the comment block in initial_schema around specific sections
$directStringReplacements = 0
foreach ($f in $origFiles) {
    $origLines = $origTexts[$f] -split "`n"
    for ($i = 0; $i -lt $origLines.Length; $i++) {
        $origLine = $origLines[$i].Trim()
        if ($origLine.StartsWith("--") -and $origLine.Length -gt 10 -and [regex]::IsMatch($origLine, "[\u0600-\u06FF]")) {
            $origSig = Get-AsciiSignature $origLine
            if ($origSig.Length -ge 5) {
                # Check if this exact line exists in UNIFIED (after replacements)
                $found = $false
                for ($j = 0; $j -lt $unifiedLines.Length; $j++) {
                    if ($unifiedLines[$j].Trim() -eq $origLine) { $found = $true; break }
                }
                if (-not $found) {
                    # Find mojibake lines with same ASCII signature
                    for ($j = 0; $j -lt $unifiedLines.Length; $j++) {
                        $uline = $unifiedLines[$j].Trim()
                        if ($uline.StartsWith("--") -and (Test-HasMojibake $uline)) {
                            $ulSig = Get-AsciiSignature $uline
                            if ($ulSig -eq $origSig -and $ulSig.Length -ge 5) {
                                $indent = ""
                                if ($unifiedLines[$j] -match "^(\s*)") { $indent = $Matches[1] }
                                $unifiedLines[$j] = "$indent$origLine"
                                $directStringReplacements++
                                break
                            }
                        }
                    }
                }
            }
        }
    }
}
Write-Host "Direct string replacements: $directStringReplacements"

# ====================================================================
# STEP 6: Write the corrected file
# ====================================================================
$corrected = $unifiedLines -join "`n"
Write-Host "`nWriting corrected UNIFIED_schema.sql..."
[System.IO.File]::WriteAllText($unifiedPath, $corrected, $utf8)
Write-Host "Written $($corrected.Length) chars"

# ====================================================================
# STEP 7: Verification
# ====================================================================
$verify = [System.IO.File]::ReadAllText($unifiedPath, $utf8)
Write-Host "`n=== Verification ==="
Write-Host "Functions: $([regex]::Matches($verify, 'CREATE OR REPLACE FUNCTION').Count)"
Write-Host "Tables: $([regex]::Matches($verify, 'CREATE TABLE').Count)"
Write-Host "Policies: $([regex]::Matches($verify, 'CREATE POLICY').Count)"
Write-Host "Triggers: $([regex]::Matches($verify, 'CREATE TRIGGER').Count)"
$dollarCount = [regex]::Matches($verify, '\$').Count
Write-Host "`$ pairs: $($dollarCount / 2)"

# Count remaining mojibake
$verifyLines = $verify -split "`n"
$remainingMojibake = 0
$remainingLines = @()
for ($i = 0; $i -lt $verifyLines.Length; $i++) {
    if (Test-HasMojibake $verifyLines[$i]) {
        $remainingMojibake++
        $remainingLines += "  L$($i+1): $($verifyLines[$i].Trim().Substring(0, [Math]::Min(130, $verifyLines[$i].Trim().Length)))"
    }
}
Write-Host "Remaining mojibake: $remainingMojibake"
foreach ($rl in $remainingLines[0..([Math]::Min(29, $remainingLines.Count-1))]) {
    Write-Host $rl
}

# Arabic chars
$arabicCount = ([regex]::Matches($verify, "[\u0600-\u06FF]")).Count
Write-Host "`nArabic characters: $arabicCount"

# Functions check
$funcNames = [regex]::Matches($verify, 'CREATE OR REPLACE FUNCTION\s+(?:public\.)?(\w+)') | ForEach-Object { $_.Groups[1].Value }
$uniqueFuncs = $funcNames | Sort-Object -Unique
Write-Host "Unique functions: $($uniqueFuncs.Count) / Total: $($funcNames.Count)"
if ($funcNames.Count -ne $uniqueFuncs.Count) {
    $funcNames | Sort-Object | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object {
        Write-Host "  DUPLICATE: $($_.Name) (x$($_.Count))"
    }
}

# Key functions check
Write-Host "`n=== Key functions ==="
foreach ($func in @("bootstrap_create_farm_and_manager", "calc_dispatch_total", "calc_total_eggs", "validate_flock_farm")) {
    $funcPattern = "CREATE OR REPLACE FUNCTION\s+(?:public\.)?" + $func
    $funcIdx = [regex]::Match($verify, $funcPattern)
    if ($funcIdx.Success) {
        $startPos = $funcIdx.Index
        $funcBody = $verify.Substring($startPos, [Math]::Min(15000, $verify.Length - $startPos))
        $dollarMatches = [regex]::Matches($funcBody, '\$\$')
        Write-Host "  $func : $($dollarMatches.Count) `\$` markers (need 2)"
    } else {
        Write-Host "  $func : NOT FOUND!"
    }
}

Write-Host "`n=== DONE ==="
