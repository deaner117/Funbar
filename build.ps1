# Builds build\HangoutMansion.apk, ready to sideload onto the Quest 3.
Set-Location $PSScriptRoot
$godot = Join-Path $PSScriptRoot "tools\Godot_v4.7.2-stable_win64_console.exe"
New-Item -ItemType Directory -Force build | Out-Null
# Without this Gradle leaves a daemon running that keeps Godot from exiting.
$env:GRADLE_OPTS = "-Dorg.gradle.daemon=false"
# Run through cmd so Godot's warnings on stderr are not treated as PowerShell errors.
cmd /c "`"$godot`" --headless --path . --install-android-build-template --export-debug `"Quest 3`" build/HangoutMansion.apk 2>&1"
Get-Item build\HangoutMansion.apk | Select-Object Name, Length, LastWriteTime
