<#
.SYNOPSIS
  LagScope Game Mode - frees your PC for gaming the moment a game starts.

.DESCRIPTION
  Runs in the tray and watches for games. When one starts it:
    1. Closes the apps listed in "closeApps" (gracefully first, then forcefully)
    2. Trims the RAM that every remaining background program is holding (EmptyWorkingSet),
       not just the standby cache
    3. Purges the Windows standby list
    4. Raises the game's priority to High
    5. Switches to the High performance power plan
    6. Optionally stops services listed in "stopServices"
  When the game closes, it restores the power plan and services and reopens the closed apps.

  Settings live in GameMode.config.json next to this script.

.PARAMETER Once
  Apply the boost immediately (without waiting for a game) and exit.
#>
param([switch]$Once)

$ErrorActionPreference = "Continue"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Game Mode must run as administrator. Use START_GAMEMODE.bat." -ForegroundColor Red
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class GameModeNative {
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

    // Moves a process's pages out of RAM (they come back on demand). Returns true on success.
    public static bool TrimProcess(int pid) {
        IntPtr h = OpenProcess(0x0100 | 0x0400, false, pid); // PROCESS_SET_QUOTA | PROCESS_QUERY_INFORMATION
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

# ---------------- Config ----------------
$configPath = Join-Path $PSScriptRoot "GameMode.config.json"
$logDir = Join-Path $PSScriptRoot "Logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "GameMode.log"

function Write-Log($text) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $text
    $line | Out-File $logFile -Append -Encoding UTF8
    Write-Host $line
}

function Read-Config {
    $defaults = @{
        games = @(); autoDetectGameFolders = @(); notGames = @(); closeApps = @(); neverTouch = @()
        forceCloseAfterSeconds = 5; reopenAppsAfterGame = $true; trimBackgroundRam = $true
        purgeStandbyList = $true; setGameHighPriority = $true; highPerformancePowerPlan = $true
        stopServices = @(); checkIntervalSeconds = 3
    }
    try {
        $json = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $defaults[$p.Name] = $p.Value }
    } catch {
        Write-Log "WARNING: could not read GameMode.config.json ($($_.Exception.Message)) - using defaults."
    }
    return $defaults
}

# Processes Game Mode must never close or trim
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

function Test-IsGame($proc, $cfg) {
    $name = $proc.ProcessName
    if (Test-NameMatch $name $cfg.notGames) { return $false }
    if (Test-NameMatch $name $cfg.games) { return $true }
    $path = $null
    try { $path = $proc.Path } catch {}
    if (-not $path) { return $false }
    foreach ($folder in @($cfg.autoDetectGameFolders)) {
        if ($folder -and $path -like "*$folder*") {
            # Only real game windows, not background helpers
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { return $true }
        }
    }
    return $false
}

function Find-Game($cfg) {
    foreach ($p in Get-Process) {
        if (Test-IsGame $p $cfg) { return $p }
    }
    return $null
}

function Get-FreeRamMB { [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory).AvailableMBytes }

# ---------------- Boost state ----------------
$script:boosted = $false
$script:gameName = $null
$script:closedApps = @()      # paths to reopen
$script:stoppedServices = @()
$script:previousPowerPlan = $null
$script:missedChecks = 0

function Close-Apps($cfg, $gamePid) {
    $closed = @()
    $targets = Get-Process | Where-Object {
        $_.Id -ne $gamePid -and $_.Id -ne $PID -and
        (Test-NameMatch $_.ProcessName $cfg.closeApps) -and
        -not (Test-NameMatch $_.ProcessName $cfg.neverTouch) -and
        -not (Test-NameMatch $_.ProcessName $systemCritical)
    }
    if (-not $targets) { return @() }

    # 1) ask nicely
    foreach ($p in $targets) {
        try { [void]$p.CloseMainWindow() } catch {}
    }
    $wait = [int]$cfg.forceCloseAfterSeconds
    if ($wait -gt 0) { Start-Sleep -Seconds $wait }

    # 2) force whatever is still running (tray apps ignore CloseMainWindow)
    foreach ($p in $targets) {
        $path = $null
        try { $path = $p.Path } catch {}
        try {
            $p.Refresh()
            if (-not $p.HasExited) {
                if ($wait -gt 0) { Stop-Process -Id $p.Id -Force -ErrorAction Stop }
            }
        } catch {}
        $closed += [pscustomobject]@{ Name = $p.ProcessName; Path = $path }
    }
    return $closed
}

