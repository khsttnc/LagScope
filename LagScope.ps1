<#
.SYNOPSIS
  LagScope - one tray app that finds out why your PC stutters while gaming and frees it up for the game.

.DESCRIPTION
  Start it once (LagScope.bat). It sits in the tray and does everything automatically:
    * Game Mode     - when a game starts: closes background apps, stops dev tools (Docker, WSL,
                      dev servers, local AI servers), gently trims background RAM, purges the
                      standby list, switches to the High performance power plan.
                      Everything is restored when the game closes.
    * RAM cleaner   - while you play, purges the standby list whenever free RAM gets low.
    * Monitor       - overlay with CPU / core / clock / RAM / GPU / temps / disk and the live
                      lag cause; after each game session a report with the main problem.
  All switches are in the tray menu and saved to LagScope.config.json.

.PARAMETER Once
  Apply the game boost right now and exit (no tray icon).
#>
param([switch]$Once)

$ErrorActionPreference = "Continue"
$appDir = $PSScriptRoot

# ---------------- Single instance ----------------
$createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($true, "Global\LagScope_SingleInstance", [ref]$createdNew)
if (-not $createdNew -and -not $Once) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("LagScope is already running. Look for the shield icon next to the clock.", "LagScope")
    exit 0
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class LagScopeNative {
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TOKEN_PRIVILEGES { public int Count; public long Luid; public int Attr; }

    [DllImport("ntdll.dll")]
    static extern uint NtSetSystemInformation(int infoClass, ref int info, int length);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState, int len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("psapi.dll")]
    static extern bool EmptyWorkingSet(IntPtr process);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);

    public static void EnablePrivilege(string name) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) return;
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.Count = 1;
        LookupPrivilegeValue(null, name, out tp.Luid);
        tp.Attr = 2;
        AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        CloseHandle(token);
    }
    public static bool TrimProcess(int pid) {
        IntPtr h = OpenProcess(0x0100 | 0x0400, false, pid);
        if (h == IntPtr.Zero) return false;
        bool ok = EmptyWorkingSet(h);
        CloseHandle(h);
        return ok;
    }
    // SystemMemoryListInformation = 80: 3 = flush modified list, 4 = purge standby list
    public static uint MemoryCommand(int command) {
        EnablePrivilege("SeProfileSingleProcessPrivilege");
        EnablePrivilege("SeIncreaseQuotaPrivilege");
        return NtSetSystemInformation(80, ref command, 4);
    }
}
"@
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// Lightweight background sampler: PDH performance counters (English names, language-independent)
// + one long-running nvidia-smi process. Runs on its own thread so the UI never blocks.
public static class LagSampler {
    [StructLayout(LayoutKind.Explicit)]
    struct PDH_FMT_COUNTERVALUE { [FieldOffset(0)] public uint CStatus; [FieldOffset(8)] public double doubleValue; }

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhOpenQuery(string src, IntPtr user, out IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhAddEnglishCounter(IntPtr query, string path, IntPtr user, out IntPtr counter);
    [DllImport("pdh.dll")] static extern uint PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll")] static extern uint PdhCloseQuery(IntPtr query);
    [DllImport("pdh.dll")] static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint format, IntPtr type, out PDH_FMT_COUNTERVALUE value);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhGetFormattedCounterArray(IntPtr counter, uint format, ref uint bufferSize, out uint itemCount, IntPtr buffer);

    const uint FMT = 0x00000200 | 0x00008000; // PDH_FMT_DOUBLE | PDH_FMT_NOCAP100

    static IntPtr q = IntPtr.Zero;
    static Dictionary<string, IntPtr> c = new Dictionary<string, IntPtr>();

    public static volatile bool Ready;
    public static double Cpu = -1, Core = -1, Speed = -1, AvailMB = -1, StandbyMB = -1, DiskPct = -1, DiskMBs = -1;
    public static double Gpu = -1, GpuTemp = -1, Vram = -1;
    public static string LastError = "";

    static Thread worker;
    static volatile bool running;
    static int intervalMs = 2000;
    static Process smi;
    static DateTime smiLast = DateTime.MinValue;

