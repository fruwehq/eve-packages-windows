$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start 20"
Write-Host "#########################################################"

. "$PSScriptRoot\..\lib\downloads.ps1"

$rebootFlag = 'C:\Users\Administrator\provision\state\reboot.flag'
$driverVersion = '24.12.24'

$alreadyInstalled = $false

# === Check existing VDD installation ==========================================
Write-Host "Checking Virtual Display Driver (VDD)..."

try {
  $existing = @(Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object {
      $_.InstanceId -like 'ROOT\\DISPLAY\\0000*' -or
      $_.InstanceId -like 'ROOT\\MTTVDD*' -or
      $_.FriendlyName -match 'Virtual Display|VDD|MttVDD'
    }
  )
  $healthy = @($existing | Where-Object {
      $_.Status -eq 'OK' -and $_.ConfigManagerErrorCode -eq 'CM_PROB_NONE'
    })
  $unhealthy = @($existing | Where-Object {
      $_.Status -ne 'OK' -or $_.ConfigManagerErrorCode -ne 'CM_PROB_NONE'
    })
  if ($healthy.Count -gt 0) {
    Write-Host "VDD already installed and healthy. Skipping installation step."
    $alreadyInstalled = $true
  } elseif ($unhealthy.Count -gt 0) {
    Write-Host "VDD is present but unhealthy; removing stale device before reinstall."
    foreach ($dev in $unhealthy) {
      Write-Host "Removing unhealthy VDD device: $($dev.FriendlyName) [$($dev.InstanceId)] status=$($dev.Status) code=$($dev.ConfigManagerErrorCode)"
      pnputil /remove-device "$($dev.InstanceId)" | ForEach-Object { Write-Host "  $_" }
    }
    Start-Sleep -Seconds 3
  }
} catch {
  Write-Host "Could not verify existing VDD installation. Continuing..."
}

# === Download VDD Control =====================================================
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$headers = @{ "User-Agent" = "Mozilla/5.0"; "Accept" = "application/vnd.github+json" }
$api = "https://api.github.com/repos/VirtualDrivers/Virtual-Display-Driver/releases/latest"

$release = $null
for ($i = 1; $i -le 5; $i++) {
  try { $release = Invoke-RestMethod -Uri $api -Headers $headers; break } catch {
    if ($i -eq 5) { throw "Failed to fetch VDD releases from GitHub API after 5 attempts: $_" }
    Start-Sleep -Seconds 2
  }
}

$controlAsset = $release.assets | Where-Object { $_.name -match '^VDD\.Control\..*\.zip$' } | Select-Object -First 1
if (-not $controlAsset) {
  throw "Could not find VDD.Control ZIP in latest release. Assets: $($release.assets.name -join ', ')"
}

$controlZipPath = "C:\Users\Administrator\provision\downloads\vdd\$($controlAsset.name)"
$controlExtractPath = "C:\Users\Administrator\provision\downloads\vdd\control"
Write-Host "Downloading VDD Control: $($controlAsset.name)"
Download-File -Url $controlAsset.browser_download_url -OutFile $controlZipPath -SkipIfExists
if (Test-Path $controlExtractPath) { Remove-Item $controlExtractPath -Recurse -Force }
New-Item -ItemType Directory -Path $controlExtractPath | Out-Null
Expand-Archive -Path $controlZipPath -DestinationPath $controlExtractPath -Force

