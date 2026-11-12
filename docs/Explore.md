# Explore implementation and review verification

## Map stability

The map uses an explicit camera position and fits the original markers once on the first nonempty load, unless the user has already moved the map. Reclustering and filter changes preserve the camera. This avoids a feedback loop between automatic framing and viewport-dependent clusters. Grid steps change only at power-of-two zoom boundaries, so groups can be coarser than before; sorted asset IDs provide stable annotation identities and cover photos. Unchanged cluster results do not replace map content.

`Tests/ExploreChecks.swift` covers small camera-span changes, reordered markers, identity across zoom levels, and initial bounds for empty, invalid, single-location and date-line data. Visual confirmation of issue #3 is left to the maintainer in the installed Dev app.

Targets Immich v3.3.5 and macOS 26. This review pass never launched the app, read Keychain credentials, contacted the user's server, used a live demo session, or pushed the branch.

## Review findings

| Finding | Result |
| --- | --- |
| 1 | Fixed. Ordinary media keeps its original client and disk cache; pipeline creation no longer purges it. Per-ID eviction covers thumbnail, preview, fullsize and original requests. Move-to-locked repeats eviction after two seconds; revision checks also reject and purge requests completing after eviction. Locked Folder owns one ephemeral client per appearance with matching User-Agent, connection limit and timeout, invalidated when done. |
| 2 | Fixed. Memories sends `for` for today's date. The v3.3.5 OpenAPI and `MemorySearchDto` require an ISO **date**, so this uses YYYY-MM-DD rather than the review's suggested full timestamp. |
| 3 | Fixed. Include Archived sends `isArchived=true`; disabling it omits the parameter. |
| 4 | Fixed. Duplicate additions and not-found removals succeed. Permission/unknown failures still surface. The grid refreshes after partial failures too. |
| 5 | Fixed. Map cluster navigation now uses timeline buckets with a compact bounding-box source, no per-asset detail requests or ID-array hashing. Bounding boxes use `west,south,east,north`. Favorite, archive and partner filters carry through. Date limits filter months before fetching and assets inside fetched months because these timeline endpoints have no date-range parameters. |
| 6 | Fixed. Lock returns early unless unlocked. Locked views clear their own state and never purge the shared image cache. Pending unlocks use a generation check to relock if the view left. |
| 7 | Fixed. API-key users have no Locked Folder sidebar item, and a directly restored route explains the session-login requirement. The API method also rejects API-key PIN setup before issuing a request. |
| 8 | Fixed. Auth status decodes `pinExpiresAt`; unlocking schedules automatic locking at that deadline, with a conservative 15-minute fallback. Media 401/403 responses clear the locked UI and explain that access expired. |
| 9 | Fixed. Delete Memory uses a confirmation and says photos are kept. |
| 10 | Fixed. Tag timeline queries omit visibility so archived tagged photos are included. |
| 11 | Fixed. Move to Locked Folder is available in the grid context menu, Image menu and viewer context menu. The locked viewer and its toolbar menu offer removal, as does the locked grid context menu. |
| 12 | Fixed. Tags form a disclosure tree using parent IDs. The editor accepts only #RRGGBB or empty, matching rendering. |
| 13 | Fixed. On-this-day titles use localized singular/plural years-ago strings. Load More is hidden until an initial batch has loaded and is disabled while loading. |
| 14 | Fixed. Locked metadata filtering remains. Counts use visible appended items; pages containing only locked results or empty pages with a continuation advance without depending on a visible cell. |

Additional checks addressed: tag/preferences requests moved out of context menus into a coalesced session cache refreshed after tag edits; map date controls moved into a popover; successful initial marker loading explicitly reclusters; restored memory windows show a sign-in explanation when no session exists.

## Grid tag actions

The grid's Tags menu offers Add Tag… and Remove Tag… commands. Each opens a searchable list of full tag paths for the photos captured when the command was chosen. The sheet stays open and reports failures; affected grids refresh after partial failures too. Tag rows and their actions are no longer materialized as nested context-menu items. A sample of the installed Dev app captured the slow path inside `ContextMenuResponder.items` and the tag `ForEach` before the root menu appeared.

