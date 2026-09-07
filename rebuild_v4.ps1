$ErrorActionPreference = "Stop"
$basePath = "C:\Users\MTC\Desktop\madjana\supabase\migrations"
$utf8 = [System.Text.Encoding]::UTF8

function Test-HasMojibake($s) {
    $hasArabic = [regex]::IsMatch($s, "[\u0600-\u06FF]")
    $hasLatinSpecial = [regex]::IsMatch($s, "[\u00B0-\u00FF\u2018-\u2026\u2013\u2014\u201C\u201D]")
    return ($hasArabic -and $hasLatinSpecial)
}

function Get-AsciiSignature($s) {
    return [regex]::Replace($s, "[^a-zA-Z0-9\s\-\(\)\[\]\{\},\.;:\/\\!@#%^&*+=<>?`~]", "").Trim()
}

# ====================================================================
# STEP 1: Read all files (RESTORED from git)
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
        if ($line -match "CREATE OR REPLACE FUNCTION\s+(\w+)") {
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
                $origRaise += @{ FuncName=$currentFunc; Position=$pos; Message=$msg; ErrorCode=$errorCode }
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
    if ($line -match "CREATE OR REPLACE FUNCTION\s+(\w+)") {
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
        } else {
            if ([regex]::IsMatch($msg, "[\u0600-\u06FF]")) {
                $pos = $funcRaiseCount[$currentFunc]
                $funcRaiseCount[$currentFunc] = $pos + 1
            }
        }
    }
}
Write-Host "RAISE EXCEPTION replacements: $replaced"

# ====================================================================
# STEP 3: Replace comment lines with mojibake
# ====================================================================
# Build original comment lookup by ASCII signature
$origCommentsBySig = @{}
foreach ($f in $origFiles) {
    $lines = $origTexts[$f] -split "`n"
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed.StartsWith("--") -and $trimmed.Length -gt 3 -and [regex]::IsMatch($trimmed, "[\u0600-\u06FF]")) {
            $sig = Get-AsciiSignature $trimmed
            if ($sig.Length -gt 3 -or ($trimmed -match "^\s*--\s*\d+\)")) {
                if (-not $origCommentsBySig.ContainsKey($sig)) {
                    $origCommentsBySig[$sig] = $trimmed
                }
            }
        }
    }
}

Write-Host "Original comment ASCII signatures: $($origCommentsBySig.Count)"

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
# STEP 4: Write the corrected file
# ====================================================================
$corrected = $unifiedLines -join "`n"
Write-Host "`nWriting corrected UNIFIED_schema.sql..."
[System.IO.File]::WriteAllText($unifiedPath, $corrected, $utf8)
Write-Host "Written $($corrected.Length) chars"

# ====================================================================
# STEP 5: Verification
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
foreach ($vline in $verifyLines) {
    if (Test-HasMojibake $vline) { $remainingMojibake++ }
}
Write-Host "Remaining mojibake: $remainingMojibake"

# Show first 30 remaining mojibake
$count = 0
for ($i = 0; $i -lt $verifyLines.Length; $i++) {
    if (Test-HasMojibake $verifyLines[$i]) {
        $count++
        if ($count -le 30) {
            $preview = $verifyLines[$i].Trim().Substring(0, [Math]::Min(130, $verifyLines[$i].Trim().Length))
            Write-Host "  L$($i+1): $preview"
        }
    }
}

# Arabic chars
$arabicCount = ([regex]::Matches($verify, "[\u0600-\u06FF]")).Count
Write-Host "`nArabic characters: $arabicCount"

# No duplicate functions
$funcNames = [regex]::Matches($verify, 'CREATE OR REPLACE FUNCTION (\w+)') | ForEach-Object { $_.Groups[1].Value }
$uniqueFuncs = $funcNames | Sort-Object -Unique
Write-Host "Unique functions: $($uniqueFuncs.Count) / Total: $($funcNames.Count)"
if ($funcNames.Count -ne $uniqueFuncs.Count) {
    $funcNames | Sort-Object | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object {
        Write-Host "  DUPLICATE: $($_.Name) (x$($_.Count))"
    }
}

# Check key functions
Write-Host "`n=== Key functions ==="
foreach ($func in @("bootstrap_create_farm_and_manager", "calc_dispatch_total", "calc_total_eggs", "validate_flock_farm")) {
    $funcIdx = $verify.IndexOf("CREATE OR REPLACE FUNCTION $func")
    if ($funcIdx -ge 0) {
        # Find the $$ markers in this function
        $funcBody = $verify.Substring($funcIdx, [Math]::Min(10000, $verify.Length - $funcIdx))
        $dollarMatches = [regex]::Matches($funcBody, '\$\$')
        Write-Host "  $func : $($dollarMatches.Count) `\$` markers"
    } else {
        Write-Host "  $func : NOT FOUND!"
    }
}

Write-Host "`n=== DONE ==="
