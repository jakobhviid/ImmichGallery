<p align="center">
  <a href="https://github.com/IGOLz/ImmichGallery/releases/latest"><img src="https://img.shields.io/github/v/release/IGOLz/ImmichGallery?include_prereleases&style=for-the-badge&label=Release&color=E8475F&labelColor=ececec" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-blue?style=for-the-badge&logo=apple&logoColor=000000&color=3F51B5&labelColor=ececec" alt="macOS 15 or later">
  <img src="https://img.shields.io/badge/Swift-6-orange?style=for-the-badge&logo=swift&logoColor=000000&color=F05138&labelColor=ececec" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge&color=3F51B5&labelColor=ececec" alt="License: MIT"></a>
</p>

<p align="center">
  <img src=".github/assets/icon.png" width="128" alt="Immich Gallery icon">
</p>
<h1 align="center">Immich Gallery</h1>
<h3 align="center">A native macOS app for your <a href="https://immich.app">Immich</a> library, with an Apple Photos–style interface</h3>
<br/>

<p align="center">
  <img src=".github/assets/library.webp" alt="Immich Gallery showing the library timeline">
</p>

<p align="center">
  <a href="https://github.com/IGOLz/ImmichGallery/releases/latest"><b>Download</b></a> ·
  <a href="#features">Features</a> ·
  <a href="#screenshots">Screenshots</a> ·
  <a href="#try-it-with-the-demo">Demo</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="#contributing">Contributing</a>
</p>

