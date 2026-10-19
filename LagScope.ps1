<#
.SYNOPSIS
  LagScope - finds out WHY your PC stutters while gaming.

.DESCRIPTION
  Shows a small click-through overlay at the bottom of the screen and continuously answers:
    1) Is RAM running out?
    2) Is something overheating? (CPU/GPU temperature + CPU clock throttling)
    3) Is the CPU the bottleneck? (one core pinned at 100% while the GPU sits idle)
  When you close it, it writes a "MAIN PROBLEM" report with concrete advice.

  Close / report: right-click the (i) tray icon next to the clock.
  Note: In exclusive fullscreen the overlay may be hidden; use borderless/windowed fullscreen.
        Measuring and reporting work either way.

.PARAMETER IntervalMs
  Sampling interval in milliseconds (default 2000).
#>
param([int]$IntervalMs = 2000)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
}
"@

# ---------------- Log files ----------------
$logDir = Join-Path $PSScriptRoot "Logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$startTime = Get-Date
$stamp = $startTime.ToString("yyyy-MM-dd_HH-mm")
$csv = Join-Path $logDir "Samples_$stamp.csv"
$log = Join-Path $logDir "Stutters_$stamp.log"
$reportFile = Join-Path $logDir "REPORT_$stamp.txt"
"Time;CPU%;BusiestCore%;CPU_Speed%;CPU_C;RAM%;FreeRAM_MB;GPU%;GPU_C;VRAM_MB;Disk%;Disk_MBs;Causes" | Out-File $csv -Encoding UTF8

# ---------------- Sensors ----------------
$nvsmi = @(
    "$env:SystemRoot\System32\nvidia-smi.exe",
    "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function Get-Gpu {
    if ($nvsmi) {
        try {
            $o = & $nvsmi --query-gpu=utilization.gpu,temperature.gpu,memory.used --format=csv,noheader,nounits 2>$null
            $p = ($o | Select-Object -First 1) -split ",\s*"
            return @{ Load = [int]$p[0]; Temp = [int]$p[1]; VRAM = [int]$p[2] }
        } catch {}
    }
    try {
        $e = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop |
             Where-Object { $_.Name -like "*engtype_3D" }
        $y = ($e | Measure-Object UtilizationPercentage -Sum).Sum
        return @{ Load = [int][math]::Min(100, $y); Temp = $null; VRAM = $null }
    } catch { return @{ Load = $null; Temp = $null; VRAM = $null } }
}

$script:cpuTempAvailable = $true
function Get-CpuTemp {
    if (-not $script:cpuTempAvailable) { return $null }
    try {
        $z = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        $c = ($z | ForEach-Object { ($_.CurrentTemperature / 10) - 273.15 } | Measure-Object -Maximum).Maximum
        if ($c -lt 15 -or $c -gt 120) { $script:cpuTempAvailable = $false; return $null }  # bogus value: sensor not supported
        return [int]$c
    } catch { $script:cpuTempAvailable = $false; return $null }
}

$totalMB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1024)

function Measure-System {
    $cpuAll = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor
    $cpu    = ($cpuAll | Where-Object Name -eq "_Total").PercentProcessorTime
    $core   = ($cpuAll | Where-Object Name -ne "_Total" | Measure-Object PercentProcessorTime -Maximum).Maximum
    $speed = $null
    try {
        $pi = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
        $speed = [int]$pi.PercentProcessorPerformance
        if (-not $speed) { $speed = [int]$pi.PercentofMaximumFrequency }
    } catch {}
    $mem  = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
    $gpu  = Get-Gpu
    $availableMB = [int]$mem.AvailableMBytes
    [pscustomobject]@{
        CPU      = [int]$cpu
        Core     = [int]$core
        CpuSpeed = $speed
        CPU_C    = Get-CpuTemp
        RAM      = [int][math]::Round((($totalMB - $availableMB) / $totalMB) * 100)
        FreeRAM  = $availableMB
        GPU      = $gpu.Load
        GPU_C    = $gpu.Temp
        VRAM     = $gpu.VRAM
        Disk     = [int][math]::Min(100, $disk.PercentDiskTime)
        DiskMBs  = [math]::Round($disk.DiskBytesPersec / 1MB, 1)
    }
}

function Get-TopProcess($property) {
    Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
        Where-Object { $_.Name -notin "_Total","Idle" } |
        Sort-Object $property -Descending | Select-Object -First 1
}

