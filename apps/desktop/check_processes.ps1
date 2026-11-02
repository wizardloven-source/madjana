
$processes = Get-Process | Where-Object {``$_.ProcessName -like "*cmake*" -or ``$_.ProcessName -like "*ninja*" -or ``$_.ProcessName -like "*cl*"} | Select-Object Id, ProcessName, StartTime
if ($processes) { $processes | Format-Table -AutoSize } else { "No cmake/ninja/cl processes found" }

