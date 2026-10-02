//! The guest's own code signature, as the guest sees it through `csops`.
//!
//! The kernel only knows maclator's signature, so a guest asking about itself (`csops(getpid(), …)`)
//! would be told it has no entitlements and is called "maclator". Frameworks check their caller's
//! entitlements this way and some trap when one is missing: CloudKit's `os_crash` when
//! `com.apple.developer.icloud-services` is absent kills Pages, Numbers and Keynote at launch.
//! So for the guest's own pid, the entitlement, identity and team-ID queries are answered from the
//! guest executable's signature. Daemons that check the guest through its audit token still see
//! maclator.
//!
//! `com.apple.security.app-sandbox` is removed: if the guest saw it, libsystem_secinit would ask
//! secinitd to sandbox the process, and secinitd (which checks maclator's real signature) refuses.

use crate::macho::MachO;
use std::io::{Read, Seek, SeekFrom};
use std::sync::OnceLock;

const LC_CODE_SIGNATURE: u32 = 0x1d;
const CSMAGIC_EMBEDDED_SIGNATURE: u32 = 0xfade_0cc0;
const CSMAGIC_EMBEDDED_ENTITLEMENTS: u32 = 0xfade_7171;
const CSMAGIC_EMBEDDED_DER_ENTITLEMENTS: u32 = 0xfade_7172;
const CSSLOT_CODEDIRECTORY: u32 = 0;
const CSSLOT_ENTITLEMENTS: u32 = 5;
const CSSLOT_DER_ENTITLEMENTS: u32 = 7;

const CS_OPS_ENTITLEMENTS_BLOB: u64 = 7;
const CS_OPS_IDENTITY: u64 = 11;
const CS_OPS_TEAMID: u64 = 14;
const CS_OPS_DER_ENTITLEMENTS_BLOB: u64 = 16;

const SANDBOX_KEY: &str = "com.apple.security.app-sandbox";

#[derive(Default)]
struct Signature {
    /// Whole blobs (magic + length + payload), as csops returns them.
    xml: Option<Vec<u8>>,
    der: Option<Vec<u8>>,
    identity: Option<String>,
    team: Option<String>,
}

static GUEST: OnceLock<Signature> = OnceLock::new();

fn be32(b: &[u8], o: usize) -> Option<u32> {
    Some(u32::from_be_bytes(b.get(o..o + 4)?.try_into().ok()?))
}

fn cstr_at(b: &[u8], o: usize) -> Option<String> {
    let s = b.get(o..)?;
    let end = s.iter().position(|&c| c == 0)?;
    Some(String::from_utf8_lossy(&s[..end]).into_owned())
}

/// Read the signature of the main executable's arm64 slice. Call once, before the guest runs.
pub fn load(path: &str, m: &MachO) {
    let sig = read(path, m).unwrap_or_default();
    if crate::syscalls::TRACE.load(std::sync::atomic::Ordering::Relaxed) {
        eprintln!(
            "[maclator] guest signature: identity={:?} team={:?} entitlements={}/{} bytes (xml/der)",
            sig.identity,
            sig.team,
            sig.xml.as_ref().map_or(0, Vec::len),
            sig.der.as_ref().map_or(0, Vec::len)
        );
    }
    let _ = GUEST.set(sig);
}

