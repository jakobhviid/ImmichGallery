# Account implementation

Account settings are split into General, Account, Security, Preferences, and Accounts tabs. The bottom of the library sidebar shows the signed-in account (avatar, name, server) and the notifications bell. They describe who is signed in, not the page shown, so they stay out of the toolbar. The account menu holds the email, server and storage use, Account Settings… (opens Settings on the Account tab), Administration… for admins, the account switcher, Add Account… and Sign Out. The app menu repeats Switch Account and Sign Out for when the sidebar is hidden.

Implemented:
- Profile name editing, email display, usage/quota display, authenticated profile image loading, JPEG upload from a security scoped file importer, and image removal.
- Password changes with confirmation entry, eight-character validation, and optional invalidation of other sessions. Hidden when password login is disabled.
- API key listing, permission selection/filtering, creation with a one-time secret and copy action, rename, and confirmed deletion. Permission names come from the v3.3.5 Permission schema.
- Device/session listing with current marker, device OS/type/app version and last activity, confirmed individual revocation and logout of other sessions. Bulk revocation requires session-token authentication.
- Notifications list, unread count, mark read/all read and delete. Polling runs once per minute only while the scene is active, backs off on failure, stops on cancellation and hides the bell on 403/404.
- Server preferences for memories, ratings, folders, tags, people, shared links, web sidebar visibility, memory duration, people threshold/update strategy, default album order, download size and embedded video inclusion, email toggles, Cast, recently added web sidebar and support badge. Only available groups/fields appear. Loaded values are exposed as LibrarySession.preferences. As in System Settings, changes save as they are made (switches at once, typing after a short pause, anything pending when Settings closes); saves run in order, and a failed save restores the server's values and shows its error.
- Multiple accounts in Keychain, sidebar account menu, app menu and Settings switcher, adding through the existing login UI, local removal, last selected restoration, and legacy credential migration. Migration now copies the legacy item without changing/deleting it. Sign Out preserves the legacy item and makes it inert through the migration flag; vault failures leave the live login intact and show an error.
- New LibrarySession and memory cache per switch, SHA-256-named disk cache directories per API URL/user ID. Old session unauthorized callbacks cannot sign out a newly selected account.

No project file or README changes. No dependencies.

## Sources and contracts

Fetched the v3.3.5 OpenAPI document once:
https://raw.githubusercontent.com/immich-app/immich/v3.3.5/open-api/immich-openapi-specs.json

Checked Users, Authentication, API keys, Sessions and Notifications operations:
- GET/PUT /users/me; GET/PUT /users/me/preferences
- POST/DELETE /users/profile-image; GET /users/{id}/profile-image
- POST /auth/change-password: password, newPassword, invalidateSessions. The requested PUT is not the actual endpoint.
- GET/POST /api-keys, PUT/DELETE /api-keys/{id}
- GET/DELETE /sessions, DELETE /sessions/{id}
- GET/PUT /notifications, DELETE /notifications/{id}

Checked request/response schemas, Permission, PersonUpdateStrategy, all preference groups, multipart file field, notification readAt semantics, session.current and nullable appVersion. User and preference updates and API key rename use PUT endpoints still supported but marked deprecated in v3.3.5. Optional response fields/groups tolerate v2.x; missing preferences/keys/sessions endpoints hide their controls, missing notification endpoints hide the bell. v2.x was not live tested.

Cross-checked https://api.immich.app and https://docs.immich.app/features/user-settings/ and the API key permissions section at https://docs.immich.app/features/command-line-interface/.

Read official source at tag v3.3.5:
web/src/routes/(user)/user-settings/{UserProfileSettings,ChangePasswordSettings,DeviceList,DownloadSettings,FeatureSettings,NotificationsSettings,UserApiKeyList}.svelte
web/src/lib/components/user-settings-page/UserApiKeyGrid.svelte
web/src/lib/stores/notification-manager.svelte.ts

Apple references checked: SwiftUI TabView and fileImporter, Security Keychain services, AppKit NSPasteboard, Foundation URLCache. All compile against the macOS 26 SDK and app deployment target. Existing Form, Observation, Task and Settings scene patterns are reused.

## Verification

Build:
xcodebuild -project ImmichGallery.xcodeproj -scheme ImmichGallery -configuration Debug -derivedDataPath build/DerivedData build

Build succeeded. Only the standard AppIntents metadata extraction warning appears; no source warnings.

Demo checks:
python3 Tests/AccountLiveCheck.py

