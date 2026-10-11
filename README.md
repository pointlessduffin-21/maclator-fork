<img src="docs/img/icon.png" width="128" alt="Maclator icon: a rosette ringed by a counter-clockwise arrow">

# Maclator

**Run arm64 macOS apps on an Intel Mac.** Maclator is a "reverse Rosetta": it loads an arm64 Mach-O
together with the real arm64 macOS userland (dyld and the arm64e dyld shared cache, taken from an Apple
Silicon macOS image that *you* download) and executes the arm64 code with an interpreter plus an x86-64
JIT. System calls and Mach traps go to the Intel host kernel where the semantics match and are emulated
where they don't. Metal calls can be bridged to the Intel Mac's real GPU.

The motivation: Apple dropped Intel Macs, and apps built for newer macOS versions will eventually be
arm64-only. This project explores how far you can get anyway.

> **Status: experimental research project.** What runs today is summarised below and listed in [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md); many apps will not.
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
- a [compatibility list](docs/COMPATIBILITY.md) with screenshots, and [Hello.app](examples/hello-arm), a small universal arm64 + x86-64 app that reports which architecture is running.

## What runs

Over 25 programs have been tried, on two Intel machines. Shown to work so far: Homebrew (official installer, `brew install`, arm64
bottles), Microsoft Word, Excel, PowerPoint and OneNote, Pages, Numbers and Keynote, Final Cut Pro, Google Chrome, VS Code,
Termius, HandBrake, VLC, and the arm64-only ChatGPT desktop app, which has no Intel build at all. Chromium with GPU
acceleration through the Metal bridge works too. "Works" means the program starts and opens its window; what was
checked beyond that, how long the first launch took and what remains broken are in the compatibility list.

**[Compatibility list, with screenshots](docs/COMPATIBILITY.md)**: every app tried, the conditions each needed,
and the test machines. Not done yet: audio, most IOKit hardware, apps that present through a `CAMetalLayer`, FairPlay-encrypted iOS apps.

![The arm64-only ChatGPT desktop app answering a prompt on an Intel machine (an HP EliteBook 840 G7 Hackintosh that About This Mac reports as a MacBook Pro 13-inch 2020 with an Intel Core i5 and Intel graphics, macOS Tahoe 26.6), with the Maclator launcher showing the run](docs/img/chatgpt-arm64.png)

*The arm64-only ChatGPT app running under Maclator on machine B, an HP EliteBook 840 G7 Hackintosh (i5-10310U, Intel UHD 620, macOS 26.6; About This Mac shows its `MacBookPro16,2` SMBIOS), with the launcher showing the run. Serial number redacted.*

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

## Next: the plan for speed

From [docs/AOT-STUDY.md](docs/AOT-STUDY.md), which measured where first-launch time goes on the HP EliteBook 840 G7.
Translation dominates a first launch (about 90 % of it in the general-purpose x86 assembler and `malloc`), and the
existing translation cache covers far less than it seems. The plan, in order, each step measurable on its own:

| Phase | What | Rough size | How we'll know it worked |
|---|---|---|---|
| 0 | **Fix the existing cache.** Cache universal (fat) libraries too; save profiles repeatedly, not once per process; pre-slide the shared cache once instead of in every process; let cached code chain like JIT code; load cache files lazily; forward `--no-aot` to child processes. **Done on the `speed` branch** ([results](docs/AOT-STUDY.md#phase-0-results-branch-speed-2026-10-11)). | ~1 week | measured, same loaded machine, before → after: warm `hello` 2.3 s / 376 MB → 0.6–0.7 s / 27 MB; warm `fastfetch` 4.7–5.1 s → 1.3–1.7 s; warm AppCleaner dispatcher entries 12.5 M → 0.8 M; Termius second launch 66 s → 12 s (main process translates 22 k blocks instead of 61 k) |
| 1 | **A fast x86 emitter** in place of the general-purpose assembler library (iced-x86) in the JIT and the cache builder. | 2–4 weeks | under 15 µs per block (today 52–90 µs); AppCleaner's first window under 6 s from an empty cache |
| 2 | **Translate before first launch**: `maclator --aot <App.app>` translates every arm64 binary in an app, in parallel, when the app is added in Maclator.app; plus a seed of commonly used shared-cache code per sysroot. | 2–3 weeks | a first launch within 1.5× of a warm one |
| 3 | **A translation service** that owns the cache and shares translated code read-only between processes, so Chromium's helpers stop translating the same code again. | 1–2 months | total translation across an app's processes about equal to the main process alone |
| 4 | **Better code from ahead-of-time translation**: register allocation across blocks, flag liveness, native call/return. | ongoing | `bench/bench.c` and the typing benchmarks in [docs/PERFORMANCE.md](docs/PERFORMANCE.md) |

Translating Apple's whole arm64 shared cache ahead of time is not on the list: it holds about 2.95 GB of code (an
hour of CPU and ~20 GB of output), and one app uses well under 1 % of it. Help on any phase is welcome.

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
| [CHANGELOG.md](CHANGELOG.md) | what changed in each version (also on the Changelog screen in Maclator.app) |
| [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) | every app tried, with result, time to first window and notes; test machines and screenshots (table generated by `scripts/compat.py`) |
| [docs/AOT-STUDY.md](docs/AOT-STUDY.md) | why first launches are slow (measured) and a phased plan for ahead-of-time translation |
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