fn read(path: &str, m: &MachO) -> Option<Signature> {
    // Find LC_CODE_SIGNATURE in the load commands (they follow the 32-byte mach_header_64).
    let h = &m.header_bytes;
    let ncmds = u32::from_le_bytes(h.get(16..20)?.try_into().ok()?) as usize;
    let mut off = 32;
    let mut cs = None;
    for _ in 0..ncmds {
        let cmd = u32::from_le_bytes(h.get(off..off + 4)?.try_into().ok()?);
        let size = u32::from_le_bytes(h.get(off + 4..off + 8)?.try_into().ok()?) as usize;
        if cmd == LC_CODE_SIGNATURE {
            let dataoff = u32::from_le_bytes(h.get(off + 8..off + 12)?.try_into().ok()?);
            let datasize = u32::from_le_bytes(h.get(off + 12..off + 16)?.try_into().ok()?);
            cs = Some((dataoff as u64, datasize as usize));
        }
        off += size.max(8);
    }
    let (dataoff, datasize) = cs?;
    let mut f = std::fs::File::open(path).ok()?;
    f.seek(SeekFrom::Start(m.slice_offset + dataoff)).ok()?;
    let mut blob = vec![0u8; datasize];
    f.read_exact(&mut blob).ok()?;
    if be32(&blob, 0)? != CSMAGIC_EMBEDDED_SIGNATURE {
        return None;
    }
    let mut sig = Signature::default();
    for i in 0..be32(&blob, 8)? as usize {
        let (slot, at) = (be32(&blob, 12 + i * 8)?, be32(&blob, 16 + i * 8)? as usize);
        let len = be32(&blob, at + 4)? as usize;
        let Some(b) = blob.get(at..at + len) else { continue };
        match slot {
            CSSLOT_CODEDIRECTORY => {
                // CodeDirectory: identOffset at 20; teamOffset at 48 from version 0x20200.
                sig.identity = cstr_at(b, be32(b, 20)? as usize);
                if be32(b, 8)? >= 0x20200 {
                    let t = be32(b, 48)? as usize;
                    if t != 0 {
                        sig.team = cstr_at(b, t);
                    }
                }
            }
            CSSLOT_ENTITLEMENTS if be32(b, 0)? == CSMAGIC_EMBEDDED_ENTITLEMENTS => {
                sig.xml = Some(blob_of(CSMAGIC_EMBEDDED_ENTITLEMENTS, &strip_xml(&b[8..])));
            }
            CSSLOT_DER_ENTITLEMENTS if be32(b, 0)? == CSMAGIC_EMBEDDED_DER_ENTITLEMENTS => {
                // If the DER can't be rewritten, leave it out: callers fall back to the XML form.
                sig.der = strip_der(&b[8..]).map(|d| blob_of(CSMAGIC_EMBEDDED_DER_ENTITLEMENTS, &d));
            }
            _ => {}
        }
    }
    Some(sig)
}

fn blob_of(magic: u32, payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(payload.len() + 8);
    v.extend_from_slice(&magic.to_be_bytes());
    v.extend_from_slice(&((payload.len() + 8) as u32).to_be_bytes());
    v.extend_from_slice(payload);
    v
}

/// Drop `<key>com.apple.security.app-sandbox</key><true/>` from an XML plist.
fn strip_xml(xml: &[u8]) -> Vec<u8> {
    let s = String::from_utf8_lossy(xml);
    let key = format!("<key>{SANDBOX_KEY}</key>");
    let Some(k) = s.find(&key) else { return xml.to_vec() };
    let rest = &s[k + key.len()..];
    let value_end = ["<true/>", "<false/>"]
        .iter()
        .filter_map(|v| rest.find(v).map(|i| i + v.len()))
        .min()
        .filter(|&e| rest[..e].trim_start().starts_with('<'));
    match value_end {
        Some(e) => format!("{}{}", &s[..k], &rest[e..]).into_bytes(),
        None => xml.to_vec(),
    }
}

// ---- DER entitlements: [APPLICATION 16] { INTEGER version, [CONTEXT 16] { SEQUENCE { UTF8String key, value }... } }

struct Tlv<'a> {
    tag: u8,
    body: &'a [u8],
    len: usize, // whole element
}

fn tlv(b: &[u8]) -> Option<Tlv<'_>> {
    let tag = *b.first()?;
    let first = *b.get(1)? as usize;
    let (n, hdr) = if first < 0x80 {
        (first, 2)
    } else {
        let k = first & 0x7f;
        if k == 0 || k > 4 {
            return None;
        }
        let mut n = 0usize;
        for i in 0..k {
            n = n << 8 | *b.get(2 + i)? as usize;
        }
        (n, 2 + k)
    };
    Some(Tlv { tag, body: b.get(hdr..hdr + n)?, len: hdr + n })
}

fn der_elem(tag: u8, body: &[u8]) -> Vec<u8> {
    let mut v = vec![tag];
    let n = body.len();
    if n < 0x80 {
        v.push(n as u8);
    } else {
        let bytes: Vec<u8> = n.to_be_bytes().iter().copied().skip_while(|&x| x == 0).collect();
        v.push(0x80 | bytes.len() as u8);
        v.extend(bytes);
    }
    v.extend_from_slice(body);
    v
}

fn children(mut b: &[u8]) -> Option<Vec<Tlv<'_>>> {
    let mut out = Vec::new();
    while !b.is_empty() {
        let t = tlv(b)?;
        b = &b[t.len..];
        out.push(t);
    }
    Some(out)
}

