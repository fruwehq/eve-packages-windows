$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start splashtop"
Write-Host "#########################################################"

. "$PSScriptRoot\..\lib\downloads.ps1"

# Read Splashtop account/installer config delivered via env.json.
$envFile = "C:\Users\Administrator\provision\state\env.json"
$splashtopEmail = $null
$splashtopPassword = $null
$splashtopUrl = $null
if (Test-Path $envFile) {
  try {
    $envData = Get-Content $envFile | ConvertFrom-Json
    $splashtopEmail    = $envData.splashtop_email
    $splashtopPassword = $envData.splashtop_password
    $splashtopUrl      = $envData.splashtop_streamer_url
  } catch {
    Write-Warning "Failed to parse env file: $envFile"
  }
}

# The free Splashtop Streamer requires an account login (free for same-LAN/VPN
# use). Fail fast when credentials are missing rather than shipping an
# unreachable streamer.
if (-not $splashtopEmail -or -not $splashtopPassword) {
  Write-Error "SPLASHTOP_EMAIL and SPLASHTOP_PASSWORD are required. Create a free Splashtop account and connect over the same LAN/VPN."
  exit 2
}

# Splashtop gates streamer downloads behind an account, so no hidden URL is
# baked in; supply SPLASHTOP_STREAMER_URL pointing at the Windows Streamer .exe.
if (-not $splashtopUrl) {
  Write-Error "SPLASHTOP_STREAMER_URL is required. Download the Windows Streamer installer from your Splashtop account and point SPLASHTOP_STREAMER_URL at it."
  exit 2
}

$streamerExe = "C:\Program Files (x86)\Splashtop\Splashtop Remote\Server\SRServer.exe"
if (-not (Test-Path $streamerExe)) {
  $streamerExe = "C:\Program Files\Splashtop\Splashtop Remote\Server\SRServer.exe"
}

if (-not (Test-Path $streamerExe)) {
  $file = "C:\Users\Administrator\provision\downloads\splashtop\Splashtop_Streamer_Windows.exe"
  Write-Host "Downloading Splashtop Streamer installer..."
  Download-File -Url $splashtopUrl -OutFile $file -SkipIfExists
  Unblock-File $file -ErrorAction SilentlyContinue

  Write-Host "Running Splashtop Streamer installer (silent)..."
  Start-Process -FilePath $file -ArgumentList "/s", "/i" -Wait

  foreach ($candidate in @(
    "C:\Program Files (x86)\Splashtop\Splashtop Remote\Server\SRServer.exe",
    "C:\Program Files\Splashtop\Splashtop Remote\Server\SRServer.exe"
  )) {
    if (Test-Path $candidate) { $streamerExe = $candidate; break }
  }

  if (-not (Test-Path $streamerExe)) {
    throw "Splashtop Streamer did not install. SRServer.exe not found."
  }
  Write-Host "Splashtop Streamer installed at $streamerExe"
} else {
  Write-Host "Splashtop Streamer already installed at $streamerExe. Skipping installer."
}

# Log the streamer into the Splashtop account so the host registers.
Write-Host "Logging Splashtop Streamer into account $splashtopEmail..."
try {
  & $streamerExe -account -login $splashtopEmail $splashtopPassword | Out-Null
} catch {
  Write-Warning "Splashtop login command failed; verify the credentials and LAN/VPN reachability."
}

$service = Get-Service -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match 'SplashtopRemoteService' -or $_.DisplayName -match 'Splashtop' } |
  Select-Object -First 1
if ($service) {
  Set-Service -Name $service.Name -StartupType Automatic
  if ($service.Status -ne "Running") { Start-Service -Name $service.Name }
}

Write-Host "---------------------------------------------------------"
Write-Host "END splashtop"
Write-Host "---------------------------------------------------------"
Write-Host ""
exit 0
