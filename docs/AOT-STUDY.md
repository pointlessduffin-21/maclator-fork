# Ahead-of-time translation: a study

How Maclator could move from "JIT with a persistent cache" towards Rosetta-style ahead-of-time (AOT)
translation, what that would buy on first launch and in interactive use, and what to build first.
Written 2026-10-11 against commit `218e1aa` (`TRANSLATOR_VERSION` 15). Nothing in Maclator was changed for
this study; the measurements used an instrumented copy built in a scratch directory (see
[How the measurements were taken](#how-the-measurements-were-taken)).

Test machine for everything below: HP EliteBook 840 G7, Core i5-10310U (4 cores / 8 threads), 16 GB,
macOS Tahoe 26.6, arm64e shared cache from macOS 26.6.2. The machine was not idle: the Maclator.app
launcher sat at about 200 % CPU and another session was building and running Maclator at the same time
(load average 5–12). Single runs therefore vary by about ±30 %; most numbers are from 2–4 repeats.

## Summary

**Recommendation: make Maclator AOT-first with a JIT fallback, as Rosetta 2 is, but do not start with a
static whole-image translator.** Most of today's slowness is not caused by the lack of static
translation; it comes from a translator that is slow per block and from an AOT cache that, in practice,
covers less than it appears to and is costly to load. Fixing those comes first and is cheap. Static
translation then pays off for the app's own binaries, done at install or first run by a shared,
multi-threaded service.

Measured facts:

- **First launch is dominated by translation.** AppCleaner, empty cache: window after 9.8–13.1 s; of
  12–15 s of CPU, 6.7–9.4 s is the JIT translating ~105–130 k blocks (56–90 µs per block). Termius
  (Electron, 7 processes): window after 63–74 s; 118 of 129 CPU-seconds is translation, 988 k blocks
  translated across processes, mostly the same code translated once per process.
- **The translator spends ~90 % of its time in iced-x86 and malloc**, not in Maclator's own
  instruction selection (`emit_block` is under 2 % of builder samples).
- **A warm cache helps small apps a lot, Electron apps very little.** AppCleaner: 3.6–3.9 s to the window
  when warm (vs ~10–13 s cold). Termius: 53.5 s on the second launch vs 62.8 s on the first, because the
  Electron Framework is a universal (fat) binary and fat libraries are never registered for AOT
  (`syscalls.rs` only registers `mmap`s at file offset 0), and because a process that forks saves its
  profile once, at the fork, and never again.
- **Every process pays ~0.7–0.9 s and ~300 MB to slide the shared cache's data**, warm or cold
  (`cache.rs`, `map_and_slide_2`). A pre-slid copy mapped copy-on-write took this to ~11–40 ms and the
  RSS of a trivial program from 351 MB to 10 MB.
- **AOT code never chains.** Its exits go back to the dispatcher (`StubKind::Plain`), so a warm process
  makes roughly 10× more dispatcher round trips than a JIT-only one (AppCleaner 12.8–16.4 M vs 1.2–1.9 M;
  fastfetch 1.18 M vs 0.12 M). Letting
  AOT exits probe the indirect-branch cache first cut these by 94 % and CPU by 35 %.
- **The shared-cache AOT file is one ever-growing union** (225 MB, 1.74 M blocks on this machine). Every
  process copies all of it into private memory: 0.3–0.45 s with the file in the page cache, up to 5.3 s
  when it is not, plus ~225 MB RSS per process. A trivial program (`hello`) starts *slower* with this
  cache (1.55–1.60 s) than without it (1.23–1.41 s).
- **Whole-cache static translation is out of reach with this translator**: the arm64e shared cache holds
  2.95 GB of code (738 M instructions in 3,649 images). At the measured batch speed and density that is
  roughly an hour of CPU and ~20 GB of x86 code, of which one app uses well under 1 %.

Estimated (not measured) effects of the plan:

| step | first launch, small AppKit app | first launch, Electron app | warm / interactive |
|---|---|---|---|
| 0. Fix the existing cache (days) | −0.7 s per process | second launch close to warm | −35 % CPU on warm AppCleaner (measured) |
| 1. Faster code emission (2–4 weeks) | 10–13 s → ~4–6 s | 63 s → ~25–35 s | none directly |
| 2. Install-time translation of app images + shared-cache seed set | → ~3–4 s | → ~15–25 s | none directly |
| 3. Translation service, shared code (1–2 months) | small | translation work ÷2–3, RSS −200–300 MB per helper | memory |
| 4. Region-level AOT codegen (months) | none | none | 1.2–2× on hot guest code |

## Current pipeline and its limits

What the code does today (verified in `aot.rs`, `jit/mod.rs`, `jit/emit.rs`, `cache.rs`, `syscalls.rs`):

1. **Tiering.** A block executes in the interpreter until it has run `MACLATOR_JIT_THRESHOLD` (24) times,
   then `jit::translate` compiles it as one unit with iced-x86's `CodeAssembler`. All translation in a
   process is serialised by one global `TRANSLATE` mutex. Exits from JIT units go through 8-byte patchable
   slots (`StubKind::Patchable`) that `chain_slot` later points straight at the successor; indirect
   branches and returns probe a per-thread IBTC (32,768 entries) inline.
2. **Images.** `register_main`, `register_dyld`, `register_cache` and `register_image_at` (libraries dyld
   `mmap`s executable at file offset 0) define address ranges with a key: `main-<uuid>-<pathhash>`,
   `dyld-…`, `dsc-<cache uuid>`, `lib-<uuid>-<base>`.
3. **Profile.** `note_translated` records every block that runs once (cold) or is translated. On the
   first `flush_profile` call (guest `exit`, `fork` or `execve`) `save_profile` merges the run's set into
   `<key>.profile` and, if anything is new, forks a builder.
4. **Build.** The builder (`aot::build`) translates the whole profile plus blocks reachable by direct
   branches from it (up to 4× the profile size), and for the main executable also everything reachable
   from `LC_FUNCTION_STARTS`. Blocks are assembled 4,096 at a time into one unit with
   `StubKind::Plain` exits; direct branches inside a chunk become direct jumps, all other exits store
   the target pc and return to the dispatcher. The file `MCLAOT04` is rewritten from scratch.
5. **Load.** When an image is registered, `ensure_loaded` copies the whole `.aot` file into the JIT code
   cache (anonymous RWX memory) and inserts every block into the `BLOCKS` hash map, one write-lock per
   block. Files are not mapped executable, because macOS showed Gatekeeper dialogs for that.
6. **`maclator --aot <exe>`** (`build_standalone`) translates only a main executable, statically, from
   `LC_FUNCTION_STARTS` plus direct branches. Libraries and the shared cache are never translated before
   they have run.

Limits found while reading the code and confirmed by the runs below:

| limit | where | effect |
|---|---|---|
| Fat (universal) libraries are never registered | `syscalls.rs` `SYS_MMAP`: `args[5] == 0` | frameworks of universal apps (Electron Framework, most `.app` frameworks) are never cached; Termius second launch still translated 906 k blocks |
| Profile saved only once per process | `aot.rs` `SAVED.swap(true)`; `flush_profile` at `fork`/`execve` | a process that forks early (Termius' main process at 14.5 s) loses everything it runs later |
| AOT exits never chain | `StubKind::Plain`; `chain_slot` returns for slots it does not own | ~10× more dispatcher entries in warm runs |
| AOT code is not in the invalidation index | `load_file` → `register_block` only | if guest code inside an image is ever rewritten, AOT translations stay live |
| One union file for the shared cache | key `dsc-<uuid>` | loads grow with every app ever run (1.74 M blocks, 225 MB); every process copies all of it |
| Library keys include the load address | `lib-<uuid>-<base>` | one UUID cached three times at three bases (5 MB, 52 MB, 108 MB) |
| Full rebuild on any new block | `build` rewrites the file | 36 s CPU (57 s wall) to rebuild the shared-cache file; each exiting helper of a Chromium app forks its own builder |
| Profile update is read-modify-write without a lock | `save_profile` | concurrent processes can lose each other's blocks (last writer wins) |
| Profile reread at every exit | `read_profile` into a `BTreeSet` | 72–430 ms at exit even when nothing is new |
| `--no-aot` and `MACLATOR_CACHE` do not reach arm64 children | `main.rs`: forwarded flags; env filter drops `MACLATOR_*` | "cold" measurements of multi-process apps with `--no-aot` were only cold for the main process |

## Where cold-start time goes

### fastfetch and hello (CLI, `--pipe`)

| configuration | wall | CPU | RSS | notes |
|---|---|---|---|---|
| `hello`, current binary, user's cache | 1.55–1.60 s | 1.5 s | 665 MB | 1.76 M AOT blocks loaded |
| `hello`, `--no-aot` | 1.23–1.41 s | 1.4 s | 368 MB | |
| `hello`, `--no-aot`, pre-slid cache (experiment) | 0.53–0.55 s | 0.5 s | 10 MB | |
| `fastfetch`, current binary, user's cache | 1.39–1.51 s | 1.3 s | 670 MB | 1.18 M dispatcher entries |
| `fastfetch`, `--no-aot` | 2.81–2.90 s | 2.8 s | 370 MB | 20.4 k blocks translated in 1.26–1.29 s; 521 k cold blocks interpreted |
| `fastfetch`, `--interp` | 3.27–3.38 s | 3.3 s | 367 MB | |
| `fastfetch`, `--no-aot`, pre-slid | 1.95–2.02 s | 1.9 s | 47 MB | |
| `fastfetch`, own cache only, pre-slid | 0.63–0.83 s | 0.5–0.6 s | 57 MB | 210 k AOT blocks |
| `fastfetch`, own cache only, pre-slid, IBTC-probing stubs | 0.61–0.65 s | 0.5 s | 59 MB | 44 k dispatcher entries |

Phase counters from the instrumented build, warm `fastfetch` with the user's cache: shared-cache
mapping and sliding 670–800 ms, AOT load 343–447 ms, profile save at exit 138–184 ms; the guest's own
work is the remaining ~0.6 s. For a short CLI the fixed per-process costs are the whole story.

### AppCleaner (small Objective-C/AppKit app, one process)

| run | window | CPU (at window + 8 s) | blocks translated (ms) | cold blocks run | dispatcher entries | RSS |
|---|---|---|---|---|---|---|
| empty cache, 4 runs | 9.8 / 11.7 / 12.7 / 13.1 s | 11.7–15.2 s | 104–131 k (6.7–9.4 s) | 2.8–3.5 M | 1.2–1.9 M | 353–405 MB |
| warm, own cache | 3.6 / 3.9 / 5.4 s | 4.2–5.8 s | 0.03–0.7 k | 2–25 k | 12.8–16.2 M | 455–460 MB |
| warm, user's union cache (file not in page cache) | 9.5 s | 5.4 s | 1.8 k | 88 k | 13.7 M | 635 MB |
| empty cache, pre-slid | 10.2 s | 13.0 s | 110 k (8.3 s) | 2.9 M | 1.3 M | 192 MB |
| warm, pre-slid | 3.1 s | 4.7 s | 0.2 k | 13 k | 15.4 M | 201 MB |
| warm, pre-slid, IBTC-probing AOT stubs | 2.7 s | 3.1 s | 0.03 k | 3 k | 0.89 M | 206 MB |

`sample` during a cold start (CPU samples, blocked threads excluded): iced-x86 encoder and block encoder
28 %, malloc/free 28 % (nearly all of it allocation inside iced), shared-cache slide 10 %, dispatcher 7 %,
interpreter 7 %, translated code 2 %. During a warm start: slide 47 %, dispatcher (`jit::run`, lookups,
enter/exit) 33 %, translated code 7 %, AOT load 6 %. In the warm run the dispatcher cost more than the
translated code it dispatched to.

The AOT builder profiled on its own (rebuilding the shared-cache file): iced-x86 56 %, malloc/free 35 %,
`aot::build` and `emit_block` together under 2 %. Measured speeds: the JIT path costs 52–90 µs per block
in a quiet process (up to ~120 µs in Termius, where the time includes waiting for the `TRANSLATE` lock);
the batch builder costs ~21 µs per block (1.74 M blocks in 36 s of CPU). Blocks average 4.7–4.8 arm64
instructions and produce 120–130 bytes of x86, about 25–27 bytes per arm64 instruction.

### Termius (Electron, 7 processes)

| run | window | CPU, all processes | blocks translated | translation CPU | slide CPU | RSS, sum |
|---|---|---|---|---|---|---|
| empty cache | 62.8 s (74.1 s in a first, partly instrumented run) | 129 s | 988 k | 118 s | 6.2 s | 2.7 GB |
| second launch | 53.5 s | 128 s | 906 k | 109 s | 5.0 s | 2.7 GB |

Per process, the main process translated 210–270 k blocks and each of three renderers and the GPU
process 177–250 k. These are mostly the same Electron Framework and shared-cache blocks, translated
once per process. The second launch barely improved because of the two bugs above: the Electron
Framework (`lipo`: arm64 slice at file offset 212,402,176) is never registered, and the main process
saved its profile at a `fork` 14.5 s in, so its shared-cache profile holds 92.5 k blocks while it
translated 270 k. The compatibility list's 145 s for Termius was taken through the launcher under other
load; the difference to 63–74 s here is not explained by this study.

### How much code is there

| code | size | arm64 instructions | x86 at today's density | batch translation at today's speed |
|---|---|---|---|---|
| arm64e shared cache, all 3,649 images | 2.95 GB (2.74 GB `__text`) | 738 M | ~20 GB | ~55 CPU-minutes |
| Google Chrome Framework | 200 MiB `__text` | 52.5 M | ~1.4 GB | ~230 CPU-seconds |
| Electron Framework (Termius) | 141 MiB | 37.2 M | ~1.0 GB | ~165 CPU-seconds |
| AppCleaner main executable | 0.16 MiB | 42 k | ~1 MB | <1 s |
| what AppCleaner actually runs from the shared cache | — | ~1.4–1.9 M (285–395 k blocks) | ~40–50 MB | ~6–8 s |

Profiles overlap well between apps: AppCleaner's shared-cache profile covers 59 % of FluxMarkdown's,
the user's 790 k-block union covers 84 % of it, and AppCleaner covers 96 % of what Termius' main
process recorded. A first launch of FluxMarkdown with a shared-cache file built only from AppCleaner
translated 38 k blocks instead of 136 k and used 8.3 s of CPU instead of 12.5 s (window 8.9 s vs
9.2–10.7 s; the window gain was eaten by a 1.7 s AOT load from a file not yet in the page cache and by
15.7 M dispatcher entries, both fixed in step 0).

## Options compared

### 0. Make the existing cache work (fixes, not a redesign)

| fix | file / function | measured or expected effect | effort | risk |
|---|---|---|---|---|
| Register fat libraries: accept any file offset when the mapped header is an arm64 Mach-O | `syscalls.rs` `SYS_MMAP`; `aot::register_image_at` already checks magic and CPU type | Electron/Chromium frameworks and universal app frameworks get cached; expected to bring Electron second launches near warm | hours | low |
| Save profiles more than once: drop the one-shot `SAVED`; at `fork` write the profile without building; save again at exit and every ~30 s from a timer | `aot::save_profile`, `jit::flush_profile`, `syscalls.rs` fork/exec | profiles survive forks and `kill -9`; Electron main process profile complete | a day | low |
| Pre-slid shared-cache data: write the slid regions once per cache UUID and `CACHE_BASE`, map them `MAP_PRIVATE` | `cache.rs` `map_and_slide_2` | measured: slide 670–900 ms → 11–40 ms per process; RSS −160 to −340 MB per process; ~490 MB of disk, ~19 s to create once | a day | low; the slide is fixed because `CACHE_BASE` is fixed |
| AOT exit stubs probe the IBTC before returning to the dispatcher | `emit.rs` `Unit::finish` (Plain branch) | measured: dispatcher entries −94 %, warm AppCleaner CPU −35 %, window 3.1 → 2.7 s | hours | low; position-independent, needs no writable code |
| Load the shared-cache file lazily: map index read-only, copy a 4,096-block chunk on its first lookup miss | `aot::load_file`, `jit::lookup` | load cost proportional to what the process runs (0.3–5 s → est. <0.1 s); RSS −100–200 MB per process | 2–3 days | medium (lookup path) |
| Incremental builds: append new chunks instead of rewriting; one builder per image (lock file); merge profiles under that lock | `aot::build`, `save_profile` | no 36–55 s rebuild storms after quitting a Chromium app; no lost profile entries | 2–3 days | low |
| Insert AOT blocks into `INDEX` (or register image ranges) so `invalidate_range` covers them | `aot::load_file`, `jit::invalidate_range` | correctness if image code is ever patched | hours | low |
| Forward `--no-aot` / `MACLATOR_CACHE` to children | `main.rs` (`fwd`, env filter) | honest cold measurements of multi-process apps | hours | none |

### 1. Faster code emission

The selection logic is cheap; the encoding is not. Replacing `CodeAssembler` + `BlockEncoder` with a
direct encoder for the instruction forms `emit.rs` actually uses (fixed-size `rel32` branches, no
branch-size relaxation, one preallocated buffer per unit, labels as patch lists) removes most of the
90 % spent in iced and malloc. A reasonable target is 5× (≈4–5 µs per block in batch, ≈10 µs in the JIT
path); that is an estimate, not a measurement. The JIT path also assembles twice when the slot table is
misaligned (`translate_inner`); with a direct encoder alignment is a padding byte count.

Expected effect: translation is 55–90 % of cold-start CPU, so first launches drop to roughly half or
less (AppCleaner ~10–13 s → ~4–6 s; Termius ~63 s → ~25–35 s). It also speeds up V8/JavaScriptCore code,
which can never be AOT-translated, and every later AOT build. Effort 2–4 weeks: `emit.rs` is 3,900 lines
of `a!(self, …)` calls, but they can be kept and re-pointed at a new assembler with the same method
names. Risk: encoder bugs; `--selftest-jit` and `crates/difftest` cover this well.

### 2. Static translation before first launch

**App images (main executable and its frameworks).** Translate each arm64 Mach-O in an app bundle when
the app is added to the launcher or on its first run, in the background, on all hardware threads. Code
discovery, from cheapest to most complete:

- `LC_FUNCTION_STARTS` (already used for the main executable), the export trie and symbol table,
  `__unwind_info` / `__eh_frame` function ranges, `__objc_methlist` implementations, `__auth_got` and
  `__got` targets inside the image;
- direct branch following (already in `discover`), plus the fall-through after every `bl`/`blr`;
- jump tables: compiler-emitted `adr`/`add`/`ldrb|ldrh` + `br` sequences can be pattern-matched; anything
  not found falls back to the JIT at run time, as in Rosetta 2;
- data in code: arm64 Mach-Os rarely mix them, and a block that decodes into garbage is never executed
  unless reached, so over-translation costs only disk;
- PAC: Maclator treats signing as the identity, so `blraa`/`retab` translate like `blr`/`ret`.

Cost at today's speed and density: ~165 CPU-seconds and ~1 GB for the Electron Framework; after
option 1 and with 4–6 worker threads, an estimated 10–20 s once per app version. Effort: 1–2 weeks on
top of step 0 (`build_standalone` generalised to libraries, base-independent keys, a worker pool).

**The shared cache.** Translating it whole is not worth it (table above). What works instead:

- a seed set built once per sysroot: run a few reference programs (an AppKit app, a SwiftUI app, an
  Electron app, `brew`) after installing the cache, or ship their profile lists with the sysroot
  (`scripts/fetch-sysroot.sh`); measured coverage of an unseen app's shared-cache blocks: 59 % from one
  other app, 84 % from the user's union;
- static closure from the seed: follow direct branches and function starts of the dylibs the seed
  touches (`discover` already does a limited version), per dylib rather than one union file, so a
  process loads only the dylibs it maps;
- per-dylib files keyed by the cache UUID and dylib offset, so they can be shared between apps without
  loading everything.

### 3. A translation service and shared code

A per-user daemon, started on demand by the first `maclator` (a launchd agent later), in the role of
`oahd`: it owns the cache directory, translates on request with a worker pool, builds and merges profiles,
and hands translations to processes.

- **Sharing.** Today every process copies every file into private memory (225 MB for the shared-cache
  file alone). With the service, code lives once in memory objects that processes map read-only and
  executable. Ways to do this on macOS without file-backed executable mappings (which triggered the
  Gatekeeper dialogs): a Mach memory entry (`mach_make_memory_entry_64` in the service, port sent over
  the existing IPC, `mach_vm_map` with `VM_PROT_READ|VM_PROT_EXECUTE` in the client), or a POSIX
  shared-memory object (`shm_open`, then `mmap` with `PROT_EXEC`). Both are anonymous memory; whether
  either triggers the same assessment on Tahoe must be tested first (open question). Ad-hoc signing the
  cache files and mapping them is the Rosetta way (Rosetta signs its artifacts with a device key), but the
  launcher's build notes (`app/build.sh`) report that `maclator` itself is killed at exec on this machine
  once it is signed, ad hoc or not, so signing is not a safe base without testing.
- **Shared code cannot be patched.** Chaining has to move out of the code: the IBTC-probing stubs from
  step 0 already need no writes, and a per-process slot table (`jmp [r15 + table + 8*i]`) gives exact
  chaining.
- **Cross-process reuse during the first launch.** In Termius, 4–5 processes each translated 180–270 k
  mostly identical blocks. Translations requested through the service are made once; the estimate is a
  2–3× cut in total translation work for Chromium-style apps and a few hundred MB less RSS per helper.
- **Base independence.** AOT code embeds absolute guest pcs (`mov rax, target` in stubs, IBTC keys). For
  libraries that land at different bases in different apps, either keep bases deterministic per UUID
  (the 64 GB arena could place a known UUID at a remembered address) or emit pcs as image base + offset
  with the base loaded from a per-process table.

Effort 1–2 months; risks are IPC latency on the miss path (keep the in-process JIT as the fallback,
never block on the service), service lifetime and crashes, and cache corruption across concurrent
writers (the service becomes the only writer, which also fixes today's races).

### 4. Better code from AOT (interactive speed)

Static translation sees whole functions, which allows what the per-block JIT cannot do cheaply:

- keep guest registers in x86 registers across blocks and loops (today the `RegCache` is reset at every
  block start, so a loop iteration reloads everything);
- flag liveness across blocks (today: within a block, plus `flags_dead_at` looking ahead ≤24
  instructions);
- drop the TBI mask (`shl rax,8; shr rax,8`) where the base is provably the stack pointer or a
  non-tagged pointer (sp-relative accesses are common in prologues and spills);
- calls and returns as host `call`/`ret` with a check of the expected guest return address, so the return
  stack buffer predicts guest returns (Rosetta 2 does this for x86 `call`/`ret` [3]); today every `ret`
  is an IBTC probe plus an indirect `jmp`;
- native forms for instructions that still go through `helper_interp`. Statically they are rare
  (AppCleaner: 2.2 k of 516 k translated instructions, fastfetch 130 of 98 k); how often they execute
  was not measured here (`MACLATOR_FALLBACK_HIST`), so their value is unknown.

The first round of block-local work gave −11…−15 % on `bench/bench.c` (PERFORMANCE.md); region-level
allocation and native calls/returns are larger changes, and 1.2–2× on hot integer code is a plausible
range rather than a measurement. Translation becomes slower, which is acceptable only once translation
happens ahead of time (steps 2–3). Effort: months. Function-level units also make code denser (fewer
exit stubs), which matters for disk size.

### 5. What stays JIT

V8 and JavaScriptCore generate code at run time into `MAP_JIT` memory, and some programs patch code;
these must stay on the JIT with precise invalidation, as Rosetta 2 keeps a JIT for the same reasons [1]
[3]. How much of a Chromium renderer's translation is V8 code rather than framework code was not
measured; counting translated blocks outside registered images would answer it.

### Background and parallel translation

Inside one process translation is serialised by `TRANSLATE`, and a thread that hits an untranslated
block either interprets it or waits. For single-process apps a worker pool that translates the static
successors of newly hot blocks ahead of time would take translation off the main thread; on this
4-core machine a Chromium app's 5–7 busy processes already fill the cores at startup, so for those the
gain comes from not duplicating work (step 3), not from more threads.

## How other translators do it

- **Rosetta 2** translates x86-64 code ahead of time "at times the system deems optimal for
  responsiveness", stores each translation as a separate Mach-O file, keeps a JIT for code that cannot
  be translated ahead of time, and has a narrow system service that answers "is there a translation" and
  hands out read-only file descriptors; artifacts live in a data vault only that service can read, and
  are signed with a device-specific key managed by the Secure Enclave [1]. The cache is under
  `/var/db/oah/`, written as `.in_progress` then renamed to `.aot`, keyed by a hash of the binary's path,
  header, timestamps, size and ownership [2]. Translation usually completes before launch, sometimes at
  install time, and large apps can still delay launch noticeably [4]. A reverse-engineering analysis
  describes translating the entire text segment up front, a lookup table for indirect branches with a
  JIT fallback on misses, near one-to-one instruction mapping (sqlite3: ~1.64× code size), `call`/`ret`
  mapped to `bl`/`ret` for return prediction, and few inter-instruction optimisations; it also notes that
  keeping all guest registers in host registers would be a problem when emulating 64-bit ARM on x86 [3].
  Rosetta is helped by hardware TSO and flag-computation extensions on Apple Silicon [3]; Maclator's
  direction (arm64 on x86) gets TSO for free but has fewer host registers than guest registers.
- **FEX-Emu** (x86 on arm64 Linux) added a disk cache of JIT output in FEX-2609: generated code is stored
  in a database and looked up before translating, on the first run and later runs; the cache has no size
  limit or stale-entry removal yet and can conflict when files change [5]. Earlier releases shared code
  buffers between threads in preparation [5].
- **Box64** added DynaCache in 0.3.8: per-binary (and per-library, reusable across programs) files of
  generated code, read by default but written only when enabled, with a 2 GB disk limit and compression
  from 0.4.4; the author's Factorio test went from 39 s startup to 29 s on later runs [6].
- **QEMU TCG** keeps translations only in memory (the `tb-size` cache, 1 GiB by default since 5.0) with
  a jump cache for computed jumps; no persistent cache was found upstream [7].

The common pattern: everyone ships a JIT; persistent caches keyed per binary are the standard first
step; Rosetta alone translates whole binaries ahead of time, and it does so through one privileged
service that is the only writer of the cache.

Sources:
[1] [Apple Platform Security: Rosetta 2 on a Mac with Apple silicon](https://support.apple.com/guide/security/secebb113be1/web)
[2] [Mandiant: Rosetta 2 artifacts in macOS intrusions](https://cloud.google.com/blog/topics/threat-intelligence/rosetta2-artifacts-macos-intrusions/)
[3] [Dougall Johnson: Why is Rosetta 2 fast?](https://dougallj.wordpress.com/2022/11/09/why-is-rosetta-2-fast/)
[4] [The Eclectic Light Company: Explainer: Rosetta 2](https://eclecticlight.co/2022/12/10/explainer-rosetta-2/)
[5] [FEX-2609 release notes](https://fex-emu.com/FEX-2609/), [Phoronix on FEX-2609](https://phoronix.com/news/FEX-2609-Released)
[6] [Box64 v0.3.8 release](https://box86.org/2025/10/new-box64-v0-3-8-released/), [Box64 v0.4.4 release](https://box86.org/2026/08/new-box64-v0-4-4-release/)
[7] [QEMU TCG cache sizing discussion (Alex Bennée)](https://lore.kernel.org/all/875yuso6g7.fsf@linaro.org/), [Nova blueprint on the tb-size default](https://blueprints.launchpad.net/nova/+spec/control-qemu-tb-cache)

## Recommended plan

### Phase 0: fix the existing cache (about a week)

In this order, each measurable on its own:

1. `syscalls.rs` `SYS_MMAP`: register any executable mapping whose first bytes are an arm64 Mach-O
   header (drop `args[5] == 0`). Success: after a graceful quit of Termius, `lib-<uuid>-*.aot` exists for
   the Electron Framework, and the second launch's `[stats] translated=` in the main process falls from
   ~200 k to a few thousand.
2. `aot.rs` `save_profile`: allow repeated saves (save on `fork`/`execve` without building; save on exit;
   periodic save every ~30 s from a timer thread); keep one build per image at a time with a
   lock file and merge profiles under it. Success: Termius' `dsc-*.profile` grows past the main
   process's translated count; no two builders for the same file in `ps`.
3. `cache.rs`: pre-slid regions (`slid-<cache uuid>-<n>.bin` next to the AOT files, written once,
   mapped `MAP_PRIVATE`). Success: `hello --no-aot` under 0.6 s and ~10 MB max RSS (measured 0.53–0.55 s,
   10 MB with the experiment).
4. `emit.rs` `Unit::finish`: IBTC probe in `StubKind::Plain` exits; bump `TRANSLATOR_VERSION`. Success:
   warm AppCleaner `block-entries` under 1 M per 15 s (measured 0.89 M vs 13–16 M).
5. `aot.rs`: lazy, per-chunk loading (or per-dylib files for the shared cache); stop rereading the
   profile at exit when nothing is new. Success: `hello` with a warm cache is no slower than `--no-aot`;
   AOT load under 100 ms with a 1.7 M-block file.
6. Put the phase counters used here into `MACLATOR_STATS` / the SIGUSR2 line permanently (AOT load ms,
   slide ms, profile save ms, interpreter ms, process CPU and max RSS), and forward `--no-aot` and
   `MACLATOR_CACHE` to children.

### Phase 0 results (branch `speed`, 2026-10-11)

All six items are implemented, each as its own commit, and each was checked with `--selftest-jit`
(dpimm, dpreg, branch, fuse, blocks: mismatch=0), `cargo test`, guest programs (hello, fork, thread
suspend/resume, JavaScriptCore), `brew list` and AppCleaner (window appears, quit by Apple event). What
changed, in the order of the plan:

1. **Fat libraries.** `SYS_MMAP` offers every readable, executable, file-backed mapping to
   `register_image_at`, which already validates the arm64 Mach-O header. Electron Framework's arm64 slice now has a
   `lib-<uuid>-<base>.aot` (130–180 MB). A hand-made universal dylib (slice at offset 49,152) is registered too.
2. **Repeated saves, one builder per image.** The profile is append-only; a process appends what is new at
   `fork`, `execve`, exit and every 30 s (timer thread, no JIT locks, started again in forked children). The builder
   runs under a `flock` per image; `<key>.built` tells whether the `.aot` is out of date (it also detects a
   `TRANSLATOR_VERSION` bump, which the old logic missed when the profile did not grow). The builder fork now
   holds the same locks as a guest fork.
3. **Pre-slid shared cache** (`slid-<cache uuid>-<slide>-<n>.bin`, ~500 MB, written by the first process in
   13–18 s, mapped `MAP_PRIVATE` afterwards).
4. **IBTC probe in AOT exit stubs**, `TRANSLATOR_VERSION` 16.
5. **Lazy per-chunk loading** (`MCLAOT05`, 1,024-block chunks). The profile is not read at exit unless something
   new was recorded.
6. **Phase counters** (`MACLATOR_STATS` `phases:` line and SIGUSR2 `[phases]`), and `--no-aot` / `--cache-dir` /
   `MACLATOR_CACHE` forwarded to children (done first, because honest scratch-cache measurements need it).

**Measured.** Same machine as above, but under a heavier load than in the study (load average 5–15 during the
runs, so absolute times are 1.5–2.5× the study's and noisy; compare the pairs). "Before" is the commit this branch
started from plus the forwarding commit; "after" is the last commit. Scratch cache directories, CLI numbers from
`/usr/bin/time -l` (real / CPU / max RSS), AppCleaner and Termius started with `--arm64-children`.

| | before | after |
|---|---|---|
| `hello`, warm AOT cache | 2.23–2.29 s / 2.1 s / 376 MB | **0.56–0.73 s / 0.5–0.7 s / 27 MB** |
| `hello --no-aot` | 2.29–2.55 s / 2.2–2.4 s / 351 MB | 0.85–1.23 s / 0.8–1.2 s / 9 MB |
| `hello`, empty cache (pre-slid files present) | 2.44 s / 351 MB | 1.26 s / 10 MB |
| `fastfetch --pipe`, warm | 4.7–5.1 s / 4.5–4.8 s / 382 MB, 1.03 M dispatcher entries | **1.33–1.69 s / 1.2–1.5 s / 81 MB, 44 k entries** |
| `fastfetch --pipe --no-aot` | 8.4–9.0 s / 352 MB | 6.7–7.2 s / 47 MB |
| AppCleaner, first window, empty cache | 17 s (earlier run: 37 s, no save) | 14–35 s (load-dominated; 107 k blocks translated, as before) |
| AppCleaner, first window, warm | 6 s, 12.5 M block entries | **3–9 s, 0.8–1.1 M block entries** |
| Termius, first window, empty cache | 82 s | 46 s (46–78 s over five runs) |
| Termius, second launch | 66 s; main process translated 61 k blocks | **12 s; main process translated 22 k** |
| Termius, third / fourth launch | – | 13 s / 11 s |

(An earlier, quieter pass: `hello` warm 0.97–1.05 s / 376 MB before, 0.45–0.60 s / 27 MB after; `fastfetch` warm
2.8–3.2 s / 717 MB before, 1.5–1.7 s / 81 MB after.)

Per item, on the metric the plan named:

- Item 1: second launch of Termius, main process, blocks translated 61 k → 7.2 k with only this change
  (66 s → 47 s to the window), helper processes 25 k → 0.
- Item 2: the shared-cache profile after a Termius launch (302 k entries) is larger than the main process's
  translated count (237 k), and at most two builder processes were seen at once (a parent's and its forked child's; builds of the
  same image are serialised by the lock file, the second one exits when it cannot take it). The 4-second-timer test (`kill -9` after 9 s)
  leaves profiles on disk.
- Item 3: `hello --no-aot` 351 MB → 9–10 MB RSS; the slide phase is 25–55 ms per process (was 670–900 ms).
- Item 4: warm AppCleaner block entries 12.5 M → 0.8 M.
- Item 5: `hello` with a warm cache is faster than `--no-aot` (0.56–0.73 s vs 0.85–1.23 s); AOT load for `hello`
  is 16–24 ms (10 chunks). For a program that runs a lot of the file the cost is still visible: warm AppCleaner
  loads 145–590 chunks in 240–360 ms, Termius' main process 800 ms for ~1,700 chunks. The goal "under 100 ms" holds
  for small programs, not for an app that touches most of the file.
- Item 6: counters exist; `--no-aot` and the cache directory reach children (checked with a guest that
  `fork`/`exec`s another arm64 program).

**What did not work, or turned out different from the study.**

- Termius never gets an *on-screen* window here (the windows exist, `kCGWindowIsOnscreen` stays 0, CPU goes idle at
  the time the study reported its window). "Window" in the Termius rows is the first layer-0 window of the process
  tree that is at least 500 px wide in any state; for AppCleaner it is the on-screen window. A first Termius attempt
  without `--disable-gpu-sandbox` hung with GPU-process errors; the launcher passes that flag for Chromium apps.
- The warm Termius main process still translates ~20 k blocks and each renderer ~60 k (V8-generated code is the
  likely reason; not verified), so "a few thousand" was not reached. Helpers that are not renderers do reach ~0.
- Lazy loading does not reduce the work for an app that uses most of the file: it moves it from start-up to the first
  use of each chunk, and the chunk is the unit of copy. It makes small programs cheap, which is where the
  fixed cost hurt. Chunks went from 4,096 to 1,024 blocks for that reason (not measured separately).
- The first run after a shared-cache change pays 13–18 s to write the pre-slid files (disk-bound); `MACLATOR_NO_SLID=1`
  skips it. Old `slid-*.bin` and `.aot` files are not cleaned up.
- A bug found only by a multi-process run: the first version of lazy loading raced with the JIT on the code cache
  (`code cache raced` assertion in Termius' main process, once in the runs before the fix). Fixed by taking the
  translator lock for chunk copies. Any other code that allocates code-cache space outside `translate_inner` has the
  same problem.
- SIGTERM kills a guest without running its exit path, so it does not save a profile (only the 30 s timer and the
  fork/exec snapshots do); a quit through an Apple event or the guest's own `exit` does.
- Not done: putting AOT blocks into `INDEX` (invalidation of AOT code), the study's table row for it.

### Phase 1: a fast emitter (2–4 weeks)

Replace iced's `CodeAssembler`/`BlockEncoder` in `jit/emit.rs` and `jit/mod.rs` with a direct encoder
behind the same method names; fixed `rel32` branches; reuse buffers. Keep iced for `--jit-dump`
disassembly. Success: `translate_ms / translated` under 15 µs per block in the JIT path and under 5 µs in
the builder (today 52–90 and 21); AppCleaner first window under 6 s from an empty cache;
`--selftest-jit` for every class and `crates/difftest` unchanged.

### Phase 2: translate before first launch (2–3 weeks)

- `maclator --aot <App.app>`: walk `Contents/MacOS`, `Contents/Frameworks`, `Contents/Helpers`; for
  each arm64 Mach-O (fat slices included) discover code from function starts, exports, symbols, unwind
  info and Objective-C method lists; translate with a worker pool (one `Unit` per thread, chunks merged at
  the end); write per-image files keyed by UUID and slice, with image-relative pcs or a remembered base.
  The launcher runs it in the background when an app is added.
- A shared-cache seed per sysroot, from reference-app profiles, built per dylib.

Success: first launch of AppCleaner within 1.5× of its warm launch; Termius' first launch translates
under 100 k blocks in the main process (today 270 k); disk per Electron app reported and acceptable
(expected ~0.5–1 GB at today's density).

### Phase 3: translation service (1–2 months)

Per-user daemon owning the cache; read-only executable shared mappings via memory entries or shared
memory (test the Gatekeeper behaviour first); per-process slot tables or IBTC stubs for chaining;
in-process JIT kept as the fallback. Success: sum of `translated` across Termius' processes on first
launch roughly equal to the main process's alone; per-helper RSS down by the size of the AOT code.

### Phase 4: region-level codegen for AOT (ongoing)

Register allocation across blocks inside a function, cross-block flag liveness, native call/return,
TBI elision for sp-relative accesses, denser exits. Measure with `bench/bench.c` (built and run with
`--aot` first) and the VS Code/Chromium typing benchmarks in PERFORMANCE.md.

## Open questions

- Can a translation service hand out executable shared memory (Mach memory entry or `shm_open`) without
  the Gatekeeper dialogs that file mappings caused on Tahoe? This decides between sharing and copying.
- How much of a Chromium renderer's translation is V8-generated code, which no AOT can cover?
- How often do still-interpreted instructions execute in real apps (`MACLATOR_FALLBACK_HIST` per
  process type)? Static counts are small, dynamic counts are unknown.
- Why are the compatibility list's first-launch times (Termius 145 s, AppCleaner 40 s) 2–3× the
  numbers measured here (63–74 s, 10–13 s)? Launcher overhead, a different cache state and machine
  load are candidates.
- Disk budget: at ~26 bytes of x86 per arm64 instruction, whole-image translation of large frameworks
  costs ~1 GB each. Denser code (fewer stubs, no TBI mask on sp, function-level units) or compression
  (Box64 compresses) may be needed.
- Load addresses: should the 64 GB arena remember a base per library UUID, or should AOT code become
  base-relative? The first is simpler; the second survives address changes.
- The single hang after a version bump noted in PERFORMANCE.md (fork from a multithreaded GPU process)
  matters more once builders run more often; a service would remove the fork.

## How the measurements were taken

- An instrumented copy of commit `218e1aa` was built in a scratch directory (`CARGO_TARGET_DIR` outside
  the repository; `~/bin/maclator` untouched). It added: a monotonic clock at `main`, nanosecond
  counters around `interp_block` (cold blocks), JIT-side system calls, `aot::ensure_loaded`,
  `cache::map_and_slide_2` and `aot::save_profile`, and an async-signal-safe dump of all counters plus
  `getrusage` CPU and max RSS to `$MACLATOR_PHASE_DIR/phase-<pid>.txt` on SIGUSR2 and in
  `flush_profile`; `MACLATOR_PHASE_DIR`, `MACLATOR_CACHE` and `MACLATOR_X_*` were let through to child
  processes. Two experiments were switchable by environment: `MACLATOR_X_SLIDCACHE` (write slid
  shared-cache regions to files once, then map them `MAP_PRIVATE`) and `MACLATOR_X_IBTCSTUB` (IBTC probe
  in AOT exit stubs, with its own `TRANSLATOR_VERSION` and a default cache directory outside
  `~/Library/Caches`). Interpreter time includes system calls made from interpreted blocks, which makes it
  meaningless for multi-threaded processes that block in such calls; it is quoted only for
  single-process runs.
- GUI apps were started from a script: the instrumented `maclator --arm64-children <exe>` in the
  background with a scratch `MACLATOR_CACHE`; a small Swift tool polled `CGWindowListCopyWindowInfo`
  for an on-screen layer-0 window owned by the process tree (as the launcher does); after the window and
  8–15 s more, SIGUSR2 to every process, `sample <pid> 3`, then a quit Apple event
  (`NSRunningApplication.terminate()`), waiting for the builder, and SIGTERM/SIGKILL for anything left.
  Startup profiles used `sample <pid> 6–12` started at launch with `MallocNanoZone=0
  MACLATOR_NANO_OFF=1` set, so Maclator's own re-exec does not detach `sample`. Samples were grouped by
  top-of-stack symbol.
- Termius ran with `--user-data-dir` in the scratch directory. Google Chrome was not measured.
- CLI timings are `/usr/bin/time -l`. The user's `~/Library/Caches/Maclator/aot` was copied before the
  runs and was never used by the instrumented build except for read-only warm CLI runs with
  `MACLATOR_NO_AOT_BUILD=1`.
- Shared-cache code size: a script reading the cache header's image list and summing sections flagged
  as instructions in every image's load commands. App sizes: `otool -arch arm64 -l`. Profile overlaps:
  set intersections of `.profile` files.
