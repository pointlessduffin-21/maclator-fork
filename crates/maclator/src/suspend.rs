//! thread_suspend / thread_resume / thread_get_state for guest threads.
//!
//! Guests pause each other's threads and read their registers: JavaScriptCore does it for every
//! conservative GC scan (WTF::Thread::getRegisters, a release assert if it fails), Chromium's
//! stack sampler for profiling. Neither the host's thread_suspend (it can stop a thread while it
//! holds an emulator lock, and the next translation in any thread deadlocks) nor the host's
//! register state (x86) is of use, so suspension is cooperative:
//!
//! * a thread inside a system call counts as stopped at once (its guest registers can't change);
//!   when the call returns it parks before running guest code again;
//! * a thread running guest code gets `SIG_SUSPEND`; if it was inside translated code (no emulator
//!   locks held) it parks right in the signal handler, otherwise it parks at the next dispatcher
//!   iteration (`checkpoint`, also reached when a chain of translated blocks uses up its budget).
//!
//! thread_get_state then reports the parked thread's guest registers. The register cache in
//! translated code is write-through, so `Cpu` holds every committed register write.

use maclator_core::cpu::Cpu;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering::SeqCst};
use std::sync::{Arc, Mutex};

/// Host signal used to interrupt a guest thread for suspension. SIGINFO: its default action is
/// to ignore, and guest dispositions for it are not mirrored to the host (signals.rs).
pub const SIG_SUSPEND: i32 = libc::SIGINFO;

pub struct GuestThread {
    pthread: libc::pthread_t,
    cpu: *const Cpu,
    suspend_count: AtomicU32,
    /// Parked: not running guest code, waiting for suspend_count to reach 0.
    parked: AtomicBool,
    /// Inside a system call (guest registers stable).
    in_syscall: AtomicBool,
}
unsafe impl Send for GuestThread {}
unsafe impl Sync for GuestThread {}

static THREADS: Mutex<Option<HashMap<u32, Arc<GuestThread>>>> = Mutex::new(None);

thread_local! {
    static ME: std::cell::Cell<*const GuestThread> = const { std::cell::Cell::new(std::ptr::null()) };
    static PORT: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

/// Register the calling host thread as running `cpu`. Returns the thread's Mach port name.
pub fn register(cpu: &Cpu) {
    install_handler();
    let port = unsafe { libc::mach_thread_self() };
    let t = Arc::new(GuestThread {
        pthread: unsafe { libc::pthread_self() },
        cpu,
        suspend_count: AtomicU32::new(0),
        parked: AtomicBool::new(false),
        in_syscall: AtomicBool::new(false),
    });
    ME.with(|m| m.set(Arc::as_ptr(&t)));
    PORT.with(|p| p.set(port));
    THREADS.lock().unwrap().get_or_insert_with(HashMap::new).insert(port, t);
}

pub fn unregister() {
    let port = PORT.with(|p| p.replace(0));
    if let Some(m) = THREADS.lock().unwrap().as_mut() {
        m.remove(&port);
    }
    ME.with(|m| m.set(std::ptr::null()));
}

fn me() -> Option<&'static GuestThread> {
    let p = ME.with(|m| m.get());
    // The Arc in THREADS outlives every use on this thread (unregister clears ME first).
    (!p.is_null()).then(|| unsafe { &*p })
}

fn park(t: &GuestThread) {
    t.parked.store(true, SeqCst);
    while t.suspend_count.load(SeqCst) > 0 {
        // nanosleep is async-signal-safe (this also runs inside the signal handler).
        let ts = libc::timespec { tv_sec: 0, tv_nsec: 100_000 };
        unsafe { libc::nanosleep(&ts, std::ptr::null_mut()) };
    }
    t.parked.store(false, SeqCst);
}

/// Called by the dispatcher between blocks: park if a suspension is pending.
#[inline]
pub fn checkpoint() {
    if let Some(t) = me() {
        if t.suspend_count.load(SeqCst) > 0 {
            park(t);
        }
    }
}

/// Run a system call: the thread counts as stopped while inside it.
pub fn in_syscall<R>(f: impl FnOnce() -> R) -> R {
    let Some(t) = me() else { return f() };
    t.in_syscall.store(true, SeqCst);
    let r = f();
    t.in_syscall.store(false, SeqCst);
    // SeqCst on both sides: either the suspender saw in_syscall, or we see its count here.
    if t.suspend_count.load(SeqCst) > 0 {
        park(t);
    }
    r
}