/// Rebuild the DER entitlements without the app-sandbox key.
fn strip_der(der: &[u8]) -> Option<Vec<u8>> {
    let outer = tlv(der)?; // 0x70: [APPLICATION 16]
    let parts = children(outer.body)?;
    let mut body = Vec::new();
    for p in parts {
        if p.tag == 0xb0 {
            // [CONTEXT 16]: the dictionary of SEQUENCE { key, value }
            let mut dict = Vec::new();
            for kv in children(p.body)? {
                let key = children(kv.body)?.into_iter().next()?;
                if key.tag == 0x0c && key.body == SANDBOX_KEY.as_bytes() {
                    continue;
                }
                dict.extend(der_elem(kv.tag, kv.body));
            }
            body.extend(der_elem(p.tag, &dict));
        } else {
            body.extend(der_elem(p.tag, p.body));
        }
    }
    Some(der_elem(outer.tag, &body))
}

// ---- csops

/// Copy `data` to the guest the way the kernel's csops_copy_token does: an 8-byte header whose
/// second word is the big-endian length when the buffer is too small (ERANGE), else the data.
fn copy_token(data: Option<&[u8]>, uaddr: u64, usize_: u64) -> Result<(), i32> {
    if usize_ < 8 {
        return Err(libc::ERANGE);
    }
    let mut fake = [0u8; 8];
    let Some(d) = data else {
        unsafe { std::ptr::copy_nonoverlapping(fake.as_ptr(), uaddr as *mut u8, 8) };
        return Ok(());
    };
    fake[4..].copy_from_slice(&(d.len() as u32).to_be_bytes());
    if (usize_ as usize) < d.len() {
        unsafe { std::ptr::copy_nonoverlapping(fake.as_ptr(), uaddr as *mut u8, 8) };
        return Err(libc::ERANGE);
    }
    unsafe { std::ptr::copy_nonoverlapping(d.as_ptr(), uaddr as *mut u8, d.len()) };
    Ok(())
}

/// Identity and team ID: an 8-byte header (length in the second word), then the NUL-terminated string.
fn copy_string(s: Option<&str>, uaddr: u64, usize_: u64) -> Result<(), i32> {
    let Some(s) = s else { return Err(libc::ENOENT) };
    let len = s.len() + 1 + 8;
    if usize_ < 8 {
        return Err(libc::EINVAL);
    }
    let mut fake = [0u8; 8];
    fake[4..].copy_from_slice(&(len as u32).to_be_bytes());
    unsafe { std::ptr::copy_nonoverlapping(fake.as_ptr(), uaddr as *mut u8, 8) };
    if (usize_ as usize) < len {
        return Err(libc::ERANGE);
    }
    unsafe {
        std::ptr::copy_nonoverlapping(s.as_ptr(), (uaddr + 8) as *mut u8, s.len());
        *((uaddr + 8 + s.len() as u64) as *mut u8) = 0;
    }
    Ok(())
}

/// csops / csops_audittoken (pid, ops, useraddr, usersize[, token]) for the guest itself.
/// Returns None when the host should answer (another process, or an op not emulated here).
pub fn csops(pid: u64, ops: u64, uaddr: u64, usize_: u64) -> Option<Result<(), i32>> {
    let me = unsafe { libc::getpid() } as u64;
    if pid != 0 && pid != me {
        return None;
    }
    let sig = GUEST.get()?;
    Some(match ops {
        CS_OPS_ENTITLEMENTS_BLOB => copy_token(sig.xml.as_deref(), uaddr, usize_),
        CS_OPS_DER_ENTITLEMENTS_BLOB => copy_token(sig.der.as_deref(), uaddr, usize_),
        CS_OPS_IDENTITY => copy_string(sig.identity.as_deref(), uaddr, usize_),
        CS_OPS_TEAMID => copy_string(sig.team.as_deref(), uaddr, usize_),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xml_strip() {
        let x = b"<dict><key>com.apple.security.app-sandbox</key>\n\t<true/><key>a</key><true/></dict>";
        assert_eq!(strip_xml(x), b"<dict><key>a</key><true/></dict>".to_vec());
    }

    #[test]
    fn der_strip() {
        let kv = |k: &str| der_elem(0x30, &[der_elem(0x0c, k.as_bytes()), vec![0x01, 0x01, 0xff]].concat());
        let dict = der_elem(0xb0, &[kv(SANDBOX_KEY), kv("com.apple.developer.icloud-services")].concat());
        let der = der_elem(0x70, &[vec![0x02, 0x01, 0x01], dict].concat());
        let want = der_elem(0x70, &[vec![0x02, 0x01, 0x01], der_elem(0xb0, &kv("com.apple.developer.icloud-services"))].concat());
        assert_eq!(strip_der(&der).unwrap(), want);
    }
}
