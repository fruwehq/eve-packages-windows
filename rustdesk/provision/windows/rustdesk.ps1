$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start rustdesk"
Write-Host "#########################################################"

. "$PSScriptRoot\..\lib\downloads.ps1"

Write-Host "Installing RustDesk..."

# The provisioning runner executes as SYSTEM via Scheduled Task, so
# %LOCALAPPDATA% expands to systemprofile\AppData\Local. RustDesk's NSIS
# installer also writes to the invoking user's LOCALAPPDATA. Discover the
# actual install path from the running process after install rather than
# hardcoding a per-user path.

# Candidate install locations: SYSTEM profile (Scheduled Task context) and
# the Administrator user profile (interactive session context).
$candidateDirs = @(
  "C:\Program Files\RustDesk",
  "C:\Program Files (x86)\RustDesk",
  "C:\Users\Administrator\AppData\Local\rustdesk",
  "C:\Windows\System32\config\systemprofile\AppData\Local\rustdesk",
  "${env:LOCALAPPDATA}\rustdesk"
)

$rustdeskDir = $null
$rustdeskExe = $null

# Check if already installed in any candidate location.
foreach ($dir in $candidateDirs) {
  $candidate = Join-Path $dir "rustdesk.exe"
  if (Test-Path $candidate) {
    $rustdeskDir = $dir
    $rustdeskExe = $candidate
    break
  }
}

# Also check via the running process (covers non-standard paths).
if (-not $rustdeskExe) {
  $proc = Get-Process rustdesk -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($proc -and $proc.Path) {
    $rustdeskExe = $proc.Path
    $rustdeskDir = Split-Path $rustdeskExe
  }
}

if (-not $rustdeskExe) {
  # Resolve the latest Windows x86_64 installer asset via the GitHub API
  # (mirrors the Sunshine step's pattern in sunshine.ps1).
  $headers = @{ "User-Agent"="Mozilla/5.0"; "Accept"="application/vnd.github+json" }
  $api = "https://api.github.com/repos/rustdesk/rustdesk/releases/latest"
  $release = $null
  for ($i = 1; $i -le 5; $i++) {
    try {
      $release = Invoke-RestMethod -Uri $api -Headers $headers
      break
    } catch {
      if ($i -eq 5) { throw }
      Start-Sleep -Seconds 2
    }
  }

  $asset = $release.assets |
    Where-Object { $_.name -match '^rustdesk-.*-x86_64\.exe$' } |
    Select-Object -First 1
  if (-not $asset) {
    throw "Could not find a Windows x86_64 .exe in the latest RustDesk release. Assets: $($release.assets.name -join ', ')"
  }
  $url  = $asset.browser_download_url
  $file = "C:\Users\Administrator\provision\downloads\rustdesk\$($asset.name)"

  Write-Host "Downloading: $($asset.name) (RustDesk $($release.tag_name))"
  Download-File -Url $url -OutFile $file -SkipIfExists
  Unblock-File $file -ErrorAction SilentlyContinue

  # RustDesk's NSIS /S installer spawns a child and the parent exits quickly,
  # but Start-Process -Wait can block forever if the child inherits the handle.
  # Launch without -Wait and poll for the running process, which indicates the
  # install is fully complete. RustDesk 1.4+ does not register a Windows
  # service; it runs as a user process.
  Write-Host "Running RustDesk installer (silent)..."
  Start-Process -FilePath $file -ArgumentList "/S"

  $installTimeout = 120
  $installStart = Get-Date
  while (((Get-Date) - $installStart).TotalSeconds -lt $installTimeout) {
    $proc = Get-Process rustdesk -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) {
      $rustdeskExe = $proc.Path
      $rustdeskDir = Split-Path $rustdeskExe
      Write-Host "RustDesk process running after $([int]((Get-Date) - $installStart).TotalSeconds)s"
      break
    }
    Start-Sleep -Seconds 2
  }

  if (-not $rustdeskExe) {
    throw "RustDesk did not install. No rustdesk process detected after ${installTimeout}s"
  }

  Write-Host "RustDesk installed at $rustdeskDir"
} else {
  Write-Host "RustDesk already installed at $rustdeskDir. Skipping installer."
}

$programFilesExe = "C:\Program Files\RustDesk\rustdesk.exe"
if (-not (Test-Path $programFilesExe)) {
  Write-Host "Installing RustDesk machine-wide..."
  Start-Process -FilePath $rustdeskExe -ArgumentList "--silent-install"
  Start-Sleep -Seconds 20
}

