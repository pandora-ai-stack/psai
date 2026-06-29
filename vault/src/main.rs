// stack-vault — psai secrets daemon.
//
// Secrets live ONLY in this process's mlock'd memory. The single disk artifact is
// an AES-256-GCM blob (key derived from a passphrase via Argon2id); plaintext never
// touches the SSD. Consumers talk to a Unix socket that is gated by peer credentials
// (same-uid only). A reboot (manual mode) loses the in-memory key → sealed.
//
// Subcommands:
//   serve  --socket P --blob P [--keyfile P]   run the daemon (keyfile = auto-unseal)
//   put KEY            (value on stdin)         store/overwrite a secret
//   get KEY                                     print a secret
//   list | status | ping | seal                introspection / control
//
// Client subcommands read PSAI_VAULT_SOCK (or --socket) and speak the line protocol.
// TPM / Secure-Enclave sealing and an external KMS node are planned (see TODO.md);
// today the key is passphrase-derived (or fetched from the master KMS) and held in
// locked memory. The KMS additionally binds an agent to a hardware fingerprint.

use std::collections::BTreeMap;
use std::env;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::exit;
use std::time::Duration;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use rand::RngCore;
use zeroize::Zeroizing;

const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const KEY_LEN: usize = 32;
// Per-connection IO timeout. A client that connects and never sends a line (or stalls
// mid-write) must not pin a socket forever — without this the single accept loop (Unix
// socket) or the KMS could be hung indefinitely by one peer.
const IO_TIMEOUT: Duration = Duration::from_secs(5);

// Constant-time string compare for KMS token / fingerprint checks, so a network peer
// can't learn the secret byte-by-byte from response timing. Length is not secret.
fn ct_eq(a: &str, b: &str) -> bool {
    use subtle::ConstantTimeEq;
    let (a, b) = (a.as_bytes(), b.as_bytes());
    a.len() == b.len() && a.ct_eq(b).into()
}

type Store = BTreeMap<String, SecretBytes>;
type R<T> = Result<T, String>;

// ───────────────────── secret memory (memfd_secret) ─────────────────────
// Each secret value is held in a memfd_secret region when the kernel supports it
// (Linux 5.14+ with CONFIG_SECRETMEM). Those pages are removed from the kernel's direct
// map: /dev/mem, /proc/kcore, swap, and ptrace/process_vm_readv (via get_user_pages) all
// can't reach them — even as root. If secretmem isn't available (older kernel, macOS),
// it falls back to an mlock'd heap allocation (no swap, no core dump). Single-threaded
// daemon, so the raw pointer needs no Send/Sync.
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
static SECRETMEM: AtomicU8 = AtomicU8::new(0); // 0 unknown, 1 yes, 2 no

// Did the process-wide mlockall() succeed? If so, the mlock fallback's heap pages are
// already pinned (MCL_FUTURE covers new allocations). If not, each fallback buffer is
// mlock'd individually; LOCK_FAILED records that even that didn't take — so STATUS can
// say mem=unlocked instead of falsely claiming mem=mlock.
static MLOCKALL_OK: AtomicBool = AtomicBool::new(false);
static LOCK_FAILED: AtomicBool = AtomicBool::new(false);

// __NR_memfd_secret = 447 on x86_64 and on the asm-generic table (aarch64, riscv, ...).
#[cfg(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
fn memfd_secret_nr() -> Option<libc::c_long> {
    Some(447)
}
#[cfg(all(
    target_os = "linux",
    not(any(target_arch = "x86_64", target_arch = "aarch64"))
))]
fn memfd_secret_nr() -> Option<libc::c_long> {
    None
}

// Create a memfd_secret fd (Linux only; the raw syscall number differs by arch).
#[cfg(target_os = "linux")]
fn secretmem_create() -> libc::c_int {
    match memfd_secret_nr() {
        Some(nr) => unsafe { libc::syscall(nr, 0 as libc::c_uint) as libc::c_int },
        None => -1,
    }
}
#[cfg(not(target_os = "linux"))]
fn secretmem_create() -> libc::c_int {
    -1
}

