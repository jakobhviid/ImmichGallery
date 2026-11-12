# Finder access (File Provider)

Issue #23. An optional Finder location for each saved account, made by an `NSFileProviderReplicatedExtension`
(`ImmichGalleryFileProvider.appex`). It is off until turned on in **Settings ▸ Finder**, per account.

```
<Account name (server)>/        in the Finder sidebar, under Locations
├── Albums/<album>/<photo>       owned and shared albums
├── Library/<year>/<MM Month>/<photo>   the user's own timeline
└── Favorites/<photo>
```

Photos are placeholders with Immich's thumbnails until opened; opening one downloads the unedited original
(`GET /assets/{id}/original?edited=false`). Finder's Remove Download frees the space again (`.downloadLazily`).

## What Finder can do

Everything is a membership, never a file Immich doesn't have. Finder only offers what the item's capabilities
allow, and the extension checks again, since Terminal can change files directly.

| In Finder | In Immich | Needs |
| :-- | :-- | :-- |
| Open a photo | Download the original | — |
| Drop files into an album folder | Upload (or find the duplicate by checksum), add to the album | Allow Changes, album owner or editor |
| Drop files into Favorites | Upload, favorite | Allow Changes, your own photo |
| Drop files into Library, a year or a month | Upload; shown in the month it was taken | Allow Changes |
| New folder in Albums | New album | Allow Changes |
| Rename an album folder | Rename the album | Allow Changes, album owner |
| Drag a photo onto an album or Favorites | Add it there; it stays where it was | Allow Changes |
| Drag a photo from one album to another | Add to the new album, remove from the old one | Allow Changes and Allow Removing, editor of both |
| Delete a photo in an album folder | Remove it from the album | Allow Removing, album owner or editor |
| Delete a photo in Favorites | Unfavorite it | Allow Removing, your own photo |
| Delete a photo in Library | Move it to Immich's Trash (Recently Deleted) | Allow Removing, your own photo, not from an external library, server Trash on |
| Delete an album folder | Delete the album; its photos stay in the library | Allow Removing, album owner |

Refused, with the photo left as it is on the server: renaming photos (Immich has no such API), replacing or
editing an original (photos are read-only on disk), folders anywhere but Albums, moving folders, files Immich
doesn't accept (`GET /server/media-types`), and anything when its option is off. Hidden and system files
(`.DS_Store`, `Icon\r`) stay on the Mac (`excludedFromSync`). Tags, dates and other local attributes stay local
(reported as still pending, so the system stops sending them).

- **Allow Changes** is on and **Allow Removing** off when the location is turned on. Removing is only offered
  together with changes. Nothing is ever deleted permanently: with the server's Trash turned off, where
  `DELETE /assets` would delete at once, Library deletions are refused.
- **Bounced moves.** A move that only adds (from Library or Favorites, or between albums without Allow Removing)
  returns the item where it was, so Finder puts it back; the destination shows it after the next check. A refused
  rename returns the server's name, so Finder renames it back.
- **Trash.** Finder's Trash isn't Immich's. The domain sets `supportsSyncingTrash = false` and no item has the
  `allowsTrashing` capability, only `allowsDeleting` where Allow Removing permits it, so Finder is expected to offer
  deleting rather than moving to its Trash; deletions follow the rules above. The SDK leaves what the system does with
  a trash operation on such a domain unspecified, so this is checked by hand (see Verification). The trash container
  has no enumerator (`NSFeatureUnsupportedError`), and a move to it, should one still arrive, is handled as a deletion.
- **Duplicates.** Uploads check the SHA-1 first (`POST /assets/bulk-upload-check`). A duplicate in Immich's Trash is
  restored, as adding it again asks for it back; one in the Locked Folder or hidden (live photo video) is refused
  without saying where it is, and never added, restored or favorited; an archived one is refused in Library and
  Favorites, which don't show the Archive. A dropped file is never deleted by the extension: refusals are
  `cannotSynchronize` errors with a message on the item, which keep the file.
