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

## Installation

No installer, no dependencies. LagScope is plain PowerShell that ships with Windows.

1. **Download** — on this page click the green **Code** button → **Download ZIP**
   (or grab the ZIP from the [Releases](../../releases) page).
2. **Unblock the ZIP — do this *before* extracting!**
   Windows marks every file downloaded from the internet. Unsigned scripts with that mark are blocked by
   *Smart App Control* / SmartScreen ("This app was blocked" / "Windows protected your PC").
   - Right-click the downloaded `LagScope-main.zip` → **Properties**
   - At the bottom, next to *"This file came from another computer…"*, tick **Unblock**
   - Click **Apply** → **OK**
3. **Extract** — right-click the ZIP → **Extract All…** → **Extract**.
   Put the folder somewhere permanent, e.g. `Documents\LagScope`. Keep all files in the same folder.
4. **Run** — double-click **`START_LAGSCOPE.bat`**.
   - *"Do you want to allow this app to make changes?"* → **Yes** (admin rights are only used to read the CPU temperature sensor).
   - If SmartScreen still appears: **More info** → **Run anyway**.
   - A small black bar appears at the bottom of your screen — LagScope is running.

> **Already extracted without unblocking?** Delete the folder and start again from step 2,
> or unblock all files at once in PowerShell:
> ```powershell
> Get-ChildItem "C:\path\to\LagScope" -Recurse | Unblock-File
> ```

## Usage

1. Start **`START_LAGSCOPE.bat`** *before* launching your game.
2. Play. The overlay shows live values and the current lag cause; a Windows notification pops up when your PC struggles.
3. When you're done: right-click the **(i)** tray icon next to the clock → **Exit (show report)**.
4. Read the verdict. All reports and logs are saved in the `Logs` folder next to the scripts.

> The overlay is not visible in *exclusive fullscreen*. Use **borderless** or **windowed fullscreen**. Measurements and the report work either way.

### Tray menu

| Item | Action |
|---|---|
| Show report now | Report for the session so far, without stopping |
| Hide / show overlay | Toggle the bar |
| Open logs folder | Opens `Logs\` in Explorer |
| Exit (show report) | Stops monitoring and shows the final report |

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

## Troubleshooting

| Problem | Fix |
|---|---|
| *"Smart App Control blocked this app"* / *"Windows protected your PC"* | The files still carry the internet mark. Unblock the ZIP before extracting (see [Installation](#installation), step 2) or run `Get-ChildItem <folder> -Recurse \| Unblock-File`. |
| Windows asks *"How do you want to open this file?"* (Notepad, etc.) | You double-clicked a `.ps1` file. Close the dialog and double-click the **`.bat`** file instead (type: *Windows Batch File*). |
| Nothing visible after starting | Check the tray (click **^** next to the clock) for the (i) icon. If your game runs in exclusive fullscreen, switch to borderless. |
| Two (i) icons in the tray | You started it twice. Right-click one → **Exit**. |
| `CPU --C` is shown | Your motherboard doesn't expose the temperature through Windows. Heat problems are still detected via CPU throttling (`CLK` value). |
| `GPU --C` / no VRAM value | Only NVIDIA GPUs report temperature/VRAM (via `nvidia-smi`). Load % works on all GPUs. |
| Script window closes immediately | Right-click the `.bat` → **Run as administrator**, or open PowerShell and run `powershell -ExecutionPolicy Bypass -File .\LagScope.ps1` to see the error. |

## Uninstall

Close LagScope from the tray, then delete the folder. Nothing is installed, no registry keys, no services.

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