# ---------------- Diagnosis ----------------
# Each cause: Code (for statistics) + Message (on screen)
function Get-Diagnosis($o) {
    $s = @()
    # 1) RAM
    if ($o.RAM -ge 88 -or $o.FreeRAM -lt 1024) {
        $p = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
        $s += @{ Code = "RAM"; Message = "RAM RUNNING OUT ($($o.RAM)%, $($o.FreeRAM) MB free) - top user: $($p.ProcessName) $([math]::Round($p.WorkingSet64/1MB)) MB" }
    }
    # 2) Heat
    if ($null -ne $o.CPU_C -and $o.CPU_C -ge 90) {
        $s += @{ Code = "CPU_HEAT"; Message = "CPU OVERHEATING ($($o.CPU_C) C)" }
    }
    if ($null -ne $o.CpuSpeed -and $o.CPU -ge 40 -and $o.CpuSpeed -lt 80) {
        $s += @{ Code = "CPU_HEAT"; Message = "CPU THROTTLING (running at $($o.CpuSpeed)% of base speed) - usually heat or power plan" }
    }
    if ($null -ne $o.GPU_C -and $o.GPU_C -ge 83) {
        $s += @{ Code = "GPU_HEAT"; Message = "GPU HOT ($($o.GPU_C) C) - may throttle. Check fans / dust / airflow" }
    }
    # 3) CPU bottleneck
    $gpuWaiting = ($null -eq $o.GPU) -or ($o.GPU -lt 85)
    if ($o.CPU -ge 90 -or ($o.Core -ge 95 -and $gpuWaiting)) {
        $p = Get-TopProcess PercentProcessorTime
        $gpuText = if ($null -ne $o.GPU) { ", GPU only at $($o.GPU)% - waiting" } else { "" }
        $s += @{ Code = "CPU_BOTTLENECK"; Message = "CPU BOTTLENECK (total $($o.CPU)%, busiest core $($o.Core)%$gpuText) - top: $($p.Name)" }
    }
    # Disk
    if ($o.Disk -ge 90) {
        $p = Get-TopProcess IODataBytesPersec
        $s += @{ Code = "DISK"; Message = "DISK CAN'T KEEP UP ($($o.Disk)%, $($o.DiskMBs) MB/s) - top: $($p.Name)" }
    }
    # GPU maxed out (not a fault)
    if ($s.Count -eq 0 -and $null -ne $o.GPU -and $o.GPU -ge 97) {
        $s += @{ Code = "GPU_MAXED"; Message = "GPU fully loaded ($($o.GPU)%) - normal; lower graphics settings if FPS is low" }
    }
    return ,$s
}

# ---------------- Session statistics ----------------
$script:sampleCount = 0
$script:counts = @{ RAM = 0; CPU_HEAT = 0; GPU_HEAT = 0; CPU_BOTTLENECK = 0; DISK = 0; GPU_MAXED = 0 }
$script:peak = @{ CPU_C = $null; GPU_C = $null; RAM = 0; Core = 0; MinSpeed = $null }

function New-Report {
    $n = [math]::Max(1, $script:sampleCount)
    $minutes = [math]::Round(((Get-Date) - $startTime).TotalMinutes)
    $names = @{
        RAM            = "Not enough RAM"
        CPU_HEAT       = "CPU overheating / throttling"
        GPU_HEAT       = "GPU overheating"
        CPU_BOTTLENECK = "CPU bottleneck"
        DISK           = "Slow disk"
        GPU_MAXED      = "GPU at its limit (not a fault)"
    }
    $advice = @{
        RAM            = "Close background apps (browser, Discord, Spotify, emulators) or let START_GAMEMODE.bat close them automatically when a game starts. If it keeps happening, add more RAM. Also check that RAM runs in dual channel with XMP/EXPO enabled."
        CPU_HEAT       = "Clean dust from the case, check the CPU cooler and thermal paste. Set Windows power mode to 'Best performance'."
        GPU_HEAT       = "Clean the GPU fans, improve case airflow, use a more aggressive fan curve."
        CPU_BOTTLENECK = "Lower CPU-heavy settings (view distance, crowds, effects), close background apps. An FPS cap reduces stutter."
        DISK           = "Move the game to an SSD. Check for background downloads, Windows Update or antivirus scans."
        GPU_MAXED      = "Not a problem; for more FPS lower graphics settings or enable DLSS/FSR."
    }
    $lines = @()
    $lines += "==============================================="
    $lines += "  LAGSCOPE REPORT - $($startTime.ToString('yyyy-MM-dd HH:mm'))  ($minutes min monitored)"
    $lines += "==============================================="
    $lines += ""
    $sorted = $script:counts.GetEnumerator() | Sort-Object Value -Descending
    $main = $sorted | Where-Object { $_.Key -ne "GPU_MAXED" -and ($_.Value / $n) -ge 0.05 } | Select-Object -First 1
    if ($main) {
        $lines += ">>> MAIN PROBLEM: $($names[$main.Key].ToUpper())  ($([math]::Round($main.Value / $n * 100))% of the time)"
        $lines += "    What to do: $($advice[$main.Key])"
    } else {
        $lines += ">>> No clear bottleneck found. Your PC was comfortable this session."
        $lines += "    If it still stutters: network (ping), the game itself or drivers may be the cause."
    }
    $lines += ""
    $lines += "Share of time each cause was detected:"
    foreach ($k in $sorted) {
        $pct = [math]::Round($k.Value / $n * 100)
        $bar = "#" * [math]::Min(30, [math]::Round($pct / 100 * 30))
        $lines += ("  {0,-34} {1,3}%  {2}" -f $names[$k.Key], $pct, $bar)
    }
    $lines += ""
    $lines += "Peak values:"
    $lines += "  RAM usage          : $($script:peak.RAM)%"
    $lines += "  Busiest core       : $($script:peak.Core)%"
    $lines += "  CPU temperature    : " + $(if ($null -ne $script:peak.CPU_C) { "$($script:peak.CPU_C) C" } else { "sensor not readable (checked via throttling instead)" })
    $lines += "  Lowest CPU speed   : " + $(if ($null -ne $script:peak.MinSpeed) { "$($script:peak.MinSpeed)% of base" } else { "-" })
    $lines += "  GPU temperature    : " + $(if ($null -ne $script:peak.GPU_C) { "$($script:peak.GPU_C) C" } else { "-" })
    $lines += ""
    $lines += "Detailed timeline: $(Split-Path $log -Leaf)"
    $lines | Out-File $reportFile -Encoding UTF8
    return ($lines -join "`r`n")
}

