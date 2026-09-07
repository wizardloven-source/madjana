$ErrorActionPreference = "Stop"
$basePath = "C:\Users\MTC\Desktop\madjana\supabase\migrations"
$utf8 = [System.Text.Encoding]::UTF8

function Test-HasArabic($s) {
    return [regex]::IsMatch($s, "[\u0600-\u06FF]")
}

function Test-HasMojibake($s) {
    $hasArabic = [regex]::IsMatch($s, "[\u0600-\u06FF]")
    $hasLatinSpecial = [regex]::IsMatch($s, "[\u00B0-\u00FF\u2018-\u2026\u2013\u2014\u201C\u201D]")
    return ($hasArabic -and $hasLatinSpecial)
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
Write-Host "Loaded all files"

# ====================================================================
# STEP 2: Extract RAISE EXCEPTION from originals with function context
# ====================================================================
# For each original, find each RAISE EXCEPTION, the function it's in, and its position
$origRaise = @()  # Array of @{ File; FuncName; Position; Message; ErrorCode; Params }

foreach ($f in $origFiles) {
    $text = $origTexts[$f]
    $lines = $text -split "`n"
    
    $currentFunc = ""
    $funcRaiseCount = @{}
    
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        
        # Track current function
        if ($line -match "CREATE OR REPLACE FUNCTION\s+(\w+)") {
            $currentFunc = $Matches[1]
            if (-not $funcRaiseCount.ContainsKey($currentFunc)) {
                $funcRaiseCount[$currentFunc] = 0
            }
        }
        
        # Find RAISE EXCEPTION
        if ($line -match "RAISE EXCEPTION\s*'([^']*)'") {
            $msg = $Matches[1]
            if (Test-HasArabic $msg) {
                $pos = $funcRaiseCount[$currentFunc]
                $funcRaiseCount[$currentFunc] = $pos + 1
                
                $errorCode = ""
                if ($msg -match "^([A-Z_]+):") {
                    $errorCode = $Matches[1]
                }
                
                # Extract params pattern (%, NEW.xxx, etc.)
                $params = ""
                if ($line -match "RAISE EXCEPTION\s*'[^']*'(.*)$") {
                    $params = $Matches[1].Trim()
                }
                
                $origRaise += @{
                    File = $f
                    FuncName = $currentFunc
                    Position = $pos
                    Message = $msg
                    ErrorCode = $errorCode
                    Params = $params
                    Line = $i + 1
                }
            }
        }
    }
}

Write-Host "Original RAISE EXCEPTION entries: $($origRaise.Count)"

# ====================================================================
# STEP 3: Extract RAISE EXCEPTION from UNIFIED with function context
# ====================================================================
$unifiedLines = $unified -split "`n"
$unifiedRaise = @()

$currentFunc = ""
$funcRaiseCount = @{}

for ($i = 0; $i -lt $unifiedLines.Length; $i++) {
    $line = $unifiedLines[$i]
    
    if ($line -match "CREATE OR REPLACE FUNCTION\s+(\w+)") {
        $currentFunc = $Matches[1]
        if (-not $funcRaiseCount.ContainsKey($currentFunc)) {
            $funcRaiseCount[$currentFunc] = 0
        }
    }
    
    if ($line -match "RAISE EXCEPTION\s*'([^']*)'") {
        $msg = $Matches[1]
        $isMojibake = Test-HasMojibake $msg
        $hasArabic = Test-HasArabic $msg
        
        if ($hasArabic) {
            $pos = $funcRaiseCount[$currentFunc]
            $funcRaiseCount[$currentFunc] = $pos + 1
            
            $errorCode = ""
            if ($msg -match "^([A-Z_]+):") {
                $errorCode = $Matches[1]
            }
            
            $params = ""
            if ($line -match "RAISE EXCEPTION\s*'[^']*'(.*)$") {
                $params = $Matches[1].Trim()
            }
            
            $unifiedRaise += @{
                LineIdx = $i
                FuncName = $currentFunc
                Position = $pos
                Message = $msg
                ErrorCode = $errorCode
                Params = $params
                IsMojibake = $isMojibake
            }
        }
    }
}

Write-Host "Unified RAISE EXCEPTION entries: $($unifiedRaise.Count)"
$mojibakeCount = ($unifiedRaise | Where-Object { $_.IsMojibake }).Count
Write-Host "Mojibake entries: $mojibakeCount"

# ====================================================================
# STEP 4: Match and replace RAISE EXCEPTION messages
# ====================================================================
$replaced = 0
$notReplaced = 0

foreach ($ur in $unifiedRaise) {
    if (-not $ur.IsMojibake) { continue }
    
    # Find matching original by: function name + position
    $match = $origRaise | Where-Object {
        $_.FuncName -eq $ur.FuncName -and $_.Position -eq $ur.Position
    } | Select-Object -First 1
    
    if ($match -eq $null) {
        # Try matching by error code + function
        if ($ur.ErrorCode -ne "") {
            $match = $origRaise | Where-Object {
                $_.FuncName -eq $ur.FuncName -and $_.ErrorCode -eq $ur.ErrorCode
            } | Select-Object -First 1
        }
    }
    
    if ($match -ne $null) {
        # Replace the mojibake message with the correct one
        $oldLine = $unifiedLines[$ur.LineIdx]
        $newLine = $oldLine.Replace($ur.Message, $match.Message)
        $unifiedLines[$ur.LineIdx] = $newLine
        $replaced++
    } else {
        $notReplaced++
    }
}

