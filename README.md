<img src="docs/img/icon.png" width="128" alt="Maclator icon: a rosette ringed by a counter-clockwise arrow">

# Maclator

**Run arm64 macOS apps on an Intel Mac.** Maclator is a "reverse Rosetta": it loads an arm64 Mach-O
together with the real arm64 macOS userland (dyld and the arm64e dyld shared cache, taken from an Apple
Silicon macOS image that *you* download) and executes the arm64 code with an interpreter plus an x86-64
JIT. System calls and Mach traps go to the Intel host kernel where the semantics match and are emulated
where they don't. Metal calls can be bridged to the Intel Mac's real GPU.

The motivation: Apple dropped Intel Macs, and apps built for newer macOS versions will eventually be
arm64-only. This project explores how far you can get anyway.

> **Status: experimental research project.** Things that run today are listed below; many apps will not.
> Expect rough edges. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for what is missing.

## About this fork

A fork of [linuxkid473/maclator](https://github.com/linuxkid473/maclator) with, on top:

- emulator fixes that get Homebrew, Microsoft Office, Pages/Numbers/Keynote, Final Cut Pro, Chrome and the
  arm64-only ChatGPT app running: `--arm64-children`, the guest's own entitlements, cooperative thread suspension,
  fork-safe locks, `sysctl` by MIB, root-patched hosts, ARMv8 crypto features
  ([DEVELOPMENT](docs/DEVELOPMENT.md#key-bugs-found--fixed-so-you-recognise-symptoms) lists them with symptoms);
- **Homebrew** on Intel Macs (`scripts/brew`, [USAGE](docs/USAGE.md#homebrew));
- **Maclator.app**, a launcher (`app/`): a library of arm64 apps (found on all volumes, or added by hand), launch
  options, and a live view of everything running under Maclator with output, CPU and memory;
- per-process logs of the guest's stdout/stderr in `~/Library/Logs/Maclator/<pid>.log`;
- the compatibility list below.

## What runs

"Works" means the program starts and opens its window (or, for command-line tools, does its job); features beyond
that are noted where they were checked. Times are to the first window on a **first launch** with an empty translation
cache; later launches are faster. Machine-readable list, also shown in the launcher app:
[docs/compatibility.json](docs/compatibility.json).

Tested on two Intel Macs: **A** = Core i5-4440 + AMD Radeon RX 460, macOS 26.7; **B** = Core i5-10310U (MacBook Pro
13" 2020), Intel UHD, macOS 26.6, OpenCore Legacy Patcher root patches.

### arm64-only programs (there is no Intel build)

| Program | Kind | Mac | Result | Conditions |
|---|---|---|---|---|
| ChatGPT desktop 26.928 (`com.openai.codex`) | Chromium 154 | B | works (2 min) | `--no-sandbox` [C]; host icon service healthy [H] |
| VS Code 1.139 (darwin-arm64) | Electron | A | works; typing latency ~40 ms | `--no-sandbox` [C]; `scripts/vscode-gpu` for GPU |
| Chromium 157 snapshot | Chromium | A | works, **GPU accelerated** (ANGLE/Metal → RX 460, 60 fps canvas) | `--no-sandbox` [C]; `--gpu --gpu-only --type=gpu-process` ([GPU](docs/GPU.md)) |
| balenaEtcher 2.1.7 | Electron | A | starts; device access untested | `--no-sandbox` [C] |
| Homebrew 7.0.7 (Apple Silicon only since macOS 26) | bash + Ruby 4.0.7 | B | works: official installer, `brew install`, arm64 bottles | `--arm64-children`; see [Homebrew](docs/USAGE.md#homebrew) |
| Homebrew bottles: `hello`, `fastfetch`, `yyjson` | C | B | work | through `~/bin/brew` and its shims |
| `fastfetch`, `neatvi` | C | A | work | none |
| AppKit calculator (`tests/guest/calc`) | AppKit | A | works | none |

### Universal apps (their arm64 half, run under Maclator)

| Program | Kind | Mac | Result | Conditions |
|---|---|---|---|---|
| Microsoft Word, Excel, PowerPoint 16.113 | AppKit, sandboxed | B | work (15–26 s); documents not checked | [S] |
| Microsoft OneNote 16.113 | AppKit + JavaScriptCore, sandboxed | B | works (19 s) | [S]; thread suspension [T] |
| Pages, Numbers, Keynote 15.3 | Swift, sandboxed, App Store | B | work (15–20 s); iCloud not checked; busy CPU while idle | [S]; own entitlements [E] |
| Final Cut Pro 12.3 | Swift, sandboxed, App Store | B | works (87 s); editing not checked | [S]; [H] |
| Pixelmator Pro 3.6 | Swift, sandboxed, App Store | B | works; relaunches itself at start | [S] |
| Windows App 11.4 | Swift, sandboxed, App Store | B | works (11 s); remote sessions not checked | [S] |
| Google Chrome 154 | Chromium | B | works (29 s) | `--no-sandbox` [C] |
| Termius 10.1 | Electron | B | works (2.5 min) | `--no-sandbox` [C] |
| HandBrake 1.11 | AppKit, sandboxed | B | works (36 s); encoding not checked | [S] |
| Hidden Bar 1.8 | Swift, sandboxed, App Store | B | works (8 s) | [S] |
| AppCleaner 3.6.8 | AppKit | B | works (40 s) | none |
| foobar2000 2.25 | C++/AppKit | B | works (15 s) | none |
| VLC 3.0.24 | AppKit | B | works (10 s); playback not checked (no audio yet) | none |
| coconutBattery 4.4 | Swift | B | works (26 s); readings not checked | none |
| FluxMarkdown 1.34 | Swift | B | works (8 s) | none |
| Mos 4.2 | Swift | B | works (12 s); scroll smoothing not checked | needs Accessibility permission for its feature |
| RDM 2.5, OneDrive | menu bar | B | start and keep running; menus not checked | none |
| Ghostty 1.3.1 | Swift + Zig, Metal | B | opens a window; whether the terminal draws is unconfirmed | `CAMetalLayer` is not bridged yet; CPU feature report [F] |

**Conditions**

- **[C] Chromium/Electron**: run with `--no-sandbox` (the Chromium sandbox cannot initialise under Maclator). The
  launcher app adds it for any Chromium-based app; from a terminal, pass it after the program path.
- **[S] Sandboxed apps** start *without* their sandbox: the host only knows `maclator`'s signature. They run, but
  keep their data in your home folder rather than in a container.
- **[E] Own entitlements**: frameworks such as CloudKit check the process's entitlements and trap without them;
  Maclator answers the guest's own `csops` queries from the app's signature (`codesign.rs`).
- **[T] Thread suspension**: JavaScriptCore's garbage collector (and anything with a web view) suspends threads and
  reads their registers; Maclator emulates this cooperatively (`suspend.rs`).
- **[F] CPU features**: guests are told about AES/PMULL/SHA1/SHA256, which Maclator implements and software built
  for Apple Silicon may require.
- **[H] Host health**: apps wait for the icon service (`iconservicesagent`) at start. On Mac B, OpenCore Legacy
  Patcher left the system volume with a broken seal, and *native* x86 processes using VideoToolbox (icon service,
  Safari, `mediaanalysisd`) crash with `FS pagein error: 94 Bad message`; while that happens, apps under Maclator
  hang before their first window. A restart (and if needed re-applying the root patches) clears it.

Not done: audio, most IOKit hardware, `CAMetalLayer`-based apps (the GPU bridge covers Metal used by Chromium/ANGLE,
not apps that present through a Metal layer directly), FairPlay-encrypted iOS apps.

![chrome://gpu in the arm64 Chromium 157 snapshot running under Maclator on an Intel Mac Pro: canvas, compositing, rasterization, WebGL and WebGPU hardware accelerated on an AMD Radeon RX 460 via ANGLE/Metal](docs/img/chromium-gpu.png)

*The arm64 Chromium 157 snapshot running under Maclator on an Intel Mac (`chrome://gpu`): compositing, rasterization, WebGL and WebGPU are hardware accelerated on the machine's AMD Radeon RX 460, through the ANGLE/Metal bridge.*

## Quick start

You need an Intel Mac on macOS 26 (Tahoe) with Xcode Command Line Tools and a Rust toolchain, about 10 GB of
free disk, and an internet connection for the one-time download of the arm64 dyld shared cache.

```bash
git clone https://github.com/pointlessduffin-21/maclator-fork maclator && cd maclator
scripts/install.sh            # builds maclator + the GPU bridge, installs to ~/bin
scripts/fetch-sysroot.sh      # downloads the arm64e dyld shared cache (≈5.5 GB) into ~/maclator-sysroot
maclator ./some-arm64-binary  # that's it; the sysroot is found automatically
```

Details, alternatives and requirements: **[docs/SETUP.md](docs/SETUP.md)**.

Prefer clicking? `app/build.sh --install` builds **Maclator.app** into `/Applications`: a launcher that lists the
arm64 apps on all your volumes, runs them through `maclator`, shows their output and notes which ones open a window.
Running Chromium, VS Code and other apps: **[docs/USAGE.md](docs/USAGE.md)**.

## Documentation

| | |
|---|---|
| [docs/SETUP.md](docs/SETUP.md) | requirements, building, getting the arm64 userland, installing the GPU bridge |
| [docs/USAGE.md](docs/USAGE.md) | command-line flags, launching Chromium / VS Code / Etcher, tips |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | symptoms and fixes |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | loader, dyld/shared cache handling, syscall emulation, JIT, AOT cache |
| [docs/GPU.md](docs/GPU.md) | the Metal → host GPU bridge: design, protocol, profiling, pitfalls |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | measurements, JIT optimisations, Chromium configuration |
| [docs/DEBUGGING.md](docs/DEBUGGING.md) | flags, signals, JIT differential self-tests |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | open problems, bug list, history |
| [bench/](bench/README.md) | benchmark and test drivers |
| [app/](app/) | Maclator.app, the SwiftUI launcher (Paper design) |

## Legal

Maclator contains **no Apple binaries**. The arm64 userland is downloaded by you from Apple's own update
servers (via [`ipsw`](https://github.com/blacktop/ipsw)) and stays on your machine. You are responsible for
complying with Apple's software license terms for whatever you download and run, and with the licenses of the
apps you run. `ref/` holds excerpts of Apple open-source code (APSL 2.0 / Apache 2.0) used as reference, with
their license headers intact. See [NOTICE](NOTICE). Maclator does not attempt to run, or to circumvent
protection of, FairPlay/DRM-encrypted binaries.

MIT licensed, see [LICENSE](LICENSE).
