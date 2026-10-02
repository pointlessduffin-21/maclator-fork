//! Guest path redirection.
//!
//! On an Intel Mac the arm64 dyld shared cache is not installed; the user
//! supplies it (e.g. extracted from an Apple Silicon IPSW of the same macOS
//! version) and points Maclator at it with `--sysroot`. dyld's lookups in the
//! standard cache directories are redirected there.

use std::sync::Mutex;

static CACHE_DIR: Mutex<Option<String>> = Mutex::new(None);

const CACHE_PREFIXES: &[&str] = &[
    "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld",
    "/System/Cryptexes/OS/System/Library/dyld",
    "/System/Library/dyld",
];

pub fn set_cache_dir(d: &str) {
    *CACHE_DIR.lock().unwrap() = Some(d.trim_end_matches('/').to_string());
}

/// If `path` should be redirected, return the replacement.
/// Guest dyld's address range: path lookups made from dyld's own code are treated specially.
static DYLD_RANGE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static DYLD_END: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub fn set_dyld_range(lo: u64, hi: u64) {
    DYLD_RANGE.store(lo, std::sync::atomic::Ordering::Relaxed);
    DYLD_END.store(hi, std::sync::atomic::Ordering::Relaxed);
}

pub fn in_dyld(pc: u64) -> bool {
    use std::sync::atomic::Ordering::Relaxed;
    pc >= DYLD_RANGE.load(Relaxed) && pc < DYLD_END.load(Relaxed)
}

/// An x86-only file at a system library path, as root patches (OpenCore Legacy Patcher) put
/// there. arm64 dyld would take it for an override of the dylib in the shared cache and fail
/// ("incompatible architecture"), so dyld is told it doesn't exist and uses the cache.
pub fn hides_from_dyld(path: &str) -> bool {
    static SEEN: std::sync::Mutex<Option<std::collections::HashMap<String, bool>>> = std::sync::Mutex::new(None);
    if !(path.starts_with("/System/Library/") || path.starts_with("/usr/lib/")) {
        return false;
    }
    if let Some(&v) = SEEN.lock().unwrap().as_ref().and_then(|m| m.get(path)) {
        return v;
    }
    let v = matches!(crate::spawn::arm64_slices(path), Some((false, true)));
    SEEN.lock().unwrap().get_or_insert_with(Default::default).insert(path.to_string(), v);
    v
}

pub fn redirect(path: &str) -> Option<String> {
    let dir = CACHE_DIR.lock().unwrap().clone()?;
    for p in CACHE_PREFIXES {
        if let Some(rest) = path.strip_prefix(p) {
            if rest.is_empty() || rest.starts_with('/') {
                return Some(format!("{dir}{rest}"));
            }
        }
    }
    None
}

pub fn cache_dir() -> Option<String> {
    CACHE_DIR.lock().unwrap().clone()
}

/// Find a directory holding the arm64 dyld shared cache when `--sysroot` was not given:
/// `$MACLATOR_SYSROOT`, then `~/.maclator/sysroot` (a directory, or a file containing one),
/// then any `~/maclator-sysroot/*` subdirectory that has a `dyld_shared_cache_arm64e`.
pub fn discover_sysroot() -> Option<String> {
    let has_cache = |d: &std::path::Path| d.join("dyld_shared_cache_arm64e").is_file();
    if let Ok(d) = std::env::var("MACLATOR_SYSROOT") {
        if has_cache(std::path::Path::new(&d)) {
            return Some(d);
        }
    }
    let home = std::env::var("HOME").ok()?;
    let cfg = std::path::Path::new(&home).join(".maclator/sysroot");
    if cfg.is_dir() && has_cache(&cfg) {
        return Some(cfg.to_string_lossy().into_owned());
    }
    if let Ok(t) = std::fs::read_to_string(&cfg) {
        let p = std::path::PathBuf::from(t.trim());
        if has_cache(&p) {
            return Some(p.to_string_lossy().into_owned());
        }
    }
    let root = std::path::Path::new(&home).join("maclator-sysroot");
    let mut dirs: Vec<_> = std::fs::read_dir(&root).ok()?.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| has_cache(p)).collect();
    dirs.sort();
    dirs.pop().map(|p| p.to_string_lossy().into_owned())
}
