$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start 21"
Write-Host "#########################################################"

$settingsDir = 'C:\VirtualDisplayDriver'
$settingsPath = "$settingsDir\vdd_settings.xml"
$templatePath = Join-Path $PSScriptRoot '..\templates\vdd_settings.xml'
$rebootFlag = 'C:\Users\Administrator\provision\state\reboot.flag'
$envFile = 'C:\Users\Administrator\provision\state\env.json'

$changed = $false

# === Resolution config from env.json ===========================================
$DefaultDisplayResolution = '1920x1080'
if (Test-Path -LiteralPath $envFile) {
  $envData = Get-Content -LiteralPath $envFile -Raw | ConvertFrom-Json
  if ($envData.display_resolution) { $DefaultDisplayResolution = [string]$envData.display_resolution }
}

# Baseline list - 10 modes that Sunshine/Moonlight clients commonly request.
# Keep the established ultrawide/smaller mode set intact: the current VDD
# driver has been observed to fail post-start when this list is narrowed to
# only conventional monitor resolutions on Vultr Windows Server 2025.
$BaselineResolutions = @(
  '5120x1440',
  '4096x1152',
  '3008x846',
  '2560x1440',
  '2560x720',
  '1920x1080',
  '1680x1050',
  '1440x900',
  '1280x800',
  '1024x640'
)
$GlobalRefreshRates = @(30, 60, 120)
$PerResolutionRate = 60

$resolutions = New-Object System.Collections.Generic.List[object]
$seenRes = @{}
# Configured resolution first so it becomes the VDD's default/active mode; the
# full baseline set still follows (deduped) so no modes are narrowed away.
foreach ($r in (@($DefaultDisplayResolution) + @($BaselineResolutions))) {
  if ($seenRes.ContainsKey($r)) { continue }
  $seenRes[$r] = $true
  $parts = $r -split 'x'
  if ($parts.Count -ne 2) {
    Write-Host "WARNING: ignoring malformed resolution '$r' (expected WxH)"
    continue
  }
  $resolutions.Add(@{ Width = [int]$parts[0]; Height = [int]$parts[1] })
}

# === Render vdd_settings.xml from template =====================================
if (-not (Test-Path -LiteralPath $templatePath)) {
  throw "VDD settings template missing at $templatePath"
}

[xml]$xml = Get-Content -LiteralPath $templatePath -Raw

# Use SelectSingleNode (XPath) instead of dot-navigation: when <global> or
# <resolutions> are empty in the template, $xml.vdd_settings.global returns
# an empty string rather than the XmlElement, breaking .ChildNodes/.RemoveChild.
$globalNode = $xml.SelectSingleNode('/vdd_settings/global')
foreach ($child in @($globalNode.ChildNodes)) { [void]$globalNode.RemoveChild($child) }
foreach ($rate in $GlobalRefreshRates) {
  $n = $xml.CreateElement('g_refresh_rate')
  $n.InnerText = [string]$rate
  [void]$globalNode.AppendChild($n)
}

$resolutionsNode = $xml.SelectSingleNode('/vdd_settings/resolutions')
foreach ($child in @($resolutionsNode.ChildNodes)) { [void]$resolutionsNode.RemoveChild($child) }
foreach ($res in $resolutions) {
  $rNode = $xml.CreateElement('resolution')
  $w = $xml.CreateElement('width');        $w.InnerText  = [string]$res.Width;  [void]$rNode.AppendChild($w)
  $h = $xml.CreateElement('height');       $h.InnerText  = [string]$res.Height; [void]$rNode.AppendChild($h)
  $rr = $xml.CreateElement('refresh_rate'); $rr.InnerText = [string]$PerResolutionRate; [void]$rNode.AppendChild($rr)
  [void]$resolutionsNode.AppendChild($rNode)
}

# Serialize XML to UTF-8 bytes (no BOM). The driver fails to parse the file if
# the <?xml ... encoding="..."?> declaration disagrees with the on-disk encoding,
# so we write to a MemoryStream with UTF8Encoding and let XmlWriter emit the
# matching declaration.
$ms = New-Object System.IO.MemoryStream
$writerSettings = New-Object System.Xml.XmlWriterSettings
$writerSettings.Indent = $true
$writerSettings.IndentChars = '    '
$writerSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
$writerSettings.OmitXmlDeclaration = $false
$writer = [System.Xml.XmlWriter]::Create($ms, $writerSettings)
$xml.Save($writer)
$writer.Close()
$desiredBytes = $ms.ToArray()

if (-not (Test-Path -LiteralPath $settingsDir)) {
  New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
}

$existingBytes = $null
if (Test-Path -LiteralPath $settingsPath) {
  $existingBytes = [System.IO.File]::ReadAllBytes($settingsPath)
}

$bytesMatch = $false
if ($existingBytes -and $existingBytes.Length -eq $desiredBytes.Length) {
  $bytesMatch = $true
  for ($i = 0; $i -lt $existingBytes.Length; $i++) {
    if ($existingBytes[$i] -ne $desiredBytes[$i]) { $bytesMatch = $false; break }
  }
}

if (-not $bytesMatch) {
  Write-Host "Writing $settingsPath ($(($resolutions | Measure-Object).Count) resolutions, refresh rates: $($GlobalRefreshRates -join ', '))"
  [System.IO.File]::WriteAllBytes($settingsPath, $desiredBytes)
  $changed = $true
} else {
  Write-Host "$settingsPath already matches desired settings."
}

if ($changed) {
  Write-Host 'VDD settings change requires reboot. Requesting reboot...'
  New-Item $rebootFlag -ItemType File -Force | Out-Null
} else {
  Write-Host 'No reboot required.'
}

Write-Host 'VDD setup complete.'

Write-Host "---------------------------------------------------------"
Write-Host "END 21"
Write-Host "---------------------------------------------------------"
Write-Host ""
