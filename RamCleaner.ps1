<#
.SYNOPSIS
  RamCleaner - purges the Windows standby list when free RAM gets low.

.DESCRIPTION
  A bloated standby list is a common cause of in-game micro-stutters.
  This script only empties that cache (same idea as ISLC). It does NOT touch the
  memory of running programs, so nothing is lost.

.PARAMETER Once
  Purge one time and exit.
.PARAMETER MinFreeMB
  Purge when truly free RAM drops below this (default 2048 MB).
.PARAMETER MinStandbyMB
  Only purge if the standby list is at least this large (default 1024 MB).
.PARAMETER CheckSeconds
  How often to check (default 5 s).
.PARAMETER CooldownSeconds
  Minimum time between two purges (default 60 s).
#>
param(
    [switch]$Once,
    [int]$MinFreeMB = 2048,
    [int]$MinStandbyMB = 1024,
    [int]$CheckSeconds = 5,
    [int]$CooldownSeconds = 60
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must run as administrator. Use the .bat launcher." -ForegroundColor Red
    exit 1
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RamPurge {
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
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    static void EnablePrivilege(string name) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) return; // ADJUST_PRIVILEGES | QUERY
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.Count = 1;
        LookupPrivilegeValue(null, name, out tp.Luid);
        tp.Attr = 2; // SE_PRIVILEGE_ENABLED
        AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        CloseHandle(token);
    }

    // SystemMemoryListInformation = 80, MemoryPurgeStandbyList = 4
    public static uint PurgeStandbyList() {
        EnablePrivilege("SeProfileSingleProcessPrivilege");
        int command = 4;
        return NtSetSystemInformation(80, ref command, 4);
    }
}
"@

function Get-RamState {
    $m  = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $os = Get-CimInstance Win32_OperatingSystem
    $totalMB     = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $availableMB = [int]$m.AvailableMBytes
    $standbyMB   = [math]::Round(([double]$m.StandbyCacheNormalPriorityBytes + [double]$m.StandbyCoreBytes + [double]$m.StandbyCacheReserveBytes) / 1MB)
    $freeMB      = [math]::Max(0, $availableMB - $standbyMB)
    [pscustomobject]@{
        TotalMB      = $totalMB
        FreeMB       = $freeMB
        StandbyMB    = $standbyMB
        UsagePercent = [math]::Round((($totalMB - $availableMB) / $totalMB) * 100)
    }
}

function Invoke-Purge {
    $before = Get-RamState
    $result = [RamPurge]::PurgeStandbyList()
    Start-Sleep -Milliseconds 500
    $after = Get-RamState
    $time = Get-Date -Format "HH:mm:ss"
    if ($result -eq 0) {
        Write-Host "[$time] PURGED  Free RAM: $($before.FreeMB) MB -> $($after.FreeMB) MB  (Standby: $($before.StandbyMB) -> $($after.StandbyMB) MB)" -ForegroundColor Green
    } else {
        Write-Host ("[$time] Purge failed. Error code: 0x{0:X8}" -f $result) -ForegroundColor Red
    }
}

if ($Once) {
    Invoke-Purge
    exit 0
}

$Host.UI.RawUI.WindowTitle = "RamCleaner - running (close this window to stop)"
Write-Host "RamCleaner started." -ForegroundColor Cyan
Write-Host "Rule: purge when free RAM < $MinFreeMB MB and standby list > $MinStandbyMB MB."
Write-Host "Check every $CheckSeconds s, at least $CooldownSeconds s between purges."
Write-Host "--------------------------------------------------------------"

$lastPurge = [datetime]::MinValue
while ($true) {
    try {
        $s = Get-RamState
        $line = "Usage: {0,3}% | Free: {1,6} MB | Standby: {2,6} MB | Total: {3} MB" -f $s.UsagePercent, $s.FreeMB, $s.StandbyMB, $s.TotalMB
        Write-Host "`r$line   " -NoNewline
        $elapsed = ((Get-Date) - $lastPurge).TotalSeconds
        if ($s.FreeMB -lt $MinFreeMB -and $s.StandbyMB -gt $MinStandbyMB -and $elapsed -ge $CooldownSeconds) {
            Write-Host ""
            Invoke-Purge
            $lastPurge = Get-Date
        }
    } catch {
        Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Start-Sleep -Seconds $CheckSeconds
}