extern "C" fn on_signal(_sig: i32, _info: *mut libc::siginfo_t, uctx: *mut libc::c_void) {
    let Some(t) = me() else { return };
    if t.suspend_count.load(SeqCst) == 0 || t.in_syscall.load(SeqCst) {
        return;
    }
    // Interrupted inside translated code: no emulator locks are held, park here.
    let rip = unsafe {
        let uc = uctx as *const libc::ucontext_t;
        (*(*uc).uc_mcontext).__ss.__rip
    };
    if crate::jit::code_cache().contains(rip) {
        park(t);
    }
    // Otherwise the dispatcher parks at its next checkpoint.
}

fn install_handler() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| unsafe {
        let mut sa: libc::sigaction = std::mem::zeroed();
        sa.sa_sigaction = on_signal as usize;
        sa.sa_flags = libc::SA_SIGINFO | libc::SA_RESTART;
        libc::sigemptyset(&mut sa.sa_mask);
        libc::sigaction(SIG_SUSPEND, &sa, std::ptr::null_mut());
    });
}

fn lookup(port: u32) -> Option<Arc<GuestThread>> {
    THREADS.lock().unwrap().as_ref()?.get(&port).cloned()
}

fn stopped(t: &GuestThread) -> bool {
    t.parked.load(SeqCst) || t.in_syscall.load(SeqCst)
}

/// thread_suspend: returns once the thread is stopped (as XNU's does), or after a timeout.
pub fn suspend(port: u32) -> Option<()> {
    let t = lookup(port)?;
    if t.suspend_count.fetch_add(1, SeqCst) > 0 {
        return Some(()); // already held
    }
    if PORT.with(|p| p.get()) == port {
        park(&t); // suspending ourselves: wait until someone resumes us
        return Some(());
    }
    let start = std::time::Instant::now();
    while !stopped(&t) {
        unsafe { libc::pthread_kill(t.pthread, SIG_SUSPEND) };
        let ts = libc::timespec { tv_sec: 0, tv_nsec: 200_000 };
        unsafe { libc::nanosleep(&ts, std::ptr::null_mut()) };
        if start.elapsed() > std::time::Duration::from_secs(2) {
            break;
        }
    }
    Some(())
}

pub fn resume(port: u32) -> Option<Result<(), ()>> {
    let t = lookup(port)?;
    Some(
        t.suspend_count
            .fetch_update(SeqCst, SeqCst, |c| c.checked_sub(1))
            .map(|_| ())
            .map_err(|_| ()), // KERN_FAILURE: not suspended
    )
}

const ARM_THREAD_STATE64: u32 = 6;
const ARM_THREAD_STATE64_COUNT: u32 = 68;
const ARM_NEON_STATE64: u32 = 17;
const ARM_NEON_STATE64_COUNT: u32 = 130;
/// __DARWIN_ARM_THREAD_STATE64_FLAGS_NO_PTRAUTH: pc/lr/sp/fp are plain pointers.
const NO_PTRAUTH: u32 = 1;

/// thread_get_state for a guest thread: the words of the requested flavor, or None if the
/// port isn't a guest thread (the caller falls back to its old behaviour).
pub fn get_state(port: u32, flavor: u32, max_count: u32) -> Option<Result<Vec<u32>, u32>> {
    let t = lookup(port)?;
    let cpu = unsafe { &*t.cpu };
    let mut w: Vec<u32> = Vec::new();
    let mut put64 = |v: u64| {
        w.push(v as u32);
        w.push((v >> 32) as u32);
    };
    match flavor {
        ARM_THREAD_STATE64 if max_count >= ARM_THREAD_STATE64_COUNT => {
            for i in 0..29 {
                put64(cpu.x[i]);
            }
            put64(cpu.x[29]); // fp
            put64(cpu.x[30]); // lr
            put64(cpu.x[31]); // sp
            put64(cpu.pc);
            let nzcv = (cpu.nf as u32) << 31 | (cpu.zf as u32) << 30 | (cpu.cf as u32) << 29 | (cpu.vf as u32) << 28;
            w.push(nzcv);
            w.push(NO_PTRAUTH);
        }
        ARM_NEON_STATE64 if max_count >= ARM_NEON_STATE64_COUNT => {
            for v in &cpu.v {
                put64(v[0]);
                put64(v[1]);
            }
            w.push(cpu.fpsr as u32);
            w.push(cpu.fpcr as u32);
        }
        ARM_THREAD_STATE64 | ARM_NEON_STATE64 => return Some(Err(4)), // KERN_INVALID_ARGUMENT
        _ => return Some(Err(4)),
    }
    Some(Ok(w))
}
