#!/usr/bin/env python3
"""Install the prepared Hex sources and load an HTTP-delivered NIF without compilers."""
import functools
import http.server
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import threading

ROOT=Path(__file__).resolve().parent.parent
ASSETS=ROOT/'artifacts'
packages=list(ASSETS.glob('archive-*.tar'))
if len(packages)!=1:raise SystemExit('Expected one prepared Hex source package in artifacts/')
handler=functools.partial(http.server.SimpleHTTPRequestHandler,directory=str(ASSETS))
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),handler)
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
try:
    with tempfile.TemporaryDirectory(prefix='archive-precompiled-') as tmp:
        dest=Path(tmp)
        with tarfile.open(packages[0]) as package:
            contents=package.extractfile('contents.tar.gz').read()
        with tarfile.open(fileobj=io.BytesIO(contents),mode='r:gz') as sources:
            sources.extractall(dest,filter='data')
        # Use the repo's locked Hex dependencies; the NIF is downloaded into this
        # isolated application's own priv directory, never copied from a source build.
        shutil.copytree(ROOT/'deps',dest/'deps',ignore=shutil.ignore_patterns('_build','target'))
        env=os.environ.copy();env.pop('ARCHIVE_BUILD',None);env.pop('RUSTLER_PRECOMPILED_FORCE_BUILD_ALL',None)
        env['ARCHIVE_PRECOMPILED_BASE_URL']=f'http://127.0.0.1:{server.server_port}/'
        env['RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH']=str(dest/'download-cache')
        env.pop('CARGO_TARGET_DIR',None)
        env['MIX_ENV']='test'
        # A source build must fail if accidentally selected. RustlerPrecompiled
        # does not invoke Cargo, Python's C build helper, or a C compiler here.
        blockers=dest/'no-compilers';blockers.mkdir()
        for name in ['cargo','rustup','rustc','cmake','cc','clang','gcc']:
            if os.name=='nt':
                (blockers/(name+'.cmd')).write_text('@echo Unexpected compiler invocation\n@exit /b 99\n')
            else:
                p=blockers/name;p.write_text('#!/bin/sh\necho Unexpected compiler invocation >&2\nexit 99\n');p.chmod(0o755)
        env['PATH']=str(blockers)+os.pathsep+env['PATH']
        subprocess.run(['mix','deps.compile'],cwd=dest,env=env,check=True,shell=os.name=='nt')
        # These are the same production tests used for source builds.
        shutil.copytree(ROOT/'test',dest/'test')
        subprocess.run(['mix','test'],cwd=dest,env=env,check=True,shell=os.name=='nt')
        if (dest/'native/archive/target').exists():raise RuntimeError('Unexpected Cargo build output')
        downloads=list((dest/'download-cache').rglob('*.tar.gz'))
        if len(downloads)!=1:raise RuntimeError(f'Expected exactly one verified download: {downloads}')
        print('PASS: HTTP artifact download, checksum verification, NIF load, and production tests; compilers blocked.')
finally:
    server.shutdown();server.server_close();thread.join()
