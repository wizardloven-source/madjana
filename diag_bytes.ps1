$ErrorActionPreference = "Stop"
$basePath = "C:\Users\MTC\Desktop\madjana\supabase\migrations"

# Read UNIFIED as raw bytes
$unifiedPath = Join-Path $basePath "UNIFIED_schema.sql"
$bytes = [System.IO.File]::ReadAllBytes($unifiedPath)
$utf8 = [System.Text.Encoding]::UTF8

# Find the first occurrence of the comment "-- Madjana" in the UNIFIED file
$text = $utf8.GetString($bytes)
$madIdx = $text.IndexOf("-- Madjana -")
Write-Host "First '-- Madjana -' at char index: $madIdx"

# Show bytes around that area
$bytePos = 0
$charCount = 0
for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($charCount -eq $madIdx) {
        $bytePos = $i
        break
    }
    # Count UTF-8 characters
    $b = $bytes[$i]
    if ($b -lt 0x80) { $charCount++ }
    elseif (($b -band 0xE0) -eq 0xC0) { $charCount++; $i++ }
    elseif (($b -band 0xF0) -eq 0xE0) { $charCount++; $i += 2 }
    elseif (($b -band 0xF8) -eq 0xF0) { $charCount++; $i += 3 }
}

Write-Host "Byte position: $bytePos"
Write-Host "Bytes around Madjana comment (50 bytes):"
$hexStr = ""
for ($i = $bytePos; $i -lt [Math]::Min($bytePos + 80, $bytes.Length); $i++) {
    $hexStr += "{0:X2} " -f $bytes[$i]
}
Write-Host $hexStr

# Now show what the mojibake string looks like char by char
$startChar = $madIdx + len("-- Madjana - ")
Write-Host "`nMojibake chars (20 chars from position $($madIdx + 14)):"
for ($i = $madIdx + 14; $i -lt [Math]::Min($madIdx + 34, $text.Length); $i++) {
    $ch = $text[$i]
    Write-Host "  U+$([int]$ch | ForEach-Object { '{0:X4}' -f $_ }) = '$ch'"
}

# Now do the same for the original file
$origPath = Join-Path $basePath "20250101000000_initial_schema.sql"
$origBytes = [System.IO.File]::ReadAllBytes($origPath)
$origText = $utf8.GetString($origBytes)
$origMadIdx = $origText.IndexOf("-- Madjana -")
Write-Host "`nOriginal '-- Madjana -' at char index: $origMadIdx"
Write-Host "Original Arabic chars (20 chars from position $($origMadIdx + 14)):"
for ($i = $origMadIdx + 14; $i -lt [Math]::Min($origMadIdx + 34, $origText.Length); $i++) {
    $ch = $origText[$i]
    Write-Host "  U+$([int]$ch | ForEach-Object { '{0:X4}' -f $_ }) = '$ch'"
}

# Show raw bytes of original around Madjana
$origBytePos = 0
$origCharCount = 0
for ($i = 0; $i -lt $origBytes.Length; $i++) {
    if ($origCharCount -eq $origMadIdx) {
        $origBytePos = $i
        break
    }
    $b = $origBytes[$i]
    if ($b -lt 0x80) { $origCharCount++ }
    elseif (($b -band 0xE0) -eq 0xC0) { $origCharCount++; $i++ }
    elseif (($b -band 0xF0) -eq 0xE0) { $origCharCount++; $i += 2 }
    elseif (($b -band 0xF8) -eq 0xF0) { $origCharCount++; $i += 3 }
}
Write-Host "Original bytes around Madjana (50 bytes):"
$hexStr2 = ""
for ($i = $origBytePos; $i -lt [Math]::Min($origBytePos + 80, $origBytes.Length); $i++) {
    $hexStr2 += "{0:X2} " -f $origBytes[$i]
}
Write-Host $hexStr2
