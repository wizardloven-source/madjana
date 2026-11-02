
Get-Process | Where-Object {``$_.StartTime -lt (Get-Date).AddMinutes(-10)} | Select-Object Id, ProcessName, StartTime

