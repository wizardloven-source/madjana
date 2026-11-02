$output = ""
$errorOutput = ""

$process = New-Object System.Diagnostics.Process
$process.StartInfo.FileName = "cmd"
$process.StartInfo.Arguments = "/c cd /d C:\Users\MTC\Desktop\madjana\apps\desktop && flutter build windows --release"
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $true
$process.Start()

$output = $process.StandardOutput.ReadToEnd()
$errorOutput = $process.StandardError.ReadToEnd()
$process.WaitForExit()

$combined = "STDOUT:`n$output`nSTDERR:`n$errorOutput`nEXIT CODE: $($process.ExitCode)"
$combined | Out-File -FilePath "C:\Users\MTC\Desktop\madjana\build_jobs\desktop_build.log" -Encoding ASCII

exit $process.ExitCode