    static void Add(string key, string path) {
        IntPtr h;
        if (PdhAddEnglishCounter(q, path, IntPtr.Zero, out h) == 0) c[key] = h;
    }
    static double Val(string key) {
        IntPtr h; if (!c.TryGetValue(key, out h)) return -1;
        PDH_FMT_COUNTERVALUE v;
        if (PdhGetFormattedCounterValue(h, FMT, IntPtr.Zero, out v) != 0 || v.CStatus > 1) return -1;
        return v.doubleValue;
    }
    // returns (name,value) pairs of a wildcard counter
    static List<KeyValuePair<string, double>> Arr(string key) {
        var res = new List<KeyValuePair<string, double>>();
        IntPtr h; if (!c.TryGetValue(key, out h)) return res;
        uint size = 0, count = 0;
        uint r = PdhGetFormattedCounterArray(h, FMT, ref size, out count, IntPtr.Zero);
        if (r != 0x800007D2 || size == 0) return res; // PDH_MORE_DATA
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
            if (PdhGetFormattedCounterArray(h, FMT, ref size, out count, buf) != 0) return res;
            int item = IntPtr.Size + 16; // szName + PDH_FMT_COUNTERVALUE (aligned)
            for (int i = 0; i < count; i++) {
                IntPtr p = IntPtr.Add(buf, i * item);
                string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p));
                uint status = (uint)Marshal.ReadInt32(p, IntPtr.Size);
                double val = BitConverter.Int64BitsToDouble(Marshal.ReadInt64(p, IntPtr.Size + 8));
                if (status <= 1) res.Add(new KeyValuePair<string, double>(name, val));
            }
        } finally { Marshal.FreeHGlobal(buf); }
        return res;
    }

    public static void Start(int ms, string nvidiaSmiPath) {
        if (running) return;
        intervalMs = Math.Max(500, ms);
        if (PdhOpenQuery(null, IntPtr.Zero, out q) != 0) { LastError = "PdhOpenQuery failed"; return; }
        Add("cpu",   @"\Processor(_Total)\% Processor Time");
        Add("cores", @"\Processor(*)\% Processor Time");
        Add("perf",  @"\Processor Information(_Total)\% Processor Performance");
        Add("avail", @"\Memory\Available MBytes");
        Add("sb1",   @"\Memory\Standby Cache Normal Priority Bytes");
        Add("sb2",   @"\Memory\Standby Cache Core Bytes");
        Add("sb3",   @"\Memory\Standby Cache Reserve Bytes");
        Add("dpct",  @"\PhysicalDisk(_Total)\% Disk Time");
        Add("dbytes",@"\PhysicalDisk(_Total)\Disk Bytes/sec");
        Add("gpu",   @"\GPU Engine(*engtype_3D)\Utilization Percentage");
        PdhCollectQueryData(q);
        if (!string.IsNullOrEmpty(nvidiaSmiPath)) StartSmi(nvidiaSmiPath);
        running = true;
        worker = new Thread(Loop) { IsBackground = true, Priority = ThreadPriority.BelowNormal, Name = "LagSampler" };
        worker.Start();
    }

    static void StartSmi(string path) {
        try {
            var psi = new ProcessStartInfo(path, "--query-gpu=utilization.gpu,temperature.gpu,memory.used --format=csv,noheader,nounits -lms " + intervalMs) {
                UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true
            };
            smi = new Process { StartInfo = psi, EnableRaisingEvents = true };
            smi.OutputDataReceived += (s, e) => {
                if (string.IsNullOrEmpty(e.Data)) return;
                var parts = e.Data.Split(',');
                double a, b, d;
                if (parts.Length >= 3 && double.TryParse(parts[0].Trim(), out a) && double.TryParse(parts[1].Trim(), out b) && double.TryParse(parts[2].Trim(), out d)) {
                    Gpu = a; GpuTemp = b; Vram = d; smiLast = DateTime.UtcNow;
                }
            };
            smi.Start();
            smi.BeginOutputReadLine();
            smi.BeginErrorReadLine();
            try { smi.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
        } catch (Exception ex) { LastError = "nvidia-smi: " + ex.Message; smi = null; }
    }

    static void Loop() {
        while (running) {
            try {
                Thread.Sleep(intervalMs);
                if (PdhCollectQueryData(q) != 0) continue;
                Cpu = Val("cpu");
                double max = -1;
                foreach (var kv in Arr("cores")) if (kv.Key != "_Total" && kv.Value > max) max = kv.Value;
                Core = max;
                Speed = Val("perf");
                AvailMB = Val("avail");
                double s1 = Val("sb1"), s2 = Val("sb2"), s3 = Val("sb3");
                StandbyMB = (s1 < 0 && s2 < 0 && s3 < 0) ? -1 : (Math.Max(0, s1) + Math.Max(0, s2) + Math.Max(0, s3)) / 1048576.0;
                DiskPct = Val("dpct");
                double db = Val("dbytes"); DiskMBs = db < 0 ? -1 : db / 1048576.0;
                // GPU from PDH only if nvidia-smi isn't delivering
                if (smi == null || (DateTime.UtcNow - smiLast).TotalSeconds > 10) {
                    double sum = 0; bool any = false;
                    foreach (var kv in Arr("gpu")) { sum += kv.Value; any = true; }
                    Gpu = any ? Math.Min(100, sum) : -1;
                    if (smi == null) { GpuTemp = -1; Vram = -1; }
                }
                Ready = true;
            } catch (Exception ex) { LastError = ex.Message; }
        }
    }

    public static void Stop() {
        running = false;
        try { if (smi != null && !smi.HasExited) smi.Kill(); } catch { }
        try { if (q != IntPtr.Zero) PdhCloseQuery(q); } catch { }
    }

    // ---- cheap helpers used by the UI thread ----
    [StructLayout(LayoutKind.Sequential)]
    class MEMORYSTATUSEX {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys; public ulong ullTotalPageFile;
        public ulong ullAvailPageFile; public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX m);
    public static int FreeRamMB() { var m = new MEMORYSTATUSEX(); return GlobalMemoryStatusEx(m) ? (int)(m.ullAvailPhys / 1048576) : -1; }
    public static int TotalRamMB() { var m = new MEMORYSTATUSEX(); return GlobalMemoryStatusEx(m) ? (int)(m.ullTotalPhys / 1048576) : -1; }

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    // PIDs that own a visible top-level window (fast; replaces Process.MainWindowHandle on every process)
    public static int[] WindowPids() {
        var set = new HashSet<int>();
        EnumWindows((h, l) => { if (IsWindowVisible(h)) { uint pid; GetWindowThreadProcessId(h, out pid); set.Add((int)pid); } return true; }, IntPtr.Zero);
        var a = new int[set.Count]; set.CopyTo(a); return a;
    }
}
"@

# ---------------- Files ----------------
$configPath = Join-Path $appDir "LagScope.config.json"
$logDir = Join-Path $appDir "Logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$appLog = Join-Path $logDir "LagScope.log"

function Write-Log($text) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $text
    try { $line | Out-File $appLog -Append -Encoding UTF8 } catch {}
}

# ---------------- Config ----------------
$script:defaults = [ordered]@{
    overlay = "auto"; gameMode = $true; autoRamCleaner = $true; stopDevTools = $true
    sampleIntervalMs = 2000
    ramCleanerMinFreeMB = 2048; ramCleanerMinStandbyMB = 1024; ramCleanerCooldownSeconds = 60
    games = @(); autoDetectGameFolders = @(); notGames = @(); closeApps = @(); neverTouch = @()
    forceCloseAfterSeconds = 5; reopenAppsAfterGame = $true
    trimBackgroundRam = $true; trimMinProcessMB = 150; purgeStandbyOnGameStart = $true
    setGameHighPriority = $false; highPerformancePowerPlan = $true; stopServices = @()
    devProcesses = @(); devServerPatterns = @(); shutdownWsl = $true
    appPickerShown = $false
}
function Read-Config {
    $cfg = [ordered]@{}
    foreach ($k in $script:defaults.Keys) { $cfg[$k] = $script:defaults[$k] }
    try {
        $json = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    } catch { Write-Log "WARNING: could not read LagScope.config.json ($($_.Exception.Message)) - using defaults" }
    return $cfg
}
function Save-Setting($name, $value) {
    try {
        $json = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($json.PSObject.Properties[$name]) { $json.$name = $value } else { $json | Add-Member -NotePropertyName $name -NotePropertyValue $value }
        $json | ConvertTo-Json -Depth 5 | Set-Content $configPath -Encoding UTF8
    } catch { Write-Log "Could not save setting ${name}: $($_.Exception.Message)" }
    $script:cfg[$name] = $value
}
$script:cfg = Read-Config

# ---------------- Helpers ----------------
$systemCritical = @(
    "System","Idle","Registry","smss","csrss","wininit","winlogon","services","lsass","lsaiso",
    "svchost","fontdrvhost","dwm","Memory Compression","spoolsv","sihost","ctfmon","conhost",
    "SecurityHealthService","MsMpEng","NisSrv","audiodg","explorer","ShellExperienceHost",
    "StartMenuExperienceHost","SearchHost","TextInputHost","RuntimeBroker","dllhost","taskhostw"
)
function Test-NameMatch($name, $patterns) {
    foreach ($pat in @($patterns)) { if ($pat -and $name -like $pat) { return $true } }
    return $false
}
function Get-FreeRamMB { [LagSampler]::FreeRamMB() }

# ---------------- Game detection (cheap) ----------------
$script:windowPids = @{}
function Test-IsGame($proc, $cfg) {
    $name = $proc.ProcessName
    if (Test-NameMatch $name $cfg.notGames) { return $false }
    if (Test-NameMatch $name $cfg.games) { return $true }
    if (-not $script:windowPids.ContainsKey([int]$proc.Id)) { return $false }   # games have a window
    $path = $null
    try { $path = $proc.Path } catch {}
    if (-not $path) { return $false }
    foreach ($folder in @($cfg.autoDetectGameFolders)) { if ($folder -and $path -like "*$folder*") { return $true } }
    return $false
}
function Find-Game($cfg) {
    # still running? (no scan needed)
    if ($script:gameProc) {
        try { $script:gameProc.Refresh(); if (-not $script:gameProc.HasExited) { return $script:gameProc } } catch {}
    }
    # 1) games named in the config
    $named = @(@($cfg.games) | Where-Object { $_ })
    if ($named.Count) {
        foreach ($p in @(Get-Process -Name $named -ErrorAction SilentlyContinue)) {
            if (-not (Test-NameMatch $p.ProcessName $cfg.notGames)) { return $p }
        }
    }
    # 2) windowed processes running from a game library folder (only processes that own a window are inspected)
    $script:windowPids = @{}
    foreach ($id in [LagSampler]::WindowPids()) { $script:windowPids[[int]$id] = $true }
    foreach ($id in $script:windowPids.Keys) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($p -and (Test-IsGame $p $cfg)) { return $p }
    }
    return $null
}

