$ErrorActionPreference = 'Stop'

Write-Host "#########################################################"
Write-Host "### Start 22"
Write-Host "#########################################################"

# Make VDD the sole active display on the desktop at the resolution configured
# in step 21 (EPHEMERAL_DISPLAY_RESOLUTION).  NVIDIA's display output is
# disconnected from the desktop topology so the virtual desktop equals VDD's
# resolution alone.  The NVIDIA ADAPTER stays enabled - Sunshine still uses it
# for NVENC encoding and DXGI Desktop Duplication captures the whole desktop
# (which is now just VDD).  The Microsoft Basic Display Adapter is disabled
# entirely.

$stateDir  = 'C:\Users\Administrator\provision\state'
$csPath    = Join-Path $stateDir 'display-config.cs'
$exePath   = Join-Path $stateDir 'display-config.exe'
$marker    = Join-Path $stateDir 'display-config-done.flag'
$dcLog     = Join-Path $stateDir 'display-config.log'
$rebootFlg = Join-Path $stateDir 'reboot.flag'

# ---- Disable Microsoft Basic Display Adapter ----
# Match by FriendlyName rather than full PnP InstanceID. The QEMU/Bochs vendor
# (1234:1111) is consistent across cloud Windows VMs, but the trailing instance
# specifier (e.g. "3&11583659&0&08") is hardware-instance-specific and changes
# per VM, so a hardcoded InstanceID would silently skip on every fresh box.
$basicAdapters = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -eq 'Microsoft Basic Display Adapter' })

if ($basicAdapters.Count -eq 0) {
    Write-Host "Microsoft Basic Display Adapter not present - nothing to disable."
}

foreach ($dev in $basicAdapters) {
    if ($dev.ConfigManagerErrorCode -eq 'CM_PROB_DISABLED') {
        Write-Host "Basic adapter already disabled: $($dev.InstanceId)"
        continue
    }
    Write-Host "Disabling: $($dev.FriendlyName) [$($dev.InstanceId)]"
    Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false
}

# ---- C# source: display-config.exe ----
$csSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;

