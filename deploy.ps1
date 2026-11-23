# Installs build\HangoutMansion.apk on the Quest (USB or Wi-Fi) and launches it.
# Usage:  .\deploy.ps1            install + launch (USB if plugged in, otherwise Wi-Fi)
#         .\deploy.ps1 -Build     rebuild first, then install + launch
#         .\deploy.ps1 -Log       also stream the app's log after launching (Ctrl+C to stop)
#         .\deploy.ps1 -Wifi      one-time Wi-Fi setup (headset must be on USB); redo after a headset reboot
param([switch]$Build, [switch]$Log, [switch]$Wifi)

# adb writes status notices to stderr; failures are checked explicitly below instead.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
$package = "com.homebrew.hangoutmansion"
$apk = "build\HangoutMansion.apk"
$ipFile = Join-Path $PSScriptRoot "quest-ip.txt"
$port = 5555

function Get-ReadyDevices {
    adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "\tdevice$" } | ForEach-Object { $_.Split("`t")[0] }
}

if ($Wifi) {
    $usb = Get-ReadyDevices | Where-Object { $_ -notmatch ":" } | Select-Object -First 1
    if (-not $usb) { Write-Host "Plug the headset in with USB for Wi-Fi setup." -ForegroundColor Yellow; exit 1 }
    $ip = (adb -s $usb shell ip -f inet addr show wlan0 | Select-String "inet (\d+\.\d+\.\d+\.\d+)").Matches[0].Groups[1].Value
    if (-not $ip) { throw "The headset isn't on Wi-Fi." }
    adb -s $usb tcpip $port | Out-Null
    Start-Sleep -Seconds 3
    adb connect "${ip}:$port"
    Set-Content -Path $ipFile -Value $ip -Encoding ascii
    Write-Host "Wi-Fi debugging is on at ${ip}:$port. You can unplug the headset now." -ForegroundColor Green
    if (-not $Build -and -not $Log) { exit 0 }
}

if ($Build) { & "$PSScriptRoot\build.ps1" }

# The Godot export can stop the adb server (dropping Wi-Fi connections). Restart it as a
# detached process: started inline it inherits this script's output pipe and can hang the caller.
function Test-AdbServer { [bool](Get-NetTCPConnection -LocalPort 5037 -State Listen -ErrorAction SilentlyContinue) }
if (-not (Test-AdbServer)) {
    Start-Process adb -ArgumentList "start-server" -WindowStyle Hidden
    for ($i = 0; $i -lt 40 -and -not (Test-AdbServer); $i++) { Start-Sleep -Milliseconds 250 }
}

# Prefer USB; otherwise reconnect to the headset's last known Wi-Fi address.
$devices = @(Get-ReadyDevices)
$serial = $devices | Where-Object { $_ -notmatch ":" } | Select-Object -First 1
if (-not $serial) { $serial = $devices | Select-Object -First 1 }
function Connect-Wifi([string]$ip) {
    $job = Start-Job { param($target) adb connect $target 2>&1 } -ArgumentList "${ip}:$port"
    if (-not (Wait-Job $job -Timeout 15)) { Write-Host "Wi-Fi connect to $ip timed out." -ForegroundColor Yellow }
    Remove-Job $job -Force
    $s = Get-ReadyDevices | Where-Object { $_ -eq "${ip}:$port" } | Select-Object -First 1
    if ($s -and (adb -s $s shell getprop ro.product.model) -match "Quest") { return $s }
    if ($s) { adb disconnect $s | Out-Null }   # something else answered on that port
    return $null
}

function Find-QuestOnLan {
    # The headset's IP can change (e.g. moving to a Wi-Fi extender), so scan the PC's /24 for the adb port.
    $myIp = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixLength -eq 24 -and $_.IPAddress -notmatch '^(127|169\.254|172\.)' } | Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $myIp) { return $null }
    $prefix = $myIp -replace '\.\d+$', ''
    Write-Host "Scanning $prefix.0/24 for the headset..."
    $probes = foreach ($i in 1..254) { $c = New-Object Net.Sockets.TcpClient; [pscustomobject]@{ Ip = "$prefix.$i"; Client = $c; Task = $c.ConnectAsync("$prefix.$i", $port) } }
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline -and ($probes | Where-Object { -not $_.Task.IsCompleted })) { Start-Sleep -Milliseconds 200 }
    $open = $probes | Where-Object { $_.Task.Status -eq 'RanToCompletion' } | ForEach-Object { $_.Ip }
    $probes | ForEach-Object { $_.Client.Close() }
    foreach ($ip in $open) { $s = Connect-Wifi $ip; if ($s) { return @{ Serial = $s; Ip = $ip } } }
    return $null
}

if (-not $serial -and (Test-Path $ipFile)) {
    $ip = (Get-Content $ipFile -Raw).Trim()
    Write-Host "No USB headset; connecting over Wi-Fi to ${ip}:$port ..."
    $serial = Connect-Wifi $ip
    if (-not $serial) {
        $found = Find-QuestOnLan
        if ($found) {
            $serial = $found.Serial
            Set-Content -Path $ipFile -Value $found.Ip -Encoding ascii
            Write-Host "Found the headset at a new address: $($found.Ip) (saved)." -ForegroundColor Green
        }
    }
}
if (-not $serial) {
    $all = adb devices | Select-Object -Skip 1 | Where-Object { $_.Trim() }
    if ($all -match "unauthorized") {
        Write-Host "Headset found but USB debugging isn't allowed yet." -ForegroundColor Yellow
        Write-Host "Put the headset on and accept 'Allow USB debugging' (tick 'Always allow from this computer')."
    } else {
        Write-Host "No headset detected." -ForegroundColor Yellow
        Write-Host "Over Wi-Fi: the headset must be awake on the same network. After a headset reboot, plug in USB once and run .\deploy.ps1 -Wifi."
        Write-Host "Over USB: use a data cable, check Developer Mode is on, and close Rookie (its adb can conflict)."
    }
    exit 1
}
Write-Host "Headset: $serial ($(adb -s $serial shell getprop ro.product.model))"

Write-Host "Installing $apk ..."
adb -s $serial install -r -g $apk
if ($LASTEXITCODE -ne 0) {
    # Usually a signing-key mismatch with an older copy; uninstall and retry.
    Write-Host "Install failed; removing the old copy and retrying..." -ForegroundColor Yellow
    adb -s $serial uninstall $package | Out-Null
    adb -s $serial install -g $apk
    if ($LASTEXITCODE -ne 0) { throw "adb install failed." }
}

Write-Host "Launching..."
adb -s $serial shell am force-stop $package
# GodotApp itself isn't exported; the launcher alias is the public entry point.
$start = adb -s $serial shell am start -n "$package/com.godot.game.GodotAppLauncher" 2>&1 | Out-String
if ($start -match "Error|Exception") { throw "Launch failed:`n$start" }
Write-Host "Started. Put the headset on." -ForegroundColor Green

if ($Log) {
    adb -s $serial logcat -c
    Start-Sleep -Seconds 2
    $appPid = (adb -s $serial shell pidof $package).Trim()
    if ($appPid) { adb -s $serial logcat --pid=$appPid } else { adb -s $serial logcat -s godot }
}
