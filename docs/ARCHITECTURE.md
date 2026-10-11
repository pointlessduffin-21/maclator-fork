# Architecture

How Maclator is put together. (Older notes call the Intel test machine "the test Mac"; it is simply the Intel Mac the project is developed against.)

## Architecture

Workspace: `crates/core` (CPU state, interpreter, softfloat, mem), `crates/maclator` (runtime),
`crates/difftest`.

- `core/interp/*` — reference AArch64 interpreter (dp, ldst, simd incl. FP16 `fp16.rs`, sys).
  It is the semantic ground truth; JIT falls back to it per instruction (`helper_interp`).
- `maclator/loader.rs, macho.rs` — loads the main Mach-O + arm64 dyld at fixed addresses;
  the *guest's own dyld* then maps the shared cache and dylibs.
- `maclator/cache.rs` — emulates `shared_region_*` syscalls; maps the cache at `0x6_0000_0000`.
- `maclator/paths.rs` — redirects `/System/**/dyld` cache paths to `--sysroot`; tracks dirfd
  virtual paths (dyld walks paths with `openat(dirfd,"rel")`); `discover_sysroot()`.
- `maclator/syscalls.rs` — BSD syscall + Mach trap emulation/pass-through (see "Emulation notes").
- `maclator/hostsys.rs` — raw x86-64 Darwin syscall/Mach-trap trampoline (8 args).
- `maclator/workq.rs` — libdispatch workqueue/workloop/kevent emulation (worker threads,
  single event-manager rule, QoS restore, wl monitors).
- `maclator/spawn.rs` — `posix_spawn/execve`: arm64-only Mach-Os are re-launched through
  maclator with forwarded flags (`--dyld --sysroot --interp --no-aot --cache-dir --arm64-children --trace --dump-on-fault`).
- `maclator/iokit.rs` — `mach_msg2` shim: fake Apple-Silicon-only IOKit services
  (`AppleDiagnosticDataAccessReadOnly`), and thread suspend/resume/get_state neutralisation.
- `maclator/jit/{mod,emit,selftest}.rs` — x86-64 JIT (iced-x86), tiering (interpret cold
  blocks, translate after `MACLATOR_JIT_THRESHOLD`, default 24), block chaining via patchable
  slots, per-thread IBTC (32768 entries), per-unit precise invalidation (`INDEX`).
- `maclator/aot.rs` — persistent translation cache (`MCLAOT04`); see below.
- `maclator/engine.rs` — run loop, fault/USR1/USR2 dump handlers. `signals.rs`, `threads.rs`.

### AOT cache
Cache directory: `~/Library/Caches/Maclator/aot`, or `--cache-dir DIR` / `$MACLATOR_CACHE` (both are forwarded to
re-launched arm64 children, as is `--no-aot`; the guest environment itself never carries `MACLATOR_*`).

**What is cached.** Images registered: main exe (fixed base), dyld, shared cache, and **every dyld-loaded arm64
library**: any readable, executable, file-backed `mmap` whose first bytes are an arm64 Mach-O header (so the arm64
slice of a *fat* library, e.g. Electron Framework at ~212 MB into the file, is registered too; key =
`lib-<uuid>-<base>`). Bases are deterministic because `mach_vm_allocate(ANYWHERE)` is served from a 64 GB arena
(`syscalls.rs`, candidate bases tried in order). Every block that executes (cold-interpreted or JIT-translated)
is recorded per image.

**Profiles and builds.** `<key>.profile` is an append-only list of guest block addresses (8 bytes each). A process
appends only what it has recorded since its previous save and what is not already on disk: at `fork` and `execve`
(no build), at exit (`SaveMode::Exit`, which also forks a builder) and every 30 s from a timer thread
(`MACLATOR_AOT_SAVE_SECS`), so a `kill -9` or an early-forking Electron main process still contributes. O_APPEND
appends from concurrent processes cannot lose each other's blocks. `<key>.built` records the translator version
and the profile length the `.aot` was built from; an image is "dirty" when they differ. At most one builder works
on an image at a time (`flock` on `<key>.lock`, non-blocking; a finishing builder re-checks the profile, so a late
append is not lost). The builder is a fork of the guest taken while holding the same locks as a guest `fork`
(`jit::lock_for_fork`, which now includes the profile-save mutex and the lazy-load mutex), and retitles itself
"maclator: building translation cache". The timer thread takes no JIT lock.

**File format (`MCLAOT05`).** 64-byte header, block index (`pc`, code offset; sorted by pc), chunk table, code.
Code is built in chunks of 1,024 blocks: jumps inside a chunk are direct, every other exit is a stub that stores the
target pc, then probes the per-thread indirect-branch table inline (`StubKind::Plain` in `Unit::finish`) and only on
a miss returns to the dispatcher. AOT code never patches itself (no chaining slots), so it stays position
independent.

