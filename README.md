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

## What runs

"Works" means the app starts and opens its window; app features beyond that are noted where they were checked.
Machine-readable list (also shown in the launcher app): [docs/compatibility.json](docs/compatibility.json).

**Intel Core i5-4440, macOS 26.7**

| Program | Kind | Status |
|---|---|---|
| `fastfetch`, `neatvi` (arm64 CLI tools) | C | works |
| a small AppKit calculator (`tests/guest/calc`) | AppKit | works |
| VS Code 1.139 arm64 | Electron | works; typing latency ~40 ms |
| Chromium 157 arm64 snapshot | Chromium | works, including **GPU acceleration** (ANGLE/Metal → host AMD GPU, 60 fps canvas) |
| balenaEtcher 2.1.7 arm64 | Electron | starts (device access untested) |

**Intel Core i5-10310U, macOS 26.6** (arm64 half of universal apps; first launch, empty translation cache; time to
the first window in brackets)

| Program | Kind | Status |
|---|---|---|
| Homebrew 7.0.7 (`/opt/homebrew`, see [USAGE](docs/USAGE.md#homebrew)) | bash + Ruby | works: installer, `brew install`, arm64 bottles (`hello`, `fastfetch`) |
| Microsoft Word, Excel, PowerPoint, OneNote 16.113 | AppKit, sandboxed | works (15–26 s); documents not checked |
| Pages, Numbers, Keynote 15.3 | Swift, sandboxed | works (15–20 s); iCloud not checked; busy CPU while idle |
| Google Chrome 154 | Chromium | works (29 s), with `--no-sandbox` |
| Pixelmator Pro 3.6 | Swift, sandboxed | works (relaunches itself at start) |
| Windows App 11.4 | Swift, sandboxed | works (11 s); remote sessions not checked |
| AppCleaner 3.6.8 | AppKit | works (40 s) |
| foobar2000 2.25 | C++/AppKit | works (15 s) |
| coconutBattery 4.4 | Swift | works (26 s) |
| FluxMarkdown 1.34 | Swift | works (8 s) |
| Mos 4.2 | Swift | works (12 s); scrolling not checked |
| Hidden Bar 1.8 | Swift, sandboxed | works (8 s) |
| HandBrake 1.11 | AppKit, sandboxed | works (36 s); encoding not checked |
| Termius 10.1 | Electron | works (2.5 min) |
| RDM 2.5, OneDrive | menu bar | start and keep running; menus not checked |
| VLC 3.0.24 | AppKit | works (10 s); playback not checked |
| Final Cut Pro 12.3 | Swift, sandboxed | works (87 s); editing not checked |
| Ghostty 1.3.1 | Swift + Zig, Metal | opens a window; terminal drawing unconfirmed (`CAMetalLayer` is not bridged yet) |
| ChatGPT (arm64 only, no Intel build) | Chromium | works (2 min), with `--no-sandbox` |

Not done: audio, most IOKit hardware, `CAMetalLayer`-based apps. Sandboxed apps start without their sandbox (the
host does not apply the guest's entitlements); some may refuse to run that way.

![chrome://gpu in the arm64 Chromium 157 snapshot running under Maclator on an Intel Mac Pro: canvas, compositing, rasterization, WebGL and WebGPU hardware accelerated on an AMD Radeon RX 460 via ANGLE/Metal](docs/img/chromium-gpu.png)

*The arm64 Chromium 157 snapshot running under Maclator on an Intel Mac (`chrome://gpu`): compositing, rasterization, WebGL and WebGPU are hardware accelerated on the machine's AMD Radeon RX 460, through the ANGLE/Metal bridge.*

## Quick start

You need an Intel Mac on macOS 26 (Tahoe) with Xcode Command Line Tools and a Rust toolchain, about 10 GB of
free disk, and an internet connection for the one-time download of the arm64 dyld shared cache.

```bash
git clone https://github.com/linuxkid473/maclator && cd maclator
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