# ---------------- Measurement (reads the background sampler) ----------------
$nvsmi = @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") |
         Where-Object { Test-Path $_ } | Select-Object -First 1
$totalMB = [LagSampler]::TotalRamMB()

# CPU temperature via WMI is slow: read it at most every 15 s and give up for good if the board doesn't expose it
$script:cpuTempAvailable = $true; $script:cpuTemp = $null; $script:cpuTempAt = [datetime]::MinValue
function Get-CpuTemp {
    if (-not $script:cpuTempAvailable) { return $null }
    if (((Get-Date) - $script:cpuTempAt).TotalSeconds -lt 15) { return $script:cpuTemp }
    $script:cpuTempAt = Get-Date
    try {
        $z = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop -OperationTimeoutSec 2
        $c = ($z | ForEach-Object { ($_.CurrentTemperature / 10) - 273.15 } | Measure-Object -Maximum).Maximum
        if ($c -lt 15 -or $c -gt 120) { $script:cpuTempAvailable = $false; return $null }
        $script:cpuTemp = [int]$c
    } catch { $script:cpuTempAvailable = $false; $script:cpuTemp = $null }
    return $script:cpuTemp
}
function NullIfNeg($v) { if ($null -eq $v -or $v -lt 0) { $null } else { [int][math]::Round($v) } }
function Measure-System {
    $avail = [LagSampler]::FreeRamMB()
    [pscustomobject]@{
        CPU      = [int](NullIfNeg ([LagSampler]::Cpu))
        Core     = [int](NullIfNeg ([LagSampler]::Core))
        CpuSpeed = NullIfNeg ([LagSampler]::Speed)
        CPU_C    = Get-CpuTemp
        RAM      = [int][math]::Round((($totalMB - $avail) / $totalMB) * 100)
        FreeRAM  = $avail
        GPU      = NullIfNeg ([LagSampler]::Gpu)
        GPU_C    = NullIfNeg ([LagSampler]::GpuTemp)
        VRAM     = NullIfNeg ([LagSampler]::Vram)
        Disk     = [int][math]::Min(100, [math]::Max(0, [LagSampler]::DiskPct))
        DiskMBs  = [math]::Round([math]::Max(0, [LagSampler]::DiskMBs), 1)
    }
}
# Top process by CPU (cheap Get-Process deltas, at most every 10 s)
$script:cpuSnap = @{}; $script:cpuSnapAt = Get-Date; $script:topCpu = "-"; $script:topCpuAt = [datetime]::MinValue
function Get-TopCpuName {
    if (((Get-Date) - $script:topCpuAt).TotalSeconds -lt 10) { return $script:topCpu }
    $now = Get-Date; $snap = @{}; $best = $null; $bestDelta = 0
    foreach ($p in Get-Process) {
        $t = $null; try { $t = $p.TotalProcessorTime.TotalMilliseconds } catch {}
        if ($null -eq $t) { continue }
        $snap[$p.Id] = $t
        if ($script:cpuSnap.ContainsKey($p.Id) -and $p.Id -ne 0) {
            $d = $t - $script:cpuSnap[$p.Id]
            if ($d -gt $bestDelta) { $bestDelta = $d; $best = $p.ProcessName }
        }
    }
    $script:cpuSnap = $snap; $script:cpuSnapAt = $now; $script:topCpuAt = $now
    if ($best) { $script:topCpu = $best }
    return $script:topCpu
}
$script:topRam = "-"; $script:topRamAt = [datetime]::MinValue
function Get-Diagnosis($o) {
    $s = @()
    if ($o.RAM -ge 88 -or $o.FreeRAM -lt 1024) {
        if (((Get-Date) - $script:topRamAt).TotalSeconds -ge 10) {
            $p = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
            $script:topRam = "$($p.ProcessName) $([math]::Round($p.WorkingSet64/1MB)) MB"; $script:topRamAt = Get-Date
        }
        $s += @{ Code = "RAM"; Message = "RAM RUNNING OUT ($($o.RAM)%, $($o.FreeRAM) MB free) - top user: $($script:topRam)" }
    }
    if ($null -ne $o.CPU_C -and $o.CPU_C -ge 90) { $s += @{ Code = "CPU_HEAT"; Message = "CPU OVERHEATING ($($o.CPU_C) C)" } }
    if ($null -ne $o.CpuSpeed -and $o.CPU -ge 40 -and $o.CpuSpeed -lt 80) {
        $s += @{ Code = "CPU_HEAT"; Message = "CPU THROTTLING (running at $($o.CpuSpeed)% of base speed) - usually heat or power plan" }
    }
    if ($null -ne $o.GPU_C -and $o.GPU_C -ge 83) { $s += @{ Code = "GPU_HEAT"; Message = "GPU HOT ($($o.GPU_C) C) - may throttle. Check fans / dust / airflow" } }
    $gpuWaiting = ($null -eq $o.GPU) -or ($o.GPU -lt 85)
    if ($o.CPU -ge 90 -or ($o.Core -ge 95 -and $gpuWaiting)) {
        $topName = Get-TopCpuName
        $gpuText = if ($null -ne $o.GPU) { ", GPU only at $($o.GPU)% - waiting" } else { "" }
        $s += @{ Code = "CPU_BOTTLENECK"; Message = "CPU BOTTLENECK (total $($o.CPU)%, busiest core $($o.Core)%$gpuText) - top: $topName" }
    }
    if ($o.Disk -ge 90) {
        $s += @{ Code = "DISK"; Message = "DISK CAN'T KEEP UP ($($o.Disk)%, $($o.DiskMBs) MB/s)" }
    }
    if ($s.Count -eq 0 -and $null -ne $o.GPU -and $o.GPU -ge 97) {
        $s += @{ Code = "GPU_MAXED"; Message = "GPU fully loaded ($($o.GPU)%) - normal; lower graphics settings if FPS is low" }
    }
    return ,$s
}

