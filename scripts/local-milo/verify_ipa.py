#!/usr/bin/env python3
"""Inspect the produced archive without extracting or executing it."""
import argparse,json,pathlib,plistlib,zipfile
p=argparse.ArgumentParser();p.add_argument('ipa');a=p.parse_args()
with zipfile.ZipFile(a.ipa) as archive:
    names=archive.namelist();roots=[n for n in names if n.count('/')==2 and n.endswith('.app/Info.plist')]
    assert len(roots)==1,roots
    root=roots[0].removesuffix('Info.plist');info=plistlib.loads(archive.read(roots[0]))
    assert info['CFBundleIdentifier']=='com.minjung.keepkeep',info['CFBundleIdentifier']
    metallib=[n for n in names if n.endswith('mlx-swift_Cmlx.bundle/default.metallib')]
    assert metallib,'MLX Metal library not embedded'
    assert archive.getinfo(metallib[0]).file_size>1_000_000,'Metal library unexpectedly small'
    forbidden=[n for n in names if n.lower().endswith(('.gguf','.safetensors','.onnx','.pt','.pth'))]
    assert not forbidden,forbidden
    assert any(n.endswith('Qwen-LICENSE.txt') for n in names),'Qwen license missing'
    assert any(n.endswith('MLX-LICENSE.txt') for n in names),'MLX license missing'
    assert any(n.endswith('MLXLM-LICENSE.txt') for n in names),'MLXLM license missing'
    assert any(n.endswith('KeepKeepWidget.appex/') for n in names),'Widget extension missing'
    print(json.dumps(dict(bundle_id=info['CFBundleIdentifier'],version=info['CFBundleShortVersionString'],build=info['CFBundleVersion'],minimum_os=info['MinimumOSVersion'],metallib_bytes=archive.getinfo(metallib[0]).file_size,ipa_bytes=pathlib.Path(a.ipa).stat().st_size,weights_bundled=False),indent=2))
