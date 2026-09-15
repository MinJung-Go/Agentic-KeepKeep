#!/usr/bin/env python3
"""Embed entitlement declarations using ad-hoc signing; a sideloader must re-sign.

This does NOT grant HealthKit access or create an installable provisioning profile.
Run on macOS after building/archiving, before zipping Payload.
"""
import argparse
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def verify_entitlements(bundle, expected):
    actual = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', str(bundle)))
    if actual != expected:
        raise RuntimeError(f'Embedded entitlements do not match source: {bundle}')
    run('codesign', '--verify', '--strict', str(bundle))


def prepare(app):
    widget = app / 'PlugIns/KeepKeepWidget.appex'
    specs = [
        (widget, ROOT / 'AgenticKeepKeepWidget/KeepKeepWidget.entitlements'),
        (app, ROOT / 'AgenticKeepKeep/Resources/KeepKeep.entitlements'),
    ]
    for bundle, entitlements in specs:
        if not bundle.is_dir() or not entitlements.is_file():
            raise FileNotFoundError(f'Missing signing input: {bundle}, {entitlements}')
    # Nested executable code must be signed before its enclosing bundle.
    nested = list(app.rglob('*.framework')) + list(app.rglob('*.dylib'))
    for binary in sorted(nested, key=lambda p: len(p.parts), reverse=True):
        run('codesign', '--force', '--sign', '-', '--timestamp=none', str(binary))
    for bundle, entitlements in specs:
        expected = plistlib.loads(entitlements.read_bytes())
        if bundle == app and expected.get('com.apple.developer.healthkit') is not True:
            raise RuntimeError('App must declare HealthKit access')
        run('codesign', '--force', '--sign', '-', '--timestamp=none',
            '--entitlements', str(entitlements), str(bundle))
        verify_entitlements(bundle, expected)
    run('codesign', '--verify', '--deep', '--strict', str(app))
    print('Verified ad-hoc signatures and embedded entitlements for App and widget.')
    print('Device installation still requires provisioning and re-signing by a sideloader.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    prepare(parser.parse_args().app.resolve())
