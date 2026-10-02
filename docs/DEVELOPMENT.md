# Development notes

Open problems, the bug list (so you recognise symptoms), and a short history.

## Remaining hot spots / next steps (rough priority)

1. **JIT code quality** (still the biggest lever): the first round (fusion, dead flag stores, a write-through
   register cache inside a block) is done, see "JIT code quality work". Remaining: registers still reload at every
   block boundary (a loop iteration is one block), the TBI mask (`shl/shr 8`) on every access, block-exit/IBTC cost,
   flags kept as four bytes.
2. Still-interpreted instructions: SHA-256 (`sha256h/h2/su0/su1`), `sys` (dc zva/cvau…), `tbl`,
   FRINT*, FCVTZU, UCVTF vector, unsigned/other shifts (SQSHL…), FMAX/FMIN, FMADD (needs FMA or
   double-double), LDXR/STXR exclusives, many rarer NEON ops. Use `MACLATOR_FALLBACK_HIST` on the
   GPU (`--type=gpu-process`) and renderer processes to see what matters.
3. Startup: work is ~10 processes on 4 cores; per-process translation. Ideas: pre-warm AOT,
   fewer VS Code processes/features, check Chromium/Electron flags (`--in-process-gpu`,
   `--disable-features=…`), persistent V8 code cache (don't wipe the profile dir).
4. Chromium-specific: run with a real profile; check `about:blank` page target had `url ""`
   for a long time in one run (renderer for the initial page slow to start) — investigate.
5. GPU: done for Chromium via the Metal bridge (see "GPU passthrough"); apps that present through
   `CAMetalLayer`/`MTKView` directly still need that bridged.
6. Robustness: stale-IBTC hazard if a thread only ever hits IBTC entries after invalidation
   (accepted risk); AOT profile saving only on graceful exit; concurrent builders write the same
   files (last writer wins, atomic rename); `MACLATOR_SPIN_DEBUG` for infinite-dispatch bugs.
7. Overcast / iOS-on-Mac apps: would need the iOS-on-Mac runtime and unencrypted binaries;
   FairPlay-encrypted App Store binaries are not runnable off Apple Silicon and circumventing DRM
   is out of scope. Suggested alternative: build your own UIKit "Designed for iPad" or Mac
   Catalyst app.

## Key bugs found & fixed (so you recognise symptoms)

- `--sysroot` was parsed but never used; dyld walks paths via dirfd (fixed with vpath tracking).
- Host rejects arm64 code signatures (errno 85) → emulate `fcntl` code-sign ops.
- libobjc aborts on `task_restartable_ranges_register` → patch mach_msg2 reply.
- Non-canonical address GP faults from TBI-tagged pointers → mask in interp and JIT.
- IOKit: MobileGestalt waits forever for `AppleDiagnosticDataAccessReadOnly` → fake service+iterator.
- libdispatch timers never fire → event-manager QoS lost on fired events.
- Two event-manager threads → libdispatch "Locking the manager should not fail".
- `bsdthread_ctl` EINVAL → libdispatch "_pthread_set_properties_self failed".
- 4K vs 16K pages → V8 allocator crash (`munmap` EINVAL) → 16K mmap.
- `posix_spawn` of arm64 helpers failed on the Intel kernel → re-launch through maclator.
- JIT cache exhausted / thrash from flush-all invalidation → per-unit invalidation, 4 GiB cache.
- Forked child spun forever (stale task port) → libc fork.
- Vacuous self-tests (fallback == interpreter) → report `native=` count.
- Wrong bit masks pinned the U bit for unsigned SIMD variants (umull/raddhn/ushr/ushll/uminv).
- AdvSIMD load/store were never routed to the SIMD translator (dispatched via `ldst`).
- LD4/ST4 element size is bits 11:10 (not 23:22).
- Two labels at the same address need a `nop` between (iced).
- Exec-mmap of AOT files triggers Gatekeeper dialogs → copy into the code cache.
- Chromium hang: profiler `thread_suspend` (msg id 3605) → no-op shim (now replaced by cooperative suspension, below).
- `maclator: sigreturn without a delivered signal` from bash → `sigreturn(UC_SET_ALT_STACK/UC_RESET_ALT_STACK)` is
  libplatform's `longjmp` toggling the alt-stack flag; answered with success.
- Forked child hangs in `jit::translate` (`git fetch`) → JIT/AOT/vpath locks held by threads that don't exist in the
  child; `fork` now takes them first. The `BLOCKS` `RwLock` was then replaced by a spin lock: std's queue `RwLock`
  wakes parent-only waiters from the child and dies in `_dispatch_sema4_signal`.
- `sysctl hw.cputype` (the command) said x86 → only `sysctlbyname` was faked; name2oid/oidfmt/oid2name and the
  MIB query now answer the overridden names too (Homebrew: "Cannot install on Intel processor").
- `malloc: nano zone abandoned due to inability to reserve vm space` → host and guest nano zones both live at
  `0x6000_0000_0000`; maclator re-execs itself with `MallocNanoZone=0` (not passed to the guest).
- Pages/Numbers/Keynote `os_crash` in CloudKit (`kCKCloudServicesEntitlementKey`) → `csops` about the guest itself
  now answers from the guest's own signature (entitlements without `app-sandbox`, identity, team ID): `codesign.rs`.
- OneNote: JavaScriptCore `WTF::Thread::getRegisters` release assert → `thread_suspend/resume/get_state` emulated
  cooperatively for guest threads (`suspend.rs`).
- `Library not loaded: …IO80211 … incompatible architecture (have 'x86_64')` → root-patched hosts (OpenCore Legacy
  Patcher) have x86-only files at system library paths; dyld took them for overrides of the cache. Lookups from
  dyld's own code now get ENOENT for such files.
- Universal children ran as x86_64 (`uname -m` in a guest shell) → `--arm64-children` (spawn.rs, with `#!` scripts).


## Session log summary (chronological)

1. Obtained arm64e dyld cache (macOS 26.6.2) on the test Mac via `ipsw` partial IPSW extraction
   (26.7/25G229 not indexed). 2. Made fastfetch, then neatvi, run on the test Mac. 3. IOKit shim,
   FP16 NEON, dispatch timers, single event manager → AppKit calculator. 4. 16K pages, arm64
   child spawn, libc fork, precise invalidation → VS Code Electron boots. 5. Long performance
   campaign (native NEON/atomics, AOT for libs, invalidation) using VS Code as the benchmark.
6. `maclator ./binary` auto-sysroot. 7. Chromium snapshot downloaded to Downloads (both Macs),
   thread-suspend shim, Gatekeeper fix → Chromium renders.