`Tests/ExploreTagPickerChecks.swift` covers search by full path, case and accents, whitespace, empty results, and a source guard against rebuilding the tag catalog in the context menu. The integration runner includes this check and the deferred-menu regression. The maintainer confirmed responsive context menus in the updated Dev app. Tag mutations remain unverified interactively; no demo-server writes are used by these checks.

## Privacy and limits

Ordinary media uses the existing 4 GB HTTP disk cache and 512 MB decoded-image cache. Locked media uses only the view's ephemeral session and SwiftUI image state. Per-ID eviction removes ordinary cached media when moving it into Locked Folder, including stale in-flight completions. Other cached assets are retained.

Touch ID unlocking is described in [MacIntegration.md](MacIntegration.md#locked-folder). Locked video/Live Photo and memory playback still use preview images. The map grid represents the cluster's geographic bounds, so co-located photos inside those bounds can also appear. Date-filtered timeline counts for boundary months become exact as those buckets load.

## Source evidence

- [Immich v3.3.5 OpenAPI](https://raw.githubusercontent.com/immich-app/immich/v3.3.5/open-api/immich-openapi-specs.json): timeline bbox syntax and supported parameters, memories `for` date format, optional auth PIN expiry, tag bulk results.
- [Memory DTO](https://github.com/immich-app/immich/blob/v3.3.5/server/src/dtos/memory.dto.ts): `for: isoDateToDate.optional()`.
- [Memory repository](https://github.com/immich-app/immich/blob/v3.3.5/server/src/repositories/memory.repository.ts): `for` limits showAt/hideAt.
- [Map repository](https://github.com/immich-app/immich/blob/v3.3.5/server/src/repositories/map.repository.ts): `isArchived=true` includes timeline/archive; absent/false selects timeline.

No finding was rejected. Finding 2 follows the versioned contract's date-only representation.

## Verification

```
xcodebuild -project ImmichGallery.xcodeproj -scheme ImmichGallery -configuration Debug -derivedDataPath build/DerivedData build

swiftc -parse-as-library ImmichGallery/API/ImmichClient.swift ImmichGallery/API/ImmichClient+Explore.swift ImmichGallery/API/Models.swift ImmichGallery/API/Models+Explore.swift ImmichGallery/Support/ImagePipeline.swift ImmichGallery/App/ExploreClustering.swift ImmichGallery/App/ExploreFolders.swift Tests/ExploreChecks.swift -o build/explore/review-checks
build/explore/review-checks
```

Build succeeded with no Swift compiler warnings. Xcode emits its existing AppIntents metadata-extraction warning because there is no AppIntents.framework dependency.

Standalone checks run production client/model/cache code with a URLProtocol stub, without live requests. They cover memory/archive query parameters, optional PIN expiry, API-key PIN rejection before transport, idempotent bulk-tag outcomes, hierarchy, bbox/date/month filtering, private-client configuration, selective HTTP/decoded cache eviction, and rejection of in-flight image responses invalidated during transport. Existing checks cover preferences, folder deduplication, 50,000-marker clustering and the date line.

UI interaction, real PIN setup/unlock/expiry and live asset mutations remain unverified. No shared demo data or settings were changed.

## Shared files changed in this review pass

- API/ImmichClient.swift: optional timeline bbox and parameter encoding.
- App/AssetGridModel.swift: tag/map timeline routing, local date bounds, continuation after filtered pages, shared move-to-locked action.
- App/AppModel.swift: session tag/preference cache and bootstrap load.
- App/ImmichGalleryApp.swift: Image menu move action.
- Views/Viewer/AssetViewer.swift: viewer context-menu move action.
- Support/ImagePipeline.swift: restore ordinary cache and add selective eviction with in-flight protection.

MainView, AssetGridView, AssetInspector and Models.swift were not changed by this review pass. Remaining changes are confined to Explore files, these checks and this document. Local build products and logs are ignored and excluded from the commit.