This script is hardcoded to https://demo.immich.app/api/ and its public demo credentials. It reads version/user/preferences/keys/sessions/notifications, creates and renames a temporary asset.read key, deletes that key in finally, and deletes only its own login session. It saves public response fixtures under gitignored build/AccountChecks, with the created key secret redacted. It never reads Keychain. It never modifies profile/password/preferences or other sessions/notifications.

Actual demo result: v3.3.5; all six reads succeeded; temporary key creation/rename/deletion succeeded; only this script's login session was deleted. Notifications list was empty, so optional notification fields also have a synthetic schema check.

DTO/request checks:
swiftc -swift-version 6 ImmichGallery/API/Models.swift ImmichGallery/API/ImmichClient.swift ImmichGallery/API/Models+Account.swift ImmichGallery/API/ImmichClient+Account.swift Tests/AccountChecks.swift -o build/AccountChecks/check
build/AccountChecks/check

Passed: decoding real responses; optional old-server groups; preferences encode/decode; password method/path/body; notification timestamp/IDs; multipart file body/auth; independent caches. URLProtocol intercepts all request-contract checks. No real network, Keychain or account-store writes occur in this check.

UI limit:
No interactive UI pass was run for this feature; UI verification happens on the merged app. Restore migration preserves the legacy Keychain item. Three settings tabs initially had duplicate SwiftUI IDs; those IDs are now distinct, verified by compilation only.

Untested by design: profile/name/password/preference mutations on the shared demo, deleting anyone else's sessions/notifications, end-to-end account switching and Keychain migration test runs, and final tab layout after the identity correction. A real account's Keychain was not read through scripts or diagnostic tooling; automatic restoration happened only through the launched app before the stop instruction.


## Review fixes

All findings 1–11 were addressed without launching the app or calling a live Immich server. The v3.3.5 OpenAPI document was consulted again. `shouldChangePassword` is decoded and offers a non-blocking password-change sheet from the library banner. The banner excludes administrators, API-key sessions, and servers with password login disabled, matching the applicable web password-login checks.

Account cache sessions are reused by API URL/user ID. Removing an account or signing out invalidates its cached session and removes its disk directory, including the stable credential-based offline fallback directory. Bootstrap uses no persistent cache; the legacy ImageCache directory is removed on isolated startup. Offline bootstrap retries vault migration when the user becomes available. Saved entries are observed in AppModel rather than loaded by view evaluation. Account transitions use a busy guard and verify the original session after awaiting authentication.

Profile imports run ImageIO decoding outside the main actor, reject files over 50 MiB, downsample to 512 pixels, and crop the center square before JPEG encoding. Settings height depends on the selected tab. Dates are localized, usage bars are clamped, names are trimmed, preferences have a controlled setter, and notification failures back off from 120 seconds to a 15-minute maximum, resetting after success. Only initial capability probes hide unavailable settings; mutation errors preserve the server message. Password success survives a failed optional session refresh.

The vault uses the legacy accessibility class, AfterFirstUnlock, and the label "Immich Gallery accounts". Every write verifies a full encode/decode round trip, reads existing contents before updating, and rejects an empty replacement unless explicitly removing. It updates the blob without deleting it first. This protects against local encoding/corruption failures; it is not a cross-process transaction system.

Additional local regression checks:

```
python3 Tests/AccountVaultChecks.py
python3 Tests/AccountImageChecks.py
```

The vault check compiles the production vault with a unique temporary test-only service and an isolated UserDefaults suite. A stub AccountStore prevents legacy credential reads. It verifies accounts-v1-only restoration, selected-entry persistence, rejected nonexistent selection, preservation of corrupt stored bytes, explicit removal, optional shouldChangePassword decoding, date parsing, and initial-probe versus mutation 404 handling. Its temporary Keychain item and defaults are removed. The image check extracts the production ImageIO helper, generates a two-color wide PNG, verifies a square blue center crop within 512 pixels, and rejects invalid/oversized inputs. It deletes all generated images.

The existing AccountChecks request/DTO executable was rerun against existing public-demo fixtures and URLProtocol interception. Cache checks now verify A→B→A session reuse, independent account sessions, deletion of a uniquely named test directory, and fresh session creation after removal. Foundation emitted cache-database diagnostics while these test directories were removed; all assertions passed. No request is sent by the isolated cache clients.

The required xcodebuild command succeeded. No warnings in changed source files; only the existing AppIntents metadata warning. No new live-server tests were needed, no production Keychain item was read or modified, and no app was launched. UI layout and interactive switching remain untested under the user's explicit no-launch constraint.