fn secretmem_ok() -> bool {
    match SECRETMEM.load(Ordering::Relaxed) {
        1 => true,
        2 => false,
        _ => {
            let fd = secretmem_create();
            let ok = fd >= 0;
            if ok {
                unsafe {
                    libc::close(fd);
                }
            }
            SECRETMEM.store(if ok { 1 } else { 2 }, Ordering::Relaxed);
            ok
        }
    }
}
// Honest backing label. secretmem is per-secret and independent of mlock. Otherwise we
// only claim "mlock" if locking actually held; if it failed the secrets are pageable.
fn mem_backing() -> &'static str {
    if secretmem_ok() {
        "secretmem"
    } else if LOCK_FAILED.load(Ordering::Relaxed) {
        "unlocked"
    } else {
        "mlock"
    }
}

enum SecretBytes {
    Secret {
        ptr: *mut u8,
        len: usize,
        map_len: usize,
        fd: libc::c_int,
    },
    Locked(Zeroizing<Vec<u8>>),
}
impl SecretBytes {
    fn new(data: Vec<u8>) -> Self {
        let len = data.len();
        if len > 0 && secretmem_ok() {
            let fd = secretmem_create();
            if fd >= 0 {
                let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as usize;
                let map_len = len.div_ceil(page) * page;
                if unsafe { libc::ftruncate(fd, map_len as libc::off_t) } == 0 {
                    let p = unsafe {
                        libc::mmap(
                            std::ptr::null_mut(),
                            map_len,
                            libc::PROT_READ | libc::PROT_WRITE,
                            libc::MAP_SHARED,
                            fd,
                            0,
                        )
                    };
                    if p != libc::MAP_FAILED {
                        unsafe {
                            std::ptr::copy_nonoverlapping(data.as_ptr(), p as *mut u8, len);
                        }
                        drop(Zeroizing::new(data)); // wipe the heap copy
                        return SecretBytes::Secret {
                            ptr: p as *mut u8,
                            len,
                            map_len,
                            fd,
                        };
                    }
                    unsafe {
                        libc::close(fd);
                    }
                } else {
                    unsafe {
                        libc::close(fd);
                    }
                }
            }
        }
        // mlock fallback. If the process-wide mlockall() succeeded, MCL_FUTURE already
        // pinned this allocation; otherwise lock it explicitly and record any failure so
        // STATUS reports mem=unlocked rather than pretending the bytes are pinned.
        let z = Zeroizing::new(data);
        if len > 0 && !MLOCKALL_OK.load(Ordering::Relaxed) {
            let rc = unsafe { libc::mlock(z.as_ptr() as *const libc::c_void, len) };
            if rc != 0 {
                LOCK_FAILED.store(true, Ordering::Relaxed);
            }
        }
        SecretBytes::Locked(z)
    }
    fn as_slice(&self) -> &[u8] {
        match self {
            SecretBytes::Secret { ptr, len, .. } => unsafe {
                std::slice::from_raw_parts(*ptr, *len)
            },
            SecretBytes::Locked(v) => v.as_slice(),
        }
    }
}
impl Drop for SecretBytes {
    fn drop(&mut self) {
        match self {
            SecretBytes::Secret {
                ptr,
                len,
                map_len,
                fd,
            } => unsafe {
                std::ptr::write_bytes(*ptr, 0, *len); // wipe before unmap
                libc::munmap(*ptr as *mut libc::c_void, *map_len);
                libc::close(*fd);
            },
            // Zeroizing wipes the bytes; release the explicit lock (best-effort).
            SecretBytes::Locked(v) => unsafe {
                if !v.is_empty() {
                    libc::munlock(v.as_ptr() as *const libc::c_void, v.len());
                }
            },
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let rc = match args.get(1).map(|s| s.as_str()) {
        Some("serve") => cmd_serve(&args[2..]),
        Some("kms") => cmd_kms(&args[2..]),
        Some("put") => cmd_put(&args[2..]),
        Some("get") => cmd_client(&args[2..], "GET", true),
        Some("del") => cmd_client(&args[2..], "DEL", false),
        Some("list") => cmd_client(&args[2..], "LIST", false),
        Some("status") => cmd_client(&args[2..], "STATUS", false),
        Some("ping") => cmd_client(&args[2..], "PING", false),
        Some("seal") => cmd_client(&args[2..], "SEAL", false),
        Some("reseal") => cmd_reseal(&args[2..]),
        Some("fingerprint") => cmd_fingerprint(),
        _ => {
            eprintln!("stack-vault {}", env!("CARGO_PKG_VERSION"));
            eprintln!("usage: stack-vault serve --socket P --blob P [--keyfile P | --kms ADDR --kms-id N --kms-token[-file] X]");
            eprintln!("       stack-vault kms --listen IP:PORT --socket P     (master: serve agent unseal keys)");
            eprintln!("       stack-vault reseal --socket P                   (rotate passphrase; new one on PSAI_VAULT_NEWPASS/stdin)");
            eprintln!("       stack-vault fingerprint                         (agent hardware/instance id)");
            eprintln!(
                "       stack-vault put|get|del KEY | list | status | ping | seal   [--socket P]"
            );
            Err("unknown subcommand".into())
        }
    };
    if let Err(e) = rc {
        eprintln!("stack-vault: {e}");
        exit(1);
    }
}

// ───────────────────────── arg helpers ─────────────────────────
fn flag(args: &[String], name: &str) -> Option<String> {
    let mut i = 0;
    while i < args.len() {
        if args[i] == name {
            return args.get(i + 1).cloned();
        }
        i += 1;
    }
    None
}
fn sock_path(args: &[String]) -> R<String> {
    flag(args, "--socket")
        .or_else(|| env::var("PSAI_VAULT_SOCK").ok())
        .ok_or_else(|| "no socket (set --socket or PSAI_VAULT_SOCK)".into())
}

// ───────────────────────── crypto ─────────────────────────
fn derive_key(pass: &[u8], salt: &[u8]) -> R<Zeroizing<[u8; KEY_LEN]>> {
    use argon2::Argon2;
    let mut key = Zeroizing::new([0u8; KEY_LEN]);
    Argon2::default()
        .hash_password_into(pass, salt, &mut key[..])
        .map_err(|e| format!("argon2: {e}"))?;
    Ok(key)
}

fn serialize(store: &Store) -> Zeroizing<Vec<u8>> {
    let mut out = String::new();
    for (k, v) in store {
        out.push_str(k);
        out.push('\t');
        out.push_str(&B64.encode(v.as_slice()));
        out.push('\n');
    }
    Zeroizing::new(out.into_bytes())
}
fn deserialize(buf: &[u8]) -> R<Store> {
    let mut store = Store::new();
    for line in buf.split(|&b| b == b'\n') {
        if line.is_empty() {
            continue;
        }
        let s = std::str::from_utf8(line).map_err(|_| "blob utf8")?;
        let (k, b64) = s.split_once('\t').ok_or("blob format")?;
        let v = B64.decode(b64).map_err(|_| "blob base64")?;
        store.insert(k.to_string(), SecretBytes::new(v));
    }
    Ok(store)
}

fn write_blob(path: &str, pass: &[u8], store: &Store) -> R<()> {
    let mut salt = [0u8; SALT_LEN];
    let mut nonce = [0u8; NONCE_LEN];
    rand::thread_rng().fill_bytes(&mut salt);
    rand::thread_rng().fill_bytes(&mut nonce);
    let key = derive_key(pass, &salt)?;
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key[..]));
    let pt = serialize(store);
    let ct = cipher
        .encrypt(Nonce::from_slice(&nonce), pt.as_slice())
        .map_err(|_| "encrypt")?;
    let mut out = Vec::with_capacity(SALT_LEN + NONCE_LEN + ct.len());
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    let tmp = format!("{path}.tmp");
    std::fs::write(&tmp, &out).map_err(|e| format!("write blob: {e}"))?;
    set_mode_600(&tmp);
    std::fs::rename(&tmp, path).map_err(|e| format!("rename blob: {e}"))?;
    Ok(())
}
fn read_blob(path: &str, pass: &[u8]) -> R<Store> {
    let data = std::fs::read(path).map_err(|e| format!("read blob: {e}"))?;
    if data.len() < SALT_LEN + NONCE_LEN {
        return Err("blob too short".into());
    }
    let (salt, rest) = data.split_at(SALT_LEN);
    let (nonce, ct) = rest.split_at(NONCE_LEN);
    let key = derive_key(pass, salt)?;
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key[..]));
    let pt = cipher
        .decrypt(Nonce::from_slice(nonce), ct)
        .map_err(|_| "decrypt (wrong passphrase?)")?;
    deserialize(&Zeroizing::new(pt))
}

