#!/usr/bin/env python3
"""Run authentication policy/account preference XCTest without Apple SDKs."""
import os
import pathlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='moveliq-auth-tests-') as folder:
    package = pathlib.Path(folder)
    sources = package / 'Sources' / 'AgenticKeepKeep'
    tests = package / 'Tests' / 'AuthTests'
    sources.mkdir(parents=True)
    tests.mkdir(parents=True)
    for name in ['AuthModels.swift', 'AccountPreferences.swift', 'ServiceEndpoint.swift']:
        shutil.copy2(root / 'AgenticKeepKeep/Core/Auth' / name, sources)
    shutil.copy2(root / 'AgenticKeepKeepTests/AgentTests/AuthPolicyTests.swift', tests)
    (package / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AuthChecks", targets: [
    .target(name: "AgenticKeepKeep"),
    .testTarget(name: "AuthTests", dependencies: ["AgenticKeepKeep"])
])
''')
    subprocess.run([os.environ.get('SWIFT', 'swift'), 'test', '--package-path', str(package)], check=True)
