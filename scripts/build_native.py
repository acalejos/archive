#!/usr/bin/env python3
"""Build pinned, verified, position-independent static C dependencies for Cargo."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent

def run(args):
    subprocess.run([str(arg) for arg in args], check=True)

def download(url, expected_sha256, dest):
    temp = dest.with_suffix('.tmp')
    for attempt in range(1, 4):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'archive-native-build'})
            with urllib.request.urlopen(req, timeout=120) as response, temp.open('wb') as output:
                shutil.copyfileobj(response, output)
            actual = hashlib.sha256(temp.read_bytes()).hexdigest()
            if actual != expected_sha256:
                raise RuntimeError(f'{dest.name} checksum mismatch: expected {expected_sha256}, got {actual}')
            temp.replace(dest)
            return
        except (OSError, RuntimeError) as error:
            temp.unlink(missing_ok=True)
            if attempt == 3: raise
            print(f'Download attempt {attempt} failed: {error}; retrying', file=sys.stderr)
            time.sleep(attempt)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cc', required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    prefix = out / 'install'
    cache = Path(os.environ.get('ARCHIVE_NATIVE_CACHE', ROOT / '_build/native-downloads'))
    cache.mkdir(parents=True, exist_ok=True)
    deps = json.loads((ROOT / 'native/dependencies.json').read_text())
    # Never discover developer-machine shared libraries in the precompiled bundle.
    common = ['-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF',
              '-DCMAKE_POSITION_INDEPENDENT_CODE=ON', f'-DCMAKE_INSTALL_PREFIX={prefix.as_posix()}',
              '-DCMAKE_INSTALL_LIBDIR=lib', f'-DCMAKE_C_COMPILER={Path(args.cc).as_posix()}',
              f'-DCMAKE_PREFIX_PATH={prefix.as_posix()}', '-DCMAKE_FIND_FRAMEWORK=LAST', '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local']
    if os.environ.get('ARCHIVE_CC_ARGS'):
        common += ['-DCMAKE_C_FLAGS=' + os.environ['ARCHIVE_CC_ARGS']]
    if os.environ.get('MACOSX_DEPLOYMENT_TARGET'):
        common += ['-DCMAKE_OSX_DEPLOYMENT_TARGET=' + os.environ['MACOSX_DEPLOYMENT_TARGET']]
    options = {
      'zlib': ['-DZLIB_BUILD_SHARED=OFF', '-DZLIB_BUILD_STATIC=ON', '-DZLIB_BUILD_TESTING=OFF'],
      'bzip2': [],
      'xz': ['-DBUILD_TESTING=OFF', '-DXZ_TOOL_XZ=OFF', '-DXZ_TOOL_XZDEC=OFF', '-DXZ_TOOL_LZMADEC=OFF', '-DXZ_TOOL_LZMAINFO=OFF', '-DXZ_TOOL_SCRIPTS=OFF'],
      'lz4': ['-DLZ4_BUILD_CLI=OFF', '-DLZ4_BUILD_LEGACY_LZ4C=OFF'],
      'zstd': ['-DZSTD_BUILD_SHARED=OFF', '-DZSTD_BUILD_STATIC=ON', '-DZSTD_BUILD_PROGRAMS=OFF', '-DZSTD_BUILD_TESTS=OFF'],
      'libxml2': ['-DLIBXML2_WITH_PYTHON=OFF', '-DLIBXML2_WITH_PROGRAMS=OFF', '-DLIBXML2_WITH_TESTS=OFF', '-DLIBXML2_WITH_ICONV=OFF', '-DLIBXML2_WITH_LZMA=OFF', '-DLIBXML2_WITH_ZLIB=OFF'],
      'libarchive': ['-DENABLE_TEST=OFF', '-DENABLE_TAR=OFF', '-DENABLE_CPIO=OFF', '-DENABLE_CAT=OFF', '-DENABLE_UNZIP=OFF', '-DENABLE_LIBB2=OFF', '-DENABLE_LZO=OFF', '-DENABLE_PCREPOSIX=OFF', '-DENABLE_PCRE2POSIX=OFF', '-DENABLE_EXPAT=OFF', '-DENABLE_BSDXML=OFF', '-DENABLE_NETTLE=OFF', '-DENABLE_MBEDTLS=OFF', '-DENABLE_MD=OFF', '-DENABLE_ACL=OFF', '-DENABLE_ICONV=ON', '-DOPENSSL_USE_STATIC_LIBS=TRUE'],
    }
    for name, dep in deps.items():
        stamp = out / (name + '.built')
        config_hash = hashlib.sha256(json.dumps([dep['sha256'], common, options[name], os.environ.get('DEP_OPENSSL_ROOT')], sort_keys=True).encode()).hexdigest()
        if stamp.exists() and stamp.read_text() == config_hash:
            continue
        archive = cache / (name + '-' + dep['version'] + '.tar')
        if not archive.exists():
            download(dep['url'], dep['sha256'], archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != dep['sha256']:
            raise RuntimeError(f'{name} checksum mismatch')
        unpack = out / ('source-' + name)
        if not unpack.exists():
            unpack.mkdir(parents=True)
            with tarfile.open(archive) as package:
                # Reject absolute/traversing/link entries rather than trusting a tar path.
                package.extractall(unpack, filter='data')
        source = next(path for path in unpack.iterdir() if path.is_dir())
        license_dir = prefix / 'share/archive/licenses'
        license_dir.mkdir(parents=True, exist_ok=True)
        for filename in ['LICENSE', 'LICENSE.txt', 'COPYING', 'COPYING.LESSER', 'COPYING.BSD', 'Copyright']:
            if (source / filename).is_file():
                shutil.copyfile(source / filename, license_dir / (name + '-' + filename))
        if name == 'bzip2':
            (source / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.17)
project(bzip2 C)
add_library(bz2 STATIC blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c)
install(TARGETS bz2 ARCHIVE DESTINATION lib)
install(FILES bzlib.h DESTINATION include)
''')
        extra = list(options[name])
        if name == 'libarchive':
            crypto = Path(os.environ['DEP_OPENSSL_ROOT']).as_posix()
            extra += [f'-DOPENSSL_ROOT_DIR={crypto}', f'-DOPENSSL_INCLUDE_DIR={crypto}/include']
            # Explicitly pin every discovered compression/XML library to static archives.
            extension = '.lib' if os.name == 'nt' else '.a'
            for cmake_var, choices in {
                'ZLIB_LIBRARY': ['z', 'zlibstatic', 'zlib'],
                'BZIP2_LIBRARIES': ['bz2'], 'LIBLZMA_LIBRARY': ['lzma', 'liblzma'],
                'LZ4_LIBRARY': ['lz4', 'lz4_static'], 'ZSTD_LIBRARY': ['zstd', 'zstd_static'],
                'LIBXML2_LIBRARY': ['xml2', 'libxml2'],
            }.items():
                paths = [prefix / 'lib' / ((('' if os.name == 'nt' else 'lib') + choice) + extension) for choice in choices]
                found = next((p for p in paths if p.exists()), None)
                if found is None:
                    raise RuntimeError(f'Missing static dependency {cmake_var}: {paths}')
                extra.append(f'-D{cmake_var}={found.as_posix()}')
            for var in ['ZLIB_INCLUDE_DIR','BZIP2_INCLUDE_DIR','LIBLZMA_INCLUDE_DIR','LZ4_INCLUDE_DIR','ZSTD_INCLUDE_DIR']:
                extra.append(f'-D{var}={prefix.as_posix()}/include')
            extra.append(f'-DLIBXML2_INCLUDE_DIR={prefix.as_posix()}/include/libxml2')
        build = out / ('build-' + name)
        if build.exists(): shutil.rmtree(build)
        run(['cmake', '-S', source / dep['cmake_subdir'], '-B', build, *common, *extra])
        if name == 'libarchive':
            run(['cmake', '--build', build, '--target', 'archive_static', '--parallel', os.environ.get('NUM_JOBS', '4')])
            # Installing the upstream project would also build its shared target.
            installed = build / 'libarchive' / ('archive_static.lib' if os.name == 'nt' else 'libarchive.a')
            shutil.copyfile(installed, prefix / 'lib' / installed.name)
        else:
            run(['cmake', '--build', build, '--target', 'install', '--parallel', os.environ.get('NUM_JOBS', '4')])
        if os.name == 'nt':
            # Normalize upstream Windows naming before Rust link selection.
            names = {'zlib': ('zlibstatic', ['zlibstatic', 'zlibstaticd', 'zs']),
                     'xz': ('lzma', ['lzma', 'liblzma']),
                     'lz4': ('lz4', ['lz4', 'lz4_static']),
                     'libxml2': ('xml2', ['xml2', 'libxml2', 'libxml2s'])}
            if name in names:
                canonical, choices = names[name]
                source_lib = next((prefix / 'lib' / (n + '.lib') for n in choices
                                   if (prefix / 'lib' / (n + '.lib')).exists()), None)
                if source_lib is None:
                    raise RuntimeError(f'Missing Windows static library {name}')
                dest = prefix / 'lib' / (canonical + '.lib')
                if source_lib != dest: shutil.copyfile(source_lib, dest)
        stamp.write_text(config_hash)

if __name__ == '__main__':
    main()
