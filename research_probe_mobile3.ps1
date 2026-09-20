$root=(Get-Location).Path
$mob=Join-Path $root "apps\mobile\lib"

Write-Output "=== 1) mobile: which file wires SUPABASE for mobile (supabase_client.dart) — does it provide remote Datasources + SyncRepositoryImpl? ==="
$sc=Join-Path $mob "core\supabase_client.dart"
if(Test-Path $sc){
  Write-Output "  exists: core\supabase_client.dart ($((Get-Content $sc).Count) lines)"
  $classes = Select-String -Path $sc -Pattern "class Supabase|Provider<Supabase|supabaseClientProvider|SupabaseApi|sync_records_batch|functions.invoke|invoke\('sync" | ForEach-Object { "  L$($_.LineNumber): $($_.Line.Trim())" }
  $classes
} else { Write-Output "  NO core\supabase_client.dart in mobile" }

Write-Output ""
Write-Output "=== 2) mobile: is there a SyncRepositoryImpl / SyncRepository pushed via sync_records_batch anywhere in mobile? ==="
Get-ChildItem $mob -Recurse -File -Filter *.dart | ForEach-Object {
  $h = Select-String -Path $_.FullName -Pattern "SyncRepositoryImpl|SyncRepository\(|sync_records_batch|functions.invoke\('sync_records|invoke\('sync_records|class .*SyncEngine" -ErrorAction SilentlyContinue
  if($h){ foreach($x in $h){ "  $($_.FullName.Substring($mob.Length+1)) L$($x.LineNumber): $($x.Line.Trim())" } }
} | Select-Object -First 40

Write-Output ""
Write-Output "=== 3) mobile: does apps\mobile actually SEARCH-LINK the shared packages/data LocalDatabase (package:data/local_database) or does it have its own? — find the file mobile uses to open its DB ==="
Get-ChildItem $mob -Recurse -File -Filter *.dart | ForEach-Object {
  $h = Select-String -Path $_.FullName -Pattern "LocalDatabase|openDatabase|sqflite|CREATE TABLE IF NOT EXISTS" -ErrorAction SilentlyContinue
  if($h){ "  $($_.FullName.Substring($mob.Length+1)): " + (($h | ForEach-Object { "L$($_.LineNumber)" }) -join ",") }
} | Select-Object -First 40