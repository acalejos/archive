#!/usr/bin/env python3
"""Check the Hex source package, optionally requiring all release checksums."""
import argparse
import io
from pathlib import PurePosixPath
import re
import tarfile
from package_nif import TARGETS, filename

required = {
    'assets/logo/archive.png', 'mix.exs', 'LICENSE', 'lib/archive/nif.ex',
    'native/archive/Cargo.toml', 'native/archive/Cargo.lock', 'native/archive/build.rs',
    'native/archive/src/lib.rs', 'native/archive/src/adapters.rs', 'native/archive/src/stat.rs',
    'native/archive/src/generated.rs', 'native/archive/.cargo/config.toml',
    'native/dependencies.json', 'native/targets.json', 'rust-toolchain.toml',
    'checksum-Elixir.Archive.Nif.exs', 'priv/bindings.exs', 'priv/api_inventory.json',
    'priv/operations.json', 'priv/tables.json', 'vendor/libarchive/archive.h',
    'vendor/libarchive/archive_entry.h', 'scripts/build_native.py',
    'scripts/generate_bindings.py', 'README.md', 'guides/bindings.md', 'guides/high_level.md',
}
allowed_extensions = {'.ex','.exs','.rs','.toml','.h','.py','.md','.json','.lock'}
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--require-checksums',action='store_true')
parser.add_argument('package')
a=parser.parse_args()
with tarfile.open(a.package) as package:
    contents=package.extractfile('contents.tar.gz').read()
with tarfile.open(fileobj=io.BytesIO(contents),mode='r:gz') as sources:
    names={member.name for member in sources if member.isfile()}
    checksum=sources.extractfile('checksum-Elixir.Archive.Nif.exs').read().decode()
missing=required-names
unexpected={name for name in names if
    name == 'VALIDATION.md' or name.startswith(('prototypes/','native/archive/target/','deps/','_build/'))
    or (PurePosixPath(name).suffix not in allowed_extensions and name not in {'LICENSE','assets/logo/archive.png'})
    or any(part.startswith('.') and part not in {'.formatter.exs','.cargo'} for part in PurePosixPath(name).parts)}
if missing or unexpected:raise SystemExit(f'Invalid package: missing={sorted(missing)}, unexpected={sorted(unexpected)}')
if a.require_checksums:
    entries=dict(re.findall(r'"([^"]+)"\s*=>\s*"sha256:([0-9a-f]{64})"',checksum))
    if set(entries)!={filename(t)+'.tar.gz' for t in TARGETS}:raise SystemExit('Package requires exactly eight valid release checksums')
print(f'Verified {len(names)} source files; no compiled artifacts or validation document.')
