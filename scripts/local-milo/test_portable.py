#!/usr/bin/env python3
"""Run the same pure Swift XCTest cases on Linux; does not substitute for iOS CI."""
import os, pathlib, shutil, subprocess, tempfile, json, re
from dependency import inference_dependency
root = pathlib.Path(__file__).resolve().parents[2]
files = ['Core/Data/HealthActivityDigest.swift','Core/LLM/LLMClient.swift','Core/LLM/LLMJSON.swift','Core/Agents/AgentModels.swift','Core/Agents/AgentPrompts.swift','Core/Agents/MiloPersona.swift','Core/Agents/ParserAgent.swift','Core/LLM/LLMTypes.swift','Core/LLM/JSONValue.swift','Core/LLM/LLMRequestTime.swift',
         'Core/LLM/FitnessSearchTopic.swift','Core/Agents/CoachToolResult.swift',
         'Core/LocalMilo/LocalDownloadPolicy.swift','Core/LocalMilo/LocalMiloError.swift','Core/LocalMilo/LocalPrompt.swift','Core/LocalMilo/LocalMLXPolicy.swift','Core/LocalMilo/LocalInferenceDiagnostic.swift','Core/LocalMilo/LocalBrowserPolicy.swift']
with tempfile.TemporaryDirectory(prefix='milo-tests-') as path:
    path = pathlib.Path(path)
    source = path/'Sources'/'AgenticKeepKeep'; source.mkdir(parents=True)
    test = path/'Tests'/'LocalMiloTests'; test.mkdir(parents=True)
    for file in files: shutil.copy2(root/'AgenticKeepKeep'/file, source)
    # Extract the unchanged, Foundation-only enum from the SwiftData models file.
    models = (root/'AgenticKeepKeep/Core/Data/Models.swift').read_text()
    role = re.search(r'enum ChatRole: String, Codable \{[^}]+\}', models)
    assert role, 'ChatRole declaration changed; update portable source selection'
    (source/'ChatRole.swift').write_text(role.group(0))
    for name in ['ParserAgentTests.swift', 'RecordJSONRecoveryTests.swift', 'MockLLMClient.swift', 'JSONExtractorTests.swift', 'LocalMiloTests.swift', 'LocalDownloadPolicyTests.swift', 'LocalMLXPolicyTests.swift', 'LocalMemoryPolicyTests.swift']:
        shutil.copy2(root/'AgenticKeepKeepTests/AgentTests'/name, test)
    (path/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LocalMiloChecks", platforms: [.macOS(.v14)],
 dependencies: [.package(url: __INFERENCE_URL__, revision: __INFERENCE_REVISION__)], targets: [
 .target(name: "AgenticKeepKeep", dependencies: [.product(name: "MiloInferenceCore", package: "MiloInference")]), .testTarget(name: "LocalMiloTests", dependencies: ["AgenticKeepKeep"])
])
'''.replace('__INFERENCE_URL__', json.dumps(inference_dependency()['url'])).replace('__INFERENCE_REVISION__', json.dumps(inference_dependency()['revision'])))
    subprocess.run([os.environ.get('SWIFT', 'swift'), 'test', '--package-path', str(path)], check=True)