Write-Host "`nRAISE EXCEPTION replacements: $replaced"
Write-Host "Not replaced: $notReplaced"

# ====================================================================
# STEP 5: Handle comment lines with mojibake
# ====================================================================
# For comments, we'll match by section number and surrounding context
$origCommentLines = @()
foreach ($f in $origFiles) {
    $lines = $origTexts[$f] -split "`n"
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed.StartsWith("--") -and $trimmed.Length -gt 5 -and (Test-HasArabic $trimmed)) {
            $origCommentLines += @{
                File = $f
                LineIdx = $i
                Text = $trimmed
                SectionNum = ""
                English = ""
            }
            if ($trimmed -match "^\s*--\s*(\d+)") {
                $origCommentLines[-1].SectionNum = $Matches[1]
            }
            # Extract English parts (function names, keywords, etc.)
            $origCommentLines[-1].English = [regex]::Replace($trimmed, "[\u0600-\u06FF]", "").Trim()
        }
    }
}

# Replace mojibake comments in UNIFIED
$commentReplaced = 0
for ($i = 0; $i -lt $unifiedLines.Length; $i++) {
    $line = $unifiedLines[$i].Trim()
    if ($line.StartsWith("--") -and $line.Length -gt 5 -and (Test-HasMojibake $line)) {
        # Extract section number
        $sectionNum = ""
        if ($line -match "^\s*--\s*(\d+)") {
            $sectionNum = $Matches[1]
        }
        
        # Extract English parts from mojibake
        $mojibakeEnglish = [regex]::Replace($line, "[\u0600-\u06FF\u00B0-\u00FF\u2018-\u2026\u2013\u2014]", "").Trim()
        
        # Find best matching original comment
        $bestMatch = $null
        $bestScore = 0
        
        foreach ($oc in $origCommentLines) {
            $score = 0
            
            # Match by section number
            if ($sectionNum -ne "" -and $oc.SectionNum -eq $sectionNum) {
                $score += 10
            }
            
            # Match by English content
            if ($oc.English -eq $mojibakeEnglish -and $oc.English.Length -gt 5) {
                $score += 50
            }
            
            if ($score -gt $bestScore) {
                $bestScore = $score
                $bestMatch = $oc
            }
        }
        
        if ($bestMatch -ne $null -and $bestScore -ge 10) {
            # Preserve leading whitespace
            $indent = ""
            if ($unifiedLines[$i] -match "^(\s*)") { $indent = $Matches[1] }
            $unifiedLines[$i] = "$indent$($bestMatch.Text)"
            $commentReplaced++
        }
    }
}

Write-Host "Comment replacements: $commentReplaced"

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

# Check for remaining mojibake
$verifyLines = $verify -split "`n"
$remainingMojibake = 0
foreach ($line in $verifyLines) {
    if (Test-HasMojibake $line) {
        $remainingMojibake++
    }
}
Write-Host "Remaining mojibake lines: $remainingMojibake"

# Show remaining mojibake (first 20)
$count = 0
for ($i = 0; $i -lt $verifyLines.Length; $i++) {
    if (Test-HasMojibake $verifyLines[$i]) {
        $count++
        if ($count -le 20) {
            $trimmed = $verifyLines[$i].Trim()
            $preview = $trimmed.Substring(0, [Math]::Min(120, $trimmed.Length))
            Write-Host "  L$($i+1): $preview"
        }
    }
}

# Check Arabic char count
$arabicCount = ([regex]::Matches($verify, "[\u0600-\u06FF]")).Count
Write-Host "`nArabic characters: $arabicCount"

# Verify function completeness
Write-Host "`n=== Key functions check ==="
foreach ($func in @("bootstrap_create_farm_and_manager", "calc_dispatch_total", "calc_total_eggs", "validate_flock_farm")) {
    $idx = $verify.IndexOf($func)
    if ($idx -ge 0) {
        # Find the $$ delimiters around this function
        $before = $verify.Substring(0, $idx)
        $funcStart = $before.LastIndexOf("CREATE OR REPLACE FUNCTION")
        $afterFunc = $verify.Substring($funcStart)
        $body = $afterFunc.Substring(0, [Math]::Min(5000, $afterFunc.Length))
        $dollarMatches = [regex]::Matches($body, '\$\$')
        Write-Host "  $func : $($dollarMatches.Count) `\$` delimiters found (need 2)"
    } else {
        Write-Host "  $func : NOT FOUND!"
    }
}

# No duplicate functions
$funcNames = [regex]::Matches($verify, 'CREATE OR REPLACE FUNCTION (\w+)') | ForEach-Object { $_.Groups[1].Value }
$uniqueFuncs = $funcNames | Sort-Object -Unique
Write-Host "`nUnique functions: $($uniqueFuncs.Count) / Total: $($funcNames.Count)"
if ($funcNames.Count -ne $uniqueFuncs.Count) {
    $funcNames | Sort-Object | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object {
        Write-Host "  DUPLICATE: $($_.Name) (x$($_.Count))"
    }
}

Write-Host "`n=== DONE ==="
