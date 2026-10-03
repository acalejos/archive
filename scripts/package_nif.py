#!/usr/bin/env python3
"""Audit a native library and package a RustlerPrecompiled-compatible release asset."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import subprocess
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parent.parent
TARGETS = json.loads((ROOT / 'native/targets.json').read_text())

def version():
    release = re.search(r'version: "([^"]+)"', (ROOT / 'mix.exs').read_text()).group(1)
    crate = tomllib.loads((ROOT/'native/archive/Cargo.toml').read_text())
    lock = tomllib.loads((ROOT/'native/archive/Cargo.lock').read_text())
    assert crate['package']['version'] == release, 'Cargo.toml version differs from mix.exs'
    assert next(p['version'] for p in lock['package'] if p['name']=='archive_nif') == release, 'Cargo.lock version differs from mix.exs'
    loader = (ROOT/'lib/archive/nif.ex').read_text()
    configured = json.loads('['+re.search(r'targets:\s*\[(.*?)\]', loader, re.S).group(1)+']')
    assert configured == TARGETS, 'Native target manifest differs from RustlerPrecompiled configuration'
    return release

def filename(target):
    prefix, ext = ('', 'dll') if 'windows' in target else ('lib', 'so')
    return f'{prefix}archive_nif-v{version()}-nif-2.17-{target}.{ext}'

def windows_imports(data):
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    machine, count = struct.unpack_from('<HH', data, pe + 4)
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    optional = pe + 24
    if data[pe:pe+4] != b'PE\0\0' or struct.unpack_from('<H', data, optional)[0] != 0x20b:
        raise ValueError('Expected a 64-bit PE DLL')
    sections = optional + optional_size
    def offset(rva):
        for n in range(count):
            start = sections + n * 40
            size, address, rawsize, raw = struct.unpack_from('<IIII', data, start + 8)
            if address <= rva < address + max(size, rawsize): return raw + rva - address
        raise ValueError(f'Invalid PE RVA {rva}')
    rva = struct.unpack_from('<I', data, optional + 112 + 8)[0]
    imports = []
    if rva:
        pos = offset(rva)
        while any(data[pos:pos+20]):
            name = offset(struct.unpack_from('<I', data, pos + 12)[0])
            imports.append(data[name:data.index(0, name)].decode().lower())
            pos += 20
    return machine, imports

def audit(path, target):
    data = path.read_bytes()
    arm = target.startswith('aarch64')
    if 'windows' in target:
        machine, deps = windows_imports(data)
        assert machine == (0xaa64 if arm else 0x8664), 'Wrong PE architecture'
        allowed = {'kernel32.dll','ntdll.dll','advapi32.dll','bcrypt.dll','bcryptprimitives.dll','crypt32.dll',
                   'ws2_32.dll','user32.dll','xmllite.dll','ole32.dll','secur32.dll',
                   'shell32.dll','msvcrt.dll','ucrtbase.dll','vcruntime140.dll','vcruntime140_1.dll'}
        bad = [d for d in deps if d not in allowed and not d.startswith('api-ms-win-')]
    elif 'apple' in target:
        magic, cpu = struct.unpack_from('<II', data)
        assert magic == 0xfeedfacf and cpu == (0x100000c if arm else 0x1000007), 'Wrong Mach-O architecture'
        output = subprocess.check_output(['otool','-L',str(path)], text=True)
        # First entry is this library's LC_ID_DYLIB, rather than a dependency.
        deps = [line.strip().split(' (')[0] for line in output.splitlines()[2:]]
        bad = [d for d in deps if not d.startswith(('/usr/lib/', '/System/Library/'))]
    else:
        assert data[:4] == b'\x7fELF' and data[4:6] == b'\x02\x01', 'Expected a 64-bit little-endian ELF'
        assert struct.unpack_from('<H', data, 18)[0] == (183 if arm else 62), 'Wrong ELF architecture'
        output = subprocess.check_output(['readelf','-d',str(path)], text=True)
        deps = re.findall(r'\(NEEDED\).*\[([^]]+)\]', output)
        allowed = re.compile(r'^(lib(c|m|gcc_s|pthread|dl|rt|util)\.so(?:\.[0-9]+)*|ld-linux.*\.so\.[0-9]+|libc\.musl-.*\.so\.1)$')
        bad = [d for d in deps if not allowed.fullmatch(d)]
        symbols = subprocess.check_output(['readelf','-V',str(path)], text=True)
        required = [tuple(map(int,v.split('.'))) for v in re.findall(r'GLIBC_([0-9.]+)', symbols)]
        if target.endswith('-gnu') and required:
            assert max(required) <= (2,28), f'glibc baseline exceeded: {max(required)}'
        if target.endswith('-musl'):
            assert not any(d.startswith(('libc.so.', 'ld-linux')) for d in deps), f'musl artifact depends on glibc: {deps}'
            # GCC's ARM64 musl unwinder exports historical GLIBC_2.0 versions.
            # Inspect their provider, rather than treating that name as libc.
            provider = None
            unexpected = []
            for line in symbols.partition('Version needs section')[2].splitlines():
                match = re.search(r'File: (\S+)', line)
                if match: provider = match.group(1)
                for name in re.findall(r'Name: (GLIBC_[0-9.]+)', line):
                    if (provider, name) != ('libgcc_s.so.1', 'GLIBC_2.0'):
                        unexpected.append((provider, name))
            assert not unexpected, f'musl artifact has glibc version requirements: {unexpected}'
    if bad: raise ValueError(f'Non-system shared dependencies: {bad}')
    print(f'Audited {target}: {deps}')

def package(path, target, out, licenses):
    audit(path, target)
    out.mkdir(parents=True, exist_ok=True)
    name = filename(target)
    dest = out / (name + '.tar.gz')
    files = [(name,path), ('licenses/archive-LICENSE', ROOT/'LICENSE')]
    if licenses:
        files += [('licenses/'+p.name,p) for p in sorted(licenses.glob('*')) if p.is_file()]
        assert len(files) > 2, 'Missing third-party license notices'
    with dest.open('wb') as stream, gzip.GzipFile(fileobj=stream, mode='wb', filename='', mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w') as archive:
            for name, source in files:
                data = source.read_bytes()
                info = tarfile.TarInfo(name)
                info.size, info.mode, info.mtime = len(data), 0o644, 0
                archive.addfile(info, io.BytesIO(data))
    print(f'{dest}: sha256:{hashlib.sha256(dest.read_bytes()).hexdigest()}')

def checksums(directory, output, complete=True):
    expected = {filename(t)+'.tar.gz' for t in TARGETS}
    actual = {p.name for p in directory.glob('*.tar.gz')}
    if actual - expected or (complete and expected != actual):
        raise ValueError(f'Incomplete/unexpected release assets: missing={expected-actual}, unexpected={actual-expected}')
    entries = []
    for name in sorted(actual):
        path = directory/name
        with tarfile.open(path) as archive:
            member = archive.getmember(name[:-7])
            assert member.isfile(), 'Missing NIF payload'
            # No filesystem paths escape the extracted artifact directory.
            assert all(not p.name.startswith('/') and '..' not in Path(p.name).parts
                       and (p.isfile() or p.isdir()) for p in archive), 'Unsafe release archive'
        entries.append(f'  "{name}" => "sha256:{hashlib.sha256(path.read_bytes()).hexdigest()}"')
    output.write_text('%{\n' + ',\n'.join(entries) + '\n}\n')
    print(f'Wrote {len(entries)} checksums to {output}')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command',required=True)
    p = sub.add_parser('package');p.add_argument('--target',choices=TARGETS,required=True);p.add_argument('--library',type=Path,required=True);p.add_argument('--out',type=Path,default=ROOT/'artifacts');p.add_argument('--licenses',type=Path,required=True)
    p = sub.add_parser('checksums');p.add_argument('--directory',type=Path,default=ROOT/'artifacts');p.add_argument('--output',type=Path,default=ROOT/'checksum-Elixir.Archive.Nif.exs');p.add_argument('--allow-partial',action='store_true')
    args=parser.parse_args()
    if args.command=='package':package(args.library,args.target,args.out,args.licenses)
    else:checksums(args.directory,args.output,not args.allow_partial)
