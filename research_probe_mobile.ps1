$root=(Get-Location).Path
$mob=Join-Path $root "apps\mobile\lib"

Write-Output "=== mobile core tree ==="
Get-ChildItem (Join-Path $mob "core") -Recurse -File -Filter *.dart | ForEach-Object { $_.FullName.Substring($mob.Length) }

Write-Output ""
Write-Output "=== mobile: who CREATEs dispatch_requests locally ==="
Get-ChildItem $mob -Recurse -File -Filter *.dart | ForEach-Object {
  $h = Select-String -Path $_.FullName -Pattern "CREATE TABLE IF NOT EXISTS dispatch|CREATE TABLE dispatch_requests" -ErrorAction SilentlyContinue
  if ($h) { foreach ($x in $h) { $_.FullName.Substring($mob.Length) + " L" + $x.LineNumber + ": " + $x.Line.Trim() } }
}

Write-Output ""
Write-Output "=== mobile: local DB opened via which class? (sqflite / openDatabase refs) ==="
Get-ChildItem $mob -Recurse -File -Filter *.dart | ForEach-Object {
  $h = Select-String -Path $_.FullName -Pattern "openDatabase\(|class LocalDatabase|class AppDatabase|sqflite_database" -ErrorAction SilentlyContinue
  if ($h) { foreach ($x in $h) { $_.FullName.Substring($mob.Length) + " L" + $x.LineNumber + ": " + $x.Line.Trim() } }
} | Select-Object -First 15

Write-Output ""
Write-Output "=== mobile: FILES which hold remote insert for dispatch_requests (the approval write) ==="
Get-ChildItem $mob -Recurse -File -Filter *.dart | ForEach-Object {
  $h = Select-String -Path $_.FullName -Pattern "from\\('dispatch_requests'\\)|from\(\"dispatch_requests\"\)|INSERT INTO dispatch_requests" -ErrorAction SilentlyContinue
  if ($h) { $_.FullName.Substring($mob.Length) + " -> " + (($h | ForEach-Object { "L" + $_.LineNumber }) -join ",") }
}