# ---------------- Session (one per game) ----------------
$script:session = $null
function New-Session($gameName) {
    $stamp = (Get-Date).ToString("yyyy-MM-dd_HH-mm")
    $s = [pscustomobject]@{
        Game = $gameName; Start = Get-Date; Samples = 0
        Counts = @{ RAM = 0; CPU_HEAT = 0; GPU_HEAT = 0; CPU_BOTTLENECK = 0; DISK = 0; GPU_MAXED = 0 }
        Peak = @{ CPU_C = $null; GPU_C = $null; RAM = 0; Core = 0; MinSpeed = $null }
        Csv = Join-Path $logDir "Samples_$stamp.csv"
        Log = Join-Path $logDir "Stutters_$stamp.log"
        Report = Join-Path $logDir "REPORT_$stamp.txt"
        RamFreedAtStart = 0; StandbyPurges = 0
    }
    "Time;CPU%;BusiestCore%;CPU_Speed%;CPU_C;RAM%;FreeRAM_MB;GPU%;GPU_C;VRAM_MB;Disk%;Disk_MBs;Causes" | Out-File $s.Csv -Encoding UTF8
    return $s
}
function Add-Sample($o, $causes) {
    $s = $script:session
    if (-not $s) { return }
    $s.Samples++
    if ($o.RAM -gt $s.Peak.RAM) { $s.Peak.RAM = $o.RAM }
    if ($o.Core -gt $s.Peak.Core) { $s.Peak.Core = $o.Core }
    if ($null -ne $o.CPU_C -and ($null -eq $s.Peak.CPU_C -or $o.CPU_C -gt $s.Peak.CPU_C)) { $s.Peak.CPU_C = $o.CPU_C }
    if ($null -ne $o.GPU_C -and ($null -eq $s.Peak.GPU_C -or $o.GPU_C -gt $s.Peak.GPU_C)) { $s.Peak.GPU_C = $o.GPU_C }
    if ($null -ne $o.CpuSpeed -and $o.CPU -ge 40 -and ($null -eq $s.Peak.MinSpeed -or $o.CpuSpeed -lt $s.Peak.MinSpeed)) { $s.Peak.MinSpeed = $o.CpuSpeed }
    foreach ($k in ($causes | ForEach-Object { $_.Code } | Select-Object -Unique)) { $s.Counts[$k]++ }
    $time = Get-Date -Format "HH:mm:ss"
    $codes = ($causes | ForEach-Object { $_.Code }) -join ","
    "$time;$($o.CPU);$($o.Core);$($o.CpuSpeed);$($o.CPU_C);$($o.RAM);$($o.FreeRAM);$($o.GPU);$($o.GPU_C);$($o.VRAM);$($o.Disk);$($o.DiskMBs);$codes" | Out-File $s.Csv -Append -Encoding UTF8
    $real = @($causes | Where-Object { $_.Code -ne "GPU_MAXED" })
    if ($real.Count) { "[$time] " + (($real | ForEach-Object { $_.Message }) -join " | ") | Out-File $s.Log -Append -Encoding UTF8 }
}
function New-Report {
    $s = $script:session
    if (-not $s) { return "No game session yet. A report is created automatically after each game." }
    $n = [math]::Max(1, $s.Samples)
    $minutes = [math]::Round(((Get-Date) - $s.Start).TotalMinutes)
    $names = @{
        RAM = "Not enough RAM"; CPU_HEAT = "CPU overheating / throttling"; GPU_HEAT = "GPU overheating"
        CPU_BOTTLENECK = "CPU bottleneck"; DISK = "Slow disk"; GPU_MAXED = "GPU at its limit (not a fault)"
    }
    $advice = @{
        RAM            = "Close background apps (browser, Discord, Spotify, emulators) or add them to closeApps. If it keeps happening, add more RAM and check that RAM runs in dual channel with XMP/EXPO enabled."
        CPU_HEAT       = "Clean dust from the case, check the CPU cooler and thermal paste. Set Windows power mode to 'Best performance'."
        GPU_HEAT       = "Clean the GPU fans, improve case airflow, use a more aggressive fan curve."
        CPU_BOTTLENECK = "Lower CPU-heavy settings (view distance, crowds, effects), close background apps. An FPS cap reduces stutter."
        DISK           = "Move the game to an SSD. Check for background downloads, Windows Update or antivirus scans."
        GPU_MAXED      = "Not a problem; for more FPS lower graphics settings or enable DLSS/FSR."
    }
    $l = @()
    $l += "==============================================="
    $l += "  LAGSCOPE REPORT - $($s.Game) - $($s.Start.ToString('yyyy-MM-dd HH:mm'))  ($minutes min)"
    $l += "==============================================="
    $l += ""
    $sorted = $s.Counts.GetEnumerator() | Sort-Object Value -Descending
    $main = $sorted | Where-Object { $_.Key -ne "GPU_MAXED" -and ($_.Value / $n) -ge 0.05 } | Select-Object -First 1
    if ($main) {
        $l += ">>> MAIN PROBLEM: $($names[$main.Key].ToUpper())  ($([math]::Round($main.Value / $n * 100))% of the time)"
        $l += "    What to do: $($advice[$main.Key])"
    } else {
        $l += ">>> No clear bottleneck found. Your PC was comfortable this session."
        $l += "    If it still stutters: network (ping), the game itself or drivers may be the cause."
    }
    $l += ""
    $l += "Share of time each cause was detected:"
    foreach ($k in $sorted) {
        $pct = [math]::Round($k.Value / $n * 100)
        $l += ("  {0,-34} {1,3}%  {2}" -f $names[$k.Key], $pct, ("#" * [math]::Min(30, [math]::Round($pct / 100 * 30))))
    }
    $l += ""
    $l += "Peak values:"
    $l += "  RAM usage          : $($s.Peak.RAM)%"
    $l += "  Busiest core       : $($s.Peak.Core)%"
    $l += "  CPU temperature    : " + $(if ($null -ne $s.Peak.CPU_C) { "$($s.Peak.CPU_C) C" } else { "sensor not readable (checked via throttling instead)" })
    $l += "  Lowest CPU speed   : " + $(if ($null -ne $s.Peak.MinSpeed) { "$($s.Peak.MinSpeed)% of base" } else { "-" })
    $l += "  GPU temperature    : " + $(if ($null -ne $s.Peak.GPU_C) { "$($s.Peak.GPU_C) C" } else { "-" })
    $l += ""
    $l += "Game Mode: freed $($s.RamFreedAtStart) MB at game start, $($s.StandbyPurges) automatic RAM cleanups during the game."
    $l += "Detailed timeline: $(Split-Path $s.Log -Leaf)"
    $l | Out-File $s.Report -Encoding UTF8
    return ($l -join "`r`n")
}

# Apps that are never offered because the game or the PC needs them
$hardProtected = @(
    "steam","steamwebhelper","steamservice","EpicGamesLauncher","EpicWebHelper","Battle.net","Agent",
    "RiotClient*","vgc","vgtray","BEService*","EasyAntiCheat*","FACEIT*",
    "NVIDIA*","nv*","NVDisplay*","Radeon*","AMDRS*","Razer*","GameManagerService*","lghub*","logi*",
    "audiodg","explorer","powershell","pwsh","conhost","WindowsTerminal","OpenConsole","cmd",
    "msedgewebview2","RuntimeBroker","SearchHost","ShellExperienceHost","StartMenuExperienceHost","TextInputHost",
    "ctfmon","sihost","dllhost","taskhostw","SecurityHealthSystray","MsMpEng","Taskmgr","GameBar*","XboxPcApp*",
    "ShellHost","cowork-svc","*svc","*Service","*Svc","python*","pythonw*","py","uv","uvx","node","java","javaw",
    "wsl*","vmmem*","Docker*","com.docker.*","git*","ssh*","LagScope*"
)

# ---------------- Game Mode actions ----------------
$script:boosted = $false
$script:closedApps = @()
$script:stoppedServices = @()
$script:previousPowerPlan = $null
$script:gameProc = $null
$script:lastPurge = [datetime]::MinValue

