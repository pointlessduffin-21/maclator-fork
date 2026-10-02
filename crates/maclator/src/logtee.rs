//! A copy of the guest's stdout/stderr in `~/Library/Logs/Maclator/<pid>.log`, so tools (the
//! launcher's Running inspector) can show the output of any program running under maclator,
//! however it was started. The guest's own fds are untouched (isatty, buffering and colours
//! behave as before); successful writes to fd 1 and 2 are appended to the file as well.
//! `MACLATOR_NO_LOG=1` turns it off. Files older than a day are removed at start-up and a file
//! is cut back to empty when it passes `MAX_BYTES`.

use std::sync::atomic::{AtomicI32, AtomicU64, Ordering::Relaxed};

static FD: AtomicI32 = AtomicI32::new(-1);
static BYTES: AtomicU64 = AtomicU64::new(0);
const MAX_BYTES: u64 = 16 << 20;

pub fn dir() -> Option<std::path::PathBuf> {
    Some(std::path::PathBuf::from(std::env::var_os("HOME")?).join("Library/Logs/Maclator"))
}

/// Open this process's log. `command` is the guest command line, written as the first line.
pub fn init(command: &str) {
    if std::env::var_os("MACLATOR_NO_LOG").is_some() {
        return;
    }
    let Some(dir) = dir() else { return };
    let _ = std::fs::create_dir_all(&dir);
    cleanup(&dir);
    open(&dir, command);
}

/// In a forked child: the inherited fd is the parent's log; start our own.
pub fn reopen_after_fork() {
    let old = FD.swap(-1, Relaxed);
    if old < 0 {
        return;
    }
    unsafe { libc::close(old) };
    if let Some(dir) = dir() {
        open(&dir, "(forked)");
    }
}

fn open(dir: &std::path::Path, command: &str) {
    let path = dir.join(format!("{}.log", unsafe { libc::getpid() }));
    let Ok(c) = std::ffi::CString::new(path.to_string_lossy().as_bytes()) else { return };
    let fd = unsafe { libc::open(c.as_ptr(), libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC | libc::O_APPEND | libc::O_CLOEXEC, 0o600) };
    if fd < 0 {
        return;
    }
    FD.store(fd, Relaxed);
    BYTES.store(0, Relaxed);
    note(&format!("# maclator {}: {command}", unsafe { libc::getpid() }));
}

fn cleanup(dir: &std::path::Path) {
    let day = std::time::Duration::from_secs(24 * 3600);
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let old = e.metadata().and_then(|m| m.modified()).map(|t| t.elapsed().map_or(false, |a| a > day)).unwrap_or(false);
        if old && e.path().extension().is_some_and(|x| x == "log") {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

fn append(bytes: &[u8]) {
    let fd = FD.load(Relaxed);
    if fd < 0 || bytes.is_empty() {
        return;
    }
    if BYTES.fetch_add(bytes.len() as u64, Relaxed) > MAX_BYTES {
        unsafe { libc::ftruncate(fd, 0) };
        BYTES.store(0, Relaxed);
        let m = b"[maclator: log cut back to empty at 16 MB]\n";
        unsafe { libc::write(fd, m.as_ptr() as *const libc::c_void, m.len()) };
    }
    unsafe { libc::write(fd, bytes.as_ptr() as *const libc::c_void, bytes.len()) };
}

/// A line from maclator itself (crash reports and the like).
pub fn note(line: &str) {
    append(format!("{line}\n").as_bytes());
}

/// After the guest's write/write_nocancel(fd, buf, n) returned `written` bytes.
pub fn write(fd: u64, buf: u64, written: u64) {
    if (fd == 1 || fd == 2) && buf != 0 && FD.load(Relaxed) >= 0 {
        append(unsafe { std::slice::from_raw_parts(buf as *const u8, written as usize) });
    }
}

/// After the guest's writev(fd, iov, cnt) returned `written` bytes.
pub fn writev(fd: u64, iov: u64, cnt: u64, written: u64) {
    if !(fd == 1 || fd == 2) || iov == 0 || FD.load(Relaxed) < 0 {
        return;
    }
    let mut left = written as usize;
    for i in 0..cnt.min(1024) as usize {
        if left == 0 {
            break;
        }
        let (base, len) = unsafe { (*((iov + i as u64 * 16) as *const u64), *((iov + i as u64 * 16 + 8) as *const u64) as usize) };
        let n = len.min(left);
        if base != 0 {
            append(unsafe { std::slice::from_raw_parts(base as *const u8, n) });
        }
        left -= n;
    }
}
