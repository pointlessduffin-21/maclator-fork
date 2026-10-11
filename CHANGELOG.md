# Changelog

Versions follow `MAJOR.MINOR.PATCH`, with `-beta.N` for pre-releases. The current version is in [VERSION](VERSION):
`maclator --version` prints it, and Maclator.app shows it in its sidebar and on this page (Changelog).

## [0.1.0-beta.2] - 2026-10-11

Phase 0 of the [plan for speed](docs/AOT-STUDY.md): the translation cache now does what it was meant to.
Measured on the HP EliteBook 840 G7 (loaded machine, scratch caches; compare the pairs):

| | 0.1.0-beta.1 | 0.1.0-beta.2 |
|---|---|---|
| `hello`, warm | 1.3–2.3 s, ~350 MB | 0.2–0.7 s, 15–27 MB |
| `fastfetch`, warm | 4.7–5.1 s, 382 MB | 1.3–1.7 s, 81 MB |
| Termius, second launch | 66 s | 11–13 s |
| Termius, first launch | 82 s | 46–78 s |

### Changed
- Universal (fat) libraries are cached too. Their arm64 slice sits at a non-zero offset in the file, and it used to
  be translated again in every process.
- Profiles are saved repeatedly: every 30 s (`MACLATOR_AOT_SAVE_SECS`), at `fork`/`exec`, and at exit. They are
  append-only, and one builder per cache file runs under a lock file.
- The arm64 shared cache is slid once and kept as `slid-*.bin` files in the cache directory, mapped copy-on-write.
  Every process used to slide it again. Set `MACLATOR_NO_SLID=1` to turn this off.
- Cached code checks the indirect-branch cache before returning to the dispatcher, which cuts dispatcher round
  trips on warm runs by about 12×.
- Cache files load lazily, 1,024 blocks at a time, on first use (format `MCLAOT05`).
- `MACLATOR_STATS=1` and the SIGUSR2 dump report time per phase: AOT load, slide, profile save, interpreter,
  CPU, and max RSS.
- `--no-aot` and the new `--cache-dir DIR` (or `MACLATOR_CACHE`) are passed on to arm64 child processes.
- `maclator --version`, and one version number for the repository (`VERSION`).
- Maclator.app shows its version and this changelog.

### Upgrade notes
- `TRANSLATOR_VERSION` is now 16 and the file format changed, so existing translation caches are ignored and
  rebuilt.
- The first launch writes the slid shared-cache files (about 500 MB, 13–18 s, once per shared cache).
- New files in the cache directory: `*.built`, `*.lock` and `slid-*.bin`.

## [0.1.0-beta.1] - 2026-10-11

The first release of this fork ([release page](https://github.com/pointlessduffin-21/maclator-fork/releases/tag/v0.1.0-beta.1)).
It got Homebrew, Microsoft Office, Pages/Numbers/Keynote, Final Cut Pro, Chrome and the arm64-only ChatGPT app
running; [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) has the full list.

### Added
- **Maclator.app**, a launcher in the Paper design:
  - a Library of the arm64 apps on all volumes, plus apps added by hand or dropped onto it;
  - launch options and a live log for each run;
  - a Running view of everything under translation, with an inspector: output, CPU and memory charts, processes;
  - Setup checks.
  - The release build carries `maclator` and the GPU bridge inside the app.
- **Hello.app**, a universal test app. It says "Hello, I am ARM." or "Hello, I am Intel." depending on which code
  runs, and reports what it sees. It is built into Maclator.app (Setup: Run the arm64 test).
- **Homebrew on Intel Macs**: `scripts/brew` and launchers for its arm64 tools.
- `--arm64-children`: universal child programs and `#!` scripts run as arm64 too.
- Per-process logs of the guest's stdout and stderr in `~/Library/Logs/Maclator/<pid>.log`.
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) with screenshots, and `scripts/compat.py`, which imports the
  launcher's run results.
- [docs/AOT-STUDY.md](docs/AOT-STUDY.md), which measures where first-launch time goes and lays out the plan.

### Fixed
- `sigreturn` used by `longjmp` to reset the alternate signal stack crashed the emulator.
- Hangs in forked children: the emulator's locks are now taken around `fork`, and a fork-safe lock replaces one
  that woke threads only the parent had.
- `sysctl` lookups by number now get the same arm64 answers as lookups by name.
- The host's and guest's nano malloc zones no longer collide.
- The guest's own entitlements are reported to it, minus app-sandbox. Without them, CloudKit crashed Pages, Numbers
  and Keynote.
- Cooperative `thread_suspend`, `thread_resume` and `thread_get_state` for guest threads. Without them,
  JavaScriptCore's garbage collector crashed OneNote.
- Root-patched hosts (OpenCore Legacy Patcher, OCLP-X): x86-only files at system library paths are hidden from the
  guest's dyld.
- The ARMv8 crypto features (AES, PMULL, SHA1, SHA256) are reported to guests.
- A race when a new thread's port was written.
- The translation-cache builder no longer looks like the program still running.
- The GPU shim is built for arm64e as well.
- `install.sh` stopped on a missing test file.

## Upstream

Maclator was created by Vihaan Nathan ([@linuxkid473](https://github.com/linuxkid473)). This fork starts from
[linuxkid473/maclator](https://github.com/linuxkid473/maclator) at `7a65c4a` (2026-09-30), whose history covers
the loader, interpreter, JIT, translation cache, syscall emulation and GPU bridge.

[0.1.0-beta.2]: https://github.com/pointlessduffin-21/maclator-fork/compare/v0.1.0-beta.1...main
[0.1.0-beta.1]: https://github.com/pointlessduffin-21/maclator-fork/releases/tag/v0.1.0-beta.1
