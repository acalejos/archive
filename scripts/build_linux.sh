#!/bin/sh
set -eu
if [ -f /etc/alpine-release ]; then
  apk add --no-cache build-base clang clang-dev llvm-dev cmake ninja python3 perl curl git
  export LIBCLANG_PATH=/usr/lib
else
  dnf install -y clang clang-devel cmake ninja-build perl-core curl git
  export PATH="/opt/python/cp312-cp312/bin:$PATH"
  export LIBCLANG_PATH=/usr/lib64
fi
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/archive-rustup.sh
sh /tmp/archive-rustup.sh -y --profile minimal --default-toolchain 1.95.0
export PATH="$HOME/.cargo/bin:$PATH"
rustup target add "$TARGET"
python3 scripts/build_release.py --target "$TARGET"
