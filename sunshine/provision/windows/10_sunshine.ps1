$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start 10"
Write-Host "#########################################################"

. "$PSScriptRoot\..\lib\downloads.ps1"

Write-Host "Ensuring Sunshine is installed and configured..."

$sunshineDir = "${env:ProgramFiles}\Sunshine"
$sunshineExe = Join-Path $sunshineDir "sunshine.exe"
$configPath = Join-Path $sunshineDir "config\sunshine.conf"
$envFile = "C:\Users\Administrator\provision\state\env.json"
$sunshinePassword = $env:EPHEMERAL_SUNSHINE_PASSWORD

# Resolve the desired Sunshine version (pinned via SUNSHINE_VERSION or env.json;
# otherwise the latest GitHub release is used).
$sunshineVersion = $null
if ($env:SUNSHINE_VERSION) {
  $sunshineVersion = $env:SUNSHINE_VERSION
} elseif ((Test-Path $envFile)) {
  try {
    $envData = Get-Content $envFile | ConvertFrom-Json
    $sunshineVersion = $envData.sunshine_version
  } catch {}
}

# Determine the currently installed version so re-provisioning can converge on
# the pinned version (uninstall + reinstall) instead of blindly skipping.
$installedVersion = $null
if (Test-Path $sunshineExe) {
  $installedVersion = (Get-Item $sunshineExe).VersionInfo.ProductVersion
}

$needInstall = $true
if ($installedVersion) {
  if (-not $sunshineVersion) {
    Write-Host "Sunshine v$installedVersion already installed and no version pinned. Skipping installer."
    $needInstall = $false
  } elseif ($installedVersion -eq $sunshineVersion) {
    Write-Host "Sunshine v$installedVersion already installed (matches pinned version). Skipping installer."
    $needInstall = $false
  } else {
    Write-Host "Sunshine v$installedVersion installed but v$sunshineVersion is pinned. Reinstalling."
  }
}

if ($needInstall) {
  $asset = "Sunshine-Windows-AMD64-installer.exe"

  if ($sunshineVersion) {
    $url = "https://github.com/LizardByte/Sunshine/releases/download/v$sunshineVersion/$asset"
    # Version-stamped local name so a cached installer from a different version
    # is never reused (the upstream asset name is identical across releases).
    $localName = "Sunshine-$sunshineVersion-installer.exe"
    Write-Host "Downloading: $asset (v$sunshineVersion)"
  } else {
    Write-Host "SUNSHINE_VERSION not set - resolving latest release via GitHub API..."
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $apiHeaders = @{ "User-Agent" = "Mozilla/5.0"; "Accept" = "application/vnd.github+json" }
    $apiUrl = "https://api.github.com/repos/LizardByte/Sunshine/releases/latest"
    $release = $null
    for ($i = 1; $i -le 5; $i++) {
      try { $release = Invoke-RestMethod -Uri $apiUrl -Headers $apiHeaders; break } catch {
        if ($i -eq 5) { throw "Failed to query GitHub API for Sunshine releases: $($_.Exception.Message)" }
        Start-Sleep -Seconds 2
      }
    }
    $releaseAsset = $release.assets | Where-Object { $_.name -eq $asset } | Select-Object -First 1
    if (-not $releaseAsset) {
      $releaseAsset = $release.assets | Where-Object { $_.name -match "^Sunshine-Windows-.*-installer\.exe$" } | Select-Object -First 1
    }
    if (-not $releaseAsset) {
      throw "Could not find Windows installer in latest Sunshine release. Assets: $($release.assets.name -join ', ')"
    }
    $url = $releaseAsset.browser_download_url
    $localName = $releaseAsset.name
    Write-Host "Downloading: $($releaseAsset.name) (latest)"
  }

  # Uninstall any existing version first so a different (pinned) version can take
  # its place; preserve paired-client state across the reinstall.
  $pairingBackup = $null
  if ($installedVersion) {
    $stateFile = Join-Path $sunshineDir "config\sunshine_state.json"
    if (Test-Path $stateFile) {
      $pairingBackup = Join-Path $env:TEMP "sunshine_state.json.bak"
      Copy-Item $stateFile $pairingBackup -Force
    }
    Get-Service SunshineService -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    $uninstaller = Join-Path $sunshineDir "Uninstall.exe"
    if (-not (Test-Path $uninstaller)) {
      throw "Cannot replace Sunshine: uninstaller not found at $uninstaller"
    }
    Write-Host "Uninstalling Sunshine v$installedVersion (silent)..."
    Start-Process -FilePath $uninstaller -ArgumentList "/S" -PassThru | Out-Null
    # The NSIS uninstaller forks, so poll for sunshine.exe removal instead of -Wait.
    $deadline = (Get-Date).AddSeconds(90)
    while ((Test-Path $sunshineExe) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (Test-Path $sunshineExe) {
      throw "Sunshine uninstall did not complete (sunshine.exe still present)"
    }
    Write-Host "Sunshine uninstalled."
  }

  $file = "C:\Users\Administrator\provision\downloads\sunshine\$localName"
  Download-File -Url $url -OutFile $file -SkipIfExists
  Unblock-File $file -ErrorAction SilentlyContinue

  Write-Host "Running Sunshine installer (silent)..."
  $proc = Start-Process -FilePath $file -ArgumentList "/S" -Wait -PassThru
  if ($proc.ExitCode -ne 0) {
    throw "Sunshine installer failed with exit code $($proc.ExitCode)"
  }
  Write-Host "Sunshine installer exit code: $($proc.ExitCode)"

  # Restore paired-client state so existing Moonlight clients stay paired.
  if ($pairingBackup -and (Test-Path $pairingBackup)) {
    $stateDir = Join-Path $sunshineDir "config"
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    Copy-Item $pairingBackup (Join-Path $stateDir "sunshine_state.json") -Force
    Write-Host "Restored paired-client state."
  }
}

# Ensure the config file exists and allows remote access for this ephemeral instance.
if (!(Test-Path $configPath)) {
  New-Item -ItemType File -Path $configPath -Force | Out-Null
}


if (-not (Select-String -Path $configPath -Pattern "^\s*origin_web_ui_allowed\s*=" -Quiet)) {
  Add-Content -Path $configPath -Value "`norigin_web_ui_allowed = wan`n"
}

if (-not (Select-String -Path $configPath -Pattern "^\s*private_key_mandatory\s*=" -Quiet)) {
  Add-Content -Path $configPath -Value "private_key_mandatory = disabled`n"
}

$pubIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -ErrorAction SilentlyContinue)
if ($pubIp -and -not (Select-String -Path $configPath -Pattern "^\s*external_ip\s*=" -Quiet)) {
  Add-Content -Path $configPath -Value "external_ip = $pubIp`n"
  Write-Host "Sunshine external_ip set to $pubIp"
}