// ───────────────────────── hardening ─────────────────────────
fn harden_memory() {
    unsafe {
        let skip_mlock = env::var("PSAI_VAULT_SKIP_MLOCK")
            .map(|v| v == "1" || v == "true")
            .unwrap_or(false);
        if skip_mlock {
            MLOCKALL_OK.store(false, Ordering::Relaxed);
        } else {
            // Raise the memlock soft limit to the hard limit so mlockall(MCL_FUTURE) +
            // Argon2's ~19 MB working buffer don't hit a low default (common in containers).
            let mut rl = libc::rlimit {
                rlim_cur: 0,
                rlim_max: 0,
            };
            if libc::getrlimit(libc::RLIMIT_MEMLOCK, &mut rl) == 0 {
                rl.rlim_cur = rl.rlim_max;
                libc::setrlimit(libc::RLIMIT_MEMLOCK, &rl);
            }
            // Pin all pages in RAM (no swap). Record whether it actually held; SecretBytes
            // falls back to per-buffer mlock and STATUS reports mem=unlocked if even that fails.
            MLOCKALL_OK.store(
                libc::mlockall(libc::MCL_CURRENT | libc::MCL_FUTURE) == 0,
                Ordering::Relaxed,
            );
        }
        // Disable core dumps so secrets can't leak.
        let lim = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        libc::setrlimit(libc::RLIMIT_CORE, &lim);
        // Non-dumpable: blocks ptrace / /proc/<pid>/mem from non-root. (Root still needs
        // Yama ptrace_scope=3 to be fully locked out; memfd_secret covers the rest.)
        #[cfg(target_os = "linux")]
        libc::prctl(libc::PR_SET_DUMPABLE, 0);
    }
}
fn set_mode_600(path: &str) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
}

