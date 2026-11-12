#!/usr/bin/env python3
"""Build/install the isolated Dev app, or keep it updated from this checkout."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
STATE = ROOT / 'build/development'
DERIVED = ROOT / 'build/DerivedData'
PRODUCT = DERIVED / 'Build/Products/Debug/ImmichGallery.app'
DESTINATION = Path('/Applications/Immich Gallery Dev.app')
BUNDLE_ID = 'dev.igol.ImmichGallery.Dev'
WATCH_LOG = STATE / 'watch.log'
WATCH_PID = STATE / 'watch.pid'


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def fingerprint():
    digest = hashlib.sha256()
    for folder in ['ImmichGallery', 'ImmichGalleryWidget', 'ImmichGalleryFileProvider', 'FileProviderShared', 'Shared', 'Config',
                   'ImmichGallery.xcodeproj']:
        for path in sorted((ROOT / folder).rglob('*')):
            if not path.is_file() or any(part in {'xcuserdata', 'project.xcworkspace'} for part in path.parts):
                continue
            digest.update(str(path.relative_to(ROOT)).encode())
            digest.update(path.read_bytes())
    digest.update(Path(__file__).read_bytes())
    return digest.hexdigest()


def bundle_info(path):
    with (path / 'Contents/Info.plist').open('rb') as stream:
        return plistlib.load(stream)


def development_pids():
    # Exact executable paths only. Never stop the daily-use app with the production ID.
    executables = {str(path / 'Contents/MacOS' / bundle_info(path)['CFBundleExecutable'])
                   for path in [DESTINATION, PRODUCT] if path.exists() and bundle_info(path)['CFBundleIdentifier'] == BUNDLE_ID}
    output = run('ps', '-axo', 'pid=,comm=', capture_output=True, text=True).stdout
    return [int(line.strip().split(None, 1)[0]) for line in output.splitlines()
            if len(line.strip().split(None, 1)) == 2 and line.strip().split(None, 1)[1] in executables]


def check_file_provider(app, info):
    # Finder access: Dev's extension, App Group and credential owner are Dev's own, never the public app's.
    provider = app / 'Contents/PlugIns/ImmichGalleryFileProvider.appex'
    extension = bundle_info(provider)
    assert extension['CFBundleIdentifier'] == info['CFBundleIdentifier'] + '.FileProvider'
    assert extension['ImmichAppBundleIdentifier'] == info['CFBundleIdentifier']
    assert extension['ImmichAppGroup'] == info['ImmichAppGroup']
    assert extension['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.fileprovider-nonui'
    assert extension['NSExtension']['NSExtensionFileProviderDocumentGroup'] == info['ImmichAppGroup']
    # The app reaches plain-HTTP servers (LAN, VPN); the extension must reach the same ones.
    assert extension.get('NSAppTransportSecurity') == info.get('NSAppTransportSecurity'), 'File Provider ATS must match the app'
    entitlements = run('codesign', '-d', '--entitlements', ':-', provider, capture_output=True).stdout
    groups = plistlib.loads(entitlements)['com.apple.security.application-groups'] if entitlements else []
    assert groups == [info['ImmichAppGroup']], groups


def update(open_app=True, force=True):
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / 'update.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        revision = fingerprint()
        stamp = STATE / 'installed-source.sha256'
        if not force and stamp.exists() and stamp.read_text() == revision and DESTINATION.exists():
            return
        identities = run('security', 'find-identity', '-v', '-p', 'codesigning', capture_output=True, text=True).stdout
        match = re.search(r'"(Developer ID Application: [^\n"]+ \(([A-Z0-9]+)\))"', identities)
        if not match:
            raise RuntimeError('A Developer ID Application signing identity is required for stable Dev Keychain access.')
        identity, team = match.groups()
        print('Building Immich Gallery Dev…', flush=True)
        with (STATE / 'build.log').open('w') as log:
            run('xcodebuild', '-project', ROOT / 'ImmichGallery.xcodeproj', '-scheme', 'ImmichGallery',
                '-configuration', 'Debug', '-derivedDataPath', DERIVED, 'build',
                'CODE_SIGN_IDENTITY=' + identity, 'DEVELOPMENT_TEAM=' + team,
                cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        info = bundle_info(PRODUCT)
        assert info['CFBundleIdentifier'] == BUNDLE_ID
        assert info['CFBundleDisplayName'] == 'Immich Gallery Dev'
        assert info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == ['immichgallery-dev']
        # Crosslink: Dev takes only its own scheme and announces no draft other apps follow.
        schemes = [scheme for entry in info['CFBundleURLTypes'] for scheme in entry['CFBundleURLSchemes']]
        assert 'immich-crosslink' not in schemes and 'immich-crosslink-dev' in schemes
        assert info['ImmichCrosslink']['Version'] != '0.2'
        assert info['ImmichAppGroup'].endswith('.ImmichGallery.Dev')
        widget = PRODUCT / 'Contents/PlugIns/ImmichGalleryWidget.appex'
        assert bundle_info(widget)['CFBundleIdentifier'] == BUNDLE_ID + '.Widget'
        check_file_provider(PRODUCT, info)
        run('codesign', '--verify', '--deep', '--strict', PRODUCT)
        if DESTINATION.exists() and bundle_info(DESTINATION)['CFBundleIdentifier'] != BUNDLE_ID:
            raise RuntimeError('Refusing to replace an application without the Dev bundle identifier.')
        staged = DESTINATION.with_name('.Immich Gallery Dev-staging.app')
        backup = DESTINATION.with_name('.Immich Gallery Dev-previous.app')
        for path in [staged, backup]:
            if path.exists():
                if bundle_info(path)['CFBundleIdentifier'] != BUNDLE_ID:
                    raise RuntimeError('Unexpected application at ' + str(path))
                shutil.rmtree(path)
        run('ditto', PRODUCT, staged)
        pids = development_pids()
        for pid in pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for _ in range(100):
            if not development_pids():
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Dev app did not exit; leaving installed application intact.')
        if DESTINATION.exists():
            DESTINATION.rename(backup)
        try:
            staged.rename(DESTINATION)
        except Exception:
            if backup.exists():
                backup.rename(DESTINATION)
            raise
        if backup.exists():
            shutil.rmtree(backup)
        stamp.write_text(revision)
        if open_app or pids:
            run('open', DESTINATION)
        print('Updated ' + str(DESTINATION), flush=True)


def watcher_running():
    if not WATCH_PID.exists():
        return False
    try:
        pid = int(WATCH_PID.read_text())
        command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout.strip()
        executable, separator, arguments = command.partition(str(Path(__file__).resolve()))
        return bool(separator) and Path(executable.strip()).name.lower().startswith('python') and arguments == ' --watch'
    except (ValueError, OSError):
        return False


def install_watcher():
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / 'watcher.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if watcher_running():
            return
        with WATCH_LOG.open('a') as log:
            process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--watch'],
                                       cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
        WATCH_PID.write_text(str(process.pid))
        print('Automatic source updates enabled for this development session.', flush=True)


def watch():
    previous = None
    changed_at = time.monotonic()
    failed = None
    while True:
        current = fingerprint()
        if current != previous:
            previous, changed_at = current, time.monotonic()
        elif time.monotonic() - changed_at >= 5 and current != failed:
            try:
                update(open_app=False, force=False)
            except Exception as error:
                failed = current
                print('Dev update failed; keeping the last working build: ' + str(error), flush=True)
        time.sleep(2)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--watch', action='store_true')
    parser.add_argument('--install-watcher', action='store_true')
    parser.add_argument('--no-open', action='store_true')
    parser.add_argument('--stop-watcher', action='store_true')
    args = parser.parse_args()
    if args.stop_watcher:
        if watcher_running():
            os.kill(int(WATCH_PID.read_text()), signal.SIGTERM)
        WATCH_PID.unlink(missing_ok=True)
    elif args.watch:
        watch()
    elif args.install_watcher:
        install_watcher()
    else:
        update(open_app=not args.no_open)
        install_watcher()
