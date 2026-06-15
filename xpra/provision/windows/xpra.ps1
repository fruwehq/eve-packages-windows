$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start 35"
Write-Host "#########################################################"

. "$PSScriptRoot\..\lib\downloads.ps1"

Write-Host "Installing Xpra..."

$xpraDir = "${env:ProgramFiles}\Xpra"
$xpraExe = Join-Path $xpraDir "Xpra_cmd.exe"
$url  = "https://xpra.org/dists/windows/Xpra-x86_64_6.4.3-r0.msi"
$file = "C:\Users\Administrator\provision\downloads\xpra\Xpra-x86_64_6.4.3-r0.msi"

if (Test-Path $xpraExe) {
  Write-Host "Xpra already installed at $xpraDir. Skipping."

  Write-Host "---------------------------------------------------------"
  Write-Host "END 35 - early exit"
  Write-Host "---------------------------------------------------------"
  Write-Host ""

  exit 0
}

Download-File -Url $url -OutFile $file -SkipIfExists

Write-Host "Installing Xpra (silent MSI)..."
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Xpra_is1"
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
    Set-ItemProperty -Path $regPath -Name "UninstallString" -Value '""' -Force
}
$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", $file, "/qn", "/norestart" -Wait -PassThru
if ($proc.ExitCode -notin @(0, 1603)) {
  throw "Xpra MSI installer failed with exit code $($proc.ExitCode)"
}
if ($proc.ExitCode -eq 1603) {
  Write-Host "WARNING: Xpra MSI returned 1603 (known MSI Wrapper registry bug). Checking if install succeeded..."
}
Write-Host "Xpra installer exit code: $($proc.ExitCode)"

if (!(Test-Path $xpraExe)) {
  throw "Xpra did not install. Xpra_cmd.exe not found at $xpraExe"
}

Write-Host "Xpra installed at $xpraDir"

Write-Host "---------------------------------------------------------"
Write-Host "END 35"
Write-Host "---------------------------------------------------------"
Write-Host ""