> [!NOTE]
> Immich Gallery is an independent open-source project and is **not affiliated with the Immich project**. It is a client: you need an Immich server (your own, or the public demo). Find Immich itself at [immich.app](https://immich.app).

> [!WARNING]
> This is an early preview. It can edit, move and delete photos on your server, so expect rough edges, and always follow a [3-2-1 backup plan](https://www.backblaze.com/blog/the-3-2-1-backup-strategy/) for your photos and videos.

## Why

Immich has a great web app and mobile apps, but on the Mac you live in a browser tab. Immich Gallery is written in SwiftUI from scratch to feel like it belongs on macOS: a sidebar, a real toolbar, keyboard shortcuts, several windows and tabs, Quick Look, drag and drop to and from the Finder, the share sheet, Shortcuts, and native full screen.

## Install

With [Homebrew](https://brew.sh), run:

```sh
brew install --cask igolz/tap/immich-gallery
```

If Homebrew asks you to trust this third-party cask, run `brew trust --cask igolz/tap/immich-gallery`, then repeat the install command.

The [official tap](https://github.com/IGOLz/homebrew-tap) installs the same signed and notarized app as the download below. The app can update itself. To update through Homebrew instead, run `brew update` followed by `brew upgrade --cask --greedy igolz/tap/immich-gallery`.

Or install manually:

1. Download **ImmichGallery-x.y.z.dmg** from the [latest release](https://github.com/IGOLz/ImmichGallery/releases/latest).
2. Open it and drag **Immich Gallery** to Applications.
3. Sign in with your server address and your email and password, single sign-on (OAuth), or an API key.

The app is signed with a Developer ID and notarized by Apple, so it opens without Gatekeeper warnings.

From version 0.3.2 the app updates itself: it looks for a new version when it opens and once a day, and asks before installing it. Choose **Immich Gallery › Check for Updates…** to check now, or turn on automatic installs in **Settings › Updates**. Versions up to 0.3.1 need one last manual download.

**Requirements:** macOS 15 Sequoia or later, and an Immich server v2.0 or later (tested with v3.3). The app is a universal binary for Apple silicon and Intel Macs.

On macOS 15 everything works, with a few differences from macOS 26 Tahoe:

- Controls use the standard translucent material instead of Liquid Glass.
- Dragging to the Finder exports only the photo you drag, named after its Immich ID, rather than the whole selection with original file names. Dragging a selection onto an album works on both.
- On pages opened from a grid (a place, tag, album or person), the Import button is hidden until you go back. **File › Import…** stays available.
- Video options sit in a strip above the video instead of over it.

## Try it with the demo

No server yet? Use Immich's public demo. Enter `https://demo.immich.app` as the server, then:

| Email           | Password |
| --------------- | -------- |
| demo@immich.app | demo     |

The demo is shared with everyone and doesn't accept uploads.

## Features

| Feature                                                          | Immich Gallery |
| :--------------------------------------------------------------- | :------------: |
| Timeline grouped by month, with ThumbHash placeholders           | ✅ |
| Library as Years, Months or All Photos, like Photos; square or aspect-ratio grid | ✅ |
| View options: favorites only, photos or videos only, newest or oldest first, date taken or date added | ✅ |
| Favorites, Videos, Archive, Recently Deleted                     | ✅ |
| Viewer with zoom, video, Live Photos, slideshow and full screen  | ✅ |
| HDR photos on HDR displays (gain-map HEIC/JPEG, HLG, PQ)        | ✅ |
| Info inspector: camera, exposure, location map, people, albums   | ✅ |
| Upload files and folders, with duplicate detection               | ✅ |
| Download originals, or a selection or album as a ZIP             | ✅ |
| Albums: create, edit, cover, sort, share with users; group the albums page by year or owner, as covers or a list | ✅ |
| Album comments and likes                                         | ✅ |
| Edit date, time zone, location, description and rating           | ✅ |
| Non-destructive rotate and crop                                  | ✅ |
| People: rename, merge, hide, birthday, assign faces; show favorites or hidden people | ✅ |
| Smart (CLIP), file name, description and OCR search              | ✅ |
| Search filters: people, place, camera, date, type, rating        | ✅ |
| Global map with clusters, places by city or country, memories    | ✅ |
| Tags and folder view                                             | ✅ |
| Locked Folder (PIN)                                              | ✅ |
| Stacks, duplicates, large files, photos without a location      | ✅ |
| Public shared links, filtered by type, and partner sharing       | ✅ |
| Several accounts and servers                                     | ✅ |
| API keys, sessions, notifications, preferences                   | ✅ |
| Administration: stats, jobs, users, external libraries           | ✅ |
| Several windows and tabs, Quick Look, drag and drop              | ✅ |
| Customizable sidebar, edited in place, with collapsible sections and a choice of how many albums it lists; it follows the system's sidebar icon size | ✅ |
| Customizable toolbar, grouped like Photos                        | ✅ |
| Shortcuts actions and the macOS share sheet                      | ✅ |
| Show in other Immich apps ([Immich Crosslink](https://jakob.hviid.phd/immich-crosslink/)), Open in Immich, Copy Immich Link | ✅ |
| Desktop widgets: photos (featured, album, person, place, favorites, chosen), mosaic, library | ✅ |
| In-app updates, optionally automatic                             | ✅ |
| English and Italian                                              | ✅ |
| OAuth (OIDC) sign-in                                             | ✅ |
| Automatic background backup                                      | ❌ |
| 360° photos                                                      | ❌ |
| Offline library                                                  | ❌ |

<details>
<summary><b>Keyboard shortcuts</b></summary>

| Action                         | Shortcut |
| :----------------------------- | :------- |
| Search                         | ⌘F |
| Search filters                 | ⌥⌘F |
| Info inspector                 | ⌘I |
| Favorite                       | . |
| Archive                        | ⌃⌘A |
| Delete / restore               | ⌘⌫ |
| Bigger / smaller thumbnails    | ⌘+ / ⌘− |
| Refresh                        | ⌘R |
| Import                         | ⇧⌘I |
| Export unmodified original     | ⇧⌘E |
| New album                      | ⌥⌘N |
| Rotate left / right            | ⌥⌘R / ⇧⌥⌘R |
| Copy image                     | ⌘C |
| Move through photos / extend the selection | Arrow keys / ⇧ arrow keys |
| Quick Look (arrow keys step through) | Space |
| New window / new tab           | ⌘N / ⌘T |
| Administration (admins)        | ⌥⌘A |

</details>

When filtering Library to photos or videos only, results contain your own items. Partner photos remain available in the unfiltered Library and on partner pages. Date Added sorting is available for the unfiltered timeline on Immich v3.0 or later.

### Works with other Immich apps

Immich Gallery takes part in [Immich Crosslink](https://jakob.hviid.phd/immich-crosslink/), an open protocol for links
between Immich apps on the same Mac. With another app that takes part installed, such as
[Immich Mount](https://github.com/jakobhviid/immich-mount), which shows your library as a drive in Finder, photos,
albums, people and places get a **Show in** item for it, and the gallery opens what that app sends in return. There is
nothing to set up: apps find each other once they are installed, and Settings ▸ Other Apps turns this off, for every
app or for one.

## Screenshots

<table>
  <tr>
    <td width="50%"><img src=".github/assets/viewer.webp" alt="Photo viewer with the info inspector"><p align="center"><sub>Viewer and info inspector</sub></p></td>
    <td width="50%"><img src=".github/assets/map.webp" alt="Map with photo clusters"><p align="center"><sub>Map</sub></p></td>
  </tr>
  <tr>
    <td width="50%"><img src=".github/assets/search.webp" alt="Smart search results"><p align="center"><sub>Smart search</sub></p></td>
    <td width="50%"><img src=".github/assets/places.webp" alt="Places grid"><p align="center"><sub>Places</sub></p></td>
  </tr>
  <tr>
    <td width="50%"><img src=".github/assets/albums.webp" alt="Albums grid"><p align="center"><sub>Albums</sub></p></td>
    <td width="50%"><img src=".github/assets/library.webp" alt="Library timeline"><p align="center"><sub>Library</sub></p></td>
  </tr>
</table>

<sub>Screenshots use the photos from Immich's public demo server.</sub>

## Privacy

Immich Gallery talks only to the servers you sign in to. There is no analytics, no tracking and no third-party service. Credentials are stored in the macOS Keychain, and thumbnails are cached on disk separately for each account.

## Build from source

You need Xcode 26 or later. The app builds with the macOS 26 SDK or later and runs on macOS 15 or later; macOS 26–only APIs are wrapped in `#available` checks in `ImmichGallery/Views/MacIntegration/OSCompatibility.swift`.

```sh
git clone https://github.com/IGOLz/ImmichGallery.git
cd ImmichGallery
open ImmichGallery.xcodeproj         # then ⌘R
```

Or from the command line:

```sh
xcodebuild -project ImmichGallery.xcodeproj -scheme ImmichGallery -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/ImmichGallery.app
```

Debug builds are signed ad hoc ("Sign to Run Locally"), so macOS may ask for Keychain access again after each rebuild. To sign with your own identity, set a team in *Signing & Capabilities*. The project uses Xcode's folder-synced groups: any file you add under `ImmichGallery/` is picked up automatically.

Debug builds are **Immich Gallery Dev**, with a separate identity, saved accounts, widget storage, and a blue DEV icon. To install and keep a local Dev app updated from this checkout, run `python3 scripts/dev-app.py` with a local Developer ID Application signing certificate. See [local development](docs/Development.md) for automatic updates and the demo account.

<details>
<summary><b>Project layout</b></summary>

```
ImmichGallery/
  API/        ImmichClient (REST + discovery) and one extension + DTO file per feature
  App/        App entry & menus, AccountServices (per account) and LibrarySession (per window), feature state
  Support/    Image pipeline, ThumbHash decoder, Keychain, formatters, export, notifications
  Views/      One folder per feature: Login, Grid, Viewer, Inspector, Albums, People, Search, Explore,
              Sharing, Upload, Metadata, Assets, Account, Admin, MacIntegration, Settings
  Localizable.xcstrings   English and Italian strings
Config/       Info.plist (ATS for http LAN servers), entitlements (sandbox)
docs/         Notes on each feature area and on the multi-window architecture
scripts/      Offline checks and the release script
Tests/        Offline check programs used by the scripts
```

The app targets the Immich v3.3 API ([OpenAPI spec](https://github.com/immich-app/immich/blob/main/open-api/immich-openapi-specs.json)) and stays compatible with servers from v2.0.

</details>

<details>
<summary><b>Releasing</b></summary>

`scripts/release.sh` archives the app with your Developer ID certificate, notarizes and staples it, and writes a DMG, a zip and the in-app update feed (`appcast.xml`) to `build/release/`. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project first. `scripts/publish.sh` then publishes them as the latest GitHub release. See [docs/Updates.md](docs/Updates.md) for the update feed and its signing key. After publishing a stable release, the publisher updates the [Homebrew tap](https://github.com/IGOLz/homebrew-tap) with its version and verified DMG checksum, using your existing GitHub CLI login. Prereleases leave the tap unchanged. If a tap update fails after publication, retry with `python3 scripts/update-homebrew.py vX.Y.Z`; the release is already live. Run `python3 Tests/HomebrewChecks.py` to check the tap publisher offline.

For repeat releases on the same Mac, save the notarization configuration in `.release.env` at the repository root. The script loads it automatically; Git ignores it. Store only the key path and identifiers there, keeping the private key outside the repository. Use shell defaults so environment overrides still work:

```sh
: "${NOTARY_KEY:=$HOME/.appstoreconnect/private_keys/AuthKey_YOUR_KEY_ID.p8}"
: "${NOTARY_KEY_ID:=YOUR_KEY_ID}"
: "${NOTARY_ISSUER:=YOUR_ISSUER_ID}"
```

Alternatively, set `NOTARY_PROFILE` to an existing notarytool Keychain profile. Once configured, run `scripts/release.sh` directly. Also increment `CURRENT_PROJECT_VERSION`, run the offline checks and localization check, and publish with `scripts/publish.sh`, which uploads the DMG, ZIP, `appcast.xml` and `SHA256SUMS.txt`.

```sh
NOTARY_PROFILE=my-profile scripts/release.sh
# or, with an App Store Connect API key:
NOTARY_KEY=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<issuer-id> scripts/release.sh
```

</details>

## Contributing

Bug reports, ideas and pull requests are welcome: open an [issue](https://github.com/IGOLz/ImmichGallery/issues) or a PR. Before sending a PR, please run the offline checks:

```sh
python3 scripts/check-integration.py
python3 scripts/check-mac-localization.py   # after a Debug build into build/DerivedData
```

New user-facing strings go in `ImmichGallery/Localizable.xcstrings`, with an Italian translation. Translations into other languages are very welcome.

Please never test write actions (uploads, edits, deletes) against someone else's server; use your own instance or the demo for read-only checks.

## Acknowledgements

- [Immich](https://github.com/immich-app/immich), the self-hosted photo and video server this app is built for. Please consider [supporting the project](https://immich.app/support).
- [ThumbHash](https://github.com/evanw/thumbhash) by Evan Wallace, for the image placeholders.

## License

Immich Gallery is released under the [MIT License](LICENSE). Immich is a trademark of its respective owners; this project is not endorsed by or affiliated with them.