- **External libraries.** Read-only: shown and downloadable, never deleted.
- **Errors** are built with the SDK's constructors where it has them: a refused deletion carries the item as it still
  is (`fileProviderErrorForRejectedDeletion(of:)`), so the system puts it back; a missing item names its identifier
  (`fileProviderErrorForNonExistentItem(withIdentifier:)`).

## Listing

- **Library**: `GET /timeline/buckets?visibility=timeline` for the years and months; each month with
  `POST /search/metadata` (`visibility: timeline`, `withExif`, pages of 1000) over the month plus a day either
  side, kept to the user's own assets whose local date falls in the month (how the timeline groups them).
  Archive, partners and stacks' hiding don't apply; every stacked photo is listed.
- **Albums**: `GET /albums` (v2 also the shared list). An album's members come from
  `timeline/bucket?albumId=` (shared albums include everyone's photos); names from one metadata search
  (`albumIds`) for the user's own assets and `GET /assets/{id}` for others'. Assets already listed keep their
  details, so a large shared album is looked up once.
- **Favorites**: metadata search with `isFavorite`, own assets in the timeline.
- **Names** are the original file names, `/` shown as `/` (stored as `:`), with no leading dot. Same-named photos
  in one folder get the end of their ID, `IMG_0001 (3fa85f64).JPG`; names already shown never change, and the
  check is case- and normalization-insensitive like APFS. A photo in two albums is two items: identifiers carry their
  folder (`asset|album:<id>|<asset id>`), so each has one parent. Identifiers only accept Immich-style IDs.

## Changes and the replica

The extension keeps a replica of every folder the system has listed (`ProviderStore`, JSON per folder in
`<App Group>/FileProvider/<domain>/Replica`). The working set's changes are the differences between a fresh listing
and the replica, reported as updates and deletions; a deleted folder takes its contents with it.

- **When**: the app signals the working set two seconds after its own changes (uploads, deletions, album edits,
  archive and Locked Folder moves), when it becomes active and every ten minutes while running; Refresh in
  Settings lists every folder again. Without the app, browsing a folder asks for a check when the last one is over
  ten minutes old. Checks closer than 20 seconds only report queued changes and list the folders a change from
  Finder marked stale (the album or Favorites a bounced move added to), so those show at once.
- **A queue that survives failures**: every difference a check applies to the replica (and every removal a folder
  listing finds) is also queued in `meta.json` with a generation number. A report sends the whole queue, and only
  the new anchor issued after the system received it removes those generations. A check that fails halfway (timeout,
  5xx, 429) or a report that never arrives therefore loses nothing: the next report still has the earlier folders'
  updates and deletions, including photos that moved to the Locked Folder.
- **Write failures** of the replica are errors, never ignored: the call fails and the replica starts a new epoch, so
  every anchor expires and the system lists everything again.
- **Cheap checks**: one `GET /albums`, one `timeline/buckets` and, if Favorites was listed, one favorites bucket
  list. A folder is listed again only when its signature changed (album count, update and last asset time; month
  count; favorites buckets) or after six hours.
- **Anchors**: the working set's anchor is the replica's epoch and a counter; any anchor but the last one issued
  expires, and the system lists everything again from the replica. An unreadable replica starts a new epoch.
- **Capabilities** follow Settings at once: each check re-renders the replica with the current options.

## Accounts, credentials and the Locked Folder

- **One domain per account**, identified by a hash of the API address and user ID (`account-<32 hex>`). Domains,
  replicas, URL caches and keychain items are per domain; another account's data is never read.
- **A key of its own.** Turning a location on creates an API key named “Immich Gallery Finder (Mac)”
  (Dev: “Immich Gallery Dev Finder (Mac)”) with only the permissions it uses: `asset.read/view/download/upload/
  update/delete`, `album.read/create/update/delete`, `albumAsset.create/delete`, `user.read`. A server that refuses
  that list (400) gets no key at all, never one with every permission: Settings says so, with the server's message,
  and suggests updating Immich or signing in to the account with an API key the user made, which Finder then uses.
  The key is checked against the account (`GET /users/me`) before the domain is added. An account signed in with an
  API key shares that key, which is never deleted.
- **Locked Folder.** Immich grants the Locked Folder only to an elevated session; an API key never is, so the server
  refuses its assets to the extension whatever the app has unlocked. The extension accepts only API keys, never asks
  for `visibility=locked`, drops locked and hidden assets from every listing, and checks an asset again
  before downloading it.
- **Revocation takes a check.** A photo moved to the Locked Folder (or trashed, or removed from a shared album) after
  Finder showed it disappears from Finder at the next working-set check (above): its placeholder and any downloaded
  copy are then removed by the system. Until that check a copy already downloaded stays readable on this Mac, and
  copies the user made elsewhere (dragged out, opened in another app) are outside the extension's reach. Downloads
  are refused at once, since each is checked against the server first. Archiving only removes a photo from Library
  and Favorites; albums keep showing it, as Immich does.
- **Handing over the key.** Without a provisioning profile, an App Group can't be a keychain access group (checked:
  `errSecMissingEntitlement`), so the app and the extension can't share a keychain item. The app sends the key over
  the extension's XPC service (`NSFileProviderManager.getService`, `FinderAccessService`). The service source is
  restricted (`isRestricted`, macOS 13+: only processes that can manage the domain reach it, through `getService`),
  its anonymous listener is resumed once and answers every endpoint request, and the extension accepts
  connections only from `anchor apple generic and identifier "<app bundle ID>" and certificate leaf[subject.OU] =
  "<its own team>"` and keeps the key in its own keychain item (service `<extension ID>.credentials`, account =
  domain). Unsigned builds have no team: nothing is accepted. Only non-secret settings are in the App Group
  (`configuration.json`).
