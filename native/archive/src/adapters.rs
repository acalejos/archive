//! Audited adapters for constructors, pointer outputs and retained C buffers.
use crate::*;
use std::ptr::{null, null_mut};

unsafe fn raw_bytes<'a>(env: Env<'a>, p: *const c_void, len: usize) -> NifResult<Term<'a>> {
    if p.is_null() {
        return Ok(Option::<u8>::None.encode(env));
    }
    // SAFETY: callers hold the owning lock and supply the C-reported length.
    bytes(env, unsafe {
        std::slice::from_raw_parts(p.cast::<u8>(), len)
    })
}
fn digest_size(kind: i32) -> NifResult<usize> {
    match kind {
        1 => Ok(16),
        2 | 3 => Ok(20),
        4 => Ok(32),
        5 => Ok(48),
        6 => Ok(64),
        _ => Err(error("InvalidDigest")),
    }
}
fn enum_arg(t: Term<'_>, category: &str) -> NifResult<i32> {
    generated::enum_value(category, &t.atom_to_string()?)
}
fn allocation(size: usize) -> NifResult<Box<[u8]>> {
    let mut v = Vec::new();
    v.try_reserve_exact(size)
        .map_err(|_| error("ArchiveAllocation"))?;
    v.resize(size, 0);
    Ok(v.into_boxed_slice())
}
unsafe fn read<'a>(
    ctx: &mut Context<'a, '_, '_>,
    arg: Term<'a>,
    size: usize,
) -> NifResult<Term<'a>> {
    if size == 0 {
        return Err(Error::BadArg);
    }
    let reader = ctx.archive(arg, Some(Kind::Reader))?;
    let mut binary = OwnedBinary::new(size).ok_or_else(|| error("ArchiveAllocation"))?;
    let n =
        unsafe { ffi::archive_read_data(reader, binary.as_mut_slice().as_mut_ptr().cast(), size) };
    if n < 0 {
        status(n as i32)?;
        return Err(error("ArchiveFailed"));
    }
    let n = n as usize;
    if n > size {
        return Err(error("ArchiveFailed"));
    }
    if n < size && !binary.realloc(n) {
        return Err(error("ArchiveAllocation"));
    }
    Ok(binary.release(ctx.env).encode(ctx.env))
}