#[cfg(target_os = "linux")]
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    use std::os::unix::io::AsRawFd;
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let r = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut cred as *mut _ as *mut libc::c_void,
            &mut len,
        )
    };
    if r == 0 {
        Some(cred.uid)
    } else {
        None
    }
}
#[cfg(target_os = "macos")]
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    use std::os::unix::io::AsRawFd;
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    let r = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    if r == 0 {
        Some(uid)
    } else {
        None
    }
}

// ───────────────────────── passphrase ─────────────────────────
fn load_passphrase(args: &[String]) -> R<Zeroizing<Vec<u8>>> {
    // KMS unseal: fetch the passphrase from the master vault's KMS over the WG tunnel.
    if let Some(addr) = flag(args, "--kms") {
        let id = flag(args, "--kms-id").unwrap_or_else(|| "0".into());
        let token = match flag(args, "--kms-token") {
            Some(t) => t,
            None => match flag(args, "--kms-token-file") {
                Some(f) => std::fs::read_to_string(&f)
                    .map_err(|e| format!("kms token file: {e}"))?
                    .trim()
                    .to_string(),
                None => String::new(),
            },
        };
        return kms_fetch(&addr, &id, &token);
    }
    if let Some(kf) = flag(args, "--keyfile") {
        let p = std::fs::read(&kf).map_err(|e| format!("keyfile: {e}"))?;
        let trimmed = p
            .iter()
            .rev()
            .skip_while(|&&b| b == b'\n' || b == b'\r')
            .count();
        return Ok(Zeroizing::new(p[..trimmed].to_vec()));
    }
    if let Ok(p) = env::var("PSAI_VAULT_PASS") {
        return Ok(Zeroizing::new(p.into_bytes()));
    }
    // stdin (manual mode)
    let mut s = String::new();
    std::io::stdin()
        .read_line(&mut s)
        .map_err(|e| format!("stdin: {e}"))?;
    Ok(Zeroizing::new(
        s.trim_end_matches(['\n', '\r']).as_bytes().to_vec(),
    ))
}