**Loading is lazy.** Registering an image only `mmap`s its `.aot` read-only (microseconds). The first time a thread
misses on a block (`jit::run`, or the chain path), `aot::lazy_lookup` binary-searches the mapped index and, on a hit,
copies that block's whole chunk into the JIT code cache (under the translator lock, because `translate_inner` assumes
nobody else allocates code between reading the cursor and allocating) and registers the chunk's blocks. Load cost is therefore
proportional to what the process runs, not to the size of the file (the shared-cache file is 70+ MB). Chunks are
copied, never mapped executable: do NOT mmap the files PROT_EXEC (macOS Gatekeeper pops "Apple could not
verify…" dialogs for every file).

**Pre-slid shared cache.** The arm64e shared cache's writable regions need sliding to our fixed `CACHE_BASE`
(`cache.rs`). The first process does it and writes each slid region to `<cache dir>/slid-<cache uuid>-<slide>-<n>.bin`
(~500 MB in total, written before the guest can touch the regions, temp file + rename); every later process maps
those files `MAP_PRIVATE` and skips the slide: about 0.7-0.9 s and ~340 MB less RSS per process
(`MACLATOR_NO_SLID=1` disables it). Files for old cache versions are not removed automatically.

**Versions.** Bump `TRANSLATOR_VERSION` (currently **16**) whenever codegen changes. A version bump invalidates the
*whole* cache (files are shared between binaries: two builds with different versions on the same machine keep
overwriting each other's cache, so A/B-test translators with `--no-aot` or a separate `--cache-dir`); stale files are
detected through `<key>.built` and rebuilt at the next exit. `MACLATOR_NO_AOT_BUILD` stops builders,
`MACLATOR_AOT_SYNC` builds in the exiting process (tests), `MACLATOR_NO_AOT_SAVE` disables the timer.
Rebuilds can take minutes; a process that is killed still has its last periodic snapshot in the profile.

**Counters.** `MACLATOR_STATS=1` prints, at exit, fork and exec, a `phases:` line (AOT load ms and chunks,
slide ms, profile-save ms, interpreter ms, process CPU ms, max RSS); SIGUSR2 prints the same as `[phases]` next to
`[stats]`.

### Emulation notes / important decisions
- **Page size 16 KiB**: `mmap` returns 16K-aligned, 16K-rounded regions (`mmap_16k`), sysctl
  `hw.pagesize` = 16384.
- **Top-byte-ignore**: guest addresses have bits 63:56 masked in `mem::host()` and in the
  JIT's `commpage_fix` (shl/shr 8) — libobjc/libmalloc use tagged pointers.
- **Code-signing fcntls** (`F_ADDFILESIGS*`, `F_CHECK_LV`) accepted (host rejects arm64 sigs).
- **fork** goes through libc `fork()` (raw syscall left the child with a stale `mach_task_self`,
  making the JIT's `mach_vm_read` of guest code fail → empty blocks → infinite loop).
- `bsdthread_ctl(SET_SELF)` accepted (host EINVALs some QoS combos; libdispatch aborts).
- `task_restartable_ranges_register` (mach_msg2 id 8000) reply patched to success.
- Thread suspend/resume/get_state MIG messages (ids 3605/3606/3603) neutralised
  (Chromium's stack-sampling profiler otherwise deadlocks the process).
- Dispatch event manager: host kqueue drops the `qos` (event-manager flag) on fired events →
  Maclator records each knote's QoS at registration and restores it; only one manager thread at
  a time (libdispatch aborts otherwise).
- FP: ARM default NaN vs x86 "real indefinite" fixed up in JIT scalar+vector arithmetic. FPCR
  rounding/DN/FZ modes are ignored by JIT-native FP (assumes defaults). QC (saturation) flag
  not maintained by native saturating ops. sNaN-vs-qNaN operand priority differs (x86 prefers
  qNaN) — 1 in ~15000 random self-test cases, not seen in practice.
- **Children**: arm64-only programs started by a guest always run under maclator; with `--arm64-children` so do
  universal ones and `#!` scripts whose interpreter has an arm64 slice (setuid programs stay native).
- **Own signature** (`codesign.rs`): `csops`/`csops_audittoken` for the guest's pid report the guest executable's
  entitlements (minus `com.apple.security.app-sandbox`, which would make libsystem_secinit try to sandbox
  maclator), identity and team ID. Daemons that check the process by audit token still see maclator.
- **Thread suspension** (`suspend.rs`): `thread_suspend` waits until the target is in a system call or parked; a
  thread running guest code is interrupted with SIGINFO and parks in the handler if it was inside translated code,
  else at the next dispatcher checkpoint. `thread_get_state` returns guest `ARM_THREAD_STATE64`/`ARM_NEON_STATE64`.
- x86 baseline for JIT is SSE2 + selected SSE4.1/SSSE3 (pshufb, pmin/pmax, pmulld, pmovzx…);
  the Haswell hack and Rosetta (dev Mac) both support these.