if (Test-Path $programFilesExe) {
  $rustdeskExe = $programFilesExe
  $rustdeskDir = Split-Path $rustdeskExe
  Write-Host "Using machine-wide RustDesk at $rustdeskExe"
}

function Get-RustDeskService {
  return Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'rustdesk' -or $_.DisplayName -match 'rustdesk' } |
    Select-Object -First 1
}

$service = Get-RustDeskService
if (-not $service) {
  Write-Host "Installing RustDesk Windows service..."
  Start-Process -FilePath $rustdeskExe -ArgumentList "--install-service"
  Start-Sleep -Seconds 20
  $service = Get-RustDeskService
}

if ($service) {
  Set-Service -Name $service.Name -StartupType Automatic
  if ($service.Status -ne "Running") {
    Write-Host "Starting RustDesk Windows service..."
    Start-Service -Name $service.Name
    Start-Sleep -Seconds 5
  }
} else {
  Write-Warning "RustDesk Windows service was not found after install-service."
}

# Put RustDesk on the system PATH so SSH-invoked clients can call `rustdesk` directly
# (the bare `rustdesk` lookup is what scripts/remote-rustdesk runs over SSH).
$systemPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($systemPath -notlike "*$rustdeskDir*") {
  Write-Host "Adding $rustdeskDir to system PATH"
  [Environment]::SetEnvironmentVariable("Path", "$systemPath;$rustdeskDir", "Machine")
  $env:Path = "$env:Path;$rustdeskDir"
}

# Read RustDesk config delivered via env.json (see scripts/provision).
$envFile = "C:\Users\Administrator\provision\state\env.json"
$rustdeskKey = $null
$rustdeskServer = $null
$rustdeskPassword = $null
$windowsPassword = $null
if (Test-Path $envFile) {
  try {
    $envData = Get-Content $envFile | ConvertFrom-Json
    $rustdeskKey      = $envData.rustdesk_key
    $rustdeskServer   = $envData.rustdesk_server
    $rustdeskPassword = $envData.rustdesk_password
    $windowsPassword  = $envData.windows_password
  } catch {
    Write-Warning "Failed to parse env file: $envFile"
  }
}

function Write-TextFileIfChanged {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Value
  )

  $existing = if (Test-Path $Path) { Get-Content $Path -Raw } else { $null }
  if ($existing -ne $Value) {
    $parent = Split-Path $Path
    if (-not (Test-Path $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -Path $Path -Value $Value -Encoding UTF8 -NoNewline
  }
}

function Escape-ForSingleQuotedPowerShell {
  param([string]$Value)
  return $Value.Replace("'", "''")
}

function Get-PasswordMarkerValue {
  param([Parameter(Mandatory = $true)][string]$Password)

  $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Password))
  $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
  return "v3:$hash"
}

function Set-RustDeskPasswordIfNeeded {
  param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Password,
    [Parameter(Mandatory = $true)][string]$MarkerDir,
    [Parameter(Mandatory = $true)][string]$Context
  )

  if (-not (Test-Path $MarkerDir)) {
    New-Item -ItemType Directory -Path $MarkerDir -Force | Out-Null
  }

  $passwordMarker = Join-Path $MarkerDir 'eve-password.sha256'
  $desired = Get-PasswordMarkerValue -Password $Password
  $existing = if (Test-Path $passwordMarker) { (Get-Content $passwordMarker -Raw).Trim() } else { '' }
  if ($existing -eq $desired) {
    Write-Host "RustDesk permanent password already applied for $Context."
    return
  }

  Write-Host "Setting RustDesk permanent password for $Context..."
  $output = & $Exe --password $Password 2>&1 | Out-String
  if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "RustDesk --password failed for ${Context}: $output"
  }
  Set-Content -Path $passwordMarker -Value $desired -Encoding ASCII -NoNewline
}