// ───────────────────────── daemon ─────────────────────────
fn cmd_serve(args: &[String]) -> R<()> {
    harden_memory();
    let socket = sock_path(args)?;
    let blob = flag(args, "--blob").ok_or("no --blob")?;
    let mut pass = load_passphrase(args)?; // mutable: RESEAL rotates it in place

    let mut store: Store = if Path::new(&blob).exists() {
        read_blob(&blob, &pass)?
    } else {
        let s = Store::new();
        write_blob(&blob, &pass, &s)?; // seal an empty store so future restarts can unseal
        s
    };

    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).map_err(|e| format!("bind: {e}"))?;
    set_mode_600(&socket);
    let me = unsafe { libc::geteuid() };
    // Same-uid only by default. The clients (secret_get/vault_get/put, KMS) always run as
    // the user that started the daemon, so root acceptance is not needed for normal
    // operation — and on a root-compromised host it would let any root process read every
    // secret straight off the socket (memfd_secret only stops memory scraping, not this).
    // Opt back in with PSAI_VAULT_ALLOW_ROOT=1 if the daemon runs as a non-root user and a
    // root admin tool must query it.
    let allow_root = env::var("PSAI_VAULT_ALLOW_ROOT")
        .map(|v| v == "1" || v == "true")
        .unwrap_or(false);
    eprintln!(
        "stack-vault: serving on {socket} ({} secrets, {}{})",
        store.len(),
        mem_backing(),
        if allow_root { ", +root" } else { "" }
    );

    for conn in listener.incoming() {
        let stream = match conn {
            Ok(s) => s,
            Err(_) => continue,
        };
        let _ = stream.set_read_timeout(Some(IO_TIMEOUT));
        let _ = stream.set_write_timeout(Some(IO_TIMEOUT));
        match peer_uid(&stream) {
            Some(uid) if uid == me || (allow_root && uid == 0) => {}
            _ => {
                // Reject any caller that is not us (the peer-cred gate).
                continue;
            }
        }
        if handle(stream, &mut store, &blob, &mut pass) {
            break; // a SEAL that asked us to exit
        }
    }
    Ok(())
}

