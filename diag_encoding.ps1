$ErrorActionPreference = "Stop"
$basePath = "C:\Users\MTC\Desktop\madjana\supabase\migrations"

# Try reading the initial_schema.sql with Windows-1252 encoding
$enc1252 = [System.Text.Encoding]::GetEncoding(1252)
$path1 = Join-Path $basePath "20250101000000_initial_schema.sql"

# Read raw bytes
$bytes = [System.IO.File]::ReadAllBytes($path1)
Write-Host "File size: $($bytes.Length) bytes"
Write-Host "First 20 bytes (hex):"
$hexStr = ""
for ($i = 0; $i -lt 20; $i++) {
    $hexStr += "{0:X2} " -f $bytes[$i]
}
Write-Host $hexStr

# Try reading as UTF-8
$utf8 = [System.Text.Encoding]::UTF8
$text8 = $utf8.GetString($bytes)
# Try reading as Windows-1252
$text1252 = $enc1252.GetString($bytes)

Write-Host "`n=== UTF-8 first 300 chars ==="
Write-Host $text8.Substring(0, [Math]::Min(300, $text8.Length))

Write-Host "`n=== Windows-1252 first 300 chars ==="
Write-Host $text1252.Substring(0, [Math]::Min(300, $text1252.Length))

# Check if 1252 reading has proper Arabic
$arabicCount8 = ([regex]::Matches($text8, "[\u0600-\u06FF]")).Count
$arabicCount1252 = ([regex]::Matches($text1252, "[\u0600-\u06FF]")).Count
Write-Host "`nArabic chars in UTF-8 reading: $arabicCount8"
Write-Host "Arabic chars in Windows-1252 reading: $arabicCount1252"

# Look for a known Arabic comment pattern
$idx8 = $text8.IndexOf("Madjana")
$idx1252 = $text1252.IndexOf("Madjana")
Write-Host "`n'Madjana' found in UTF-8 at: $idx8"
Write-Host "'Madjana' found in 1252 at: $idx1252"

if ($idx1252 -ge 0) {
    $snippet = $text1252.Substring($idx1252, [Math]::Min(100, $text1252.Length - $idx1252))
    Write-Host "1252 context: $snippet"
}
if ($idx8 -ge 0) {
    $snippet = $text8.Substring($idx8, [Math]::Min(100, $text8.Length - $idx8))
    Write-Host "UTF-8 context: $snippet"
}

# Check for BOM
Write-Host "`nBOM check: bytes[0]=$($bytes[0]) bytes[1]=$($bytes[1]) bytes[2]=$($bytes[2])"
if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Write-Host "File has UTF-8 BOM"
} else {
    Write-Host "No BOM"
}

# Try reading first RAISE EXCEPTION line from initial schema  
Write-Host "`n=== First RAISE EXCEPTION (UTF-8) ==="
$lines8 = $text8 -split "`n"
for ($i = 0; $i -lt $lines8.Length; $i++) {
    if ($lines8[$i] -match "RAISE EXCEPTION") {
        Write-Host "Line $($i+1): $($lines8[$i].Trim())"
        break
    }
}

Write-Host "`n=== First RAISE EXCEPTION (1252) ==="
$lines1252 = $text1252 -split "`n"
for ($i = 0; $i -lt $lines1252.Length; $i++) {
    if ($lines1252[$i] -match "RAISE EXCEPTION") {
        Write-Host "Line $($i+1): $($lines1252[$i].Trim())"
        break
    }
}