function Invoke-TrimBackground($gamePid, $cfg) {
    $count = 0
    foreach ($p in Get-Process) {
        if ($p.Id -eq $gamePid -or $p.Id -eq $PID -or $p.Id -le 4) { continue }
        if (Test-NameMatch $p.ProcessName $systemCritical) { continue }
        if (Test-NameMatch $p.ProcessName $cfg.neverTouch) { continue }
        if ([GameModeNative]::TrimProcess($p.Id)) { $count++ }
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
    $gamePid = if ($game) { $game.Id } else { -1 }
    $script:gameName = if ($game) { $game.ProcessName } else { "manual boost" }
    Write-Log "=== Game detected: $($script:gameName) (PID $gamePid). Free RAM before: $before MB ==="
    $summary = @()

    # 1) Close apps
    $closed = @(Close-Apps $cfg $gamePid)
    $script:closedApps = @($closed | Where-Object { $_.Path } | Sort-Object Path -Unique)
    if ($closed.Count -gt 0) {
        $names = ($closed | Select-Object -ExpandProperty Name -Unique) -join ", "
        Write-Log "Closed: $names"
        $summary += "Closed: $names"
    }

    # 2) Stop services
    $script:stoppedServices = @()
    foreach ($svcName in @($cfg.stopServices)) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop
            if ($svc.Status -eq "Running") {
                Stop-Service -Name $svcName -Force -ErrorAction Stop
                $script:stoppedServices += $svcName
                Write-Log "Stopped service: $svcName"
            }
        } catch { Write-Log "Could not stop service ${svcName}: $($_.Exception.Message)" }
    }

    # 3) Trim RAM held by background programs, then flush + purge
    if ($cfg.trimBackgroundRam) {
        $n = Invoke-TrimBackground $gamePid $cfg
        [void][GameModeNative]::MemoryCommand(3)   # write modified pages out
        Write-Log "Trimmed RAM of $n background processes"
    }
    if ($cfg.purgeStandbyList) {
        $r = [GameModeNative]::MemoryCommand(4)
        if ($r -ne 0) { Write-Log ("Standby purge failed: 0x{0:X8}" -f $r) }
    }

    # 4) Game priority
    if ($game -and $cfg.setGameHighPriority) {
        try { $game.PriorityClass = "High"; Write-Log "Game priority set to High" } catch { Write-Log "Could not set priority: $($_.Exception.Message)" }
    }

    # 5) Power plan
    if ($cfg.highPerformancePowerPlan) {
        $script:previousPowerPlan = Get-ActivePowerPlan
        $highPerf = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
        powercfg /setactive $highPerf 2>$null | Out-Null
        if ((Get-ActivePowerPlan) -eq $highPerf) { Write-Log "Power plan: High performance" }
        else { Write-Log "High performance power plan not available on this PC - skipped"; $script:previousPowerPlan = $null }
    }

    Start-Sleep -Milliseconds 800
    $after = Get-FreeRamMB
    $freed = $after - $before
    Write-Log "Free RAM after: $after MB (+$freed MB)"
    $summary = @("Freed $freed MB RAM (now $after MB free)") + $summary
    $script:boosted = $true
    return ($summary -join "`n")
}