// Returns true to stop the daemon.
fn handle(
    stream: UnixStream,
    store: &mut Store,
    blob: &str,
    pass: &mut Zeroizing<Vec<u8>>,
) -> bool {
    let mut reader = BufReader::new(match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return false,
    });
    let mut w = stream;
    let mut line = String::new();
    if reader.read_line(&mut line).is_err() {
        return false;
    }
    let line = line.trim_end();
    let mut it = line.splitn(3, ' ');
    let cmd = it.next().unwrap_or("");
    let resp: String = match cmd {
        "PING" => "OK pong".into(),
        "STATUS" => format!("OK unsealed count={} mem={}", store.len(), mem_backing()),
        "LIST" => {
            let keys: Vec<&str> = store.keys().map(|s| s.as_str()).collect();
            format!("OK {}", keys.join(" "))
        }
        "GET" => match it.next() {
            Some(k) => match store.get(k) {
                Some(v) => format!("OK {}", B64.encode(v.as_slice())),
                None => "ERR notfound".into(),
            },
            None => "ERR usage".into(),
        },
        "PUT" => match (it.next(), it.next()) {
            (Some(k), Some(b64)) => match B64.decode(b64) {
                Ok(v) => {
                    store.insert(k.to_string(), SecretBytes::new(v));
                    match write_blob(blob, &pass[..], store) {
                        Ok(_) => "OK".into(),
                        Err(e) => format!("ERR {e}"),
                    }
                }
                Err(_) => "ERR base64".into(),
            },
            _ => "ERR usage".into(),
        },
        "DEL" => match it.next() {
            Some(k) => {
                store.remove(k);
                match write_blob(blob, &pass[..], store) {
                    Ok(_) => "OK".into(),
                    Err(e) => format!("ERR {e}"),
                }
            }
            None => "ERR usage".into(),
        },
        // RESEAL: re-encrypt the current store under a NEW passphrase and adopt it, so
        // future writes/unseals use the new key. Rotates the on-disk blob without
        // changing any secret values — the basis for agent key rotation.
        "RESEAL" => match it.next() {
            Some(b64) => match B64.decode(b64) {
                Ok(newpass) => match write_blob(blob, &newpass, store) {
                    Ok(_) => {
                        *pass = Zeroizing::new(newpass);
                        "OK".into()
                    }
                    Err(e) => format!("ERR {e}"),
                },
                Err(_) => "ERR base64".into(),
            },
            None => "ERR usage".into(),
        },
        "SEAL" => {
            // Persist, wipe memory, exit. Clearing drops each SecretBytes, which zeroes
            // (and munmaps the secretmem region). The blob remains for the next unseal.
            let _ = write_blob(blob, &pass[..], store);
            store.clear();
            let _ = writeln!(w, "OK");
            return true;
        }
        _ => "ERR unknown".into(),
    };
    let _ = writeln!(w, "{resp}");
    false
}

// ───────────────────────── client ─────────────────────────
fn cmd_put(args: &[String]) -> R<()> {
    let key = args
        .iter()
        .find(|a| !a.starts_with("--"))
        .ok_or("usage: put KEY  (value on stdin)")?;
    let mut val = Vec::new();
    std::io::stdin()
        .read_to_end(&mut val)
        .map_err(|e| format!("stdin: {e}"))?;
    // strip a single trailing newline so `echo x | put` stores "x"
    if val.last() == Some(&b'\n') {
        val.pop();
    }
    let cmd = format!("PUT {} {}", key, B64.encode(&val));
    let resp = send(&sock_path(args)?, &cmd)?;
    if resp.starts_with("OK") {
        Ok(())
    } else {
        Err(resp)
    }
}

// Rotate the vault passphrase: the new one comes from PSAI_VAULT_NEWPASS or stdin. The
// running daemon re-encrypts its blob under the new key and adopts it (RESEAL).
fn cmd_reseal(args: &[String]) -> R<()> {
    let newpass: Vec<u8> = match env::var("PSAI_VAULT_NEWPASS") {
        Ok(p) if !p.is_empty() => p.into_bytes(),
        _ => {
            let mut s = String::new();
            std::io::stdin()
                .read_line(&mut s)
                .map_err(|e| format!("stdin: {e}"))?;
            s.trim_end_matches(['\n', '\r']).as_bytes().to_vec()
        }
    };
    if newpass.is_empty() {
        return Err("empty new passphrase".into());
    }
    let resp = send(
        &sock_path(args)?,
        &format!("RESEAL {}", B64.encode(&newpass)),
    )?;
    if resp.starts_with("OK") {
        Ok(())
    } else {
        Err(resp)
    }
}