$script:pendingKills = @()   # apps asked to close; killed by the timer if still running after the grace period
function Close-Apps($cfg, $gamePid) {
    $targets = @(Get-Process | Where-Object {
        $_.Id -ne $gamePid -and $_.Id -ne $PID -and
        (Test-NameMatch $_.ProcessName $cfg.closeApps) -and
        -not (Test-NameMatch $_.ProcessName $cfg.neverTouch) -and
        -not (Test-NameMatch $_.ProcessName $hardProtected) -and
        -not (Test-NameMatch $_.ProcessName $systemCritical)
    })
    $closed = @()
    $deadline = (Get-Date).AddSeconds([math]::Max(0, [int]$cfg.forceCloseAfterSeconds))
    foreach ($p in $targets) {
        $path = $null; try { $path = $p.Path } catch {}
        try { [void]$p.CloseMainWindow() } catch {}
        if ([int]$cfg.forceCloseAfterSeconds -gt 0) { $script:pendingKills += [pscustomobject]@{ Id = $p.Id; Name = $p.ProcessName; At = $deadline } }
        $closed += [pscustomobject]@{ Name = $p.ProcessName; Path = $path }
    }
    return $closed
}
function Invoke-PendingKills {
    if (-not $script:pendingKills.Count) { return }
    $now = Get-Date; $left = @()
    foreach ($k in $script:pendingKills) {
        if ($now -lt $k.At) { $left += $k; continue }
        $p = Get-Process -Id $k.Id -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq $k.Name) { try { Stop-Process -Id $k.Id -Force -ErrorAction Stop } catch {} }
    }
    $script:pendingKills = $left
}

function Stop-DevTools($cfg) {
    $stopped = @()
    $pattern = (@($cfg.devServerPatterns) | Where-Object { $_ }) -join '|'
    if ($pattern) {
        Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -match "(?i)$pattern" } | ForEach-Object {
            try {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
                $what = if ($_.CommandLine -match '(?i)expo') { "Expo" } elseif ($_.CommandLine -match '(?i)next') { "Next.js" } elseif ($_.CommandLine -match '(?i)vite') { "Vite" } else { "dev server" }
                $stopped += $what
                Write-Log "Stopped dev server ($what) PID $($_.ProcessId)"
            } catch {}
        }
    }
    foreach ($svc in Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' -and $_.Name -match '(?i)^com\.docker|ollama' }) {
        try { Stop-Service -Name $svc.Name -Force -ErrorAction Stop; Write-Log "Stopped service $($svc.Name)" } catch {}
    }
    foreach ($pat in @($cfg.devProcesses)) {
        Get-Process -Name $pat -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; $stopped += $_.ProcessName; Write-Log "Stopped $($_.ProcessName)" } catch {}
        }
    }
    if ($cfg.shutdownWsl -and (Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue) -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath "wsl.exe" -ArgumentList "--shutdown" -WindowStyle Hidden
        $stopped += "WSL"; Write-Log "WSL shutting down"
    }
    return @($stopped | Select-Object -Unique)
}

# Gentle trim: only big background processes, never the game, its folder, anti-cheat, launchers or protected apps
function Invoke-GentleTrim($cfg, $game) {
    $gameDir = $null
    try { if ($game) { $gameDir = Split-Path (Split-Path $game.Path -Parent) -Parent } } catch {}
    $minBytes = [int64]$cfg.trimMinProcessMB * 1MB
    $count = 0
    foreach ($p in Get-Process) {
        if ($p.Id -le 4 -or $p.Id -eq $PID -or ($game -and $p.Id -eq $game.Id)) { continue }
        if ($p.WorkingSet64 -lt $minBytes) { continue }
        if (Test-NameMatch $p.ProcessName $systemCritical) { continue }
        if (Test-NameMatch $p.ProcessName $cfg.neverTouch) { continue }
        if (Test-NameMatch $p.ProcessName $cfg.notGames) { continue }
        $path = $null; try { $path = $p.Path } catch {}
        if ($path -and $gameDir -and $path.StartsWith($gameDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($path -and (@($cfg.autoDetectGameFolders) | Where-Object { $_ -and $path -like "*$_*" })) { continue }
        if ([LagScopeNative]::TrimProcess($p.Id)) { $count++ }
    }
    return $count
}

function Get-ActivePowerPlan {
    $out = powercfg /getactivescheme 2>$null
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1] }
    return $null
}

function Start-Boost($game, $cfg) {
    $before = Get-FreeRamMB
    $name = if ($game) { $game.ProcessName } else { "manual boost" }
    Write-Log "=== Game detected: $name. Free RAM before: $before MB ==="
    $summary = @()

    $closed = @(Close-Apps $cfg $(if ($game) { $game.Id } else { -1 }))
    $script:closedApps = @($closed | Where-Object { $_.Path } | Sort-Object Path -Unique)
    if ($closed.Count) { $n = ($closed | Select-Object -ExpandProperty Name -Unique) -join ", "; Write-Log "Closed: $n"; $summary += "Closed: $n" }

    if ($cfg.stopDevTools) {
        $dev = @(Stop-DevTools $cfg)
        if ($dev.Count) { $summary += "Dev tools stopped: $($dev -join ', ')" }
    }

    $script:stoppedServices = @()
    foreach ($svcName in @($cfg.stopServices)) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop
            if ($svc.Status -eq "Running") { Stop-Service -Name $svcName -Force -ErrorAction Stop; $script:stoppedServices += $svcName; Write-Log "Stopped service $svcName" }
        } catch { Write-Log "Could not stop service ${svcName}: $($_.Exception.Message)" }
    }

    if ($isAdmin -and $cfg.trimBackgroundRam) {
        $n = Invoke-GentleTrim $cfg $game
        Write-Log "Trimmed RAM of $n large background processes"
    }
    if ($isAdmin -and $cfg.purgeStandbyOnGameStart) {
        $r = [LagScopeNative]::MemoryCommand(4)
        if ($r -ne 0) { Write-Log ("Standby purge failed: 0x{0:X8}" -f $r) }
        $script:lastPurge = Get-Date
    }
    if ($game -and $cfg.setGameHighPriority) {
        try { $game.PriorityClass = "AboveNormal"; Write-Log "Game priority set to AboveNormal" } catch {}
    }
    if ($cfg.highPerformancePowerPlan) {
        $script:previousPowerPlan = Get-ActivePowerPlan
        $hp = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
        powercfg /setactive $hp 2>$null | Out-Null
        if ((Get-ActivePowerPlan) -eq $hp) { Write-Log "Power plan: High performance" } else { $script:previousPowerPlan = $null }
    }

    $after = Get-FreeRamMB
    $freed = [math]::Max(0, $after - $before)
    Write-Log "Free RAM after: $after MB (+$freed MB)"
    if ($script:session) { $script:session.RamFreedAtStart = $freed }
    $script:boosted = $true
    return ((@("Freed $freed MB RAM (now $after MB free)") + $summary) -join "`n")
}

function Stop-Boost($cfg) {
    $script:pendingKills = @()
    Write-Log "=== Game closed. Restoring... ==="
    if ($script:previousPowerPlan) { powercfg /setactive $script:previousPowerPlan 2>$null | Out-Null; Write-Log "Power plan restored" }
    foreach ($svcName in $script:stoppedServices) { try { Start-Service -Name $svcName -ErrorAction Stop } catch {} }
    $reopened = @()
    if ($cfg.reopenAppsAfterGame) {
        foreach ($app in $script:closedApps) {
            try { Start-Process -FilePath $app.Path -WindowStyle Minimized -ErrorAction Stop; $reopened += $app.Name } catch {}
        }
        if ($reopened.Count) { Write-Log "Reopened: $($reopened -join ', ')" }
    }
    $script:boosted = $false; $script:closedApps = @(); $script:stoppedServices = @(); $script:previousPowerPlan = $null
}