function Get-Color($value, $warn, $crit) {
    if ($null -eq $value) { return [System.Drawing.Color]::Gray }
    if ($value -ge $crit) { return [System.Drawing.Color]::FromArgb(255, 80, 80) }
    if ($value -ge $warn) { return [System.Drawing.Color]::FromArgb(255, 200, 60) }
    return [System.Drawing.Color]::FromArgb(120, 230, 120)
}

# ---------------- Overlay window ----------------
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = "None"
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::Black
$form.Opacity = 0.80
$form.StartPosition = "Manual"
$form.Size = New-Object System.Drawing.Size(760, 50)
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($screen.Left + [int](($screen.Width - $form.Width) / 2)), ($screen.Bottom - $form.Height - 4))

$font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$labels = @{}
$i = 0
foreach ($name in "CPU","CORE","SPEED","CPUTEMP","RAM","GPU","GPUTEMP","DISK") {
    $l = New-Object System.Windows.Forms.Label
    $l.Font = $font
    $l.AutoSize = $false
    $l.Size = New-Object System.Drawing.Size(94, 24)
    $l.Location = New-Object System.Drawing.Point((4 + $i * 94), 2)
    $l.TextAlign = "MiddleLeft"
    $l.ForeColor = [System.Drawing.Color]::White
    $l.Text = "--"
    $form.Controls.Add($l)
    $labels[$name] = $l
    $i++
}
$causeLabel = New-Object System.Windows.Forms.Label
$causeLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$causeLabel.AutoSize = $false
$causeLabel.Size = New-Object System.Drawing.Size(752, 22)
$causeLabel.Location = New-Object System.Drawing.Point(4, 26)
$causeLabel.TextAlign = "MiddleLeft"
$causeLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 230, 120)
$causeLabel.Text = "Status: measuring..."
$form.Controls.Add($causeLabel)

$form.Add_Shown({
    $style = [Win]::GetWindowLong($form.Handle, -20)
    [void][Win]::SetWindowLong($form.Handle, -20, ($style -bor 0x80000 -bor 0x20 -bor 0x80)) # LAYERED|TRANSPARENT|TOOLWINDOW: clicks pass through to the game
})

# ---------------- Tray icon ----------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Information
$tray.Text = "LagScope"
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
($menu.Items.Add("Show report now")).Add_Click({
    [void][System.Windows.Forms.MessageBox]::Show((New-Report), "LagScope Report")
})
($menu.Items.Add("Hide / show overlay")).Add_Click({ $form.Visible = -not $form.Visible })
($menu.Items.Add("Open logs folder")).Add_Click({ Start-Process explorer.exe $logDir })
($menu.Items.Add("Exit (show report)")).Add_Click({
    $timer.Stop()
    $text = New-Report
    $tray.Visible = $false
    [void][System.Windows.Forms.MessageBox]::Show($text, "LagScope Report")
    $form.Close()
})
$tray.ContextMenuStrip = $menu

