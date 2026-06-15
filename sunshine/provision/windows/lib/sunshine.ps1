# Shared Sunshine helpers used across provisioning steps.

$Script:SunshineExe = 'C:\Program Files\Sunshine\sunshine.exe'

function Restart-Sunshine {
  $svc = Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue
  if ($svc) {
    Restart-Service -Name 'SunshineService' -Force
    return
  }
  Get-Process -Name 'sunshine' -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
  Start-Process -FilePath $Script:SunshineExe -WindowStyle Hidden
}
