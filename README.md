# LagScope

**One small tray app that finds out *why* your Windows PC stutters while gaming and frees it up for the game.**

Start it once. It sits next to the clock and does everything automatically:

| | What it does |
|---|---|
| 🎮 **Game Mode** | When a game starts: closes background apps you don't need, stops developer tools (Docker, WSL, dev servers, local AI servers), gently trims RAM held by big background programs, purges the standby cache and switches to the High performance power plan. **Everything is restored when the game closes.** |
| 🧹 **Auto RAM cleaner** | While you play, purges the Windows standby list whenever free RAM gets low (the ISLC trick) to prevent micro-stutters. |
| 📊 **Monitor** | Overlay with CPU, busiest core, CPU clock, RAM, GPU, temperatures and disk, plus the **live lag cause**: not enough RAM, overheating/throttling, CPU bottleneck or slow disk. |
| 📝 **Report** | After every game: *"Main problem: …"* with concrete advice. |

```
CPU  43%  CORE100%  CLK 129%  CPU  --C  RAM  91%  GPU  45%  GPU 67C  DISK  2%
LAG CAUSE: RAM RUNNING OUT (91%, 1545 MB free) - top user: TslGame 5537 MB
```

No installer, no dependencies, just Windows PowerShell.

## Installation

1. **Download**: click the green **Code** button → **Download ZIP**.
2. **Unblock the ZIP *before* extracting**: right-click the ZIP → **Properties** → tick **Unblock** → **OK**.
   Otherwise *Smart App Control* / SmartScreen blocks the scripts.
3. **Extract**: right-click → **Extract All…**. Put the folder somewhere permanent (e.g. `Documents\LagScope`).
4. Double-click **`LagScope.bat`** → admin prompt → **Yes**. A shield icon appears next to the clock.
5. Optional: right-click the shield → **Start with Windows**. LagScope then starts with admin rights at every login, with no prompt.

> Already extracted without unblocking? Run in PowerShell: `Get-ChildItem "C:\path\to\LagScope" -Recurse | Unblock-File`

## Usage

Just play. Right-click the shield icon for everything else:

| Menu item | |
|---|---|
| Game Mode | Free the PC when a game starts (on/off) |
| Auto RAM cleaner while gaming | on/off |
| Stop dev tools in games | Docker, WSL, Expo/Next.js/Vite dev servers, llama-server, Ollama (on/off) |
| Overlay | *Only while gaming* (default), *Always*, *Off* |
| Boost now / Clean RAM now | Manual actions |
| Show last report | Report of the current or last game |
| Open logs folder / Edit settings | |
| Start with Windows | Autostart via a scheduled task (no UAC prompt) |
| Exit | Restores everything and quits |

> The overlay is hidden in *exclusive fullscreen*. Use **borderless** / **windowed fullscreen**. Measuring and reports work either way.

## Settings: `LagScope.config.json`

Tray switches are saved here automatically. Other useful keys:

| Key | Default | Meaning |
|---|---|---|
| `closeApps` | Spotify, BlueStacks, OneDrive, Teams, Phone Link, Widgets | Closed when a game starts, reopened afterwards. Add e.g. `"chrome"` |
| `neverTouch` | Discord, Steam, Epic, Battle.net, Riot, NVIDIA, Razer, Logitech, OBS, anti-cheat… | Never closed and never trimmed |
| `games` | popular titles | Extra process names to treat as games (others are auto-detected from game library folders) |
| `notGames` | launchers, crash handlers, anti-cheat | Never treated as the game |
| `trimMinProcessMB` | `150` | Only background programs larger than this are trimmed |
| `ramCleanerMinFreeMB` | `2048` | Auto RAM cleaner threshold |
| `setGameHighPriority` | `false` | Raise the game to *AboveNormal*. Off by default because higher priority can **cause** stutter (it starves audio, input and anti-cheat) |
| `highPerformancePowerPlan` | `true` | Switch power plan while gaming |
| `stopServices` | `[]` | Services to stop while gaming, e.g. `"SysMain"` |
| `devServerPatterns`, `devProcesses`, `shutdownWsl` | | What *Stop dev tools* stops |

> ⚠️ Apps in `closeApps` are force-closed. Don't add programs where you might have unsaved work.

## Output (`Logs/` folder)

| File | Content |
|---|---|
| `REPORT_*.txt` | Verdict for each game session |
| `Stutters_*.log` | Every moment the PC struggled, with the cause |
| `Samples_*.csv` | All measurements (`;`-separated, opens in Excel) |
| `LagScope.log` | What Game Mode did (apps closed, RAM freed, …) |

## Troubleshooting

| Problem | Fix |
|---|---|
| *"Smart App Control blocked this app"* | Unblock the ZIP before extracting (Installation step 2). |
| Windows asks *"How do you want to open this file?"* | You clicked the `.ps1`. Double-click **`LagScope.bat`**. |
| *"LagScope is already running"* | It's in the tray. Click **^** next to the clock. |
| My game isn't detected | Add its process name (Task Manager → Details) to `games`. |
| Something I need gets closed | Remove it from `closeApps` or add it to `neverTouch`. |
| `CPU --C` | Your motherboard doesn't expose the CPU temperature. Heat is still detected via throttling (`CLK`). |
| `GPU --C` | GPU temperature/VRAM need an NVIDIA GPU (`nvidia-smi`). |

## How it works

- Measurements come from built-in Windows performance counters (CIM/WMI) and work in any Windows language.
- CPU throttling is detected from `% Processor Performance`, with no extra driver needed.
- RAM: `EmptyWorkingSet` for big background processes and `NtSetSystemInformation` to purge the standby list.
- Games are detected by name or by running from a game library folder (`steamapps\common`, `Epic Games`, …).
- The overlay is click-through (`WS_EX_TRANSPARENT`).
- Only one instance can run at a time.

## Uninstall

Right-click the shield → turn off **Start with Windows** → **Exit**, then delete the folder.

## License

[MIT](LICENSE)
