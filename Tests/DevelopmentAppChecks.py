"""Offline safety checks for the local Dev updater; never builds or launches an app."""
from pathlib import Path
import plistlib
import runpy
import subprocess
import tempfile
from unittest.mock import patch

repo = Path(__file__).resolve().parent.parent
module = runpy.run_path(str(repo / 'scripts/dev-app.py'), run_name='development_checks')
namespace = module['watcher_running'].__globals__
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    pid_file = root / 'watch.pid'
    pid_file.write_text('123')
    script = str(repo / 'scripts/dev-app.py')
    with patch.dict(namespace, WATCH_PID=pid_file):
        for command, expected in [
            ('/Applications/Xcode.app/Python.app/Contents/MacOS/Python ' + script + ' --watch', True),
            ('/usr/bin/python3 ' + script + ' --watch', True),
            ('/usr/bin/python3 /other-checkout/scripts/dev-app.py --watch', False),
            ('/usr/bin/python3 ' + script, False),
            ('', False),
        ]:
            with patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0, stdout=command)):
                assert module['watcher_running']() == expected, command

    for directory in ['ImmichGallery', 'ImmichGalleryWidget', 'Shared', 'Config', 'ImmichGallery.xcodeproj', 'build']:
        (root / directory).mkdir()
    source = root / 'ImmichGallery/Example.swift'
    source.write_text('initial')
    with patch.dict(namespace, ROOT=root):
        initial = module['fingerprint']()
        (root / 'build/output.log').write_text('A build must not trigger another build')
        assert module['fingerprint']() == initial
        source.write_text('changed')
        assert module['fingerprint']() != initial

    dev = root / 'Dev.app'
    product = root / 'Build.app'
    for app in [dev, product]:
        (app / 'Contents').mkdir(parents=True)
        with (app / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier': module['BUNDLE_ID'], 'CFBundleExecutable': 'ImmichGallery'}, stream)
    output = f'11 {dev}/Contents/MacOS/ImmichGallery\n12 {product}/Contents/MacOS/ImmichGallery\n13 /Applications/ImmichGallery.app/Contents/MacOS/ImmichGallery\n14 /some/other/app\n'
    with patch.dict(namespace, DESTINATION=dev, PRODUCT=product), patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0, stdout=output)):
        assert module['development_pids']() == [11, 12], 'Production and unrelated processes must never be stopped'

# Crosslink: the Info.plist each configuration builds, with Xcode's own build settings (read, not built). Release
# registers and announces the protocol's scheme; Dev only its own, which no other app takes part with.
import re


def processed_info(configuration):
    output = subprocess.run(['xcodebuild', '-project', str(repo / 'ImmichGallery.xcodeproj'), '-target', 'ImmichGallery',
                             '-configuration', configuration, '-showBuildSettings'],
                            cwd=repo, capture_output=True, text=True, check=True).stdout
    settings = dict(re.findall(r'^\s+(\w+) = (.*)$', output, re.M))
    template = (repo / 'Config/Info.plist').read_text()
    return plistlib.loads(re.sub(r'\$\((\w+)\)', lambda m: settings[m[1]], template).encode())


def crosslink_info(info):
    schemes = [scheme for entry in info['CFBundleURLTypes'] if entry['CFBundleURLName'].endswith('.crosslink')
               for scheme in entry['CFBundleURLSchemes']]
    every = [scheme for entry in info['CFBundleURLTypes'] for scheme in entry['CFBundleURLSchemes']]
    return schemes, every, info['ImmichCrosslink']['Version']


release_schemes, _, release_version = crosslink_info(processed_info('Release'))
assert (release_schemes, release_version) == (['immich-crosslink'], '0.2'), (release_schemes, release_version)
debug_schemes, debug_every, debug_version = crosslink_info(processed_info('Debug'))
assert debug_schemes == ['immich-crosslink-dev'], debug_schemes
assert 'immich-crosslink' not in debug_every, 'Dev must not register the public Crosslink scheme'
assert debug_version != '0.2', 'Dev must not announce the protocol draft other apps follow'
source = (repo / 'ImmichGallery/App/Crosslink.swift').read_text()
assert '#if DEBUG\n    static let scheme = "immich-crosslink-dev"' in source, 'Crosslink.scheme must match the Debug plist'
print('Crosslink: Release registers immich-crosslink 0.2; Dev only immich-crosslink-dev')
print('Dev updater source detection, watcher identity, and production-process isolation passed')
