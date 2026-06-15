Write-Host "#########################################################"
Write-Host "### discord (windows)"
Write-Host "#########################################################"

$adminDiscordRoot = "C:\Users\Administrator\AppData\Local\Discord"
$adminUpdateExe   = Join-Path $adminDiscordRoot 'Update.exe'

if (Test-Path $adminUpdateExe) {
  Write-Host "Discord already installed at $adminDiscordRoot. Skipping."
  exit 0
}

$envFile = "C:\Users\Administrator\provision\state\env.json"
if (-not (Test-Path $envFile)) {
  throw "env.json not found at $envFile; cannot resolve Administrator password for user-context install"
}

$envData = Get-Content -Path $envFile -Raw | ConvertFrom-Json
$windowsPassword = $envData.windows_password
if (-not $windowsPassword) {
  throw "windows_password missing from env.json; cannot run Discord install as Administrator"
}

$taskName = 'EveDiscordInstall'
$scriptPath = 'C:\Users\Administrator\provision\scripts\steps\install-discord.ps1'
Set-Content -Path $scriptPath -Value @'
winget install --id Discord.Discord --silent --accept-package-agreements --accept-source-agreements --source winget --scope user
'@
$taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

try { & schtasks.exe /Delete /TN $taskName /F 2>$null } catch {}
try { & schtasks.exe /Create /TN $taskName /SC ONCE /ST (Get-Date).AddMinutes(1).ToString("HH:mm") /RU "Administrator" /RP $windowsPassword /RL HIGHEST /IT /TR $taskCommand /F 2>$null | Out-Null } catch {}
try { & schtasks.exe /Run /TN $taskName 2>$null | Out-Null } catch {}

Write-Host "Scheduled Discord install under Administrator..."
$maxWaitSeconds = 600
$elapsed = 0
$installed = $false
while ($elapsed -lt $maxWaitSeconds) {
  Start-Sleep -Seconds 10
  $elapsed += 10
  if (Test-Path $adminUpdateExe) {
    $installed = $true
    break
  }
  Write-Host "Waiting for Discord install to complete... (${elapsed}s/${maxWaitSeconds}s)"
}

try { & schtasks.exe /Delete /TN $taskName /F 2>$null } catch {}

if (-not $installed) {
  throw "Discord did not install within ${maxWaitSeconds}s. $adminUpdateExe missing."
}

Write-Host "Discord installed at $adminDiscordRoot"