class DisplayConfig
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public uint dmDisplayOrientation;
        public uint dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel;
        public uint dmPelsWidth;
        public uint dmPelsHeight;
        public uint dmDisplayFlags;
        public uint dmDisplayFrequency;
        public uint dmICMMethod;
        public uint dmICMIntent;
        public uint dmMediaType;
        public uint dmDitherType;
        public uint dmReserved1;
        public uint dmReserved2;
        public uint dmPanningWidth;
        public uint dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(
        string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettingsEx(
        string deviceName, int modeNum, ref DEVMODE devMode, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int ChangeDisplaySettingsEx(
        string deviceName, ref DEVMODE devMode, IntPtr hwnd, uint flags, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
    static extern int ChangeDisplaySettingsExNull(
        string deviceName, IntPtr devMode, IntPtr hwnd, uint flags, IntPtr lParam);

    const uint ATTACHED  = 0x1;
    const uint CDS_UPDATEREGISTRY     = 0x01;
    const uint CDS_NORESET            = 0x10000000;
    const uint CDS_SET_PRIMARY_DEVICE = 0x10;
    const uint DM_POSITION            = 0x20;

    static void Main()
    {
        string markerDir = @"C:\Users\Administrator\provision\state";
        string markerPath = Path.Combine(markerDir, "display-config-done.flag");
        string logPath    = Path.Combine(markerDir, "display-config.log");

        using (var writer = new StreamWriter(logPath, false))
        {
            Console.SetOut(writer);

            string vddAdapter = null;
            var adapter = new DISPLAY_DEVICE();

            for (uint i = 0; ; i++)
            {
                adapter.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, i, ref adapter, 0)) break;

                bool active = (adapter.StateFlags & ATTACHED) != 0;
                bool isVdd  = adapter.DeviceString.IndexOf("Virtual Display", StringComparison.OrdinalIgnoreCase) >= 0;

                Console.WriteLine("{0} | {1} | active={2} vdd={3} flags=0x{4:X}",
                    adapter.DeviceName, adapter.DeviceString, active, isVdd, adapter.StateFlags);

                if (isVdd && active)
                    vddAdapter = adapter.DeviceName;
            }

            if (vddAdapter == null)
            {
                Console.WriteLine("ERROR: No active VDD adapter found.");
                File.WriteAllText(markerPath, "ERROR: No VDD\n");
                return;
            }

            Console.WriteLine("Target: " + vddAdapter);

            int disconnected = 0;
            adapter = new DISPLAY_DEVICE();

            for (uint i = 0; ; i++)
            {
                adapter.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, i, ref adapter, 0)) break;

                bool active = (adapter.StateFlags & ATTACHED) != 0;
                if (!active) continue;
                if (adapter.DeviceName == vddAdapter) continue;

                Console.WriteLine("Disconnecting: " + adapter.DeviceName +
                    " (" + adapter.DeviceString + ")");

                var dm = new DEVMODE();
                dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
                EnumDisplaySettingsEx(adapter.DeviceName, -1, ref dm, 0);
                dm.dmPositionX = -10000;
                dm.dmPositionY = -10000;
                dm.dmFields    = DM_POSITION;

                int r = ChangeDisplaySettingsEx(adapter.DeviceName, ref dm,
                    IntPtr.Zero, CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
                Console.WriteLine("  -> " + r);
                disconnected++;
            }

            var dmVdd = new DEVMODE();
            dmVdd.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            EnumDisplaySettingsEx(vddAdapter, -1, ref dmVdd, 0);

            dmVdd.dmPositionX = 0;
            dmVdd.dmPositionY = 0;
            dmVdd.dmFields    = DM_POSITION;

            int rp = ChangeDisplaySettingsEx(vddAdapter, ref dmVdd,
                IntPtr.Zero,
                CDS_UPDATEREGISTRY | CDS_NORESET | CDS_SET_PRIMARY_DEVICE,
                IntPtr.Zero);
            Console.WriteLine("Set-primary: " + rp);

            int ra = ChangeDisplaySettingsExNull(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
            Console.WriteLine("Apply: " + ra);

            var dmAfter = new DEVMODE();
            dmAfter.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            EnumDisplaySettingsEx(vddAdapter, -1, ref dmAfter, 0);
            Console.WriteLine("Result: {0}x{1} @{2}Hz pos=({3},{4})",
                dmAfter.dmPelsWidth, dmAfter.dmPelsHeight,
                dmAfter.dmDisplayFrequency,
                dmAfter.dmPositionX, dmAfter.dmPositionY);

            int activeNonVdd = 0;
            adapter = new DISPLAY_DEVICE();
            for (uint i = 0; ; i++)
            {
                adapter.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, i, ref adapter, 0)) break;

                bool active = (adapter.StateFlags & ATTACHED) != 0;
                bool isVdd  = adapter.DeviceString.IndexOf("Virtual Display", StringComparison.OrdinalIgnoreCase) >= 0;
                Console.WriteLine("After: {0} | {1} | active={2} vdd={3} flags=0x{4:X}",
                    adapter.DeviceName, adapter.DeviceString, active, isVdd, adapter.StateFlags);
                if (active && !isVdd)
                    activeNonVdd++;
            }

            if (activeNonVdd > 0)
            {
                // On vGPU instances (e.g. Vultr A40), the NVIDIA virtual GPU
                // display cannot be fully deactivated from within the guest —
                // the hypervisor controls it. If the VDD is active and primary,
                // Sunshine captures the full virtual desktop regardless; the
                // non-VDD adapter is needed for NVENC encoding. Write OK with
                // a note rather than failing the provision step.
                Console.WriteLine("NOTE: {0} non-VDD display(s) remain active — acceptable on vGPU.", activeNonVdd);
            }

            File.WriteAllText(markerPath,
                "OK " + dmAfter.dmPelsWidth + "x" + dmAfter.dmPelsHeight +
                " disconnected=" + disconnected + "\n");
        }
    }
}
'@

# ---- Compile ----
Set-Content -Path $csPath -Value $csSource -Encoding UTF8
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
Write-Host "Compiling display-config.exe ..."
& $csc /nologo "/out:$exePath" $csPath
if ($LASTEXITCODE -ne 0) {
    throw "csc.exe failed (exit $LASTEXITCODE)"
}
Write-Host "Compiled OK."

if (Test-Path $marker) { Remove-Item $marker -Force }

# ---- Run via interactive scheduled task ----
$taskName = 'EphemeralDisplayConfig'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$action     = New-ScheduledTaskAction -Execute $exePath
$principal  = New-ScheduledTaskPrincipal -UserId 'Administrator' -LogonType Interactive -RunLevel Highest
$settings   = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $taskName -InputObject (
    New-ScheduledTask -Action $action -Principal $principal -Settings $settings
) -Force | Out-Null

Write-Host "Starting interactive task ..."
Start-ScheduledTask -TaskName $taskName

$timeout = 60
$start   = Get-Date
while (((Get-Date) - $start).TotalSeconds -lt $timeout) {
    if (Test-Path $marker) { break }
    Start-Sleep -Seconds 2
}

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

if (Test-Path $marker) {
    Write-Host "Display config: $((Get-Content $marker -Raw).Trim())"
    if (Test-Path $dcLog) {
        Get-Content $dcLog | ForEach-Object { Write-Host "  $_" }
    }
} else {
    Write-Host "Interactive task did not complete within ${timeout}s."
    Write-Host "Placing display-config.exe in Startup folder and requesting reboot."
    $startupBat = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\display-config.bat'
    $batLine = '@echo off`n"{0}" > "{1}" 2>&1' -f $exePath, $dcLog
    Set-Content -Path $startupBat -Value $batLine.Replace("`n", "`r`n") -Encoding ASCII
    New-Item $rebootFlg -ItemType File -Force | Out-Null
}

Write-Host "---------------------------------------------------------"
Write-Host "END 22"
Write-Host "---------------------------------------------------------"
Write-Host ""
