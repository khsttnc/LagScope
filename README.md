# LagScope

**Find out *why* your Windows PC stutters while gaming — RAM, heat, or CPU bottleneck.**

LagScope is a tiny, dependency-free PowerShell tool. It puts a click-through overlay at the bottom of your screen, watches your hardware while you play, and tells you in plain words what is causing the lag. When you quit, it gives you a report with the **main problem** and what to do about it.

It also ships with **RamCleaner**, which automatically purges the Windows standby list when free memory gets low (the same trick ISLC uses) to reduce micro-stutters.

```
CPU  43%  CORE100%  CLK 129%  CPU  --C  RAM  91%  GPU  45%  GPU 67C  DISK  2%
LAG CAUSE: RAM RUNNING OUT (91%, 1545 MB free) - top user: TslGame 5537 MB
```

## What it detects

| Problem | How LagScope detects it |
|---|---|
| **Not enough RAM** | RAM ≥ 88 % used or < 1 GB available; names the process using the most memory |
| **CPU overheating / throttling** | CPU temperature ≥ 90 °C (if the sensor is exposed), or the CPU running below 80 % of its base clock while under load |
| **GPU overheating** | GPU temperature ≥ 83 °C (NVIDIA, via `nvidia-smi`) |
| **CPU bottleneck** | One core pinned at ≥ 95 % while the GPU sits below 85 % — games usually hammer a single thread, so total CPU % can look fine while one core is maxed |
| **Slow disk** | Disk active time ≥ 90 %; names the process doing the most I/O |
| GPU at its limit | GPU ≥ 97 % with no other problem — reported as *normal*, not a fault |

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in) — nothing to install
- NVIDIA GPU for GPU temperature and VRAM (load works on any GPU)

## Usage

1. Download the repository (**Code → Download ZIP**) and extract it.
2. **Before extracting**, right-click the ZIP → **Properties** → tick **Unblock** → **OK**.
   Otherwise Windows *Smart App Control* / SmartScreen may block the scripts.
3. Double-click **`START_LAGSCOPE.bat`** (accept the admin prompt — it is needed to read the CPU temperature sensor).
4. Play your game. The overlay shows live values and the current lag cause.
5. When you're done: right-click the **(i)** tray icon → **Exit (show report)**.

> The overlay is not visible in *exclusive fullscreen*. Use **borderless** or **windowed fullscreen**. Measurements and the report work either way.

### Example report

```
===============================================
  LAGSCOPE REPORT - 2026-10-17 20:41  (12 min monitored)
===============================================

>>> MAIN PROBLEM: NOT ENOUGH RAM  (21% of the time)
    What to do: Close background apps (browser, Discord, Spotify, emulators) ...

Share of time each cause was detected:
  Not enough RAM                      21%  ######
  CPU bottleneck                       2%  #
  Slow disk                            0%
  CPU overheating / throttling         0%
  GPU overheating                      0%
  GPU at its limit (not a fault)       0%

Peak values:
  RAM usage          : 96%
  Busiest core       : 100%
  CPU temperature    : sensor not readable (checked via throttling instead)
  Lowest CPU speed   : 121% of base
  GPU temperature    : 74 C
```

### Output files (`Logs/` folder)

| File | Content |
|---|---|
| `REPORT_*.txt` | Session summary and verdict |
| `Stutters_*.log` | Timestamped list of every moment the PC struggled, with the cause |
| `Samples_*.csv` | Every sample (opens in Excel; `;`-separated) |

### Options

```powershell
.\LagScope.ps1 -IntervalMs 1000   # sample every second (default 2000)
```

## RamCleaner

| Launcher | What it does |
|---|---|
| `CLEAN_RAM_AUTO.bat` | Keeps running; purges the standby list when free RAM < 2 GB |
| `CLEAN_RAM_NOW.bat` | Purges once and exits |

It only empties Windows' file cache (the *standby list*). Running programs keep their memory, so nothing is lost. Requires administrator rights.

```powershell
.\RamCleaner.ps1 -MinFreeMB 3072 -MinStandbyMB 1024 -CheckSeconds 5 -CooldownSeconds 60
.\RamCleaner.ps1 -Once
```

> RamCleaner reduces stutter caused by a bloated cache. It cannot create more RAM — if LagScope keeps reporting *Not enough RAM*, close background apps or upgrade your memory.

## How it works

- All data comes from built-in Windows performance counters via CIM/WMI (`Win32_PerfFormattedData_*`), which are language-independent, so the tool works on any Windows display language.
- CPU throttling is detected from `% Processor Performance` — no third-party driver needed.
- CPU temperature uses `MSAcpi_ThermalZoneTemperature`; many motherboards don't expose it, in which case LagScope relies on throttling detection.
- GPU temperature/VRAM come from `nvidia-smi` when present.
- The overlay uses `WS_EX_TRANSPARENT` so mouse clicks pass straight through to your game.

## Limitations

- CPU temperature is unavailable on many systems (see above).
- GPU temperature and VRAM are NVIDIA-only for now; AMD/Intel show load only.
- Thresholds are fixed in the script — edit `Get-Diagnosis` in `LagScope.ps1` to tune them.

## License

[MIT](LICENSE)