- **Expired or deleted key**: Finder shows the item errors as “not authenticated”, with the message to turn Finder
  access on again; **Reconnect** in Settings makes a new key, hands it over and deletes the old one.
- **Turning off, Sign Out, Remove Account**: the extension forgets the key, the domain is removed
  (`preserveDirtyUserData`: files dropped but not uploaded yet are kept and their folder is shown), the replica and
  configuration are deleted, and the Finder key is deleted from the server. If the server can't be reached, Settings
  says which key to delete in Account Settings ▸ API Keys. A saved login refused at launch removes the location too
  (its key can't be deleted with a refused login). The extension also deletes keychain items and caches of domains
  whose configuration is gone. Locations without a saved account are listed in Settings with Remove.

## Builds and identities

| | Release | Debug (Dev) |
| :-- | :-- | :-- |
| Extension | `dev.igol.ImmichGallery.FileProvider` | `dev.igol.ImmichGallery.Dev.FileProvider` |
| Accepts keys from | `dev.igol.ImmichGallery` | `dev.igol.ImmichGallery.Dev` |
| App Group | `884UZN5CH3.dev.igol.ImmichGallery` | `884UZN5CH3.dev.igol.ImmichGallery.Dev` |

`IMMICH_APP_BUNDLE_ID` (project build settings) fills `ImmichAppBundleIdentifier` in
`Config/ImmichGalleryFileProvider-Info.plist`. The extension compiles seven API files of the app through a folder
exception set (`ImmichClient`, `Models`, `Models+Albums`, `Models+Assets`, `Models+Upload`, `ImmichClient+Albums`,
`ImmichClient+Upload`) and `FileProviderShared/`. It reads only its own string catalog,
`ImmichGalleryFileProvider/Localizable.xcstrings`, which repeats the shared API files' strings.

Sandbox: the extension has network client and the App Group only. Its Info.plist has the app's ATS exception
(`NSAllowsArbitraryLoads`), so it reaches the same plain-HTTP LAN and VPN servers; `scripts/dev-app.py` and
`Tests/DevelopmentAppChecks.py` check that it matches the app's. Like the widget, it needs a team-prefixed App
Group, so ad-hoc builds can't use it; `scripts/dev-app.py` signs Dev with the Developer ID team. `release.sh`
signs, notarizes and staples it with the app. macOS 15 is the minimum: every API used is from macOS 11–13, and
`NSXPCConnection.setCodeSigningRequirement` from 13.

## Verification

- `python3 scripts/check-integration.py` runs `Tests/FileProviderChecks.swift` (case `file-provider`): identifiers
  and their validation, names (collisions, stability, APFS rules, length), capabilities for each option and role,
  the replica (differences, nested deletions, queued deletions, anchors across restarts, a new epoch), and the engine
  against a fake server: nothing locked, hidden, trashed, archived or partner's where it doesn't belong; signatures
  skipping listings, Refresh, options; creating (hidden files, folders, kinds, options off, duplicates in the Trash,
  the Locked Folder and the Archive, Library placement); moves, renames, replacing, local attributes; deletions
  (options, external, the Trash off, Favorites, albums, non-empty folders, unknown items). Requests go through
  URLProtocol: album members and names, only the Finder key sent, no Locked Folder or `withStacked` request, the month
  window, v3 album details, server features, 401 and original downloads, error mapping. Breaking the Locked Folder
  filter, the Trash check or the external-library rule makes it fail.
  Also: a check failing halfway over several folders (a deleted album, a photo leaving an album, one moving to the
  Locked Folder, new capabilities) followed by the next check and an undelivered report; acknowledgement by
  generation; the queue across restarts; a bounced move shown within the minimum interval; a replica that can't be
  written. Disabling the queue, the stale list or the write errors makes it fail.
- `file-provider-framework` (`Tests/FileProviderFrameworkChecks.swift`): `FinderAccessListener` over real XPC in one
  process (three endpoint requests and a call over each; a requirement the peer fails; no requirement), errors built
  with the SDK (the item in a rejected deletion, the identifier of a missing item, the trash container), capabilities
  as the SDK's bits and never `allowsTrashing`, location names. Resuming the listener on every request traps there.
- `python3 Tests/DevelopmentAppChecks.py`: Dev and Release extension IDs, the app each accepts, their App Groups
  and ATS, from Xcode's settings. `scripts/dev-app.py` checks the same in the built Dev bundle, and the extension's signed
  App Group.
- `python3 scripts/check-mac-localization.py`: the extension's strings against its own catalog.

Verified on the signed production-identity local build: account activation, domain registration, credential hand-over
and Finder's root enumeration showing Albums, Library and Favorites. The first live attempt exposed an empty root
filename, which caused FileProvider to trap repeatedly; the root now has a valid name and an engine regression check.
After updating the installed app, Finder displayed the three folders with the account and domain preserved.

Not verified yet: album and timeline contents, thumbnails, downloads, uploads, bounced moves and removal behavior
in Finder. Writes need a server that may be written to; the public demo is read-only by policy.
The offline checks run the model, replica and engine against a fake server and the framework-facing parts outside
Finder; they don't show how fileproviderd and Finder behave. The behaviors marked above as system-driven need that
manual pass:

1. Turn Finder access on for an account on a private server (HTTPS and, if available, plain HTTP on the LAN): the
   location appears, Settings shows no error, the server lists the Finder key.
2. Browse Albums, Library and Favorites; thumbnails appear; opening a photo downloads it; Remove Download frees it.
3. With Allow Changes: drop a photo into an album, Library and Favorites; make, rename an album folder; drag a
   Library photo onto an album (it stays in Library and appears in the album within seconds).
4. With Allow Removing: select a photo in an album, Favorites and Library and choose Finder's delete command; note
   whether Finder offers Delete Immediately or Move to Trash, and that each removal does what the table says and
   no original is downloaded to do it. Turn Allow Removing off and check a deletion is refused and the item returns.
5. Move a photo to the Locked Folder in the app: it leaves Finder at the next check, its download with it.
6. Reconnect, turn off, Sign Out: the location and key go away; pending dropped files are kept.

Known limits, not failures: each folder's listing is one JSON file rewritten whole when it changes (one write per
item added from Finder), and listings stay in memory once read, so very large months or albums cost proportionally;
the configuration and the keychain item are read for each operation.