function Stop-Boost($cfg) {
    Write-Log "=== Game closed: $($script:gameName). Restoring... ==="
    if ($script:previousPowerPlan) {
        powercfg /setactive $script:previousPowerPlan 2>$null | Out-Null
        Write-Log "Power plan restored"
    }
    foreach ($svcName in $script:stoppedServices) {
        try { Start-Service -Name $svcName -ErrorAction Stop; Write-Log "Restarted service: $svcName" } catch { Write-Log "Could not restart ${svcName}: $($_.Exception.Message)" }
    }
    $reopened = @()
    if ($cfg.reopenAppsAfterGame) {
        foreach ($app in $script:closedApps) {
            try {
                Start-Process -FilePath $app.Path -WindowStyle Minimized -ErrorAction Stop
                $reopened += $app.Name
            } catch { Write-Log "Could not reopen $($app.Name): $($_.Exception.Message)" }
        }
        if ($reopened.Count) { Write-Log "Reopened: $($reopened -join ', ')" }
    }
    $script:boosted = $false
    $script:closedApps = @()
    $script:stoppedServices = @()
    $script:previousPowerPlan = $null
    $msg = "Settings restored."
    if ($reopened.Count) { $msg += " Reopened: $($reopened -join ', ')" }
    return $msg
}

# ---------------- One-shot mode ----------------
if ($Once) {
    $cfg = Read-Config
    $game = Find-Game $cfg
    Write-Host (Start-Boost $game $cfg)
    Write-Host "Boost applied. Closed apps are NOT reopened automatically in -Once mode."
    exit 0
}

# ---------------- Tray app ----------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Shield
$tray.Text = "LagScope Game Mode - waiting for a game"
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = $menu.Items.Add("Waiting for a game...")
$statusItem.Enabled = $false
[void]$menu.Items.Add("-")
($menu.Items.Add("Boost now")).Add_Click({
    if (-not $script:boosted) {
        $cfg = Read-Config
        $msg = Start-Boost (Find-Game $cfg) $cfg
        $tray.ShowBalloonTip(5000, "Game Mode ON", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
    }
})
($menu.Items.Add("Restore now")).Add_Click({
    if ($script:boosted) {
        $msg = Stop-Boost (Read-Config)
        $tray.ShowBalloonTip(4000, "Game Mode OFF", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
    }
})
($menu.Items.Add("Edit settings")).Add_Click({ Start-Process notepad.exe $configPath })
($menu.Items.Add("Open log")).Add_Click({ if (Test-Path $logFile) { Start-Process notepad.exe $logFile } })
[void]$menu.Items.Add("-")
($menu.Items.Add("Exit")).Add_Click({
    $timer.Stop()
    if ($script:boosted) { [void](Stop-Boost (Read-Config)) }
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
$tray.ContextMenuStrip = $menu

$startCfg = Read-Config
Write-Log "Game Mode started. Watching for games..."
$tray.ShowBalloonTip(3000, "LagScope Game Mode", "Running. I'll free up your PC as soon as a game starts.", [System.Windows.Forms.ToolTipIcon]::Info)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [math]::Max(1, [int]$startCfg.checkIntervalSeconds) * 1000
$timer.Add_Tick({
    try {
        $cfg = Read-Config
        $game = Find-Game $cfg
        if ($game -and -not $script:boosted) {
            $timer.Stop()
            $statusItem.Text = "Boosting $($game.ProcessName)..."
            $msg = Start-Boost $game $cfg
            $statusItem.Text = "ON: $($game.ProcessName)"
            $tray.Text = "LagScope Game Mode - ON ($($game.ProcessName))"
            $tray.ShowBalloonTip(5000, "Game Mode ON: $($game.ProcessName)", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
            $timer.Start()
        } elseif ($game) {
            $script:missedChecks = 0
        } elseif ($script:boosted -and $script:gameName -ne "manual boost") {
            # game gone - wait 2 checks to avoid flapping during loading screens / restarts
            $script:missedChecks++
            if ($script:missedChecks -ge 2) {
                $script:missedChecks = 0
                $msg = Stop-Boost $cfg
                $statusItem.Text = "Waiting for a game..."
                $tray.Text = "LagScope Game Mode - waiting for a game"
                $tray.ShowBalloonTip(4000, "Game Mode OFF", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
    } catch { Write-Log "Error: $($_.Exception.Message)"; $timer.Start() }
})
$timer.Start()
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
