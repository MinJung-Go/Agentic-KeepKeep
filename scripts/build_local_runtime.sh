#!/bin/bash
set -euo pipefail
# Reproducible engine only; no model weights are downloaded by the build.
revision=972d2313bc0bf0a45f634f77d95c9fb03aeab12c
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$root/build/local-runtime/source"
mkdir -p "$root/build/local-runtime" "$root/Vendor"
if [ ! -d "$source_dir/.git" ]; then
  git init "$source_dir"
  git -C "$source_dir" remote add origin https://github.com/ggml-org/llama.cpp.git
fi
git -C "$source_dir" fetch --depth 1 origin "$revision"
git -C "$source_dir" checkout --detach "$revision"
cd "$source_dir"
bash build-xcframework.sh ios-sim ios-device
rm -rf "$root/Vendor/llama.xcframework"
cp -R build-apple/llama.xcframework "$root/Vendor/llama.xcframework"