function Invoke-AutoRamClean($cfg) {
    if (-not $isAdmin -or -not $cfg.autoRamCleaner) { return }
    if (((Get-Date) - $script:lastPurge).TotalSeconds -lt [int]$cfg.ramCleanerCooldownSeconds) { return }
    $standbyMB = [int][LagSampler]::StandbyMB
    if ($standbyMB -lt 0) { return }
    $freeMB = [math]::Max(0, [LagSampler]::FreeRamMB() - $standbyMB)
    if ($freeMB -lt [int]$cfg.ramCleanerMinFreeMB -and $standbyMB -gt [int]$cfg.ramCleanerMinStandbyMB) {
        $r = [LagScopeNative]::MemoryCommand(4)
        $script:lastPurge = Get-Date
        if ($r -eq 0) {
            Write-Log "Auto RAM clean: standby list purged (free was $freeMB MB, standby $standbyMB MB)"
            if ($script:session) { $script:session.StandbyPurges++ }
        }
    }
}

# ---------------- One-shot mode ----------------
if ($Once) {
    $game = Find-Game $script:cfg
    Write-Host (Start-Boost $game $script:cfg)
    Write-Host "Boost applied."
    exit 0
}

# ---------------- Overlay ----------------
function Get-Color($value, $warn, $crit) {
    if ($null -eq $value) { return [System.Drawing.Color]::Gray }
    if ($value -ge $crit) { return [System.Drawing.Color]::FromArgb(255, 80, 80) }
    if ($value -ge $warn) { return [System.Drawing.Color]::FromArgb(255, 200, 60) }
    return [System.Drawing.Color]::FromArgb(120, 230, 120)
}
$green = [System.Drawing.Color]::FromArgb(120, 230, 120)
$red   = [System.Drawing.Color]::FromArgb(255, 80, 80)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = "None"; $form.TopMost = $true; $form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::Black; $form.Opacity = 0.80
$form.StartPosition = "Manual"; $form.Size = New-Object System.Drawing.Size(760, 50)
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($screen.Left + [int](($screen.Width - $form.Width) / 2)), ($screen.Bottom - $form.Height - 4))
$font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$labels = @{}; $i = 0
foreach ($name in "CPU","CORE","SPEED","CPUTEMP","RAM","GPU","GPUTEMP","DISK") {
    $l = New-Object System.Windows.Forms.Label
    $l.Font = $font; $l.AutoSize = $false; $l.Size = New-Object System.Drawing.Size(94, 24)
    $l.Location = New-Object System.Drawing.Point((4 + $i * 94), 2); $l.TextAlign = "MiddleLeft"
    $l.ForeColor = [System.Drawing.Color]::White; $l.Text = "--"
    $form.Controls.Add($l); $labels[$name] = $l; $i++
}
$causeLabel = New-Object System.Windows.Forms.Label
$causeLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$causeLabel.AutoSize = $false; $causeLabel.Size = New-Object System.Drawing.Size(752, 22)
$causeLabel.Location = New-Object System.Drawing.Point(4, 26); $causeLabel.TextAlign = "MiddleLeft"
$causeLabel.ForeColor = $green; $causeLabel.Text = "LagScope: waiting for a game..."
$form.Controls.Add($causeLabel)
$form.Add_Shown({
    $style = [LagScopeNative]::GetWindowLong($form.Handle, -20)
    [void][LagScopeNative]::SetWindowLong($form.Handle, -20, ($style -bor 0x80000 -bor 0x20 -bor 0x80))
})

function Update-Overlay($o, $causes) {
    $labels["CPU"].Text = "CPU {0,3}%" -f $o.CPU; $labels["CPU"].ForeColor = Get-Color $o.CPU 70 90
    $labels["CORE"].Text = "CORE{0,3}%" -f $o.Core; $labels["CORE"].ForeColor = Get-Color $o.Core 85 95
    $labels["SPEED"].Text = if ($null -ne $o.CpuSpeed) { "CLK {0,3}%" -f $o.CpuSpeed } else { "CLK  --" }
    $labels["SPEED"].ForeColor = if ($null -ne $o.CpuSpeed -and $o.CpuSpeed -lt 80) { $red } else { $green }
    $labels["CPUTEMP"].Text = if ($null -ne $o.CPU_C) { "CPU {0}C" -f $o.CPU_C } else { "CPU  --C" }
    $labels["CPUTEMP"].ForeColor = Get-Color $o.CPU_C 80 90
    $labels["RAM"].Text = "RAM {0,3}%" -f $o.RAM; $labels["RAM"].ForeColor = Get-Color $o.RAM 75 88
    $labels["GPU"].Text = if ($null -ne $o.GPU) { "GPU {0,3}%" -f $o.GPU } else { "GPU  --" }
    $labels["GPU"].ForeColor = Get-Color $o.GPU 90 99
    $labels["GPUTEMP"].Text = if ($null -ne $o.GPU_C) { "GPU {0}C" -f $o.GPU_C } else { "GPU  --C" }
    $labels["GPUTEMP"].ForeColor = Get-Color $o.GPU_C 75 83
    $labels["DISK"].Text = "DISK{0,3}%" -f $o.Disk; $labels["DISK"].ForeColor = Get-Color $o.Disk 60 90
    if ($causes.Count -gt 0) {
        $causeLabel.Text = "LAG CAUSE: " + (($causes | ForEach-Object { $_.Message }) -join "  |  ")
        $causeLabel.ForeColor = if ($causes[0].Code -eq "GPU_MAXED") { [System.Drawing.Color]::FromArgb(255,200,60) } else { $red }
    } else {
        $causeLabel.Text = "Status: OK - enough RAM, no overheating, no bottleneck"
        $causeLabel.ForeColor = $green
    }
}
function Set-OverlayVisible([bool]$v) {
    if ($v -and -not $form.Visible) { $form.Show() }
    elseif (-not $v -and $form.Visible) { $form.Hide() }
}
function Update-OverlayVisibility {
    switch ("$($script:cfg.overlay)".ToLower()) {
        "always" { Set-OverlayVisible $true }
        "off"    { Set-OverlayVisible $false }
        default  { Set-OverlayVisible ($null -ne $script:session) }
    }
}

# ---------------- App picker (choose what to close while gaming) ----------------
$friendlyNames = @{
    "HD-Player" = "BlueStacks"; "BlueStacks*" = "BlueStacks (background helpers)"; "OneDrive" = "Microsoft OneDrive"
    "Teams" = "Microsoft Teams"; "ms-teams" = "Microsoft Teams"; "PhoneExperienceHost" = "Phone Link"; "YourPhone" = "Phone Link"
    "Widgets" = "Windows Widgets"; "chrome" = "Google Chrome"; "msedge" = "Microsoft Edge"; "firefox" = "Firefox"
    "Spotify" = "Spotify"; "Discord" = "Discord"; "claude" = "Claude"; "Code" = "Visual Studio Code"
}
function Get-FriendlyName($name) { if ($friendlyNames.ContainsKey($name)) { return $friendlyNames[$name] } return $name.TrimEnd('*') }

