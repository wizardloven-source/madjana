$ErrorActionPreference = "Stop"
$basePath = "C:\Users\MTC\Desktop\madjana\supabase\migrations"
$enc1252 = [System.Text.Encoding]::GetEncoding(1252)
$path1 = Join-Path $basePath "20250101000000_initial_schema.sql"

# Read as UTF-8 (what we have now - mojibake)
$text = [System.IO.File]::ReadAllText($path1, [System.Text.Encoding]::UTF8)

# Try to recover: encode the mojibake string as Windows-1252 bytes, then decode as UTF-8
# This reverses the PS5.1 double-encoding: UTF-8 -> misread as 1252 -> re-encoded to UTF-8
$mojibakeBytes = $enc1252.GetBytes($text)
$recovered = [System.Text.Encoding]::UTF8.GetString($mojibakeBytes)

Write-Host "=== First 300 chars (recovered) ==="
Write-Host $recovered.Substring(0, [Math]::Min(300, $recovered.Length))

$arabicCount = ([regex]::Matches($recovered, "[\u0600-\u06FF]")).Count
Write-Host "`nArabic chars in recovered: $arabicCount"

# Check if known Arabic words appear
Write-Host "`nContains 'مجمع': $($recovered.Contains('مجمع'))"
Write-Host "Contains 'مزرعة': $($recovered.Contains('مزرعة'))"
Write-Host "Contains 'المدير': $($recovered.Contains('المدير'))"

# Check first RAISE EXCEPTION
$lines = $recovered -split "`n"
for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($lines[$i] -match "RAISE EXCEPTION") {
        Write-Host "`nFirst RAISE EXCEPTION (line $($i+1)):"
        Write-Host $lines[$i].Trim()
        break
    }
}

# Count ?? (question marks) in recovered
$qmarks = ([regex]::Matches($recovered, "\?")).Count
Write-Host "`nQuestion marks in recovered: $qmarks"

# Check for U+FFFD replacement chars
$fffd = ([regex]::Matches($recovered, "\uFFFD")).Count
Write-Host "U+FFFD replacement chars in recovered: $fffd"

# Show some more recovered Arabic
Write-Host "`n=== More recovered text (lines 1-15) ==="
for ($i = 0; $i -lt 15 -and $i -lt $lines.Length; $i++) {
    Write-Host "L$($i+1): $($lines[$i])"
}
