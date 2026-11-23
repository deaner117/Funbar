# Takes a screenshot of what the headset shows (including passthrough) and copies it to the PC.
# Usage:  .\screenshot.ps1 [-OutDir <folder>]     prints the path of the saved .jpg
param([string]$OutDir = (Join-Path $PSScriptRoot "screenshots"))

$ErrorActionPreference = "Continue"
$remote = "/sdcard/Oculus/Screenshots"
$serial = adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "\tdevice$" } | ForEach-Object { $_.Split("`t")[0] } | Select-Object -First 1
if (-not $serial) { Write-Host "No headset connected (try .\deploy.ps1 to reconnect)." -ForegroundColor Yellow; exit 1 }

if ((adb -s $serial shell dumpsys power | Select-String "mWakefulness=") -notmatch "Awake") {
    Write-Host "Headset is asleep; the screenshot would be blank. Put it on or press the power button." -ForegroundColor Yellow
    exit 1
}

$before = @(adb -s $serial shell ls $remote 2>$null)
adb -s $serial shell am startservice -n com.oculus.metacam/.capture.CaptureService -a TAKE_SCREENSHOT | Out-Null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    $new = @(adb -s $serial shell ls $remote 2>$null) | Where-Object { $_ -and $before -notcontains $_ } | Select-Object -First 1
    if ($new) { break }
}
if (-not $new) { Write-Host "Screenshot didn't appear on the headset." -ForegroundColor Yellow; exit 1 }

Start-Sleep -Milliseconds 500   # let the file finish writing
New-Item -ItemType Directory -Force $OutDir | Out-Null
$local = Join-Path $OutDir $new.Trim()
adb -s $serial pull "$remote/$($new.Trim())" $local | Out-Null
adb -s $serial shell rm "$remote/$($new.Trim())" | Out-Null   # keep the headset gallery clean
$local
