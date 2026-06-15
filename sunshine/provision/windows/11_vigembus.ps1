$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start 11"
Write-Host "#########################################################"

. "$PSScriptRoot\..\lib\downloads.ps1"

# Sunshine emits "Fatal: ViGEmBus is not installed or running" without this
# kernel-mode bus driver. Install the latest release from upstream so Moonlight
# clients can send gamepad input.

$svcName = 'ViGEmBus'
$rebootFlag = 'C:\Users\Administrator\provision\state\reboot.flag'

Write-Host "Checking for ViGEmBus service..."
$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
if ($svc) {
  Write-Host "ViGEmBus already installed (service status: $($svc.Status)). Skipping installer."
  Write-Host "---------------------------------------------------------"
  Write-Host "END 11 - early exit"
  Write-Host "---------------------------------------------------------"
  Write-Host ""
  return
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$headers = @{ "User-Agent" = "Mozilla/5.0"; "Accept" = "application/vnd.github+json" }
$api = "https://api.github.com/repos/nefarius/ViGEmBus/releases/latest"

$release = $null
for ($i = 1; $i -le 5; $i++) {
  try { $release = Invoke-RestMethod -Uri $api -Headers $headers; break } catch {
    if ($i -eq 5) { throw "Failed to fetch ViGEmBus releases from GitHub API after 5 attempts: $_" }
    Start-Sleep -Seconds 2
  }
}

# Recent releases ship a single bundled installer covering x64/x86/arm64.
$asset = $release.assets | Where-Object { $_.name -match '^ViGEmBus_.*\.exe$' } | Select-Object -First 1
if (-not $asset) {
  throw "Could not find ViGEmBus installer in latest release. Assets: $($release.assets.name -join ', ')"
}

$file = "C:\Users\Administrator\provision\downloads\vigembus\$($asset.name)"
Write-Host "Downloading: $($asset.name) (ViGEmBus $($release.tag_name))"
Download-File -Url $asset.browser_download_url -OutFile $file -SkipIfExists
Unblock-File $file -ErrorAction SilentlyContinue

# ViGEmBus ships as a WiX Burn bundle, which expects /quiet (not the NSIS /S).
# Without /quiet the bundle's bootstrapper UI hangs forever in our session-0
# scheduled-task context. /norestart suppresses the bundle's own reboot - we
# request reboot ourselves via reboot.flag below.
Write-Host "Running ViGEmBus installer (silent)..."
$proc = Start-Process -FilePath $file -ArgumentList "/quiet", "/norestart" -Wait -PassThru
# WiX Burn returns 3010 to mean "success, reboot required". Treat as success.
if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
  throw "ViGEmBus installer failed with exit code $($proc.ExitCode)"
}
Write-Host "ViGEmBus installer exit code: $($proc.ExitCode)"

# Verify install. Driver service should register; sometimes the service entry
# needs a moment to appear in the SCM after the installer returns.
Start-Sleep -Seconds 3
$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
if (-not $svc) {
  throw "ViGEmBus service not registered after installer ran. Check $file."
}
Write-Host "ViGEmBus service registered (status: $($svc.Status))."

# Kernel-mode driver: a reboot is the most reliable way to ensure the bus is
# actually live for Sunshine to bind to on its next start.
Write-Host "Requesting reboot to activate ViGEmBus driver..."
New-Item $rebootFlag -ItemType File -Force | Out-Null

Write-Host "---------------------------------------------------------"
Write-Host "END 11"
Write-Host "---------------------------------------------------------"
Write-Host ""