# Sunshine spans TCP 47984/47989/48010 and UDP 47998-48000/48002. Open the full
# 47984-48010 span so the video (47998) and control (47999) ports are reachable.
New-NetFirewallRule -DisplayName "Sunshine TCP (47984-48010)" -Direction Inbound -Protocol TCP -LocalPort 47984-48010 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "Sunshine UDP (47984-48010)" -Direction Inbound -Protocol UDP -LocalPort 47984-48010 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
Write-Host "Sunshine firewall rules configured."

# Set Sunshine Web UI credentials from the environment or env.json.
# Use a fixed username to keep provisioning simple and reproducible.
if (-not $sunshinePassword -and (Test-Path $envFile)) {
  try {
    $envData = Get-Content $envFile | ConvertFrom-Json
    $sunshinePassword = $envData.sunshine_password
  } catch {
    throw "Failed to read Sunshine password from $envFile"
  }
}

if (-not $sunshinePassword) {
  throw "Sunshine password not provided. Set EPHEMERAL_SUNSHINE_PASSWORD or create $envFile with a sunshine_password field."
}

if (!(Test-Path $sunshineExe)) {
  throw "Sunshine executable not found at $sunshineExe"
}

Write-Host "Setting Sunshine credentials..."
$credsProc = Start-Process -FilePath $sunshineExe -ArgumentList $configPath, "--creds", "sunshine", $sunshinePassword -Wait -PassThru
if ($credsProc.ExitCode -ne 0) {
  throw "Sunshine credential setup failed with exit code $($credsProc.ExitCode)"
}
Write-Host "Sunshine credentials exit code: $($credsProc.ExitCode)"

Write-Host "Starting Sunshine process..."
Start-Process -FilePath $sunshineExe -ArgumentList $configPath

# Wait for Sunshine Web UI port to become available
Write-Host "Waiting for Sunshine API..."
$maxAttempts = 10
$attempt = 0
$ready = $false
$lastWaitError = $null

