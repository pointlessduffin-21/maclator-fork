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

Maclator was created by **Vihaan Nathan ([@linuxkid473](https://github.com/linuxkid473))**:
[linuxkid473/maclator](https://github.com/linuxkid473/maclator) is the original project. This repository is a fork
by [@pointlessduffin-21](https://github.com/pointlessduffin-21) with the additions listed below.

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
[docs/compatibility.json](docs/compatibility.json); readable version: [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

Tested on two Intel machines:

- **A**: Core i5-4440 (4 cores) with an AMD Radeon RX 460, macOS 26.7 (upstream's test machine).
- **B**: an **HP EliteBook 840 G7 running macOS as a Hackintosh**: Core i5-10310U (4 cores / 8 threads, Comet Lake),
  16 GB, Intel UHD 620 (spoofed as `0x3E9B`), SMBIOS `MacBookPro16,2`, so About This Mac calls it a "MacBook Pro
  13-inch, 2020". macOS Tahoe 26.6 (25G72) boots with OpenCore 1.0.8; the OCLP-X post-install root patch restores
  Wi-Fi (Ventura `IO80211` stack) and audio, which breaks the system volume's seal. EFI, kexts and notes:
  [HP-Elitebook-840-G7-Tahoe-EFI](https://github.com/pointlessduffin-21/HP-Elitebook-840-G7-Tahoe-EFI).

### arm64-only programs (there is no Intel build)

| Program | Kind | Mac | Result | Conditions |
|---|---|---|---|---|
| ChatGPT desktop 26.928 (`com.openai.codex`) | Chromium 154 | B | works (2 min) | `--no-sandbox` [C]; host icon service healthy [H] |
| VS Code 1.139 (darwin-arm64) | Electron | A | works; typing latency ~40 ms | `--no-sandbox` [C]; `scripts/vscode-gpu` for GPU |
| Chromium 157 snapshot | Chromium | A | works, **GPU accelerated** (ANGLE/Metal → RX 460, 60 fps canvas) | `--no-sandbox` [C]; `--gpu --gpu-only --type=gpu-process` ([GPU](docs/GPU.md)) |
| Pixelmator Pro 4.0 (`com.apple.pixelmator`) | Swift | B | partial: opens a window (44 s), then quits with an error | cause not investigated |
| balenaEtcher 2.1.7 | Electron | A | starts; device access untested | `--no-sandbox` [C] |
| Homebrew 7.0.7 (Apple Silicon only since macOS 26) | bash + Ruby 4.0.7 | B | works: official installer, `brew install`, arm64 bottles | `--arm64-children`; see [Homebrew](docs/USAGE.md#homebrew) |
| Homebrew bottles: `hello`, `fastfetch`, `yyjson` | C | B | work | through `~/bin/brew` and its shims |
| `fastfetch`, `neatvi` | C | A | work | none |
| AppKit calculator (`tests/guest/calc`) | AppKit | A | works | none |

![The arm64-only ChatGPT desktop app answering a prompt on an Intel machine (an HP EliteBook 840 G7 Hackintosh that About This Mac reports as a MacBook Pro 13-inch 2020 with an Intel Core i5 and Intel graphics, macOS Tahoe 26.6), with the Maclator launcher showing the run](docs/img/chatgpt-arm64.png)

*The arm64-only ChatGPT app running under Maclator on machine B, an HP EliteBook 840 G7 Hackintosh (i5-10310U, Intel UHD 620, macOS 26.6; About This Mac shows its `MacBookPro16,2` SMBIOS), with the launcher showing the run. Serial number redacted.*

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
- **[H] Host health**: apps wait for the icon service (`iconservicesagent`) at start. On machine B, the OCLP-X root
  patch left the system volume with a broken seal, and *native* x86 processes using VideoToolbox (icon service,
  Safari, `mediaanalysisd`) crash with `FS pagein error: 94 Bad message`; while that happens, apps under Maclator
  hang before their first window. A restart (and if needed re-applying the root patches) clears it.

Not done: audio, most IOKit hardware, `CAMetalLayer`-based apps (the GPU bridge covers Metal used by Chromium/ANGLE,
not apps that present through a Metal layer directly), FairPlay-encrypted iOS apps.

![chrome://gpu in the arm64 Chromium 157 snapshot running under Maclator on an Intel Mac Pro: canvas, compositing, rasterization, WebGL and WebGPU hardware accelerated on an AMD Radeon RX 460 via ANGLE/Metal](docs/img/chromium-gpu.png)

*The arm64 Chromium 157 snapshot running under Maclator on an Intel Mac (`chrome://gpu`): compositing, rasterization, WebGL and WebGPU are hardware accelerated on the machine's AMD Radeon RX 460, through the ANGLE/Metal bridge.*

## Speed: the main complaint

On a laptop like machine B, everything works noticeably slower than native, and the **first launch** of an app is
the worst of it. Maclator translates arm64 code as it runs, so the first time takes the longest to reach a window:

| App | First window, first launch |
|---|---|
| ChatGPT (Chromium, 15 processes) | ~2 min |
| Termius (Electron) | ~2.5 min |
| Final Cut Pro | ~1.5 min |
| Small AppKit/Swift apps | 8–40 s |

Translations are cached on disk (`~/Library/Caches/Maclator/aot`) when an app **quits normally**, which makes later
launches faster, but each Chromium helper process still translates on its own, and a force-quit app saves nothing.
Moving from mostly just-in-time translation to real **ahead-of-time** translation (translate an app, its libraries
and the arm64 shared cache once, before they run, the way Rosetta 2 does on Apple Silicon) is the next big step; the
study of how to get there is in [docs/AOT-STUDY.md](docs/AOT-STUDY.md).

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
| [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) | every app tried, with result, time to first window and notes (generated by `scripts/compat.py`) |
| [docs/GPU.md](docs/GPU.md) | the Metal → host GPU bridge: design, protocol, profiling, pitfalls |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | measurements, JIT optimisations, Chromium configuration |
| [docs/DEBUGGING.md](docs/DEBUGGING.md) | flags, signals, JIT differential self-tests |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | open problems, bug list, history |
| [bench/](bench/README.md) | benchmark and test drivers |
| [app/](app/) | Maclator.app, the SwiftUI launcher (Paper design) |

## Credits

- **Vihaan Nathan ([@linuxkid473](https://github.com/linuxkid473))** created Maclator: the loader, interpreter, JIT,
  translation cache, syscall emulation and GPU bridge ([linuxkid473/maclator](https://github.com/linuxkid473/maclator)).
- **[@pointlessduffin-21](https://github.com/pointlessduffin-21)**: this fork's fixes, Homebrew support, Maclator.app
  and the compatibility testing, done on the [HP EliteBook 840 G7 Hackintosh]({EFI}).
- [`ipsw`](https://github.com/blacktop/ipsw) by blacktop fetches the arm64 userland; iced-x86 and yaxpeax-arm do the
  x86 encoding and arm64 decoding.

## Legal

Maclator contains **no Apple binaries**. The arm64 userland is downloaded by you from Apple's own update
servers (via [`ipsw`](https://github.com/blacktop/ipsw)) and stays on your machine. You are responsible for
complying with Apple's software license terms for whatever you download and run, and with the licenses of the
apps you run. `ref/` holds excerpts of Apple open-source code (APSL 2.0 / Apache 2.0) used as reference, with
their license headers intact. See [NOTICE](NOTICE). Maclator does not attempt to run, or to circumvent
protection of, FairPlay/DRM-encrypted binaries.

MIT licensed, see [LICENSE](LICENSE).