fn cmd_client(args: &[String], verb: &str, decode: bool) -> R<()> {
    let key = args.iter().find(|a| !a.starts_with("--"));
    let cmd = match key {
        Some(k) => format!("{verb} {k}"),
        None => verb.to_string(),
    };
    let resp = send(&sock_path(args)?, &cmd)?;
    let body = resp.strip_prefix("OK ").or_else(|| resp.strip_prefix("OK"));
    match body {
        Some(b) => {
            let b = b.trim();
            if decode && !b.is_empty() {
                let v = B64.decode(b).map_err(|_| "bad base64 from daemon")?;
                std::io::stdout().write_all(&v).ok();
            } else if !b.is_empty() {
                println!("{b}");
            }
            Ok(())
        }
        None => Err(resp),
    }
}

fn send(socket: &str, cmd: &str) -> R<String> {
    let mut s = UnixStream::connect(socket).map_err(|e| format!("connect {socket}: {e}"))?;
    writeln!(s, "{cmd}").map_err(|e| format!("write: {e}"))?;
    let mut resp = String::new();
    BufReader::new(s)
        .read_line(&mut resp)
        .map_err(|e| format!("read: {e}"))?;
    Ok(resp.trim_end().to_string())
}

// ───────────────────────── hardware fingerprint ─────────────────────────
// Identity binding for an agent worker node. Combines identifiers that a raw disk
// image does NOT carry — chiefly the SMBIOS/DMI product UUID, which the hypervisor
// assigns per VM instance — so a cloned disk booted on different VPS hardware yields a
// different fingerprint and is refused by the KMS. Reading product_uuid needs root;
// without it we fall back to the machine-id (binds to the OS install — weaker against
// a same-host clone). Best-effort and deterministic so provision-time and unseal-time
// agree as long as the daemon runs in the same privilege both times.
fn read_trim(path: &str) -> String {
    std::fs::read_to_string(path)
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}
fn hw_fingerprint() -> String {
    let mut parts: Vec<String> = Vec::new();
    for p in [
        "/sys/class/dmi/id/product_uuid", // hypervisor-assigned, not on the disk image
        "/sys/class/dmi/id/board_serial",
        "/sys/class/dmi/id/product_serial",
    ] {
        let v = read_trim(p);
        if !v.is_empty() {
            parts.push(format!("dmi:{v}"));
        }
    }
    for p in ["/etc/machine-id", "/var/lib/dbus/machine-id"] {
        let v = read_trim(p);
        if !v.is_empty() {
            parts.push(format!("mid:{v}"));
            break;
        }
    }
    if let Some(l) = read_trim("/proc/cpuinfo")
        .lines()
        .find(|l| l.starts_with("model name"))
    {
        if let Some(v) = l.split(':').nth(1) {
            parts.push(format!("cpu:{}", v.trim()));
        }
    }
    if parts.is_empty() {
        // macOS / no-DMI fallback (local dev only; agents are Linux VMs).
        parts.push(format!("host:{}", read_trim("/etc/hostname")));
    }
    sha256(parts.join("\n").as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

// Minimal SHA-256 (FIPS 180-4), self-contained so the daemon builds offline with no
// extra crates. Used only to derive the hardware-fingerprint identifier.
fn sha256(data: &[u8]) -> [u8; 32] {
    #[rustfmt::skip]
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let bitlen = (data.len() as u64).wrapping_mul(8);
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bitlen.to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[4 * i],
                chunk[4 * i + 1],
                chunk[4 * i + 2],
                chunk[4 * i + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (dst, v) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *dst = dst.wrapping_add(v);
        }
    }
    let mut out = [0u8; 32];
    for i in 0..8 {
        out[4 * i..4 * i + 4].copy_from_slice(&h[i].to_be_bytes());
    }
    out
}
fn cmd_fingerprint() -> R<()> {
    println!("{}", hw_fingerprint());
    Ok(())
}

// ───────────────────────── KMS (master-side) ─────────────────────────
// The master vault holds each agent's unseal key (agent_unseal_<id>), an auth token
// (kms_token_<id>), and a hardware fingerprint (agent_fp_<id>). `kms` is a thin TCP
// front, meant to bind to the WireGuard IP only: a request "GET <id> <token> <fp>" is
// validated against BOTH the token and the registered fingerprint in the LOCAL vault,
// then the unseal key is returned. The WG tunnel provides transport encryption + peer
// auth; the fingerprint binds the key to that agent's hardware (anti disk-clone).
fn cmd_kms(args: &[String]) -> R<()> {
    let listen = flag(args, "--listen").ok_or("no --listen (expected <ip:port>)")?;
    let vsock = sock_path(args)?;
    let listener = TcpListener::bind(&listen).map_err(|e| format!("bind {listen}: {e}"))?;
    eprintln!("stack-vault kms: serving on {listen} (vault {vsock})");
    for conn in listener.incoming() {
        if let Ok(stream) = conn {
            let _ = stream.set_read_timeout(Some(IO_TIMEOUT));
            let _ = stream.set_write_timeout(Some(IO_TIMEOUT));
            // One thread per connection so a slow/stalled peer can't block unseal for every
            // other agent (the read timeout bounds each one regardless).
            let vsock = vsock.clone();
            std::thread::spawn(move || {
                let _ = handle_kms(stream, &vsock);
            });
        }
    }
    Ok(())
}

fn handle_kms(stream: TcpStream, vsock: &str) -> R<()> {
    let mut reader = BufReader::new(stream.try_clone().map_err(|e| e.to_string())?);
    let mut w = stream;
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|e| e.to_string())?;
    let line = line.trim();
    let mut it = line.splitn(4, ' ');
    let cmd = it.next().unwrap_or("");
    let id = it.next().unwrap_or("");
    let token = it.next().unwrap_or("");
    let fp = it.next().unwrap_or("").trim();
    if cmd != "GET" || id.is_empty() {
        let _ = writeln!(w, "ERR usage");
        return Ok(());
    }
    let want = vault_local_get(vsock, &format!("kms_token_{id}")).unwrap_or_default();
    if want.is_empty() || !ct_eq(&want, token) {
        let _ = writeln!(w, "ERR denied");
        return Ok(());
    }
    // Hardware binding: if a fingerprint was registered for this agent, the caller must
    // present a matching one. A disk clone on different VPS hardware fails this check.
    let want_fp = vault_local_get(vsock, &format!("agent_fp_{id}")).unwrap_or_default();
    if !want_fp.is_empty() && !ct_eq(&want_fp, fp) {
        let _ = writeln!(w, "ERR denied-hwid");
        return Ok(());
    }
    let key = vault_local_get(vsock, &format!("agent_unseal_{id}")).unwrap_or_default();
    if key.is_empty() {
        let _ = writeln!(w, "ERR notfound");
        return Ok(());
    }
    let _ = writeln!(w, "OK {}", B64.encode(key.as_bytes()));
    Ok(())
}

