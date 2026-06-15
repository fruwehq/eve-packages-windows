$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start 31"
Write-Host "#########################################################"

. "$PSScriptRoot\..\lib\downloads.ps1"
. "$PSScriptRoot\..\lib\sunshine.ps1"

# Sunshine needs a virtual audio sink to stream audio from a headless
# Windows VM. Sunshine's default sink is "Steam Streaming Speakers", whose
# .inf only ships inside a fully-bootstrapped Steam install. We use
# VB-CABLE instead: signed by VB-Audio (no test signing), ~1 MB, and Steam-
# independent.
#
# Install pattern (same as Easy-GPU-PV / gcloudrig / cloudy-gamer): pre-add
# VB-Audio's signing certificate to TrustedPublisher so Windows accepts the
# driver without UAC, then run the bundled VBCABLE_Setup_x64.exe with
# `-i -h` (install, hidden). Hand-rolled SetupAPI device creation hits
# SPAPI_E_NO_ASSOCIATED_SERVICE because the VB-CABLE INF binds its service
# to the Media class with a prefixed hardware ID; let the vendor installer
# handle that.

$cableZipUrl   = 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip'
$downloadDir   = 'C:\Users\Administrator\provision\downloads\vb-cable'
$cableZipPath  = Join-Path $downloadDir 'VBCABLE_Driver_Pack45.zip'
$cableExtract  = Join-Path $downloadDir 'extracted'

$sunshineConf  = 'C:\Program Files\Sunshine\config\sunshine.conf'
$cableSinkName = 'CABLE Input (VB-Audio Virtual Cable)'

function Find-CableDevice {
  Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'VB-Audio Virtual Cable|CABLE Input' } |
    Select-Object -First 1
}

function Set-SunshineConfigEntry {
  param([string]$Path, [string]$Key, [string]$Value)

  $line     = "$Key = $Value"
  $existing = if (Test-Path $Path) { @(Get-Content -LiteralPath $Path) } else { @() }
  $hit      = $false
  $updated  = foreach ($l in $existing) {
    if ($l -match "^\s*$([regex]::Escape($Key))\s*=") {
      $hit = $true
      $line
    } else {
      $l
    }
  }
  if (-not $hit) {
    $updated = @($updated) + $line
  }
  Set-Content -LiteralPath $Path -Value (($updated -join "`r`n") + "`r`n") -NoNewline -Encoding ASCII
}

$device          = Find-CableDevice
$installedDriver = $false

if ($device) {
  Write-Host "VB-CABLE already installed: $($device.InstanceId)"
} else {
  Write-Host "Downloading VB-CABLE driver pack..."
  if (-not (Test-Path $downloadDir)) {
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
  }
  Download-File -Url $cableZipUrl -OutFile $cableZipPath -SkipIfExists

  if (Test-Path $cableExtract) {
    Remove-Item $cableExtract -Recurse -Force
  }
  Expand-Archive -Path $cableZipPath -DestinationPath $cableExtract -Force

  $catFile = Get-ChildItem -Path $cableExtract -Filter '*.cat' |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $catFile) {
    throw "Could not find VB-CABLE .cat file in $cableExtract"
  }

  $installerPath = Get-ChildItem -Path $cableExtract -Filter 'VBCABLE_Setup_x64.exe' |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $installerPath) {
    throw "Could not find VBCABLE_Setup_x64.exe in $cableExtract"
  }

  $cert = (Get-AuthenticodeSignature -FilePath $catFile).SignerCertificate
  if (-not $cert) {
    throw "Could not read signing certificate from $catFile"
  }

  $alreadyTrusted = Get-ChildItem Cert:\LocalMachine\TrustedPublisher |
    Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
  if ($alreadyTrusted) {
    Write-Host "VB-Audio signing certificate already trusted."
  } else {
    Write-Host "Adding VB-Audio signing cert to TrustedPublisher: $($cert.Subject)"
    $certPath = Join-Path $cableExtract 'VBCert.cer'
    [System.IO.File]::WriteAllBytes(
      $certPath,
      $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    & certutil.exe -Enterprise -AddStore 'TrustedPublisher' $certPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "certutil failed to add VB-Audio cert to TrustedPublisher (exit $LASTEXITCODE)"
    }
  }

  Write-Host "Running VB-CABLE installer ($installerPath -i -h)..."
  $proc = Start-Process -FilePath $installerPath -ArgumentList '-i', '-h' -Wait -PassThru
  if ($proc.ExitCode -ne 0) {
    throw "VBCABLE_Setup_x64.exe failed with exit code $($proc.ExitCode)"
  }

  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline -and -not $device) {
    Start-Sleep -Seconds 2
    $device = Find-CableDevice
  }
  if (-not $device) {
    throw "VB-CABLE device did not appear in Device Manager within 60s of running the installer."
  }
  Write-Host "VB-CABLE installed: $($device.InstanceId)"
  $installedDriver = $true
}

if (-not (Test-Path $sunshineConf)) {
  throw "Sunshine config not found at $sunshineConf"
}

$confBefore = Get-Content -LiteralPath $sunshineConf -Raw
Set-SunshineConfigEntry -Path $sunshineConf -Key 'virtual_sink'                -Value $cableSinkName
Set-SunshineConfigEntry -Path $sunshineConf -Key 'install_steam_audio_drivers' -Value 'disabled'
$confAfter = Get-Content -LiteralPath $sunshineConf -Raw

if ($installedDriver -or $confBefore -ne $confAfter) {
  if ($confBefore -ne $confAfter) {
    Write-Host "Updated Sunshine config (virtual_sink, install_steam_audio_drivers)."
  }
  Write-Host "Restarting Sunshine..."
  Restart-Sunshine
}

Write-Host "---------------------------------------------------------"
Write-Host "END 31"
Write-Host "---------------------------------------------------------"
Write-Host ""
