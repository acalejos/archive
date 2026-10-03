#!/usr/bin/env python3
"""Build, audit, and package one release target with pinned Rust and static dependencies."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tomllib
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'scripts'))
from package_nif import package
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--target',required=True)
a=p.parse_args()
crate=ROOT/'native/archive'
env=os.environ.copy()
# Cargo's musl configuration must be read from the crate's .cargo directory.
if 'apple' in a.target:env.setdefault('MACOSX_DEPLOYMENT_TARGET','11.0')
toolchain=['rustup','run','1.95.0']
host_info=subprocess.check_output([*toolchain,'rustc','-vV'],text=True,env=env)
host=next(line.removeprefix('host: ') for line in host_info.splitlines() if line.startswith('host: '))
# On a native musl host, omitting --target applies the crate's dynamic CRT
# rustflags to build helpers too. Bindgen's helper must dlopen libclang.
target_args=[] if a.target.endswith('-musl') and host==a.target else ['--target',a.target]
command=[*toolchain,'cargo','build','--locked','--release',*target_args,'--message-format=json-render-diagnostics']
with subprocess.Popen(command,cwd=crate,env=env,stdout=subprocess.PIPE,text=True) as child:
    artifact=None;licenses=None
    for line in child.stdout:
        try: message=json.loads(line)
        except ValueError:print(line,end='');continue
        if message.get('reason')=='compiler-message':
            print(message['message'].get('rendered',''),end='',file=sys.stderr)
        if message.get('reason')=='compiler-artifact' and message['target']['name']=='archive_nif':
            artifact=next(Path(f) for f in message['filenames'] if f.endswith(('.dylib','.so','.dll')))
        if message.get('reason')=='build-script-executed' and message['package_id'].split('#')[0].endswith('/native/archive'):
            licenses=Path(message['out_dir'])/'native/install/share/archive/licenses'
    if child.wait():raise SystemExit(child.returncode)
if artifact is None:raise SystemExit('Cargo did not report an archive_nif library')
if licenses is None:
    build_root=crate/'target'/(a.target if target_args else '')/'release/build'
    candidates=list(build_root.glob('archive_nif-*/out/native/install/share/archive/licenses'))
    if len(candidates)!=1:raise SystemExit(f'Could not identify license directory: {candidates}')
    licenses=candidates[0]
# OpenSSL's Apache-2.0 notice accompanies its statically linked vendored build.
registry=Path(os.environ.get('CARGO_HOME',Path.home()/'.cargo'))/'registry/src'
packages = tomllib.loads((crate/'Cargo.lock').read_text())['package']
for dependency in packages:
    if 'source' not in dependency: continue
    name, version = dependency['name'], dependency['version']
    candidates = list(registry.glob(f'*/{name}-{version}'))
    # Cargo.lock also includes optional and other-platform packages not compiled here.
    if not candidates: continue
    source = candidates[0]
    for notice in source.iterdir():
        if notice.is_file() and notice.name.upper().startswith(('LICENSE','COPYING','NOTICE')):
            shutil.copyfile(notice, licenses/(name+'-'+notice.name))
    if name == 'openssl-src':
        shutil.copyfile(source/'openssl/LICENSE.txt', licenses/'openssl-LICENSE.txt')
if not (licenses/'openssl-LICENSE.txt').exists():raise SystemExit('Missing vendored OpenSSL license')
package(artifact,a.target,ROOT/'artifacts',licenses)
