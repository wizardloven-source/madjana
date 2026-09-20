$root=(Get-Location).Path
$mob=Join-Path $root "apps\mobile\lib"

Write-Output "=== A) mobile local DB: files that CREATE TABLE (local schema) ==="
Get-ChildItem $mob -Recurse -File -Filter *.dart | Where-Object { (Select-String -Path $_.FullName -Pattern "CREATE TABLE" -Quiet -ErrorAction SilentlyContinue) } | ForEach-Object { $_.FullName.Substring($mob.Length+1) }

Write-Output ""
Write-Output "=== B) mobile local: is dispatch_requests table created locally? ==="
Get-ChildItem $mob -Recurse -File -Filter *.dart | ForEach-Object {
  $h=Select-String -Path $_.FullName -Pattern "dispatch_requests" -ErrorAction SilentlyContinue
  if($h){ foreach($x in $h){ "  $($_.FullName.Substring($mob.Length+1)) L$($x.LineNumber): $($x.Line.Trim())" } }
} | Select-Object -First 40

Write-Output ""
Write-Output "=== C) mobile sync engine : how local records are pushed (find the remote push) ==="
Get-ChildItem (Join-Path $mob "features\sync") -Recurse -File -Filter *.dart | ForEach-Object { $_.FullName.Substring($mob.Length+1) }
Write-Output "--- mobile providers wiring for remote datasources (approval remote path) ---"
$p=Join-Path $mob "core\providers.dart"
$c=Get-Content $p
for($i=100;$i -lt [Math]::Min($c.Count,175);$i++){ if($c[$i] -match "Provider<|final .*Provider|Datasource"){ "L$($i+1): $($c[$i].Trim())" } }

Write-Output ""
Write-Output "=== D) mobile dispatch_screen.dart: FULL approval flow (stock check + modal + send) ==="
$d=Join-Path $mob "features\dispatch\presentation\dispatch_screen.dart"
$c=Get-Content $d
Write-Output " (file has $($c.Count) lines)"
for($i=130;$i -lt [Math]::Min($c.Count,230);$i++){ "L$($i+1): $($c[$i])" }
