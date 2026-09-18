#!/usr/bin/env python3
"""Run the same pure Swift XCTest cases on Linux; does not substitute for iOS CI."""
import os, pathlib, shutil, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
files = ['Core/LLM/LLMTypes.swift','Core/LLM/JSONValue.swift','Core/LLM/LLMRequestTime.swift',
         'Core/LLM/FitnessSearchTopic.swift','Core/Agents/CoachToolResult.swift',
         'Core/LocalMilo/LocalMiloError.swift','Core/LocalMilo/LocalPrompt.swift','Core/LocalMilo/LocalBrowserPolicy.swift']
with tempfile.TemporaryDirectory(prefix='milo-tests-') as path:
    path = pathlib.Path(path)
    source = path/'Sources'/'AgenticKeepKeep'; source.mkdir(parents=True)
    test = path/'Tests'/'LocalMiloTests'; test.mkdir(parents=True)
    for file in files: shutil.copy2(root/'AgenticKeepKeep'/file, source)
    for name in ['LocalMiloTests.swift']:
        shutil.copy2(root/'AgenticKeepKeepTests/AgentTests'/name, test)
    (path/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LocalMiloChecks", targets: [
 .target(name: "AgenticKeepKeep"), .testTarget(name: "LocalMiloTests", dependencies: ["AgenticKeepKeep"])
])
''')
    subprocess.run([os.environ.get('SWIFT', 'swift'), 'test', '--package-path', str(path)], check=True)
