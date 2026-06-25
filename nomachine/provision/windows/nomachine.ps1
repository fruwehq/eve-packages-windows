$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start nomachine"
Write-Host "#########################################################"

. "$PSScriptRoot\..\lib\downloads.ps1"

# Ensure TLS 1.2 (winget and download endpoints may require it on Server 2025).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$envFile = "C:\Users\Administrator\provision\state\env.json"
$nomachineVersion = "8.16.1_1"
if (Test-Path $envFile) {
  try {
    $envData = Get-Content $envFile | ConvertFrom-Json
    if ($envData.nomachine_version) { $nomachineVersion = $envData.nomachine_version }
  } catch {}
}
$nomachineMinor = ($nomachineVersion -split '_')[0]
$nomachineMinor = $nomachineMinor.Substring(0, $nomachineMinor.LastIndexOf('.'))

$nxServer = "C:\Program Files\NoMachine\bin\nxserver.exe"
$nxPlayer = "C:\Program Files\NoMachine\bin\nxplayer.bin"

if ((-not (Test-Path $nxServer)) -and (-not (Test-Path $nxPlayer))) {
  $installed = $false

  # Try winget (NoMachine's direct download URLs are frequently stale).
  $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($winget) {
    Write-Host "Installing NoMachine via winget..."
    try {
      & winget.exe install --id NoMachine.NoMachine --source winget --accept-package-agreements --accept-source-agreements --silent 2>&1 | ForEach-Object { Write-Host $_ }
      if ((Test-Path $nxServer) -or (Test-Path $nxPlayer)) {
        $installed = $true
        Write-Host "NoMachine installed via winget."
      }
    } catch {
      Write-Warning "winget install failed: $_"
    }
  }

  # Fall back to direct download.
  if (-not $installed) {
    $asset = "nomachine_${nomachineVersion}_x64.exe"
    $url = "https://download.nomachine.com/download/${nomachineMinor}/Windows/${asset}"
    $file = "C:\Users\Administrator\provision\downloads\nomachine\$asset"

    Write-Host "Downloading: $asset (NoMachine $nomachineVersion)"
    try {
      Download-File -Url $url -OutFile $file
    } catch {
      throw "NoMachine could not be installed. winget failed (TLS/cert issue on Server 2025) and the direct download URL is stale (NoMachine CDN redirects to homepage). To fix: manually download NoMachine from nomachine.com and set NOMACHINE_VERSION to the matching version. Error: $_"
    }
    Unblock-File $file -ErrorAction SilentlyContinue
    Write-Host "Running NoMachine installer (silent)..."
    Start-Process -FilePath $file -ArgumentList "/verysilent", "/norestart" -Wait
    if ((-not (Test-Path $nxServer)) -and (-not (Test-Path $nxPlayer))) {
      throw "NoMachine did not install."
    }
    Write-Host "NoMachine installed via direct download."
  }
} else {
  Write-Host "NoMachine already installed. Skipping installer."
}

# Ensure the service is running.
$service = Get-Service -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match 'nxserver' -or $_.DisplayName -match 'NoMachine' } |
  Select-Object -First 1
if ($service) {
  Set-Service -Name $service.Name -StartupType Automatic
  if ($service.Status -ne "Running") {
    Write-Host "Starting NoMachine service $($service.Name)..."
    Start-Service -Name $service.Name
  }
}