function Get-AppCandidates($cfg) {
    $winDir = $env:windir
    $game = if ($script:session) { $script:session.Game } else { $null }
    $rows = @{}
    foreach ($p in Get-Process) {
        $path = $null; try { $path = $p.Path } catch {}
        if (-not $path -or $path -like "$winDir*") { continue }
        if ($p.Id -eq $PID) { continue }
        $n = $p.ProcessName
        if ($game -and $n -eq $game) { continue }
        if (Test-NameMatch $n $hardProtected) { continue }
        if (Test-NameMatch $n $systemCritical) { continue }
        if (Test-IsGame $p $cfg) { continue }
        if (-not $rows.ContainsKey($n)) {
            $desc = if ($friendlyNames.ContainsKey($n)) { $friendlyNames[$n] } else { $n }
            if (-not $friendlyNames.ContainsKey($n)) { try { $vi = $p.MainModule.FileVersionInfo; if ($vi.FileDescription) { $desc = $vi.FileDescription.Trim() } elseif ($vi.ProductName) { $desc = $vi.ProductName.Trim() } } catch {} }
            $rows[$n] = [pscustomobject]@{ Name = $n; Title = $desc; Path = $path; RamMB = 0; Running = $true }
        }
        $rows[$n].RamMB += [math]::Round($p.WorkingSet64 / 1MB)
    }
    # apps already selected but not running right now
    foreach ($n in @($cfg.closeApps)) {
        if (-not $n -or ($rows.Keys | Where-Object { $_ -like $n })) { continue }
        $t = Get-FriendlyName $n
        $same = $rows.Values | Where-Object { -not $_.Running -and $_.Title -eq $t } | Select-Object -First 1
        if ($same) { $same.Name = "$($same.Name);$n" }   # e.g. Teams + ms-teams shown once
        else { $rows[$n] = [pscustomobject]@{ Name = $n; Title = $t; Path = $null; RamMB = 0; Running = $false } }
    }
    # hide tiny background helpers nobody recognises
    return $rows.Values | Where-Object { -not $_.Running -or $_.RamMB -ge 15 } | Sort-Object @{e={$_.Running};Descending=$true}, @{e={$_.RamMB};Descending=$true}
}

function Show-AppPicker {
    $cfg = $script:cfg
    $bg = [System.Drawing.Color]::FromArgb(32, 32, 32); $fg = [System.Drawing.Color]::White
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "LagScope - Apps to close while gaming"
    $dlg.Size = New-Object System.Drawing.Size(560, 600)
    $dlg.StartPosition = "CenterScreen"; $dlg.TopMost = $true
    $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $bg; $dlg.ForeColor = $fg
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Which apps should close when you start a game?"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(16, 12); $title.Size = New-Object System.Drawing.Size(520, 26)
    $dlg.Controls.Add($title)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "Ticked apps are closed to free RAM and reopened when the game ends.`nLeave anything you use while playing unticked (music, voice chat, OBS...)."
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $hint.Location = New-Object System.Drawing.Point(16, 42); $hint.Size = New-Object System.Drawing.Size(520, 42)
    $dlg.Controls.Add($hint)

    $list = New-Object System.Windows.Forms.ListView
    $list.View = "Details"; $list.CheckBoxes = $true; $list.FullRowSelect = $true; $list.HeaderStyle = "Nonclickable"
    $list.Location = New-Object System.Drawing.Point(16, 92); $list.Size = New-Object System.Drawing.Size(512, 390)
    $list.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45); $list.ForeColor = $fg; $list.BorderStyle = "FixedSingle"
    [void]$list.Columns.Add("App", 330); [void]$list.Columns.Add("RAM", 80, "Right"); [void]$list.Columns.Add("", 80)
    $icons = New-Object System.Windows.Forms.ImageList; $icons.ImageSize = New-Object System.Drawing.Size(20, 20); $icons.ColorDepth = "Depth32Bit"
    $list.SmallImageList = $icons

    foreach ($a in Get-AppCandidates $cfg) {
        $item = New-Object System.Windows.Forms.ListViewItem($a.Title)
        if ($a.Path) {
            try { $icons.Images.Add($a.Name, [System.Drawing.Icon]::ExtractAssociatedIcon($a.Path)); $item.ImageKey = $a.Name } catch {}
        }
        [void]$item.SubItems.Add($(if ($a.Running) { "$($a.RamMB) MB" } else { "" }))
        [void]$item.SubItems.Add($(if ($a.Running) { "running" } else { "not running" }))
        if (-not $a.Running) { $item.ForeColor = [System.Drawing.Color]::Gray }
        $item.Tag = $a.Name
        $item.Checked = [bool](($a.Name -split ';') | Where-Object { Test-NameMatch $_ $cfg.closeApps })
        [void]$list.Items.Add($item)
    }
    $dlg.Controls.Add($list)

    $sum = New-Object System.Windows.Forms.Label
    $sum.Location = New-Object System.Drawing.Point(16, 488); $sum.Size = New-Object System.Drawing.Size(512, 22)
    $sum.ForeColor = [System.Drawing.Color]::FromArgb(120, 230, 120)
    $updateSum = {
        $mb = 0; $c = 0
        foreach ($it in $list.Items) { if ($it.Checked) { $c++; $mb += [int]("0" + ($it.SubItems[1].Text -replace '[^0-9]', '')) } }
        $sum.Text = "$c apps selected - frees about $mb MB of RAM when a game starts"
    }.GetNewClosure()
    $list.Add_ItemChecked($updateSum)
    & $updateSum
    $dlg.Controls.Add($sum)

    function New-Btn($text, $x, $w) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, 516); $b.Size = New-Object System.Drawing.Size($w, 32)
        $b.FlatStyle = "Flat"; $b.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60); $b.ForeColor = $fg
        $dlg.Controls.Add($b); return $b
    }
    $none = New-Btn "Untick all" 16 100
    $none.Add_Click({ foreach ($it in $list.Items) { $it.Checked = $false } }.GetNewClosure())
    $cancel = New-Btn "Cancel" 328 90
    $cancel.DialogResult = "Cancel"
    $save = New-Btn "Save" 428 100
    $save.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $save.DialogResult = "OK"
    $dlg.AcceptButton = $save; $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog() -eq "OK") {
        $chosen = @(); $unchosen = @()
        foreach ($it in $list.Items) { $names = "$($it.Tag)" -split ';'; if ($it.Checked) { $chosen += $names } else { $unchosen += $names } }
        # keep wildcard entries (e.g. BlueStacks*) unless the user unticked them
        $kept = @(@($cfg.closeApps) | Where-Object { $_ -like '*`**' -and -not ($unchosen -contains $_) -and -not ($chosen -contains $_) })
        Save-Setting "closeApps" @($chosen + $kept | Select-Object -Unique | Where-Object { -not (Test-NameMatch $_ $hardProtected) })
        # an app the user explicitly chose to close must not be blocked by neverTouch
        Save-Setting "neverTouch" @(@($cfg.neverTouch) | Where-Object { $n = $_; -not ($chosen | Where-Object { $_ -like $n }) })
        Write-Log "Apps to close updated: $($chosen -join ', ')"
        $script:appsItem.Text = "Apps to close in games ($(@($script:cfg.closeApps).Count))..."
    }
    $dlg.Dispose()
}

