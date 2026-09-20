$root=(Get-Location).Path
$mob="$root\apps\mobile\lib"

Write-Output "=== A) mobile local DB files (which dart creates the SQLite tables) ==="
Get-ChildItem $mob -Recurse -File -Filter *.dart | Where-Object { (Select-String -Path $_.FullName -Pattern "CREATE TABLE" -Quiet -ErrorAction SilentlyContinue) } | ForEach-Object { $_.FullName.Substring($mob.Length+1) } | Sort-Object -Unique

Write-Output ""
Write-Output "=== B) mobile: every CREATE TABLE block inside local_database.dart (table list) ==="
$ldb = Get-ChildItem $mob -Recurse -File -Filter *.dart | Where-Object { (Select-String -Path $_.FullName -Pattern "CREATE TABLE" -Quiet) -and ($_.Name -match 'database') } | Select-Object -First 1
if($ldb){
  $c=Get-Content $ldb.FullName
  Write-Output "FILE: $($ldb.FullName.Substring($mob.Length+1))"
  $tables = Select-String -Path $ldb.FullName -Pattern "CREATE TABLE (IF NOT EXISTS )?(\w+)" | ForEach-Object { $_.Matches[0].Groups[2].Value }
  $tables | Sort-Object -Unique
  Write-Output "--- does local DB create a dispatch_requests table? ---"
  $m=Select-String -Path $ldb.FullName -Pattern "dispatch_requests" -ErrorAction SilentlyContinue
  if($m){ foreach($x in $m){ "  L$($x.LineNumber): $($x.Line.Trim())" } } else { "  NO dispatch_requests table found locally" }
}

Write-Output ""
Write-Output "=== C) mobile: DispatchRequestDao file + its class methods (this is the local DAO) ==="
$dao = Get-ChildItem $mob -Recurse -File -Filter "*dispatch_request_dao.dart" | Select-Object -First 1
if($dao){ $dao.FullName.Substring($mob.Length+1) } else { "  no dispatch_request_dao.dart in mobile -> the mobile uses iterator" }
Get-ChildItem $mob -Recurse -File -Filter *.dart | ForEach-Object { $h=Select-String -Path $_.FullName -Pattern "class DispatchRequestDao" -ErrorAction SilentlyContinue; if($h){ "  FOUND: $($_.FullName.Substring($mob.Length+1)) L$($h.LineNumber)" } } | Select-Object -First 5