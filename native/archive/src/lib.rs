//! Managed libarchive ownership. Raw pointers stay inside locked NIF dispatch.
#[allow(
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    dead_code,
    clippy::all
)]
mod ffi {
    include!(concat!(env!("OUT_DIR"), "/ffi.rs"));
    pub const AE_IFMT: u32 = ARCHIVE_BIND_AE_IFMT as u32;
    pub const AE_IFBLK: u32 = ARCHIVE_BIND_AE_IFBLK as u32;
    pub const AE_IFCHR: u32 = ARCHIVE_BIND_AE_IFCHR as u32;
    pub const AE_IFDIR: u32 = ARCHIVE_BIND_AE_IFDIR as u32;
    pub const AE_IFIFO: u32 = ARCHIVE_BIND_AE_IFIFO as u32;
    pub const AE_IFLNK: u32 = ARCHIVE_BIND_AE_IFLNK as u32;
    pub const AE_IFREG: u32 = ARCHIVE_BIND_AE_IFREG as u32;
    pub const AE_IFSOCK: u32 = ARCHIVE_BIND_AE_IFSOCK as u32;
}
mod adapters;
mod generated;
mod stat;

// Keep OpenSSL's vendored native link metadata in the final NIF.
extern crate openssl_sys;
use rustler::{Atom, Binary, Encoder, Env, Error, NifResult, OwnedBinary, ResourceArc, Term};
use std::ffi::{c_void, CStr, CString};
use std::ptr::NonNull;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Reader,
    Writer,
    Match,
    Entry,
    Link,
}
#[derive(Default)]
struct Counters {
    freed: AtomicUsize,
}
struct Probe {
    counters: Arc<Counters>,
}
#[rustler::resource_impl]
impl rustler::Resource for Probe {}
struct OwnedHandle {
    ptr: NonNull<c_void>,
    kind: Kind,
    counters: Arc<Counters>,
}
// SAFETY: libarchive handles have no thread affinity; their access is serialized
// by the containing resource mutex. The unique owner is never Sync or Clone.
unsafe impl Send for OwnedHandle {}
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        // SAFETY: unique live allocation, freed before borrowed input/output storage.
        unsafe {
            match self.kind {
                Kind::Entry => ffi::archive_entry_free(self.ptr.as_ptr().cast()),
                Kind::Link => ffi::archive_entry_linkresolver_free(self.ptr.as_ptr().cast()),
                Kind::Match => {
                    ffi::archive_match_free(self.ptr.as_ptr().cast());
                }
                _ => {
                    ffi::archive_free(self.ptr.as_ptr().cast());
                }
            }
        }
        self.counters.freed.fetch_add(1, Ordering::Release);
    }
}
struct State {
    owner: Option<OwnedHandle>,
    counters: Arc<Counters>,
    buffer: Option<Box<[u8]>>,
    used: Box<usize>,
    generation: u64,
    matcher: Option<ResourceArc<Node>>,
    parents: Vec<ResourceArc<Node>>,
}
struct Node {
    id: u64,
    kind: Kind,
    state: Mutex<State>,
}
#[rustler::resource_impl]
impl rustler::Resource for Node {}
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
fn error(reason: &'static str) -> Error {
    Error::RaiseAtom(reason)
}
fn atom<'a>(env: Env<'a>, name: &str) -> NifResult<Term<'a>> {
    Ok(Atom::from_str(env, name)?.encode(env))
}
fn ok(env: Env<'_>) -> NifResult<Term<'_>> {
    atom(env, "ok")
}
fn status(result: i32) -> NifResult<()> {
    match result {
        0 => Ok(()),
        1 => Err(error("ArchiveEof")),
        -10 => Err(error("ArchiveRetry")),
        -20 => Err(error("ArchiveWarn")),
        -30 => Err(error("ArchiveFailed")),
        -40 => Err(error("ArchiveFatal")),
        _ => Err(error("ArchiveFailed")),
    }
}
fn owned<'a>(
    env: Env<'a>,
    ptr: *mut c_void,
    kind: Kind,
    parents: Vec<ResourceArc<Node>>,
) -> NifResult<Term<'a>> {
    let ptr = NonNull::new(ptr).ok_or_else(|| error("ArchiveAllocation"))?;
    let counters = Arc::new(Counters::default());
    Ok(ResourceArc::new(Node {
        id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
        kind,
        state: Mutex::new(State {
            owner: Some(OwnedHandle {
                ptr,
                kind,
                counters: counters.clone(),
            }),
            counters,
            buffer: None,
            used: Box::new(0),
            generation: 0,
            matcher: None,
            parents,
        }),
    })
    .encode(env))
}
fn bytes<'a>(env: Env<'a>, data: &[u8]) -> NifResult<Term<'a>> {
    let mut out = OwnedBinary::new(data.len()).ok_or_else(|| error("ArchiveAllocation"))?;
    out.as_mut_slice().copy_from_slice(data);
    Ok(out.release(env).encode(env))
}
unsafe fn string<'a>(env: Env<'a>, p: *const std::ffi::c_char) -> NifResult<Term<'a>> {
    if p.is_null() {
        return Ok(Option::<u8>::None.encode(env));
    }
    // SAFETY: caller holds the owning resource lock until the C bytes are copied.
    bytes(env, unsafe { CStr::from_ptr(p) }.to_bytes())
}
fn cstring(t: Term<'_>, nullable: bool) -> NifResult<Option<CString>> {
    if nullable && t.is_atom() && t.atom_to_string()? == "nil" {
        return Ok(None);
    }
    let bytes = t.decode::<Binary<'_>>()?;
    Ok(Some(
        CString::new(bytes.as_slice()).map_err(|_| error("EmbeddedNul"))?,
    ))
}
fn cptr(s: &Option<CString>) -> *const std::ffi::c_char {
    s.as_ref().map_or(std::ptr::null(), |s| s.as_ptr())
}
fn wide(t: Term<'_>, nullable: bool) -> NifResult<Option<Vec<libc::wchar_t>>> {
    let s = cstring(t, nullable)?;
    s.map(|s| {
        let utf8 = std::str::from_utf8(s.as_bytes()).map_err(|_| Error::BadArg)?;
        #[cfg(windows)]
        let mut out: Vec<libc::wchar_t> = utf8.encode_utf16().collect();
        #[cfg(not(windows))]
        let mut out: Vec<libc::wchar_t> = utf8.chars().map(|c| c as libc::wchar_t).collect();
        out.push(0);
        Ok(out)
    })
    .transpose()
}
fn wptr(s: &Option<Vec<libc::wchar_t>>) -> *const libc::wchar_t {
    s.as_ref().map_or(std::ptr::null(), |s| s.as_ptr())
}
// wchar_t is unsigned on Linux ARM64 and signed on macOS/Linux x86-64.
#[allow(clippy::unnecessary_cast)]
unsafe fn wide_string<'a>(env: Env<'a>, p: *const libc::wchar_t) -> NifResult<Term<'a>> {
    if p.is_null() {
        return Ok(Option::<u8>::None.encode(env));
    }
    let mut n = 0;
    // SAFETY: caller holds the entry/reader lock, and C guarantees NUL termination.
    while unsafe { *p.add(n) } != 0 {
        n += 1;
    }
    let slice = unsafe { std::slice::from_raw_parts(p, n) };
    #[cfg(windows)]
    let out = String::from_utf16(slice).map_err(|_| Error::BadArg)?;
    #[cfg(not(windows))]
    let out: String = slice
        .iter()
        .map(|c| char::from_u32(*c as u32).ok_or(Error::BadArg))
        .collect::<NifResult<_>>()?;
    bytes(env, out.as_bytes())
}
fn map<'a>(env: Env<'a>, fields: &[(&str, Term<'a>)]) -> NifResult<Term<'a>> {
    let mut out = Term::map_new(env);
    for (key, value) in fields {
        out = out.map_put(atom(env, key)?, *value)?;
    }
    Ok(out)
}

struct Context<'a, 'b, 'c> {
    env: Env<'a>,
    nodes: &'b [ResourceArc<Node>],
    states: &'b mut [MutexGuard<'c, State>],
}
impl Context<'_, '_, '_> {
    fn index(&self, term: Term<'_>, invalid: &'static str) -> NifResult<usize> {
        let node = term
            .decode::<ResourceArc<Node>>()
            .map_err(|_| error(invalid))?;
        self.nodes
            .iter()
            .position(|n| n.id == node.id)
            .ok_or(Error::BadArg)
    }
    fn ptr(&self, term: Term<'_>, kind: Option<Kind>) -> NifResult<*mut c_void> {
        let invalid = match kind {
            Some(Kind::Entry) | Some(Kind::Link) => "argument_error",
            _ => "InvalidArchiveType",
        };
        let i = self.index(term, invalid)?;
        let node = &self.nodes[i];
        if let Some(kind) = kind {
            if node.kind != kind {
                return Err(error(match kind {
                    Kind::Reader => "InvalidReaderType",
                    Kind::Writer => "InvalidWriterType",
                    Kind::Match => "InvalidMatcherType",
                    _ => "argument_error",
                }));
            }
        } else if matches!(node.kind, Kind::Entry | Kind::Link) {
            return Err(error("InvalidArchiveType"));
        }
        if let Some(matcher) = &self.states[i].matcher {
            let j = self
                .nodes
                .iter()
                .position(|n| n.id == matcher.id)
                .ok_or(Error::BadArg)?;
            if self.states[j].owner.is_none() {
                return Err(error("MatcherClosed"));
            }
        }
        for parent in &self.states[i].parents {
            let j = self
                .nodes
                .iter()
                .position(|n| n.id == parent.id)
                .ok_or(Error::BadArg)?;
            if self.states[j].owner.is_none() {
                return Err(error("ArchiveClosed"));
            }
        }
        Ok(self.states[i]
            .owner
            .as_ref()
            .ok_or_else(|| {
                error(if node.kind == Kind::Entry {
                    "EntryClosed"
                } else {
                    "ArchiveClosed"
                })
            })?
            .ptr
            .as_ptr())
    }
    fn archive(&self, term: Term<'_>, kind: Option<Kind>) -> NifResult<*mut ffi::archive> {
        Ok(self.ptr(term, kind)?.cast())
    }
    fn entry(&self, term: Term<'_>) -> NifResult<*mut ffi::archive_entry> {
        Ok(self.ptr(term, Some(Kind::Entry))?.cast())
    }
    // archive_entry_clear releases owned metadata and resets its C archive pointer.
    // It is safe even if the original archive has been explicitly freed.
    unsafe fn clear_entry(&mut self, term: Term<'_>) -> NifResult<*mut ffi::archive_entry> {
        let i = self.index(term, "argument_error")?;
        if self.nodes[i].kind != Kind::Entry {
            return Err(Error::BadArg);
        }
        let ptr = self.states[i]
            .owner
            .as_ref()
            .ok_or_else(|| error("EntryClosed"))?
            .ptr
            .as_ptr()
            .cast();
        unsafe {
            ffi::archive_entry_clear(ptr);
        }
        self.states[i].parents.clear();
        Ok(ptr)
    }
    fn resolver(&self, term: Term<'_>) -> NifResult<*mut ffi::archive_entry_linkresolver> {
        Ok(self.ptr(term, Some(Kind::Link))?.cast())
    }
    fn io(&self, term: Term<'_>) -> NifResult<*mut ffi::archive> {
        let i = self.index(term, "InvalidArchiveType")?;
        if !matches!(self.nodes[i].kind, Kind::Reader | Kind::Writer) {
            return Err(error("InvalidArchiveType"));
        }
        self.archive(term, None)
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn dispatch<'a>(env: Env<'a>, index: usize, args: Vec<Term<'a>>) -> NifResult<Term<'a>> {
    let mut nodes: Vec<ResourceArc<Node>> =
        args.iter().filter_map(|arg| arg.decode().ok()).collect();
    loop {
        nodes.sort_by_key(|n| n.id);
        nodes.dedup_by_key(|n| n.id);
        let mut states = nodes
            .iter()
            .map(|n| n.state.lock().map_err(|_| error("ResourcePoisoned")))
            .collect::<NifResult<Vec<_>>>()?;
        // Lock the complete ownership graph in ID order. Retry if a matcher was
        // attached while gathering it, avoiding unlocked reads or lock inversion.
        let dependencies: Vec<_> = states
            .iter()
            .flat_map(|s| s.parents.iter().cloned())
            .chain(states.iter().filter_map(|s| s.matcher.clone()))
            .filter(|p| !nodes.iter().any(|n| n.id == p.id))
            .collect();
        if !dependencies.is_empty() {
            drop(states);
            nodes.extend(dependencies);
            continue;
        }
        let mut context = Context {
            env,
            nodes: &nodes,
            states: &mut states,
        };
        // SAFETY: generated calls use audited signatures; all supplied resources
        // and their ownership dependencies remain locked for the entire call.
        return unsafe { generated::invoke(index, &args, &mut context) };
    }
}
rustler::init!("Elixir.Archive.Nif");
