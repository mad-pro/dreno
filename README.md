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
- **Optional AI layer** with your own API key (any provider that exposes a chat completions API with tool calling):
  - **Explanations**: every process in the report gets a description written by the model, grounded on the built-in knowledge base and the local metadata. Cached locally.
  - **Investigator**: for any process, Dreno collects local evidence (running instances, launchd job, network connections, folders in use, app bundle contents), lets the model dig deeper with read-only tools (other processes, launchd plists, recent logs) and returns a diagnosis with recommended actions picked from a fixed list the app knows how to run: quit the app, terminate its processes, stop or disable a launchd agent, open the right System Settings pane.
  - **Assistant**: ask in plain language ("why isn't my Mac sleeping?", "quit what is running non-stop and is not part of macOS"). It can run shell commands: read-only commands run right away, anything that changes the system waits for your approval, `sudo` goes through the macOS password prompt, and destructive commands are always blocked.
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

What is sent to the provider:

- **Explanations**: process name, executable path with your home folder replaced by `~`, code signature and launchd label. Command lines are not sent. Answers are cached in `~/Library/Application Support/Dreno/ai-cache.json`.
- **Investigator and assistant**: also command lines, network endpoints, folders in use, recent logs and command outputs of the process being inspected. E-mails, tokens, passwords and URL query strings are masked first.

Safety rules for the investigator and the assistant:

- The model never executes anything by itself. The investigator can only recommend actions computed locally by the app, and each one runs after a click.
- In the assistant, only simple read-only commands run automatically (`ps`, `lsof`, `launchctl print/list`, `pmset -g`, `log show`, `top -l` and similar, with pipes to filters like `grep` or `head`). Anything else shows the exact command and waits for **Executar** or **Recusar**.
- Commands that could wreck the system are blocked no matter what: wiping `/` or the home folder, erasing disks, disabling SIP or Gatekeeper, stopping `com.apple` services or essential processes, piping downloads into a shell, shutting down.

Web search is off by default. If your provider supports a `web_search` tool, set `AI_WEB_SEARCH=1` in the `.env`.

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
$DRENO --investigate mds_stores                         # run the investigator on the latest session
$DRENO --ask "why isn't my Mac sleeping?"               # assistant (commands that change things are denied in the terminal)
$DRENO --policy "kill 123" "ps aux | head"              # show how commands would be classified
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
  Agent/     investigator, assistant, local read-only tools, actions, command policy
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