$script:lastNotice = [datetime]::MinValue
$green = [System.Drawing.Color]::FromArgb(120, 230, 120)
$red   = [System.Drawing.Color]::FromArgb(255, 80, 80)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $IntervalMs
$timer.Add_Tick({
    try {
        $o = Measure-System
        $script:sampleCount++
        if ($o.RAM -gt $script:peak.RAM) { $script:peak.RAM = $o.RAM }
        if ($o.Core -gt $script:peak.Core) { $script:peak.Core = $o.Core }
        if ($null -ne $o.CPU_C -and ($null -eq $script:peak.CPU_C -or $o.CPU_C -gt $script:peak.CPU_C)) { $script:peak.CPU_C = $o.CPU_C }
        if ($null -ne $o.GPU_C -and ($null -eq $script:peak.GPU_C -or $o.GPU_C -gt $script:peak.GPU_C)) { $script:peak.GPU_C = $o.GPU_C }
        if ($null -ne $o.CpuSpeed -and $o.CPU -ge 40 -and ($null -eq $script:peak.MinSpeed -or $o.CpuSpeed -lt $script:peak.MinSpeed)) { $script:peak.MinSpeed = $o.CpuSpeed }

        $labels["CPU"].Text     = "CPU {0,3}%" -f $o.CPU;       $labels["CPU"].ForeColor  = Get-Color $o.CPU 70 90
        $labels["CORE"].Text    = "CORE{0,3}%" -f $o.Core;      $labels["CORE"].ForeColor = Get-Color $o.Core 85 95
        $labels["SPEED"].Text   = if ($null -ne $o.CpuSpeed) { "CLK {0,3}%" -f $o.CpuSpeed } else { "CLK  --" }
        $labels["SPEED"].ForeColor = if ($null -ne $o.CpuSpeed -and $o.CpuSpeed -lt 80) { $red } else { $green }
        $labels["CPUTEMP"].Text = if ($null -ne $o.CPU_C) { "CPU {0}C" -f $o.CPU_C } else { "CPU  --C" }
        $labels["CPUTEMP"].ForeColor = Get-Color $o.CPU_C 80 90
        $labels["RAM"].Text     = "RAM {0,3}%" -f $o.RAM;       $labels["RAM"].ForeColor  = Get-Color $o.RAM 75 88
        $labels["GPU"].Text     = if ($null -ne $o.GPU) { "GPU {0,3}%" -f $o.GPU } else { "GPU  --" }
        $labels["GPU"].ForeColor = Get-Color $o.GPU 90 99
        $labels["GPUTEMP"].Text = if ($null -ne $o.GPU_C) { "GPU {0}C" -f $o.GPU_C } else { "GPU  --C" }
        $labels["GPUTEMP"].ForeColor = Get-Color $o.GPU_C 75 83
        $labels["DISK"].Text    = "DISK{0,3}%" -f $o.Disk;      $labels["DISK"].ForeColor = Get-Color $o.Disk 60 90

        $causes = Get-Diagnosis $o
        foreach ($k in ($causes | ForEach-Object { $_.Code } | Select-Object -Unique)) { $script:counts[$k]++ }

        if ($causes.Count -gt 0) {
            $causeLabel.Text = "LAG CAUSE: " + (($causes | ForEach-Object { $_.Message }) -join "  |  ")
            $causeLabel.ForeColor = if ($causes[0].Code -eq "GPU_MAXED") { [System.Drawing.Color]::FromArgb(255,200,60) } else { $red }
        } else {
            $causeLabel.Text = "Status: OK - enough RAM, no overheating, no bottleneck"
            $causeLabel.ForeColor = $green
        }

        $time = Get-Date -Format "HH:mm:ss"
        $codes = ($causes | ForEach-Object { $_.Code }) -join ","
        "$time;$($o.CPU);$($o.Core);$($o.CpuSpeed);$($o.CPU_C);$($o.RAM);$($o.FreeRAM);$($o.GPU);$($o.GPU_C);$($o.VRAM);$($o.Disk);$($o.DiskMBs);$codes" |
            Out-File $csv -Append -Encoding UTF8

        $realProblems = @($causes | Where-Object { $_.Code -ne "GPU_MAXED" })
        if ($realProblems.Count -gt 0) {
            "[$time] " + (($realProblems | ForEach-Object { $_.Message }) -join " | ") | Out-File $log -Append -Encoding UTF8
            if (((Get-Date) - $script:lastNotice).TotalSeconds -ge 60) {
                $script:lastNotice = Get-Date
                $tray.ShowBalloonTip(4000, "Your PC is struggling", (($realProblems | ForEach-Object { $_.Message }) -join "`n"), [System.Windows.Forms.ToolTipIcon]::Warning)
            }
        }
    } catch {}
})

$form.Add_Load({ $timer.Start() })
[System.Windows.Forms.Application]::Run($form)
$tray.Dispose()