// Read a secret from the LOCAL vault over its Unix socket; returns the plaintext value.
fn vault_local_get(vsock: &str, key: &str) -> R<String> {
    let resp = send(vsock, &format!("GET {key}"))?;
    match resp.strip_prefix("OK ") {
        Some(b64) => {
            let bytes = B64.decode(b64.trim()).map_err(|_| "kms vault b64")?;
            Ok(String::from_utf8_lossy(&bytes).to_string())
        }
        None => Err(resp),
    }
}

// Agent-side: fetch the unseal passphrase from the master KMS over the WG tunnel.
fn kms_fetch(addr: &str, id: &str, token: &str) -> R<Zeroizing<Vec<u8>>> {
    let mut s = TcpStream::connect(addr).map_err(|e| format!("kms connect {addr}: {e}"))?;
    let fp = hw_fingerprint();
    writeln!(s, "GET {id} {token} {fp}").map_err(|e| e.to_string())?;
    let mut resp = String::new();
    BufReader::new(s)
        .read_line(&mut resp)
        .map_err(|e| e.to_string())?;
    let resp = resp.trim();
    match resp.strip_prefix("OK ") {
        Some(b64) => Ok(Zeroizing::new(
            B64.decode(b64.trim()).map_err(|_| "kms b64")?,
        )),
        None => Err(format!("kms unseal: {resp}")),
    }
}