function Sync-RustDeskIdentityToServiceProfiles {
  $adminIdentity = "C:\Users\Administrator\AppData\Roaming\RustDesk\config\RustDesk.toml"
  if (-not (Test-Path $adminIdentity)) {
    return
  }

  $sourceContent = Get-Content -LiteralPath $adminIdentity -Raw
  foreach ($dir in @(
    "C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config",
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config",
    "C:\ProgramData\RustDesk\config"
  )) {
    if (-not (Test-Path $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $targetIdentity = Join-Path $dir "RustDesk.toml"
    $targetContent = if (Test-Path $targetIdentity) { Get-Content -LiteralPath $targetIdentity -Raw } else { "" }
    if ($sourceContent -ne $targetContent) {
      Write-Host "Copying RustDesk identity to $targetIdentity"
      Set-Content -Path $targetIdentity -Value $sourceContent -Encoding UTF8 -NoNewline
    }
  }
}

Write-Host "Waiting for RustDesk process..."
for ($i = 1; $i -le 15; $i++) {
  $proc = Get-Process rustdesk -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($proc) { break }
  Start-Sleep -Seconds 2
}

# RustDesk 1.4+ runs as a user process (not a Windows service). `--option`
# and `--password` write to the *user* config; the daemon reads its *own*
# config dir. Write the TOML directly into every plausible config location so
# whichever the running process uses gets the right rendezvous_server/key/password.
#
# Password note: RustDesk stores the permanent password separately from
# RustDesk2.toml. Use a versioned local marker so provisioning can force a
# one-time password reset when this script's password handling changes.
if ($rustdeskServer -or $rustdeskKey -or $rustdeskPassword) {
  $tomlBuilder = New-Object System.Text.StringBuilder
  if ($rustdeskServer) {
    [void]$tomlBuilder.AppendLine("rendezvous_server = '${rustdeskServer}:21116'")
  }
  [void]$tomlBuilder.AppendLine("")
  [void]$tomlBuilder.AppendLine("[options]")
  if ($rustdeskServer) {
    [void]$tomlBuilder.AppendLine("custom-rendezvous-server = '$rustdeskServer'")
    [void]$tomlBuilder.AppendLine("relay-server = '$rustdeskServer'")
  }
  if ($rustdeskKey) {
    [void]$tomlBuilder.AppendLine("key = '$rustdeskKey'")
  }
  if ($rustdeskPassword) {
    [void]$tomlBuilder.AppendLine("verification-method = 'use-permanent-password'")
    [void]$tomlBuilder.AppendLine("approve-mode = 'password'")
  }
  $toml = $tomlBuilder.ToString()

  $configDirs = @(
    "C:\Users\Administrator\AppData\Roaming\RustDesk\config",
    "C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config",
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config",
    "C:\ProgramData\RustDesk\config",
    "$env:APPDATA\RustDesk\config"
  )

  $configChanged = $false
  foreach ($dir in $configDirs) {
    $cfgPath = Join-Path $dir "RustDesk2.toml"
    $existing = if (Test-Path $cfgPath) { Get-Content $cfgPath -Raw } else { "" }
    if ($existing -ne $toml) {
      $configChanged = $true
      break
    }
  }

  if ($configChanged) {
    Write-Host "Stopping RustDesk to rewrite config..."
    Get-Process rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2

    foreach ($dir in $configDirs) {
      if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
      }
      $cfgPath = Join-Path $dir "RustDesk2.toml"
      Write-Host "Writing $cfgPath"
      Set-Content -Path $cfgPath -Value $toml -Encoding UTF8 -NoNewline
    }

    Write-Host "Restarting RustDesk service..."
    $service = Get-RustDeskService
    if ($service) {
      Start-Service -Name $service.Name
    } else {
      Start-Process -FilePath $rustdeskExe -ArgumentList "--server" -WindowStyle Hidden
    }
    Start-Sleep -Seconds 3
  } else {
    Write-Host "RustDesk config already matches desired state -- leaving password/salt intact."
  }
}

if ($rustdeskPassword) {
  Set-RustDeskPasswordIfNeeded `
    -Exe $rustdeskExe `
    -Password $rustdeskPassword `
    -MarkerDir "C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk" `
    -Context "SYSTEM"
}

# RustDesk stores the generated identity and encrypted permanent password in
# RustDesk.toml, while rendezvous/server preferences live in RustDesk2.toml.
# The service and interactive tray can read different profile directories; keep
# their identity file aligned so the ID reported by --get-id is the same ID the
# unattended service registers with the rendezvous server.
Sync-RustDeskIdentityToServiceProfiles

$service = Get-RustDeskService
if ($service) {
  Set-Service -Name $service.Name -StartupType Automatic
  if ($service.Status -ne "Running") {
    Write-Host "Starting RustDesk Windows service after config update..."
    Start-Service -Name $service.Name
    Start-Sleep -Seconds 5
  }
}

# The provisioning runner executes as SYSTEM. That is enough to install RustDesk,
# but not enough to guarantee the interactive Administrator desktop has a running
# RustDesk process after login. Register a user-session launcher and a configure
# helper so the visible desktop owns the RustDesk process and permanent password.
$stateDir = "C:\Users\Administrator\provision\state"
if (-not (Test-Path $stateDir)) {
  New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

$startScript = Join-Path $stateDir "start-rustdesk.ps1"
$configureScript = Join-Path $stateDir "configure-rustdesk-user.ps1"
$startupScript = Join-Path $stateDir "ensure-rustdesk-startup.ps1"
$escapedExe = Escape-ForSingleQuotedPowerShell $rustdeskExe
$escapedEnvFile = Escape-ForSingleQuotedPowerShell $envFile
$escapedConfigureScript = Escape-ForSingleQuotedPowerShell $configureScript

$startScriptBody = @"
`$ErrorActionPreference = 'SilentlyContinue'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File '$escapedConfigureScript' | Out-Null
"@
Write-TextFileIfChanged -Path $startScript -Value $startScriptBody

$configureScriptBody = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$exe = '$escapedExe'
`$envFile = '$escapedEnvFile'
if (-not (Test-Path `$exe)) { exit 0 }
`$currentSessionId = (Get-Process -Id `$PID).SessionId
`$sessionRustDesk = Get-Process rustdesk -ErrorAction SilentlyContinue | Where-Object { `$_.SessionId -eq `$currentSessionId } | Select-Object -First 1
if (-not `$sessionRustDesk) {
  Start-Process -FilePath `$exe -WindowStyle Hidden
  Start-Sleep -Seconds 3
}
if (Test-Path `$envFile) {
  try {
    `$envData = Get-Content `$envFile | ConvertFrom-Json
    `$password = `$envData.rustdesk_password
    if (`$password) {
      `$markerDir = Join-Path `$env:APPDATA 'RustDesk'
      if (-not (Test-Path `$markerDir)) { New-Item -ItemType Directory -Path `$markerDir -Force | Out-Null }
      `$passwordMarker = Join-Path `$markerDir 'eve-password.sha256'
      `$hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes(`$password))
      `$hash = 'v3:' + ([System.BitConverter]::ToString(`$hashBytes)).Replace('-', '').ToLowerInvariant()
      `$existing = if (Test-Path `$passwordMarker) { (Get-Content `$passwordMarker -Raw).Trim() } else { '' }
      if (`$existing -ne `$hash) {
        `$output = & `$exe --password `$password 2>&1 | Out-String
        if (`$null -eq `$LASTEXITCODE -or `$LASTEXITCODE -eq 0) {
          Set-Content -Path `$passwordMarker -Value `$hash -Encoding ASCII -NoNewline
        }
      }
    }
  } catch {
  }
}
"@
Write-TextFileIfChanged -Path $configureScript -Value $configureScriptBody

$startupScriptBody = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$exe = '$escapedExe'
`$envFile = '$escapedEnvFile'
`$logFile = 'C:\Users\Administrator\provision\logs\rustdesk-startup.log'
function Write-EveLog {
  param([string]`$Message)
  try {
    `$parent = Split-Path `$logFile
    if (-not (Test-Path `$parent)) { New-Item -ItemType Directory -Path `$parent -Force | Out-Null }
    Add-Content -Path `$logFile -Value ("{0} {1}" -f (Get-Date).ToString("s"), `$Message) -Encoding UTF8
  } catch {
  }
}
if (-not (Test-Path `$exe)) {
  Write-EveLog "rustdesk.exe missing: `$exe"
  exit 0
}
`$service = Get-Service -ErrorAction SilentlyContinue |
  Where-Object { `$_.Name -match 'rustdesk' -or `$_.DisplayName -match 'rustdesk' } |
  Select-Object -First 1
if (`$service) {
  Set-Service -Name `$service.Name -StartupType Automatic
  if (`$service.Status -ne 'Running') {
    Start-Service -Name `$service.Name
    Start-Sleep -Seconds 5
    Write-EveLog "started service `$(`$service.Name)"
  }
}
`$currentSessionId = (Get-Process -Id `$PID).SessionId
`$sessionRustDesk = Get-Process rustdesk -ErrorAction SilentlyContinue |
  Where-Object { `$_.SessionId -eq `$currentSessionId } |
  Select-Object -First 1
if (-not `$sessionRustDesk) {
  Start-Process -FilePath `$exe -WindowStyle Hidden
  Start-Sleep -Seconds 5
  Write-EveLog "started process in session `$currentSessionId"
}
if (Test-Path `$envFile) {
  try {
    `$envData = Get-Content `$envFile | ConvertFrom-Json
    `$password = `$envData.rustdesk_password
    if (`$password) {
      `$markerDir = 'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk'
      if (-not (Test-Path `$markerDir)) { New-Item -ItemType Directory -Path `$markerDir -Force | Out-Null }
      `$passwordMarker = Join-Path `$markerDir 'eve-password.sha256'
      `$hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes(`$password))
      `$hash = 'v3:' + ([System.BitConverter]::ToString(`$hashBytes)).Replace('-', '').ToLowerInvariant()
      `$existing = if (Test-Path `$passwordMarker) { (Get-Content `$passwordMarker -Raw).Trim() } else { '' }
      if (`$existing -ne `$hash) {
        `$output = & `$exe --password `$password 2>&1 | Out-String
        if (`$null -eq `$LASTEXITCODE -or `$LASTEXITCODE -eq 0) {
          Set-Content -Path `$passwordMarker -Value `$hash -Encoding ASCII -NoNewline
          Write-EveLog "applied SYSTEM permanent password"
        } else {
          Write-EveLog "password command failed: `$output"
        }
      }
    }
  } catch {
    Write-EveLog "password setup failed: `$(`$_.Exception.Message)"
  }
}
try {
  `$id = (& `$exe --get-id 2>`$null) -replace '\s', ''
  if (`$id) { Write-EveLog "rustdesk id `$id" }
} catch {
}
"@
Write-TextFileIfChanged -Path $startupScript -Value $startupScriptBody

$runValue = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$configureScript`""
New-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "EveRustDesk" -Value $runValue
Write-Host "Registered RustDesk interactive autostart."

$startupTask = "EveRustDeskStartup"
$startupTaskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startupScript`""
try {
  & schtasks.exe /Create /TN $startupTask /SC ONSTART /RU SYSTEM /RL HIGHEST /TR $startupTaskCommand /F | Out-Null
  & schtasks.exe /Run /TN $startupTask | Out-Null
  Write-Host "Registered and started RustDesk SYSTEM startup task."
} catch {
  Write-Warning "Could not register or run RustDesk SYSTEM startup task."
}

if ($windowsPassword) {
  $autoTask = "EveRustDeskAutostart"
  $configureTask = "EveRustDeskConfigure"
  $startTaskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$configureScript`""
  $configureTaskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$configureScript`""

  try {
    & schtasks.exe /Create /TN $autoTask /SC ONLOGON /RU "Administrator" /RP $windowsPassword /RL HIGHEST /IT /TR $startTaskCommand /F | Out-Null
    Write-Host "Registered RustDesk Administrator logon task."
  } catch {
    Write-Warning "Could not register RustDesk Administrator logon task; HKLM Run fallback is in place."
  }

  try {
    $configureStart = (Get-Date).AddMinutes(1).ToString("HH:mm")
    & schtasks.exe /Create /TN $configureTask /SC ONCE /ST $configureStart /RU "Administrator" /RP $windowsPassword /RL HIGHEST /IT /TR $configureTaskCommand /F | Out-Null
    & schtasks.exe /Run /TN $configureTask | Out-Null
    Start-Sleep -Seconds 8
    & schtasks.exe /Delete /TN $configureTask /F | Out-Null
    Write-Host "Submitted RustDesk user-session configuration task."
  } catch {
    Write-Warning "Could not submit RustDesk user-session configuration task; it will be applied on next login."
  }
} else {
  Write-Warning "Windows password not available; RustDesk password can only be applied in the provisioning context."
}

Write-Host "Ensuring RustDesk is started in the current context..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $configureScript | Out-Null
Sync-RustDeskIdentityToServiceProfiles

$service = Get-RustDeskService
if ($service) {
  Write-Host "Restarting RustDesk service after final identity sync..."
  Restart-Service -Name $service.Name -Force
  Start-Sleep -Seconds 5
}

Write-Host "Resolving RustDesk ID..."
$resolvedId = $null
for ($i = 1; $i -le 15; $i++) {
  $id = (& $rustdeskExe --get-id 2>$null | Out-String) -replace '\s', ''
  if ($id) {
    Write-Host "RustDesk ID: $id"
    $resolvedId = $id
    break
  }
  Start-Sleep -Seconds 2
}
if (-not $resolvedId) {
  Write-Warning "RustDesk ID was not available yet; service/startup tasks are installed and will retry on boot/logon."
}

Write-Host "---------------------------------------------------------"
Write-Host "END rustdesk"
Write-Host "---------------------------------------------------------"
Write-Host ""
exit 0
