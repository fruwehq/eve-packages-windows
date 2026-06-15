$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start 30"
Write-Host "#########################################################"

. "$PSScriptRoot\..\lib\downloads.ps1"

Write-Host "Installing Steam..."

$url  = "https://steamcdn-a.akamaihd.net/client/installer/SteamSetup.exe"
$file = "C:\Users\Administrator\provision\downloads\steam\SteamSetup.exe"

$steamExe = "${env:ProgramFiles(x86)}\Steam\Steam.exe"
if (Test-Path $steamExe) {
  Write-Host "Steam already installed at $steamExe. Skipping."

  Write-Host "---------------------------------------------------------"
  Write-Host "END 30 - early exit"
  Write-Host "---------------------------------------------------------"
  Write-Host ""

  exit 0
}

Download-File -Url $url -OutFile $file -SkipIfExists
Unblock-File $file -ErrorAction SilentlyContinue

Write-Host "Running Steam installer (silent)..."
$proc = Start-Process -FilePath $file -ArgumentList "/S" -Wait -PassThru
Write-Host "Steam installer exit code: $($proc.ExitCode)"

Start-Sleep -Seconds 3

if (!(Test-Path $steamExe)) {
  throw "Steam did not install silently. Steam.exe not found at $steamExe. If Steam is already installed manually, set currentStep to 3 and rerun the runner."
}

Write-Host "Steam installed at $steamExe"

Write-Host "---------------------------------------------------------"
Write-Host "END 30"
Write-Host "---------------------------------------------------------"
Write-Host ""
