# Local development app

Debug builds are a separate **Immich Gallery Dev** application, with a blue/teal icon and a DEV badge. Release builds keep the public app's name, icon, and identity.

The Dev app has its own bundle identifier (`dev.igol.ImmichGallery.Dev`), sandbox container, preferences, Keychain service, App Group, widget extension, `immichgallery-dev` URL scheme, and Crosslink scheme `immich-crosslink-dev` (it never registers or announces the public `immich-crosslink`). It does not migrate credentials from the public app. Sparkle updates are disabled in Dev so a published release cannot replace the local build.

## Build and install

Run from the repository root:

```sh
python3 scripts/dev-app.py
```

This builds Debug, validates the main and widget identifiers, signs using a local Developer ID Application identity, and installs `/Applications/Immich Gallery Dev.app`. A previous Dev process is stopped only after a successful build and staging copy. Accounts and preferences stay in Dev's separate container and Keychain. The public app is never replaced or stopped. A signing identity is required so rebuilds keep a stable code-signing identity for Keychain access.

The first login defaults to `https://demo.immich.app`. Use the public demo account, `demo@immich.app` / `demo`. Test only read operations on the public demo. A private development server can be selected in Dev without changing the daily-use application's account.

## Automatic local updates

```sh
python3 scripts/dev-app.py --install-watcher
```

This starts a detached watcher for this checkout using the development session’s existing filesystem access. The regular build/install command also starts it if needed. After source changes have settled for five seconds, it builds and replaces the Dev app. If Dev was running, it is reopened; a closed Dev app stays closed. Build failures preserve the installed version and are retried after another source change. The watcher keeps running when Dev closes. After rebooting the Mac, run the build/install command once to start it again. Keep this checkout mounted and Xcode plus the signing certificate available. No login agent or additional disk privacy permission is required.

Logs, update locks, the watcher PID, and the installed-source stamp are under `build/development/`, ignored by Git. To stop automatic updates:

```sh
python3 scripts/dev-app.py --stop-watcher
```

Use only one source watcher per installed Dev app. Re-run the install command if this checkout moves. Agents must run the install command after code changes, even when the watcher is enabled, to confirm the final build is available before handing back.

## Verification

Run `python3 Tests/DevelopmentAppChecks.py` for offline source-watcher and process-isolation checks, plus the normal integration and localization checks. The installed Debug bundle and embedded widget are checked before each replacement; the installer refuses a destination with a different bundle identifier.
