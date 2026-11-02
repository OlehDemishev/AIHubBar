#!/bin/bash
# Puts claudepult-hook and claudepult next to the app in the installer (Tauri's externalBin wants the target triple in
# the file name). Run after `cargo build --release -p claudepult-hook -p claudepult-cli`, then
# `npx tauri build --config app/tauri.bundle.conf.json`. Used by CI; on a Mac only for trying the bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
TRIPLE="$(rustc -vV | sed -n 's/^host: //p')"
EXT=""
[[ "$TRIPLE" == *windows* ]] && EXT=".exe"
mkdir -p app/binaries
for name in claudepult-hook claudepult; do
  cp "target/release/$name$EXT" "app/binaries/$name-$TRIPLE$EXT"
done
ls app/binaries
