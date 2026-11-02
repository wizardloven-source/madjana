$output = & {
    param()
    cd "C:\Users\MTC\Desktop\madjana\apps\desktop"
    & flutter build windows --release
}
$output | Out-File -FilePath "C:\Users\MTC\Desktop\madjana\build_jobs\windows_build.log" -Encoding ASCII
exit $LASTEXITCODE