# === Install VDD driver if missing ============================================
if (-not $alreadyInstalled) {
  $driverZipPath = "C:\Users\Administrator\provision\downloads\vdd\Signed-Driver-v$driverVersion-x64.zip"
  $driverExtractPath = "C:\Users\Administrator\provision\downloads\vdd\signed-$driverVersion-x64"
  $driverUrl = "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/$driverVersion/Signed-Driver-v$driverVersion-x64.zip"

  Write-Host "Downloading Virtual Display Driver $driverVersion signed x64 package..."
  Download-File -Url $driverUrl -OutFile $driverZipPath -SkipIfExists

  if (Test-Path $driverExtractPath) { Remove-Item -Recurse -Force $driverExtractPath }
  New-Item -ItemType Directory -Path $driverExtractPath -Force | Out-Null
  Expand-Archive -Path $driverZipPath -DestinationPath $driverExtractPath -Force

  $driverInf = Get-ChildItem -Path $driverExtractPath -Recurse -Filter 'MttVDD.inf' |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $driverInf) {
    throw "Could not find MttVDD.inf in $driverExtractPath."
  }

  $driverCat = Get-ChildItem -Path $driverExtractPath -Recurse -Filter 'mttvdd.cat' |
    Select-Object -First 1 -ExpandProperty FullName
  if ($driverCat) {
    $signature = Get-AuthenticodeSignature -LiteralPath $driverCat
    if ($signature.SignerCertificate) {
      Write-Host "Trusting VDD publisher certificate: $($signature.SignerCertificate.Subject)"
      $publisherCertPath = Join-Path $driverExtractPath 'vdd-publisher.cer'
      [System.IO.File]::WriteAllBytes($publisherCertPath, $signature.SignerCertificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
      Import-Certificate -FilePath $publisherCertPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
    }
  }

  $devcon = Join-Path $controlExtractPath 'Dependencies\devcon.exe'
  if (-not (Test-Path -LiteralPath $devcon)) {
    throw "Could not find devcon.exe in VDD Control dependencies at $devcon."
  }

  Write-Host "Installing Virtual Display Driver $driverVersion via devcon..."
  & $devcon install $driverInf 'Root\MttVDD'
  if ($LASTEXITCODE -ne 0) {
    throw "devcon VDD install failed (exit $LASTEXITCODE)"
  }
  Start-Sleep -Seconds 5

  try {
    $installed = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
      Where-Object {
        $_.InstanceId -like 'ROOT\\DISPLAY\\0000*' -or
        $_.InstanceId -like 'ROOT\\MTTVDD*' -or
        $_.FriendlyName -match 'Virtual Display|VDD|MttVDD'
      })
    $healthy = @($installed | Where-Object {
        $_.Status -eq 'OK' -and $_.ConfigManagerErrorCode -eq 'CM_PROB_NONE'
      })
    if ($healthy.Count -gt 0) {
      Write-Host "VDD installation successful."
      New-Item $rebootFlag -ItemType File -Force | Out-Null
    } else {
      foreach ($dev in $installed) {
        Write-Host "VDD device not healthy: $($dev.FriendlyName) [$($dev.InstanceId)] status=$($dev.Status) code=$($dev.ConfigManagerErrorCode)"
      }
      throw "VDD installation could not be verified as healthy."
    }
  } catch {
    throw "Could not verify VDD installation: $_"
  }
}

# === Install VDD Control GUI to permanent location + desktop shortcut =========
$controlInstallDir = 'C:\Program Files\VDD Control'
$controlExe = Join-Path $controlInstallDir 'VDD Control.exe'
$controlSourceExe = Join-Path $controlExtractPath 'VDD Control.exe'

if (-not (Test-Path -LiteralPath $controlSourceExe)) {
  Write-Host "WARNING: VDD Control.exe missing from extracted ZIP at $controlExtractPath"
} else {
  $sourceSize = (Get-Item -LiteralPath $controlSourceExe).Length
  $needsInstall = $true
  if (Test-Path -LiteralPath $controlExe) {
    $installedSize = (Get-Item -LiteralPath $controlExe).Length
    if ($installedSize -eq $sourceSize) { $needsInstall = $false }
  }
  if ($needsInstall) {
    Write-Host "Installing VDD Control to $controlInstallDir"
    if (Test-Path -LiteralPath $controlInstallDir) { Remove-Item -LiteralPath $controlInstallDir -Recurse -Force }
    New-Item -ItemType Directory -Path $controlInstallDir -Force | Out-Null
    Copy-Item -Path (Join-Path $controlExtractPath '*') -Destination $controlInstallDir -Recurse -Force
  } else {
    Write-Host "VDD Control already installed at $controlInstallDir (matching size)."
  }

  $shortcutPath = 'C:\Users\Public\Desktop\VDD Control.lnk'
  if (-not (Test-Path -LiteralPath $shortcutPath)) {
    Write-Host "Creating desktop shortcut: $shortcutPath"
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($shortcutPath)
    $sc.TargetPath = $controlExe
    $sc.WorkingDirectory = $controlInstallDir
    $sc.Description = 'Virtual Display Driver Control'
    $sc.Save()
  }
}

Write-Host "---------------------------------------------------------"
Write-Host "END 20"
Write-Host "---------------------------------------------------------"
Write-Host ""
