# Dreno

**Find out what is really draining your Mac's battery.**

Dreno is a small native macOS menu bar app. It records how every process uses CPU, energy, GPU and memory over a period of time, then shows which ones kept working for long stretches (the real battery drains), which ones only spiked (normal), and what each of them actually is, with practical advice on whether and how to stop it.

It is not an Activity Monitor clone. Activity Monitor shows the current moment. Dreno records sessions you can come back to, filter and export.

> The interface and the built-in process descriptions are in Brazilian Portuguese for now.

## Features

- **Recording sessions**, started by hand or automatically whenever the Mac is unplugged.
- **Every process**, including system daemons, without admin rights.
- **Sustained vs. spikes**: separates processes that stay busy for minutes from the ones that only peak for a moment.
- **Energy**: measured by macOS for your own processes, estimated from CPU time for system ones, plus the total system power in watts read from the battery telemetry.
- **GPU time** per process.
- **Sleep blockers**: which apps kept the Mac awake or the display on (for example an app holding the microphone open).
- **App grouping**: helper processes are grouped under their app (browsers, Electron apps, WebKit content processes under the app that owns them).
- **Process explanations**: a built-in knowledge base with about 150 macOS daemons and common apps, plus metadata for everything else (owning app, code signature and developer, launchd job, man page summary).
- **Optional AI explanations** for processes that are not in the knowledge base, using your own API key with any provider that exposes a chat completions API. Answers are cached locally.
- **Time filters**: battery-only samples, or any range selected on the timeline.
- **Actions**: quit apps and processes you own, show them in Finder, copy the `launchctl` command that stops a background agent.
- **HTML export**: a self-contained report you can keep, share or print to PDF.
- **Low overhead**: around 0.5% of one CPU core at the default 10 second interval. The report shows Dreno's own cost.

## How it measures

| What | Source |
|------|--------|
| CPU time per process | `/bin/ps` (setuid, sees all processes), cumulative CPU time diffed every sample |
| Energy per process | `proc_pid_rusage` (`ri_energy_nj`) for the current user's processes. System processes are estimated with the joules per CPU second measured in the same session |
| Memory | physical footprint (`ri_phys_footprint`), or RSS for other users' processes |
| GPU | `accumulatedGPUTime` of the IOAccelerator user clients |
| System power (W) | `AppleSmartBattery` > `PowerTelemetryData.SystemLoad` |
| Sleep blockers | `IOPMCopyAssertionsByProcess` |
| Whole machine CPU | `host_statistics` |

How processes are classified:

- **Uso contínuo (sustained)**: above 2% of one core in consecutive samples for at least one minute, with most of its CPU coming from those stretches.
- **Frequente (frequent)**: active in at least 20% of the samples.
- **Só picos (spikes)**: short bursts. Normal.
- CPU that cannot be attributed to a sampled process (kernel_task and programs that start and exit between two samples) is reported as *Kernel e processos de vida curta*.

## Requirements

- macOS 15 or later on Apple Silicon.
- Swift 6 toolchain (Xcode or the Command Line Tools).

## Build and install

```sh
git clone https://github.com/mad-pro/dreno.git
cd dreno
./scripts/build-app.sh          # builds a release Dreno.app and installs it to ~/Applications
open ~/Applications/Dreno.app
```

Dreno lives in the menu bar (drop icon). The first launch also opens the reports window.

To regenerate the icon: `swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns`.

## Usage

1. Click the menu bar icon and choose **Começar a gravar**, or leave **Gravar sozinho quando sair da tomada** on.
2. Use the Mac normally.
3. Click **Parar e ver relatório**. Past sessions stay in the reports window.

## AI explanations (optional)

Open **Ajustes** in the reports window and fill in the API base URL, the model and your API key, then press **Testar**. A `.env` file works too (see `.env.example`).

What is sent to the provider: process name, executable path with your home folder replaced by `~`, code signature, launchd label and the measured numbers. Command lines are never sent. Answers are cached in `~/Library/Application Support/Dreno/ai-cache.json`.

## Your own descriptions

Add entries to `~/Library/Application Support/Dreno/processes.json` using the same format as `Resources/processes.json`. They take precedence over the built-in ones.

## Command line

The app binary also works as a command line tool:

```sh
DRENO=~/Applications/Dreno.app/Contents/MacOS/Dreno
$DRENO --selftest 60 --interval 5 --html report.html   # record 60 s into a temporary database
$DRENO --list                                           # saved sessions
$DRENO --report 3 --bateria --html report.html          # report of session 3, battery samples only
$DRENO --explain mds_stores                             # explanation of a running process
$DRENO --ai-test                                        # check the AI configuration
```

## Data and privacy

Everything stays on your Mac in `~/Library/Application Support/Dreno/` (SQLite). There is no telemetry. The network is only used if you configure AI explanations.

## Project layout

```
Sources/Dreno/
  Collect/   sampling: ps, libproc, IOKit (GPU, battery, sleep assertions)
  Store/     SQLite storage
  Analyze/   per app and per process metrics, sustained vs. spike classification
  Explain/   knowledge base, code signature, launchd, man pages, AI explanations
  Report/    HTML and text reports
  UI/        SwiftUI menu bar and reports window
Resources/   processes.json (knowledge base), Info.plist, icon
scripts/     build and icon scripts
```

## Limitations

- Energy for system processes is an estimate based on CPU time.
- Processes that start and exit between two samples are not tracked one by one.
- Display power is part of the Mac total but cannot be attributed to a specific app.

## License

MIT