# ---------------- Start with Windows ----------------
$taskName = "LagScope"
function Test-Autostart { [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) }
function Set-Autostart([bool]$on) {
    try {
        if ($on) {
            $ps = Join-Path $appDir "LagScope.ps1"
            $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ps`""
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest -LogonType Interactive
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
            Write-Log "Start with Windows: ON"
        } else {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log "Start with Windows: OFF"
        }
    } catch { [void][System.Windows.Forms.MessageBox]::Show("Could not change autostart: $($_.Exception.Message)", "LagScope") }
}

# ---------------- Tray ----------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Shield
$tray.Text = "LagScope - waiting for a game"
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$statusItem = $menu.Items.Add("Waiting for a game..."); $statusItem.Enabled = $false
[void]$menu.Items.Add("-")
$script:appsItem = $menu.Items.Add("Apps to close in games ($(@($script:cfg.closeApps).Count))...")
$script:appsItem.Font = New-Object System.Drawing.Font($script:appsItem.Font, [System.Drawing.FontStyle]::Bold)
$script:appsItem.Add_Click({ Show-AppPicker })

function New-Toggle($text, $key) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $item.CheckOnClick = $true
    $item.Checked = [bool]$script:cfg[$key]
    $item.Tag = $key
    $item.Add_Click({ param($sender) Save-Setting $sender.Tag $sender.Checked })
    [void]$menu.Items.Add($item)
    return $item
}
$gmItem  = New-Toggle "Game Mode (free PC when a game starts)" "gameMode"
$ramItem = New-Toggle "Auto RAM cleaner while gaming" "autoRamCleaner"
$devItem = New-Toggle "Stop dev tools in games (Docker, WSL, dev servers)" "stopDevTools"

$overlayMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Overlay")
foreach ($mode in @(@("auto","Only while gaming"), @("always","Always"), @("off","Off"))) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem($mode[1])
    $it.Tag = $mode[0]
    $it.Checked = ("$($script:cfg.overlay)".ToLower() -eq $mode[0])
    $it.Add_Click({
        param($sender)
        foreach ($x in $overlayMenu.DropDownItems) { $x.Checked = ($x -eq $sender) }
        Save-Setting "overlay" $sender.Tag
        Update-OverlayVisibility
    })
    [void]$overlayMenu.DropDownItems.Add($it)
}
[void]$menu.Items.Add($overlayMenu)
[void]$menu.Items.Add("-")

($menu.Items.Add("Boost now")).Add_Click({
    if (-not $script:boosted) {
        $msg = Start-Boost (Find-Game $script:cfg) $script:cfg
        $tray.ShowBalloonTip(5000, "LagScope boost", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
    }
})
($menu.Items.Add("Clean RAM now")).Add_Click({
    if ($isAdmin) {
        $b = Get-FreeRamMB; [void][LagScopeNative]::MemoryCommand(4); $script:lastPurge = Get-Date; $a = Get-FreeRamMB
        $tray.ShowBalloonTip(3000, "LagScope", "RAM cleaned: $b MB -> $a MB free", [System.Windows.Forms.ToolTipIcon]::Info)
    }
})
($menu.Items.Add("Show last report")).Add_Click({
    $last = Get-ChildItem $logDir -Filter "REPORT_*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($script:session) { [void][System.Windows.Forms.MessageBox]::Show((New-Report), "LagScope Report (current game)") }
    elseif ($last) { [void][System.Windows.Forms.MessageBox]::Show((Get-Content $last.FullName -Raw), "LagScope Report") }
    else { [void][System.Windows.Forms.MessageBox]::Show("No report yet. One is created automatically after each game.", "LagScope") }
})
($menu.Items.Add("Open logs folder")).Add_Click({ Start-Process explorer.exe $logDir })
($menu.Items.Add("Edit settings")).Add_Click({ Start-Process notepad.exe $configPath })
[void]$menu.Items.Add("-")
$autoItem = New-Object System.Windows.Forms.ToolStripMenuItem("Start with Windows")
$autoItem.Checked = Test-Autostart
$autoItem.Add_Click({ Set-Autostart (-not $autoItem.Checked); $autoItem.Checked = Test-Autostart })
[void]$menu.Items.Add($autoItem)
($menu.Items.Add("Exit")).Add_Click({
    $timer.Stop()
    if ($script:boosted) { Stop-Boost $script:cfg }
    if ($script:session) { [void](New-Report) }
    $tray.Visible = $false
    [LagSampler]::Stop()
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
})
$tray.ContextMenuStrip = $menu
$tray.Add_BalloonTipClicked({
    $last = Get-ChildItem $logDir -Filter "REPORT_*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($last) { Start-Process notepad.exe $last.FullName }
})

# ---------------- Main loop ----------------
$script:missedChecks = 0
$script:lastNotice = [datetime]::MinValue
$script:lastGameCheck = [datetime]::MinValue

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [math]::Max(1000, [int]$script:cfg.sampleIntervalMs)
$timer.Add_Tick({
    try {
        $cfg = $script:cfg
        Invoke-PendingKills

        # Game detection every ~3 s
        $gameEvery = if ($script:session) { 3 } else { 5 }
        if (((Get-Date) - $script:lastGameCheck).TotalSeconds -ge $gameEvery) {
            $script:lastGameCheck = Get-Date
            $game = Find-Game $cfg
            if ($game -and -not $script:session) {
                $timer.Stop()
                $script:gameProc = $game
                $script:session = New-Session $game.ProcessName
                $statusItem.Text = "In game: $($game.ProcessName)"
                $tray.Text = "LagScope - $($game.ProcessName)"
                Update-OverlayVisibility
                if ($cfg.gameMode) {
                    $msg = Start-Boost $game $cfg
                    $tray.ShowBalloonTip(5000, "Game Mode ON: $($game.ProcessName)", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
                }
                $timer.Start()
            } elseif ($game) {
                $script:missedChecks = 0
            } elseif ($script:session) {
                $script:missedChecks++
                if ($script:missedChecks -ge 2) {
                    $script:missedChecks = 0
                    if ($script:boosted) { Stop-Boost $cfg }
                    $report = New-Report
                    $first = ($report -split "`r`n" | Where-Object { $_ -like ">>>*" } | Select-Object -First 1)
                    $script:session = $null
                    $script:gameProc = $null
                    $statusItem.Text = "Waiting for a game..."
                    $tray.Text = "LagScope - waiting for a game"
                    Update-OverlayVisibility
                    $tray.ShowBalloonTip(6000, "Game over - report ready (click)", "$first".Replace(">>> ", ""), [System.Windows.Forms.ToolTipIcon]::Info)
                }
            }
        }

        # Monitoring only while gaming or when the overlay is forced on
        if ($script:session -or $form.Visible) {
            $o = Measure-System
            $causes = Get-Diagnosis $o
            if ($form.Visible) { Update-Overlay $o $causes }
            if ($script:session) {
                Add-Sample $o $causes
                Invoke-AutoRamClean $cfg
                $real = @($causes | Where-Object { $_.Code -ne "GPU_MAXED" })
                if ($real.Count -and ((Get-Date) - $script:lastNotice).TotalSeconds -ge 120 -and "$($cfg.overlay)" -eq "off") {
                    $script:lastNotice = Get-Date
                    $tray.ShowBalloonTip(4000, "Your PC is struggling", (($real | ForEach-Object { $_.Message }) -join "`n"), [System.Windows.Forms.ToolTipIcon]::Warning)
                }
            }
        }
    } catch { Write-Log "Error: $($_.Exception.Message)"; if (-not $timer.Enabled) { $timer.Start() } }
})

[LagSampler]::Start([int]$script:cfg.sampleIntervalMs, $nvsmi)
Write-Log "LagScope started (admin: $isAdmin)"
$tray.ShowBalloonTip(3000, "LagScope is running", "I'll take care of your PC as soon as a game starts. Right-click the shield icon for options.", [System.Windows.Forms.ToolTipIcon]::Info)
Update-OverlayVisibility
if (-not $script:cfg.appPickerShown) {
    Save-Setting "appPickerShown" $true
    Show-AppPicker
}
$timer.Start()
[System.Windows.Forms.Application]::Run()
[LagSampler]::Stop()
$tray.Dispose()
try { $script:mutex.ReleaseMutex() } catch {}
