#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/Sources/MiloMLXValidation" "$test_dir/Tests/MiloMLXValidationTests"
cp "$repo_dir/MiloMLXValidation/Core/ProbeTypes.swift" "$test_dir/Sources/MiloMLXValidation/"
cp "$repo_dir/MiloMLXValidationTests/ProbeTests.swift" "$test_dir/Tests/MiloMLXValidationTests/"
cat > "$test_dir/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MiloMLXValidation", targets: [
    .target(name: "MiloMLXValidation"),
    .testTarget(name: "MiloMLXValidationTests", dependencies: ["MiloMLXValidation"])
])
PACKAGE
swift test --package-path "$test_dir"
