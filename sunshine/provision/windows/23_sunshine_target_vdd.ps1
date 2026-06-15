$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start 23"
Write-Host "#########################################################"

# After step 22, VDD must be the only active display on the desktop. NVIDIA's
# adapter stays present for NVENC encoding. DXGI Desktop Duplication captures
# the entire virtual desktop - which is now VDD's resolution alone. If the VDD
# driver failed to start, Sunshine can still expose its API and pair with
# Moonlight, but the stream is black/no-video. Treat that as a provisioning
# failure instead of silently targeting the physical/NVIDIA display.

. "$PSScriptRoot\..\lib\sunshine.ps1"

$confPath = 'C:\Program Files\Sunshine\config\sunshine.conf'

$markerPath = 'C:\Users\Administrator\provision\state\display-config-done.flag'
if (-not (Test-Path $markerPath)) {
    Write-Host "Waiting for display-config marker ..."
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $markerPath)) {
        Start-Sleep -Seconds 3
    }
    if (-not (Test-Path $markerPath)) {
        throw "Display configuration marker was not created; VDD display setup did not complete."
    } else {
        Write-Host "Display config: $((Get-Content $markerPath -Raw).Trim())"
    }
} else {
    Write-Host "Display config already done: $((Get-Content $markerPath -Raw).Trim())"
}

$markerContent = (Get-Content -LiteralPath $markerPath -Raw).Trim()
if ($markerContent -notmatch '^OK\b') {
    $displayLog = 'C:\Users\Administrator\provision\state\display-config.log'
    if (Test-Path -LiteralPath $displayLog) {
        Get-Content -LiteralPath $displayLog | ForEach-Object { Write-Host "  $_" }
    }
    throw "VDD display setup failed: $markerContent"
}

# Ensure config file exists
if (-not (Test-Path $confPath)) {
    $confDir = Split-Path $confPath -Parent
    if (-not (Test-Path $confDir)) { New-Item -ItemType Directory -Path $confDir -Force | Out-Null }
    New-Item -ItemType File -Path $confPath -Force | Out-Null
}

function Set-ConfigValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $false)][AllowNull()][string]$Value
    )

    $lines = @()
    if (Test-Path -LiteralPath $Path) {
        $lines = @(Get-Content -LiteralPath $Path)
    }
    $filtered = @($lines | Where-Object { $_ -notmatch "^\s*$([regex]::Escape($Key))\s*=" })
    if ($null -ne $Value -and $Value.Trim() -ne '') {
        $filtered += "$Key = $Value"
    }
    $desired = ($filtered | Where-Object { $_.Trim() -ne '' }) -join "`r`n"
    $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($existing -ne $desired) {
        Set-Content -LiteralPath $Path -Value $desired -NoNewline -Encoding ASCII
        return $true
    }
    return $false
}

$changed = $false
# With VDD as the sole active desktop display, Sunshine should capture the full
# virtual desktop automatically. A stale or forced output_name can bind capture
# to a display path that is no longer stable after reboot, so remove it.
Write-Host "Removing Sunshine output_name override."
$changed = Set-ConfigValue -Path $confPath -Key 'output_name' -Value $null

if ($changed) {
    Write-Host "Restarting Sunshine ..."
    Restart-Sunshine
} else {
    Write-Host "Sunshine output_name already matches active display state."
}

Start-Sleep -Seconds 5
$svc = Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "Sunshine service: $($svc.Status)"
}

Write-Host "---------------------------------------------------------"
Write-Host "END 23"
Write-Host "---------------------------------------------------------"
Write-Host ""
