//! Copy C stat values across the BEAM boundary without exposing platform layouts.
// Platform C fields have different signedness and widths.
#![allow(clippy::unnecessary_cast, clippy::useless_conversion)]
use crate::*;
#[derive(rustler::NifMap, Default)]
pub(crate) struct Time {
    pub sec: i64,
    pub nsec: i64,
}
#[derive(rustler::NifMap, Default)]
pub(crate) struct Stat {
    pub dev: i64,
    pub rdev: i64,
    pub ino: u64,
    pub mode: u32,
    pub nlink: u64,
    pub uid: u32,
    pub gid: u32,
    pub size: i64,
    pub blocks: i64,
    pub blksize: i64,
    pub flags: u32,
    pub atim: Time,
    pub mtim: Time,
    pub ctim: Time,
    pub birthtim: Time,
}
fn field<'a, T: rustler::Decoder<'a> + Default>(
    env: Env<'a>,
    term: Term<'a>,
    name: &str,
) -> NifResult<T> {
    match term.map_get(atom(env, name)?) {
        Ok(value) => value.decode(),
        Err(_) if term.is_map() => Ok(T::default()),
        Err(_) => Err(Error::BadArg),
    }
}
fn time<'a>(env: Env<'a>, term: Term<'a>, name: &str) -> NifResult<Time> {
    field(env, term, name)
}
pub(crate) unsafe fn copy(term: Term<'_>, e: *mut ffi::archive_entry) -> NifResult<()> {
    let env = term.get_env();
    let mut s: ffi::ARCHIVE_BIND_STAT = unsafe { std::mem::zeroed() };
    macro_rules! set {
        ($field:ident,$key:literal,$ty:ty) => {
            s.$field = field::<$ty>(env, term, $key)?
                .try_into()
                .map_err(|_| error("StatOverflow"))?;
        };
    }
    set!(st_dev, "dev", i64);
    set!(st_rdev, "rdev", i64);
    set!(st_ino, "ino", u64);
    set!(st_mode, "mode", u32);
    set!(st_nlink, "nlink", u64);
    set!(st_uid, "uid", u32);
    set!(st_gid, "gid", u32);
    let size = field::<i64>(env, term, "size")?;
    #[cfg(not(windows))]
    {
        s.st_size = size.try_into().map_err(|_| error("StatOverflow"))?;
    }
    #[cfg(windows)]
    // MSVC's public struct stat may have a 32-bit size even on 64-bit targets.
    // Restore libarchive's full 64-bit value after copying the other fields.
    {
        s.st_size = size.try_into().unwrap_or(0);
    }
    let at = time(env, term, "atim")?;
    let mt = time(env, term, "mtim")?;
    let ct = time(env, term, "ctim")?;
    #[cfg(unix)]
    {
        set!(st_blocks, "blocks", i64);
        set!(st_blksize, "blksize", i64);
    }
    #[cfg(target_os = "macos")]
    {
        s.st_atimespec = ffi::timespec {
            tv_sec: at.sec,
            tv_nsec: at.nsec,
        };
        s.st_mtimespec = ffi::timespec {
            tv_sec: mt.sec,
            tv_nsec: mt.nsec,
        };
        s.st_ctimespec = ffi::timespec {
            tv_sec: ct.sec,
            tv_nsec: ct.nsec,
        };
        let bt = time(env, term, "birthtim")?;
        s.st_birthtimespec = ffi::timespec {
            tv_sec: bt.sec,
            tv_nsec: bt.nsec,
        };
        set!(st_flags, "flags", u32);
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        s.st_atim = ffi::timespec {
            tv_sec: at.sec as _,
            tv_nsec: at.nsec as _,
        };
        s.st_mtim = ffi::timespec {
            tv_sec: mt.sec as _,
            tv_nsec: mt.nsec as _,
        };
        s.st_ctim = ffi::timespec {
            tv_sec: ct.sec as _,
            tv_nsec: ct.nsec as _,
        };
    }
    #[cfg(windows)]
    {
        s.st_atime = at.sec as _;
        s.st_mtime = mt.sec as _;
        s.st_ctime = ct.sec as _;
    }
    unsafe { ffi::archive_entry_copy_stat(e, &s) };
    #[cfg(windows)]
    unsafe {
        ffi::archive_entry_set_size(e, size);
    }
    Ok(())
}
pub(crate) unsafe fn read(e: *mut ffi::archive_entry) -> NifResult<Stat> {
    let p = unsafe { ffi::archive_entry_stat(e) };
    if p.is_null() {
        return Err(error("StatError"));
    }
    let s = unsafe { &*p };
    let mut out = Stat {
        dev: s.st_dev as i64,
        rdev: s.st_rdev as i64,
        ino: s.st_ino as u64,
        mode: s.st_mode as u32,
        nlink: s.st_nlink as u64,
        uid: s.st_uid as u32,
        gid: s.st_gid as u32,
        size: unsafe { ffi::archive_entry_size(e) },
        ..Stat::default()
    };
    #[cfg(unix)]
    {
        out.blocks = s.st_blocks as i64;
        out.blksize = s.st_blksize as i64;
    }
    #[cfg(target_os = "macos")]
    {
        out.flags = s.st_flags;
        out.atim = Time {
            sec: s.st_atimespec.tv_sec,
            nsec: s.st_atimespec.tv_nsec,
        };
        out.mtim = Time {
            sec: s.st_mtimespec.tv_sec,
            nsec: s.st_mtimespec.tv_nsec,
        };
        out.ctim = Time {
            sec: s.st_ctimespec.tv_sec,
            nsec: s.st_ctimespec.tv_nsec,
        };
        out.birthtim = Time {
            sec: s.st_birthtimespec.tv_sec,
            nsec: s.st_birthtimespec.tv_nsec,
        };
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        out.atim = Time {
            sec: s.st_atim.tv_sec as i64,
            nsec: s.st_atim.tv_nsec as i64,
        };
        out.mtim = Time {
            sec: s.st_mtim.tv_sec as i64,
            nsec: s.st_mtim.tv_nsec as i64,
        };
        out.ctim = Time {
            sec: s.st_ctim.tv_sec as i64,
            nsec: s.st_ctim.tv_nsec as i64,
        };
    }
    #[cfg(windows)]
    {
        out.atim.sec = s.st_atime as i64;
        out.mtim.sec = s.st_mtime as i64;
        out.ctim.sec = s.st_ctime as i64;
    }
    Ok(out)
}
