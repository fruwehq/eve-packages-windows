$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start nomachine"
Write-Host "#########################################################"

. "$PSScriptRoot\..\lib\downloads.ps1"

# NoMachine has no stable "latest" URL; pin the version and allow env.json to
# override it (mirrors the Sunshine/RustDesk version-pinning pattern).
$envFile = "C:\Users\Administrator\provision\state\env.json"
$nomachineVersion = "8.16.1_1"
if (Test-Path $envFile) {
  try {
    $envData = Get-Content $envFile | ConvertFrom-Json
    if ($envData.nomachine_version) { $nomachineVersion = $envData.nomachine_version }
  } catch {
    Write-Warning "Failed to parse env file: $envFile"
  }
}
$nomachineMinor = ($nomachineVersion -split '_')[0]
$nomachineMinor = $nomachineMinor.Substring(0, $nomachineMinor.LastIndexOf('.'))

$nxServer = "C:\Program Files\NoMachine\bin\nxserver.exe"

if (-not (Test-Path $nxServer)) {
  $asset = "nomachine_${nomachineVersion}_x64.exe"
  $url = "https://download.nomachine.com/download/${nomachineMinor}/Windows/${asset}"
  $file = "C:\Users\Administrator\provision\downloads\nomachine\$asset"

  Write-Host "Downloading: $asset (NoMachine $nomachineVersion)"
  Download-File -Url $url -OutFile $file -SkipIfExists
  Unblock-File $file -ErrorAction SilentlyContinue

  Write-Host "Running NoMachine installer (silent)..."
  # NoMachine ships an Inno Setup installer; /verysilent installs the NX server
  # service without a reboot prompt.
  Start-Process -FilePath $file -ArgumentList "/verysilent", "/norestart" -Wait

  if (-not (Test-Path $nxServer)) {
    throw "NoMachine did not install. $nxServer not found."
  }
  Write-Host "NoMachine installed."
} else {
  Write-Host "NoMachine already installed at $nxServer. Skipping installer."
}

# Ensure the NoMachine service is running so the host is reachable right away.
$service = Get-Service -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match 'nxserver' -or $_.DisplayName -match 'NoMachine' } |
  Select-Object -First 1
if ($service) {
  Set-Service -Name $service.Name -StartupType Automatic
  if ($service.Status -ne "Running") {
    Write-Host "Starting NoMachine service $($service.Name)..."
    Start-Service -Name $service.Name
  }
} else {
  Write-Warning "NoMachine service not found after install; the server may still start via its own launcher."
}

Write-Host "---------------------------------------------------------"
Write-Host "END nomachine"
Write-Host "---------------------------------------------------------"
Write-Host ""
exit 0
