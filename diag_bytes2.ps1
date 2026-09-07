$ErrorActionPreference = "Stop"
$basePath = "C:\Users\MTC\Desktop\madjana\supabase\migrations"
$utf8 = [System.Text.Encoding]::UTF8

# Read UNIFIED as raw bytes
$unifiedPath = Join-Path $basePath "UNIFIED_schema.sql"
$bytes = [System.IO.File]::ReadAllBytes($unifiedPath)
$text = $utf8.GetString($bytes)

$madIdx = $text.IndexOf("-- Madjana -")
Write-Host "UNIFIED '-- Madjana -' at char index: $madIdx"

# Show 30 chars of mojibake
Write-Host "`nMojibake chars:"
for ($i = $madIdx; $i -lt [Math]::Min($madIdx + 50, $text.Length); $i++) {
    $ch = $text[$i]
    $code = [int]$ch
    Write-Host ("  [{0}] U+{1:X4} = '{2}'" -f ($i - $madIdx), $code, $ch)
}

# Same for original
$origPath = Join-Path $basePath "20250101000000_initial_schema.sql"
$origBytes = [System.IO.File]::ReadAllBytes($origPath)
$origText = $utf8.GetString($origBytes)
$origMadIdx = $origText.IndexOf("-- Madjana -")
Write-Host "`nOriginal chars:"
for ($i = $origMadIdx; $i -lt [Math]::Min($origMadIdx + 50, $origText.Length); $i++) {
    $ch = $origText[$i]
    $code = [int]$ch
    Write-Host ("  [{0}] U+{1:X4} = '{2}'" -f ($i - $origMadIdx), $code, $ch)
}