pub(super) unsafe fn invoke<'a>(
    name: &str,
    args: &[Term<'a>],
    ctx: &mut Context<'a, '_, '_>,
) -> NifResult<Term<'a>> {
    let env = ctx.env;
    match name {
        "listReadableFormats"
        | "listWritableFormats"
        | "listReadableFilters"
        | "listWritableFilters" => {
            let category = if name.ends_with("Formats") {
                "ArchiveFormat"
            } else {
                "ArchiveFilter"
            };
            Ok(generated::table_names(category, name.starts_with("listWritable")).encode(env))
        }
        "archive_read_new"
        | "archive_write_new"
        | "archive_read_disk_new"
        | "archive_write_disk_new"
        | "archive_match_new" => {
            let (ptr, kind) = match name {
                "archive_read_new" => (ffi::archive_read_new(), Kind::Reader),
                "archive_read_disk_new" => (ffi::archive_read_disk_new(), Kind::Reader),
                "archive_write_new" => (ffi::archive_write_new(), Kind::Writer),
                "archive_write_disk_new" => (ffi::archive_write_disk_new(), Kind::Writer),
                _ => (ffi::archive_match_new(), Kind::Match),
            };
            owned(env, ptr.cast(), kind, vec![])
        }
        "archive_entry_new" => owned(env, ffi::archive_entry_new().cast(), Kind::Entry, vec![]),
        "archive_entry_new2" => {
            let parent = ctx.archive(args[0], None)?;
            let resource = args[0].decode::<ResourceArc<Node>>()?;
            owned(
                env,
                ffi::archive_entry_new2(parent).cast(),
                Kind::Entry,
                vec![resource],
            )
        }
        "archive_entry_clone" => {
            let entry = ctx.entry(args[0])?;
            let i = ctx.index(args[0], "argument_error")?;
            let term = owned(
                env,
                ffi::archive_entry_clone(entry).cast(),
                Kind::Entry,
                ctx.states[i].parents.clone(),
            )?;
            // The new resource has a larger ID and cannot yet be shared.
            term.decode::<ResourceArc<Node>>()?
                .state
                .lock()
                .map_err(|_| error("ResourcePoisoned"))?
                .generation = ctx.states[i].generation;
            Ok(term)
        }
        "archive_entry_clear" => {
            ctx.clear_entry(args[0])?;
            ok(env)
        }
        "archive_free"
        | "archive_read_free"
        | "archive_write_free"
        | "archive_match_free"
        | "archive_read_finish"
        | "archive_write_finish"
        | "archive_entry_free"
        | "archive_entry_linkresolver_free" => {
            let i = ctx.index(args[0], "InvalidArchiveType")?;
            let required = match name {
                "archive_read_free" | "archive_read_finish" => {
                    Some((Kind::Reader, "InvalidReaderType"))
                }
                "archive_write_free" | "archive_write_finish" => {
                    Some((Kind::Writer, "InvalidWriterType"))
                }
                "archive_match_free" => Some((Kind::Match, "InvalidMatcherType")),
                _ => None,
            };
            if let Some((kind, reason)) = required {
                if ctx.nodes[i].kind != kind {
                    return Err(error(reason));
                }
            }
            if matches!(name, "archive_entry_free") && ctx.nodes[i].kind != Kind::Entry {
                return Err(Error::BadArg);
            }
            if matches!(name, "archive_entry_linkresolver_free") && ctx.nodes[i].kind != Kind::Link
            {
                return Err(Error::BadArg);
            }
            if !matches!(
                name,
                "archive_entry_free" | "archive_entry_linkresolver_free"
            ) && matches!(ctx.nodes[i].kind, Kind::Entry | Kind::Link)
            {
                return Err(error("InvalidArchiveType"));
            }
            drop(ctx.states[i].owner.take()); // Free C before dropping its borrowed storage.
            ctx.states[i].buffer = None;
            *ctx.states[i].used = 0;
            ctx.states[i].matcher = None;
            ctx.states[i].parents.clear();
            ok(env)
        }
        "archive_read_refresh" | "archive_write_refresh" => {
            let i = ctx.index(args[0], "InvalidArchiveType")?;
            let kind = if name == "archive_read_refresh" {
                Kind::Reader
            } else {
                Kind::Writer
            };
            if ctx.nodes[i].kind != kind {
                return Err(error("InvalidArchiveType"));
            }
            let p = if kind == Kind::Reader {
                ffi::archive_read_new()
            } else {
                ffi::archive_write_new()
            };
            let ptr = NonNull::new(p.cast()).ok_or_else(|| error("ArchiveAllocation"))?;
            drop(ctx.states[i].owner.take());
            ctx.states[i].buffer = None;
            *ctx.states[i].used = 0;
            ctx.states[i].matcher = None;
            ctx.states[i].generation = ctx.states[i]
                .generation
                .checked_add(1)
                .ok_or_else(|| error("GenerationExhausted"))?;
            ctx.states[i].counters = Arc::new(Counters::default());
            ctx.states[i].owner = Some(OwnedHandle {
                ptr,
                kind,
                counters: ctx.states[i].counters.clone(),
            });
            ok(env)
        }
        "archive_read_open_memory" | "archive_read_open_memory2" => {
            let reader = ctx.archive(args[0], Some(Kind::Reader))?;
            let i = ctx.index(args[0], "InvalidArchiveType")?;
            if ctx.states[i].buffer.is_some() {
                return Err(error("ArchiveAlreadyOpen"));
            }
            let input = args[1].decode::<Binary<'_>>()?;
            let mut copy = allocation(input.len())?;
            copy.copy_from_slice(input.as_slice());
            let len = copy.len();
            let ptr = copy.as_ptr().cast();
            ctx.states[i].buffer = Some(copy);
            let result = if name == "archive_read_open_memory" {
                ffi::archive_read_open_memory(reader, ptr, len)
            } else {
                ffi::archive_read_open_memory2(reader, ptr, len, args[2].decode()?)
            };
            status(result)?;
            ok(env)
        }
        "archive_write_open_memory" => {
            let writer = ctx.archive(args[0], Some(Kind::Writer))?;
            let i = ctx.index(args[0], "InvalidArchiveType")?;
            if ctx.states[i].buffer.is_some() {
                return Err(error("ArchiveAlreadyOpen"));
            }
            let mut buffer = allocation(args[1].decode()?)?;
            let len = buffer.len();
            let p = buffer.as_mut_ptr().cast();
            ctx.states[i].buffer = Some(buffer);
            *ctx.states[i].used = 0;
            let used = ctx.states[i].used.as_mut() as *mut usize;
            status(ffi::archive_write_open_memory(writer, p, len, used))?;
            ok(env)
        }
        "archive_write_memory" => {
            ctx.archive(args[0], Some(Kind::Writer))?;
            let i = ctx.index(args[0], "InvalidArchiveType")?;
            let b = ctx.states[i]
                .buffer
                .as_ref()
                .ok_or_else(|| error("NotMemoryWriter"))?;
            let used = *ctx.states[i].used;
            if used > b.len() {
                return Err(error("InvalidMemorySize"));
            }
            bytes(env, &b[..used])
        }
        "archive_read_next_header" | "archive_read_next_header2" => {
            let reader = ctx.archive(args[0], Some(Kind::Reader))?;
            let entry = ctx.clear_entry(args[1])?;
            let i = ctx.index(args[0], "InvalidArchiveType")?;
            ctx.states[i].generation = ctx.states[i]
                .generation
                .checked_add(1)
                .ok_or_else(|| error("GenerationExhausted"))?;
            let result = ffi::archive_read_next_header2(reader, entry);
            let entry_index = ctx.index(args[1], "argument_error")?;
            // A warning can still supply a usable header. Capture its ticket
            // before propagating status so Elixir's warning recovery can read it.
            ctx.states[entry_index].generation = ctx.states[i].generation;
            status(result)?;
            ok(env)
        }
        "archive_entry_read_generation" => {
            ctx.entry(args[0])?;
            Ok(ctx.states[ctx.index(args[0], "argument_error")?]
                .generation
                .encode(env))
        }
        "archive_read_generation" => {
            ctx.archive(args[0], Some(Kind::Reader))?;
            Ok(ctx.states[ctx.index(args[0], "InvalidArchiveType")?]
                .generation
                .encode(env))
        }
        "archive_read_data" => read(ctx, args[0], args[1].decode()?),
        "archive_read_extract_current" => {
            let reader = ctx.archive(args[0], Some(Kind::Reader))?;
            let i = ctx.index(args[0], "InvalidArchiveType")?;
            if ctx.states[i].generation != args[1].decode::<u64>()? {
                return Err(error("EntryExpired"));
            }
            status(ffi::archive_read_extract(
                reader,
                ctx.entry(args[2])?,
                args[3].decode()?,
            ))?;
            ok(env)
        }
        "archive_read_data_current" => {
            ctx.archive(args[0], Some(Kind::Reader))?;
            let i = ctx.index(args[0], "InvalidArchiveType")?;
            if ctx.states[i].generation != args[1].decode::<u64>()? {
                return Err(error("EntryExpired"));
            }
            read(ctx, args[0], args[2].decode()?)
        }
        "archive_read_data_block" => {
            let mut p = null();
            let mut size = 0;
            let mut offset = 0;
            status(ffi::archive_read_data_block(
                ctx.archive(args[0], Some(Kind::Reader))?,
                &mut p,
                &mut size,
                &mut offset,
            ))?;
            map(
                env,
                &[
                    ("data", raw_bytes(env, p, size)?),
                    ("offset", offset.encode(env)),
                ],
            )
        }
        "archive_write_data" | "archive_write_data_block" => {
            let writer = ctx.archive(args[0], Some(Kind::Writer))?;
            let data = args[1].decode::<Binary<'_>>()?;
            if name == "archive_write_data" {
                let n =
                    ffi::archive_write_data(writer, data.as_slice().as_ptr().cast(), data.len());
                if n < 0 {
                    return Err(error("ArchiveFailed"));
                }
                Ok((n as usize).encode(env))
            } else {
                status(ffi::archive_write_data_block(
                    writer,
                    data.as_slice().as_ptr().cast(),
                    data.len(),
                    args[2].decode()?,
                ) as i32)?;
                ok(env)
            }
        }
        "archive_seek_data" => {
            let n = ffi::archive_seek_data(
                ctx.archive(args[0], Some(Kind::Reader))?,
                args[1].decode()?,
                args[2].decode()?,
            );
            if n < 0 {
                return Err(error("ArchiveFailed"));
            }
            Ok(n.encode(env))
        }
        "archive_read_extract2" => {
            status(ffi::archive_read_extract2(
                ctx.archive(args[0], Some(Kind::Reader))?,
                ctx.entry(args[1])?,
                ctx.archive(args[2], Some(Kind::Writer))?,
            ))?;
            ok(env)
        }
        "archive_set_error" => {
            let message = cstring(args[2], false)?;
            ffi::archive_set_error(
                ctx.archive(args[0], None)?,
                args[1].decode()?,
                c"%s".as_ptr(),
                cptr(&message),
            );
            ok(env)
        }
        "archive_entry_fflags" => {
            let (mut set, mut clear) = (0, 0);
            ffi::archive_entry_fflags(ctx.entry(args[0])?, &mut set, &mut clear);
            map(
                env,
                &[("set", set.encode(env)), ("clear", clear.encode(env))],
            )
        }
        "archive_entry_mac_metadata" => {
            let mut size = 0;
            let p = ffi::archive_entry_mac_metadata(ctx.entry(args[0])?, &mut size);
            raw_bytes(env, p, size)
        }
        "archive_entry_copy_mac_metadata" => {
            let b = args[1].decode::<Binary<'_>>()?;
            ffi::archive_entry_copy_mac_metadata(
                ctx.entry(args[0])?,
                b.as_slice().as_ptr().cast(),
                b.len(),
            );
            ok(env)
        }
        "archive_entry_digest" => {
            let kind = args[1].decode()?;
            raw_bytes(
                env,
                ffi::archive_entry_digest(ctx.entry(args[0])?, kind).cast(),
                digest_size(kind)?,
            )
        }
        "archive_entry_set_digest" => {
            let kind = args[1].decode()?;
            let b = args[2].decode::<Binary<'_>>()?;
            if b.len() != digest_size(kind)? {
                return Err(error("InvalidDigestSize"));
            }
            status(ffi::archive_entry_set_digest(
                ctx.entry(args[0])?,
                kind,
                b.as_slice().as_ptr(),
            ))?;
            ok(env)
        }
        "archive_entry_xattr_add_entry" => {
            let name = cstring(args[1], false)?;
            let b = args[2].decode::<Binary<'_>>()?;
            ffi::archive_entry_xattr_add_entry(
                ctx.entry(args[0])?,
                cptr(&name),
                b.as_slice().as_ptr().cast(),
                b.len(),
            );
            ok(env)
        }
        "archive_entry_xattr_next" => {
            let (mut name, mut value, mut size) = (null(), null(), 0);
            let s = ffi::archive_entry_xattr_next(
                ctx.entry(args[0])?,
                &mut name,
                &mut value,
                &mut size,
            );
            if s == -20 {
                return Err(error("ArchiveEof"));
            }
            status(s)?;
            map(
                env,
                &[
                    ("name", string(env, name)?),
                    ("value", raw_bytes(env, value, size)?),
                ],
            )
        }
        "archive_entry_sparse_next" => {
            let (mut offset, mut length) = (0, 0);
            let s = ffi::archive_entry_sparse_next(ctx.entry(args[0])?, &mut offset, &mut length);
            if s == -20 {
                return Err(error("ArchiveEof"));
            }
            status(s)?;
            map(
                env,
                &[
                    ("offset", offset.encode(env)),
                    ("length", length.encode(env)),
                ],
            )
        }
        "archive_entry_acl_next" => {
            let (mut typ, mut perm, mut tag, mut qual, mut name) = (0, 0, 0, 0, null());
            status(ffi::archive_entry_acl_next(
                ctx.entry(args[0])?,
                args[1].decode()?,
                &mut typ,
                &mut perm,
                &mut tag,
                &mut qual,
                &mut name,
            ))?;
            map(
                env,
                &[
                    ("type", typ.encode(env)),
                    ("permset", perm.encode(env)),
                    ("tag", tag.encode(env)),
                    ("id", qual.encode(env)),
                    ("name", string(env, name)?),
                ],
            )
        }
        "archive_entry_acl_to_text" | "archive_entry_acl_to_text_w" => {
            let mut size = 0;
            let entry = ctx.entry(args[0])?;
            let flags = args[1].decode()?;
            if name.ends_with("_w") {
                let p = ffi::archive_entry_acl_to_text_w(entry, &mut size, flags);
                let result = wide_string(env, p);
                libc::free(p.cast());
                result
            } else {
                let p = ffi::archive_entry_acl_to_text(entry, &mut size, flags);
                let result = string(env, p);
                libc::free(p.cast());
                result
            }
        }
        "archive_match_path_unmatched_inclusions_next"
        | "archive_match_path_unmatched_inclusions_next_w" => {
            let matcher = ctx.archive(args[0], Some(Kind::Match))?;
            if name.ends_with("_w") {
                let mut p = null();
                status(ffi::archive_match_path_unmatched_inclusions_next_w(
                    matcher, &mut p,
                ))?;
                wide_string(env, p)
            } else {
                let mut p = null();
                status(ffi::archive_match_path_unmatched_inclusions_next(
                    matcher, &mut p,
                ))?;
                string(env, p)
            }
        }
        "archive_read_disk_entry_from_file" => {
            status(ffi::archive_read_disk_entry_from_file(
                ctx.archive(args[0], Some(Kind::Reader))?,
                ctx.entry(args[1])?,
                args[2].decode()?,
                null(),
            ))?;
            ok(env)
        }
        "archive_read_disk_set_matching" => {
            let reader = ctx.archive(args[0], Some(Kind::Reader))?;
            let matcher = ctx.archive(args[1], Some(Kind::Match))?;
            status(ffi::archive_read_disk_set_matching(
                reader,
                matcher,
                None,
                null_mut(),
            ))?;
            let i = ctx.index(args[0], "InvalidArchiveType")?;
            ctx.states[i].matcher = Some(args[1].decode()?);
            ok(env)
        }
        "getExtractInfo" => generated::extract_docs(env),
        "extractFlagToInt" => Ok(enum_arg(args[0], "ExtractFlag")?.encode(env)),
        "archiveFilterToInt" => Ok(enum_arg(args[0], "ArchiveFilter")?.encode(env)),
        "archiveFormatToInt" => Ok(enum_arg(args[0], "ArchiveFormat")?.encode(env)),
        "archiveFilterToAtom" | "archiveFormatToAtom" => {
            let cat = if name == "archiveFilterToAtom" {
                "ArchiveFilter"
            } else {
                "ArchiveFormat"
            };
            match generated::enum_name(cat, args[0].decode()?) {
                Some(name) => atom(env, name),
                None => Ok(Option::<u8>::None.encode(env)),
            }
        }
        "isSubFormatOf" => Ok(((enum_arg(args[0], "ArchiveFormat")?
            & ffi::ARCHIVE_FORMAT_BASE_MASK as i32)
            == enum_arg(args[1], "ArchiveFormat")?)
        .encode(env)),
        "tableIsSubFormatOf" => Ok(((enum_arg(args[0], "ArchiveFormat")?
            & ffi::ARCHIVE_FORMAT_BASE_MASK as i32)
            == enum_arg(args[1], "ArchiveFormat")?)
        .encode(env)),
        "fileKinds" => map(
            env,
            &[
                ("mask", ffi::AE_IFMT.encode(env)),
                ("block_device", ffi::AE_IFBLK.encode(env)),
                ("character_device", ffi::AE_IFCHR.encode(env)),
                ("directory", ffi::AE_IFDIR.encode(env)),
                ("named_pipe", ffi::AE_IFIFO.encode(env)),
                ("sym_link", ffi::AE_IFLNK.encode(env)),
                ("file", ffi::AE_IFREG.encode(env)),
                ("unix_domain_socket", ffi::AE_IFSOCK.encode(env)),
                ("unknown", 0u32.encode(env)),
            ],
        ),
        "archive_entry_copy_stat" => {
            stat::copy(args[1], ctx.entry(args[0])?)?;
            ok(env)
        }
        "archive_entry_stat" => Ok(stat::read(ctx.entry(args[0])?)?.encode(env)),
        "archive_entry_linkresolver_new" => owned(
            env,
            ffi::archive_entry_linkresolver_new().cast(),
            Kind::Link,
            vec![],
        ),
        "archive_entry_linkresolver_set_strategy" => {
            ffi::archive_entry_linkresolver_set_strategy(ctx.resolver(args[0])?, args[1].decode()?);
            ok(env)
        }
        "archive_entry_linkify" => {
            let r = ctx.resolver(args[0])?;
            let resolver_index = ctx.index(args[0], "argument_error")?;
            if let Ok(entry_index) = ctx.index(args[1], "argument_error") {
                let parents = ctx.states[entry_index].parents.clone();
                ctx.states[resolver_index].parents.extend(parents);
            }
            let parents = ctx.states[resolver_index].parents.clone();
            let mut first = if args[1].is_atom() && args[1].atom_to_string()? == "nil" {
                null_mut()
            } else {
                let p = ffi::archive_entry_clone(ctx.entry(args[1])?);
                if p.is_null() {
                    return Err(error("ArchiveAllocation"));
                }
                p
            };
            let mut spare = null_mut();
            ffi::archive_entry_linkify(r, &mut first, &mut spare);
            let a = if first.is_null() {
                Option::<u8>::None.encode(env)
            } else {
                owned(env, first.cast(), Kind::Entry, parents.clone())?
            };
            let b = if spare.is_null() {
                Option::<u8>::None.encode(env)
            } else {
                owned(env, spare.cast(), Kind::Entry, parents)?
            };
            map(env, &[("entry", a), ("spare", b)])
        }
        "archive_entry_partial_links" => {
            let mut links = 0;
            let p = ffi::archive_entry_partial_links(ctx.resolver(args[0])?, &mut links);
            let e = if p.is_null() {
                Option::<u8>::None.encode(env)
            } else {
                owned(
                    env,
                    p.cast(),
                    Kind::Entry,
                    ctx.states[ctx.index(args[0], "argument_error")?]
                        .parents
                        .clone(),
                )?
            };
            map(env, &[("entry", e), ("links", links.encode(env))])
        }
        "archive_read_open_filenames" => {
            let terms = args[1].decode::<Vec<Term<'_>>>()?;
            let strings = terms
                .into_iter()
                .map(|t| cstring(t, false))
                .collect::<NifResult<Vec<_>>>()?;
            let mut ptrs: Vec<_> = strings.iter().map(cptr).collect();
            ptrs.push(null());
            status(ffi::archive_read_open_filenames(
                ctx.archive(args[0], Some(Kind::Reader))?,
                ptrs.as_mut_ptr(),
                args[2].decode()?,
            ))?;
            ok(env)
        }
        "archive_read_open_filenames_w" => {
            #[cfg(windows)]
            {
                let terms = args[1].decode::<Vec<Term<'_>>>()?;
                let strings = terms
                    .into_iter()
                    .map(|t| wide(t, false))
                    .collect::<NifResult<Vec<_>>>()?;
                let mut ptrs: Vec<_> = strings.iter().map(wptr).collect();
                ptrs.push(null());
                status(ffi::archive_read_open_filenames_w(
                    ctx.archive(args[0], Some(Kind::Reader))?,
                    ptrs.as_mut_ptr(),
                    args[2].decode()?,
                ))?;
                ok(env)
            }
            #[cfg(not(windows))]
            {
                Err(error("UnsupportedPlatform"))
            }
        }
        "archive_utility_string_sort" => {
            let terms = args[0].decode::<Vec<Binary<'_>>>()?;
            let mut values: Vec<&[u8]> = terms.iter().map(Binary::as_slice).collect();
            values.sort();
            Ok(values
                .iter()
                .map(|b| bytes(env, b))
                .collect::<NifResult<Vec<_>>>()?
                .encode(env))
        }
        "archive_read_support_filter_program_signature"
        | "archive_read_support_compression_program_signature"
        | "archive_read_append_filter_program_signature" => {
            let cmd = cstring(args[1], false)?;
            let sig = args[2].decode::<Binary<'_>>()?;
            let reader = ctx.archive(args[0], Some(Kind::Reader))?;
            let fun = match name {
                "archive_read_support_filter_program_signature" => {
                    ffi::archive_read_support_filter_program_signature
                }
                "archive_read_support_compression_program_signature" => {
                    ffi::archive_read_support_compression_program_signature
                }
                _ => ffi::archive_read_append_filter_program_signature,
            };
            status(fun(
                reader,
                cptr(&cmd),
                sig.as_slice().as_ptr().cast(),
                sig.len(),
            ))?;
            ok(env)
        }
        "canonical_path" => {
            let binary = args[0].decode::<Binary<'_>>()?;
            #[cfg(unix)]
            let path = {
                use std::os::unix::ffi::OsStrExt;
                std::path::Path::new(std::ffi::OsStr::from_bytes(binary.as_slice()))
            };
            #[cfg(windows)]
            let path = std::path::Path::new(
                std::str::from_utf8(binary.as_slice()).map_err(|_| Error::BadArg)?,
            );
            let resolved = std::fs::canonicalize(path).map_err(|_| error("FileNotFound"))?;
            #[cfg(unix)]
            {
                use std::os::unix::ffi::OsStrExt;
                bytes(env, resolved.as_os_str().as_bytes())
            }
            #[cfg(windows)]
            {
                bytes(env, resolved.to_string_lossy().as_bytes())
            }
        }
        "archive_entry_copy_fflags_text_len" => {
            let text = cstring(args[1], false)?;
            let s = text.as_ref().unwrap();
            string(
                env,
                ffi::archive_entry_copy_fflags_text_len(
                    ctx.entry(args[0])?,
                    s.as_ptr(),
                    s.as_bytes().len(),
                ),
            )
        }
        "archive_resource_probe" => {
            let i = ctx.index(args[0], "InvalidArchiveType")?;
            Ok(ResourceArc::new(Probe {
                counters: ctx.states[i].counters.clone(),
            })
            .encode(env))
        }
        "archive_resource_stats" => {
            let probe = args[0].decode::<ResourceArc<Probe>>()?;
            map(
                env,
                &[(
                    "freed",
                    probe.counters.freed.load(Ordering::Acquire).encode(env),
                )],
            )
        }
        "constants" => generated::constants(env),
        _ => Err(error("UnknownOperation")),
    }
}