while (-not $ready -and $attempt -lt $maxAttempts) {
  $attempt++
  $client = $null
  try {
    Write-Host "Sunshine wait attempt $attempt/$maxAttempts..."
    $client = New-Object System.Net.Sockets.TcpClient
    $async = $client.BeginConnect("127.0.0.1", 47990, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne(2000, $false)) {
      throw "TCP connect timed out"
    }
    $client.EndConnect($async)
    Write-Host "Sunshine TCP port is reachable."
    $ready = $true
    break
  } catch {
    $lastWaitError = $_.Exception.Message
    Write-Host "Sunshine wait attempt $attempt failed: $lastWaitError"
  } finally {
    if ($client) {
      $client.Close()
    }
  }
  Start-Sleep -Seconds 2
}

if (-not $ready) {
  if ($lastWaitError) {
    Write-Warning "Sunshine API did not become ready in time. Last error: $lastWaitError. Skipping auto pairing."
  } else {
    Write-Warning "Sunshine API did not become ready in time. Skipping auto pairing."
  }
} else {
  Write-Host "Sunshine API ready. Completing welcome setup..."

  # Sunshine 2025.x shows a welcome page on first run. Complete it by posting
  # the credentials via the password API, which finalizes the initial setup and
  # allows authenticated API requests.
  $welcomeBody = @{
    currentUsername  = "sunshine"
    currentPassword  = $sunshinePassword
    newUsername      = "sunshine"
    newPassword      = $sunshinePassword
    confirmNewPassword = $sunshinePassword
  } | ConvertTo-Json -Compress

  try {
    $welcomeBodyFile = Join-Path $env:TEMP "sunshine-welcome-request.json"
    Set-Content -Path $welcomeBodyFile -Value $welcomeBody -NoNewline

    $welcomeResponseFile = Join-Path $env:TEMP "sunshine-welcome-response.json"
    if (Test-Path $welcomeResponseFile) {
      Remove-Item $welcomeResponseFile -Force -ErrorAction SilentlyContinue
    }

    # Try the password endpoint (Sunshine 2025.x initial setup)
    $httpCode = & curl.exe -sS -k `
      -u "sunshine:$sunshinePassword" `
      -H "Content-Type: application/json" `
      --data-binary "@$welcomeBodyFile" `
      -o $welcomeResponseFile `
      -w "%{http_code}" `
      "https://127.0.0.1:47990/api/password"
    Write-Host "Welcome/password setup: HTTP $httpCode"
    if (Test-Path $welcomeResponseFile) {
      $welcomeResp = Get-Content -Path $welcomeResponseFile -Raw
      if ($welcomeResp) { Write-Host $welcomeResp }
    }
  } catch {
    Write-Warning "Welcome setup attempt failed: $($_.Exception.Message)"
  }

  Write-Host "Sending pairing PIN..."

  $pairBody = @{ pin = "1234"; name = "ephemeral-client" } | ConvertTo-Json -Compress

  try {
    $pairBodyFile = Join-Path $env:TEMP "sunshine-pair-request.json"
    Set-Content -Path $pairBodyFile -Value $pairBody -NoNewline

    $pairResponseFile = Join-Path $env:TEMP "sunshine-pair-response.json"
    if (Test-Path $pairResponseFile) {
      Remove-Item $pairResponseFile -Force -ErrorAction SilentlyContinue
    }

    $httpCode = & curl.exe -sS -k `
      -u "sunshine:$sunshinePassword" `
      -H "Content-Type: application/json" `
      --data-binary "@$pairBodyFile" `
      -o $pairResponseFile `
      -w "%{http_code}" `
      "https://127.0.0.1:47990/api/pin"
    $curlExitCode = $LASTEXITCODE
    $responseBody = if (Test-Path $pairResponseFile) { Get-Content -Path $pairResponseFile -Raw } else { "" }

    if ($curlExitCode -ne 0) {
      throw "curl exited with code $curlExitCode. Response: $responseBody"
    }

    if ($httpCode -notmatch "^2") {
      throw "Sunshine pairing API returned HTTP $httpCode. Response: $responseBody"
    }

    Write-Host "Pairing PIN submitted successfully."
    if ($responseBody) {
      Write-Host $responseBody
    }
  } catch {
    Write-Warning "Failed to submit pairing PIN: $($_.Exception.Message)"
  }
}

Write-Host "---------------------------------------------------------"
Write-Host "END 10"
Write-Host "---------------------------------------------------------"
Write-Host ""
