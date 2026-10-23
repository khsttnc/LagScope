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
function Get-FreeRamMB { [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory).AvailableMBytes }

# ---------------- Game detection ----------------
function Test-IsGame($proc, $cfg) {
    $name = $proc.ProcessName
    if (Test-NameMatch $name $cfg.notGames) { return $false }
    if (Test-NameMatch $name $cfg.games) { return $true }
    $path = $null
    try { $path = $proc.Path } catch {}
    if (-not $path) { return $false }
    foreach ($folder in @($cfg.autoDetectGameFolders)) {
        if ($folder -and $path -like "*$folder*" -and $proc.MainWindowHandle -ne [IntPtr]::Zero) { return $true }
    }
    return $false
}
function Find-Game($cfg) {
    $all = Get-Process
    foreach ($p in $all) {
        if ((Test-NameMatch $p.ProcessName $cfg.games) -and -not (Test-NameMatch $p.ProcessName $cfg.notGames)) { return $p }
    }
    foreach ($p in $all) { if (Test-IsGame $p $cfg) { return $p } }
    return $null
}

# ---------------- Measurement ----------------
$nvsmi = @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") |
         Where-Object { Test-Path $_ } | Select-Object -First 1
function Get-Gpu {
    if ($nvsmi) {
        try {
            $o = & $nvsmi --query-gpu=utilization.gpu,temperature.gpu,memory.used --format=csv,noheader,nounits 2>$null
            $p = ($o | Select-Object -First 1) -split ",\s*"
            return @{ Load = [int]$p[0]; Temp = [int]$p[1]; VRAM = [int]$p[2] }
        } catch {}
    }
    try {
        $e = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop | Where-Object { $_.Name -like "*engtype_3D" }
        return @{ Load = [int][math]::Min(100, ($e | Measure-Object UtilizationPercentage -Sum).Sum); Temp = $null; VRAM = $null }
    } catch { return @{ Load = $null; Temp = $null; VRAM = $null } }
}
$script:cpuTempAvailable = $true
function Get-CpuTemp {
    if (-not $script:cpuTempAvailable) { return $null }
    try {
        $z = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        $c = ($z | ForEach-Object { ($_.CurrentTemperature / 10) - 273.15 } | Measure-Object -Maximum).Maximum
        if ($c -lt 15 -or $c -gt 120) { $script:cpuTempAvailable = $false; return $null }
        return [int]$c
    } catch { $script:cpuTempAvailable = $false; return $null }
}
$totalMB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1024)
function Measure-System {
    $cpuAll = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor
    $speed = $null
    try {
        $pi = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
        $speed = [int]$pi.PercentProcessorPerformance
        if (-not $speed) { $speed = [int]$pi.PercentofMaximumFrequency }
    } catch {}
    $mem  = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
    $gpu  = Get-Gpu
    $avail = [int]$mem.AvailableMBytes
    [pscustomobject]@{
        CPU      = [int]($cpuAll | Where-Object Name -eq "_Total").PercentProcessorTime
        Core     = [int]($cpuAll | Where-Object Name -ne "_Total" | Measure-Object PercentProcessorTime -Maximum).Maximum
        CpuSpeed = $speed
        CPU_C    = Get-CpuTemp
        RAM      = [int][math]::Round((($totalMB - $avail) / $totalMB) * 100)
        FreeRAM  = $avail
        GPU      = $gpu.Load; GPU_C = $gpu.Temp; VRAM = $gpu.VRAM
        Disk     = [int][math]::Min(100, $disk.PercentDiskTime)
        DiskMBs  = [math]::Round($disk.DiskBytesPersec / 1MB, 1)
    }
}
function Get-TopProcess($property) {
    Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $_.Name -notin "_Total","Idle" } |
        Sort-Object $property -Descending | Select-Object -First 1
}
function Get-Diagnosis($o) {
    $s = @()
    if ($o.RAM -ge 88 -or $o.FreeRAM -lt 1024) {
        $p = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
        $s += @{ Code = "RAM"; Message = "RAM RUNNING OUT ($($o.RAM)%, $($o.FreeRAM) MB free) - top user: $($p.ProcessName) $([math]::Round($p.WorkingSet64/1MB)) MB" }
    }
    if ($null -ne $o.CPU_C -and $o.CPU_C -ge 90) { $s += @{ Code = "CPU_HEAT"; Message = "CPU OVERHEATING ($($o.CPU_C) C)" } }
    if ($null -ne $o.CpuSpeed -and $o.CPU -ge 40 -and $o.CpuSpeed -lt 80) {
        $s += @{ Code = "CPU_HEAT"; Message = "CPU THROTTLING (running at $($o.CpuSpeed)% of base speed) - usually heat or power plan" }
    }
    if ($null -ne $o.GPU_C -and $o.GPU_C -ge 83) { $s += @{ Code = "GPU_HEAT"; Message = "GPU HOT ($($o.GPU_C) C) - may throttle. Check fans / dust / airflow" } }
    $gpuWaiting = ($null -eq $o.GPU) -or ($o.GPU -lt 85)
    if ($o.CPU -ge 90 -or ($o.Core -ge 95 -and $gpuWaiting)) {
        $p = Get-TopProcess PercentProcessorTime
        $gpuText = if ($null -ne $o.GPU) { ", GPU only at $($o.GPU)% - waiting" } else { "" }
        $s += @{ Code = "CPU_BOTTLENECK"; Message = "CPU BOTTLENECK (total $($o.CPU)%, busiest core $($o.Core)%$gpuText) - top: $($p.Name)" }
    }
    if ($o.Disk -ge 90) {
        $p = Get-TopProcess IODataBytesPersec
        $s += @{ Code = "DISK"; Message = "DISK CAN'T KEEP UP ($($o.Disk)%, $($o.DiskMBs) MB/s) - top: $($p.Name)" }
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

# ---------------- Game Mode actions ----------------
$script:boosted = $false
$script:closedApps = @()
$script:stoppedServices = @()
$script:previousPowerPlan = $null
$script:gameProc = $null
$script:lastPurge = [datetime]::MinValue

function Close-Apps($cfg, $gamePid) {
    $targets = @(Get-Process | Where-Object {
        $_.Id -ne $gamePid -and $_.Id -ne $PID -and
        (Test-NameMatch $_.ProcessName $cfg.closeApps) -and
        -not (Test-NameMatch $_.ProcessName $cfg.neverTouch) -and
        -not (Test-NameMatch $_.ProcessName $systemCritical)
    })
    if (-not $targets) { return @() }
    foreach ($p in $targets) { try { [void]$p.CloseMainWindow() } catch {} }
    $wait = [int]$cfg.forceCloseAfterSeconds
    if ($wait -gt 0) { Start-Sleep -Seconds $wait }
    $closed = @()
    foreach ($p in $targets) {
        $path = $null; try { $path = $p.Path } catch {}
        try { $p.Refresh(); if (-not $p.HasExited -and $wait -gt 0) { Stop-Process -Id $p.Id -Force -ErrorAction Stop } } catch {}
        $closed += [pscustomobject]@{ Name = $p.ProcessName; Path = $path }
    }
    return $closed
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
        wsl.exe --shutdown 2>$null
        $stopped += "WSL"; Write-Log "WSL shut down"
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

    Start-Sleep -Milliseconds 800
    $after = Get-FreeRamMB
    $freed = [math]::Max(0, $after - $before)
    Write-Log "Free RAM after: $after MB (+$freed MB)"
    if ($script:session) { $script:session.RamFreedAtStart = $freed }
    $script:boosted = $true
    return ((@("Freed $freed MB RAM (now $after MB free)") + $summary) -join "`n")
}

function Stop-Boost($cfg) {
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
    $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $standbyMB = [math]::Round(([double]$m.StandbyCacheNormalPriorityBytes + [double]$m.StandbyCoreBytes + [double]$m.StandbyCacheReserveBytes) / 1MB)
    $freeMB = [math]::Max(0, [int]$m.AvailableMBytes - $standbyMB)
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
        $b = Get-FreeRamMB; [void][LagScopeNative]::MemoryCommand(4); $script:lastPurge = Get-Date; Start-Sleep -Milliseconds 500; $a = Get-FreeRamMB
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

        # Game detection every ~3 s
        if (((Get-Date) - $script:lastGameCheck).TotalSeconds -ge 3) {
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

Write-Log "LagScope started (admin: $isAdmin)"
$tray.ShowBalloonTip(3000, "LagScope is running", "I'll take care of your PC as soon as a game starts. Right-click the shield icon for options.", [System.Windows.Forms.ToolTipIcon]::Info)
Update-OverlayVisibility
$timer.Start()
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
$script:mutex.ReleaseMutex()
