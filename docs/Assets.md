# Asset management and utilities

Implemented in the Assets API extension, DTOs, downloader, and views.

- Grid context menu: stack multiple selected assets and download selected assets as ZIP. Stack badges use the existing columnar timeline data and the new optional asset stack summary for search responses.
- Viewer: Browse Stack opens a member browser with image/video previews, member thumbnails, Set Primary, Remove from Stack, and confirmed Unstack. Unstacking preserves library assets.
- Toolbar Asset Utilities menu: selected-assets ZIP export, whole-album ZIP export, bulk coordinate entry, or Recently Deleted actions. Restore All and Empty Trash confirm their full-library scope. Trash retention days are loaded from server/config.
- Utilities sidebar: Duplicates appears only with duplicateDetection enabled; Large Files shows the official web client's largest-files results with byte-size badges; Assign Location opens the timeline with the bulk location action (see below). Coordinate entry checks finite values and geographic ranges before sending PUT /assets.
- Duplicate groups show side-by-side previews, sizes, Keep toggles, suggested defaults, confirmed keep/trash resolution, and confirmed dismiss. Resolution checks bulk response success. When trash is disabled, resolution requires an explicit permanent-deletion confirmation. Video previews use posters until Play Video is pressed. Resolved groups are removed locally, preserving scroll and other Keep choices.
- ZIP archives use the account's download.archiveSize preference. POST /download/info determines parts and motion assets. The server includes Live Photo videos and respects includeEmbeddedVideos for embedded Android motion parts. Each returned part streams through URLSession's download API into a temporary file, reports overall progress against the planned total, and uses the server-suggested filename, adding a suffix only on collision. Cancel cancels the stored task and removes this export's downloaded parts. HTTP errors never become saved ZIP files; completed parts survive later-part failure.

## Contracts and documentation

Checked the v3.3.5 OpenAPI spec at https://raw.githubusercontent.com/immich-app/immich/v3.3.5/open-api/immich-openapi-specs.json for stacks and member removal, download/info and download/archive, duplicates and duplicates/resolve, trash/empty and trash/restore, server/features and server/config, users/me/preferences, search/large-assets, and PUT /assets.

Checked https://api.immich.app and the official v3.3.5 web/source files:

- web/src/lib/services/stack.service.ts and trash.service.ts
- web/src/lib/utils/asset-utils.ts and web/src/lib/managers/download-manager.svelte.ts
- web/src/routes/(user)/utilities/duplicates/.../+page.svelte
- web/src/routes/(user)/utilities/large-files/.../+page.ts and +page.svelte
- web/src/routes/(user)/utilities/geolocation/+page.svelte
- server/src/services/download.service.ts
- server/src/repositories/asset.repository.ts: withStacked=true collapses stacks to their primary and emits [stackId, count]. Existing timeline behavior is retained.
- docs/docs/features/duplicates-utility.md: resolution merges metadata when exactly one asset is kept.

The public documentation URLs failed to load through the web tool, so the matching official tagged documentation was read from GitHub. Apple documentation for NSOpenPanel, confirmationDialog and URLSession.download(for:delegate:) was checked; download's async API requires macOS 12 and is available on the macOS 26 target.

## Compatibility and deliberate limits

New stack summaries and suggestedKeepAssetIds are optional for older responses. Duplicates is hidden when the feature flag is missing/false. Unsupported duplicate or stack reads handle 404 without crashing. Other unsupported endpoints show a recoverable error. search/large-assets is deprecated in 3.2 but is the endpoint used by the v3.3.5 web utility and was stable in v2. Duplicate resolution and member removal target v3.3.5; older servers may reject those actions. No substitute deletion is attempted.

There is no "without location" filter in the v3.3.5 web utility: its geolocation page shows the timeline and assigns locations. This app adds one (issue #42). No duplicate auto-resolve-all, automatic stacking of kept duplicates, or metadata synchronization is implemented locally; the dedicated resolve endpoint supplies the server's merge semantics.

## Assign Location view options

View Options has its own saved settings for Assign Location:

- Show: Without Location, the default, lists only your own items missing a latitude or longitude, the same test as Immich's map. All Items shows every owned item with Immich's green city or GPS badge, or a red No GPS badge. Media type and Favorites filters aren't offered: the page stays on the timeline API, whose `withCoordinates` columns (Immich v2.0+) the filter needs.
- Sort By (Date Taken, or Date Added on Immich v3.0+) and Order work as on the other timeline pages.

The timeline API can't filter by location, so Without Location loads every month in the background, one at a time; a month appears once checked. The subtitle reads "Looking for items without a location…" meanwhile. A month that fails to load isn't treated as checked: when the scan ends with failed months, the page says how many couldn't be loaded and offers Try Again, which reloads only those months. It never says "All Items Have a Location" unless every month was checked. Changing an option or reloading starts a new scan and discards responses from the old one. Assigning a location removes the item from a Without Location list in every window, or updates its badge in All Items, without reloading. The location dialog is sized for the map, with zoom, compass and scale controls, and shows coordinates with decimal points.

`scripts/check-search-paging.swift` (paging-and-services in `scripts/check-integration.py`) drives the grid against offline fixtures: every month failing, a partial failure, a retry that requests only the failed month, an interrupted scan whose late response is ignored, a request cancelled outside the app, and removal after assigning a location. `Tests/GridArrangementChecks.swift` checks the saved options.

## Verification

Debug xcodebuild succeeded with no Swift warnings. The existing AppIntents metadata-extraction warning remains because the project has no AppIntents dependency.

Read-only checks against demo.immich.app confirmed v3.3.5, decoded 129 duplicate groups and 250 large assets with the production Swift DTOs, decoded preferences/features/config/download plans, and downloaded two split ZIP parts (13,695 and 11,062 bytes) that passed ZIP integrity checks. Tests/AssetsDTOCheck.swift is an assert-based decoder check; compile it with API/Models.swift and API/Models+Assets.swift and supply captured JSON files named duplicates.json, large.json, download.json, preferences.json, config.json, and features.json. It also checks synthetic stack embedding of a real asset and missing older-server suggested IDs.

The demo rejected uploading unique generated PNG fixtures with HTTP 403 before creating any asset. Stack create/update/remove/delete and location mutations therefore could not be live-tested without modifying someone else's data; none were performed. No fixtures were created or left behind. Empty-trash, restore-all, and duplicate mutations were verified only against the spec and official source, as required. An earlier implementation run attempted a launch with `open`; its screen capture did not show the app. That evidence does not establish whether the process started, automatically signed in using the shared bundle ID/Keychain, or performed any action on the user's server. Those outcomes are unknown. The review-fix run never launched the app, accessed Keychain, or called the user's server. Interactive UI behavior remains unverified.

## Review fixes and verification

All twelve review findings were addressed. Stack creation puts the right-clicked asset first without sorting IDs; the primary cannot be removed. Member video players have asset identity. Browse Stack is gated by stackCount and loads asset details only when clicked; its top inset reserves space away from video controls. The geolocation utility has its own timeline source with partners disabled and an ownership filter. Bulk location entry excludes unknown/foreign owners with a visible skipped count and is unavailable in album/search/trash grids. Decimal commas are accepted, with range/format hints. Duplicate visibility reads the session feature cache. Large-file search sends minFileSize as a query parameter and documents the v3.2 deprecation.

`Tests/AssetsReviewCheck.swift` checks comma/point coordinates, malformed input, optional feature decoding, timeline ownership decoding, and archive request order/name. Compile with Models.swift, Models+Assets.swift, ImmichClient.swift, ImmichClient+Assets.swift, and the unchanged AssetsDownloadProgress declaration extracted from App/AssetsDownloader.swift. The optional `--demo` mode uses an ephemeral session and a fixed demo.immich.app URL, signs in with the public demo credentials, reads search results and download info, downloads one image ZIP through the production archive request and progress delegate, checks the returned temp file exists, moves it, checks ZIP magic and runs unzip -t, then removes the local ZIP and logs out. No asset mutations are performed.

The standalone demo check passed twice, downloading 952,371-byte archives with suggested filename Assets-Review-Check.zip. The returned temp file remained available after await despite the delegate's empty didFinishDownloadingTo; moving it and ZIP integrity checks succeeded. Apple's async API documentation returns a file-location tuple. Apple's [download guide](https://developer.apple.com/documentation/foundation/downloading-files-from-websites) distinguishes completion-handler and delegate download lifetimes; the delegate-only example requires moving inside its callback. The standalone check verifies the actual async API plus per-task delegate combination used here; the empty callback must not move/delete the file before the awaited caller handles it.

The review-fix Debug build succeeded. No warnings occurred in changed Swift files; the pre-existing AppIntents metadata warning remains. Cancellation panel interaction, scroll position, playback behavior, and destructive server mutations were inspected in code but not tested interactively or live. No new fixture assets were created.

## Video collection visibility

The Videos collection sends `visibility: timeline` with every metadata-search page. Hidden Live Photo motion components have no standalone thumbnails and belong to their associated photo, rather than the Videos grid. Archived videos remain in Archive. Filename and advanced searches keep their existing visibility rules.

For issue #14, read-only checks against demo.immich.app on 2026-11-06 reproduced 79 hidden components among 100 unfiltered video results. Sampled hidden components returned HTTP 404 for both thumbnail and preview, while standalone videos returned images. With the timeline filter, all 52 returned videos had timeline visibility and all 52 thumbnail requests succeeded with image/webp responses. `scripts/check-search-paging.swift` checks the production grid's outgoing visibility filter on initial, subsequent and reloaded pages, and checks that other searches retain their own visibility behavior. The offline paging/service harness passed. The isolated Dev app built, installed and started successfully. The reporter's server and interactive grid behavior were not tested.

## Find Similar Photos

Issue #41. Asset Utilities ▸ Find Similar Photos… (Library, Favorites, Archive, a person, Large Files, Assign Location) suggests stacks for photos taken in quick succession that look alike. Everything is computed on the Mac; only previews are downloaded from the user's own server. No dependency or cloud service is added.

- Scope: the selection when at least two items are selected (each item is read back from the server; items that can't be read are counted), otherwise a date range, by default the last 30 days, with 3 and 12 months or a custom range. A range is collected from every `search/metadata` page (`takenAfter`/`takenBefore`, images, timeline visibility), not from the grid's loaded months, so it includes photos the grid hasn't loaded and excludes the archive. Only the user's own still photos qualify: no videos or Live Photo video parts, partner photos, trash, Locked Folder, or photos already in a stack. An empty account ID matches nothing. More than 2,000 qualifying photos stops the scan with a request to narrow it; the first pages are never analyzed alone.
- Time first: photos are sorted by capture time (`fileCreatedAt`, then ID). A pause of up to 10 seconds (5/10/30 to choose) keeps photos in the same run; only photos with a neighbor are analyzed. Groups span at most 60 seconds, with 2–20 photos.
- Similarity: Vision image feature prints, revision 2, from the server preview (already upright) decoded at 720 px, off the main actor with three analyses at a time. Groups are complete-link: every two photos are within the sensitivity's distance, Strict 0.25, Normal 0.35 (default) or Loose 0.45, so A≈B≈C chains don't merge unlike photos. Ties merge earlier photos first. These thresholds are starting points measured on synthetic images; real-photo quality is not guaranteed and the user reviews every group.
- Suggested cover: a favorite, then Vision's aesthetics score, then sharpness (variance of the Laplacian), resolution, the earlier shot and the ID. Clicking a photo makes it the cover; members can be removed and restored, and each group has a checkbox.
- Nothing is written until Stack N Groups… is confirmed. Then, group by group, each photo is read again; a group with any photo no longer the user's, trashed, locked/hidden or already stacked is skipped as changed. `POST /stacks` sends the cover first; if the response names another primary, `PUT /stacks/{id}` sets it and the response is checked. A failed group shows the server's message and is never sent again, because a failed request may still have created a stack. Shared grids are invalidated after any stack is created. Stop, closing the sheet, switching account or signing out stop analysis and prevent later requests; a request already sent is recorded, not repeated.
- Each stacked group offers Open Stack…, the existing stack browser, for changing the cover or unstacking. The browser also has Move Others to Recently Deleted…: after confirmation it reads the stack again, refuses if its cover changed, and moves only members that are still in the stack, still the user's and not the cover to Recently Deleted (`force: false`). It's unavailable when the server's trash is disabled, in the Locked Folder and in Recently Deleted. Nothing is ever deleted automatically or permanently.

`Tests/SimilarPhotosChecks.swift` (similar-photos in `scripts/check-integration.py`) covers time boundaries, the 60-second and 20-member limits, complete-link chains, sensitivities, eligibility, cover determinism and override, real Vision prints of generated geometric scenes (variants under Normal, different scenes over Loose, distance equal to `computeDistance`, sharpness), paging every page, zero writes before confirmation, revalidation of owner/locked/stack, primary correction, partial failures without retry, selection read-back, analysis failures, the 2,000 limit, a repeated page, and cancel or account switch during analysis and stacking, against a URLProtocol fixture.

Similar-photo clustering runs off the main actor and checks cancellation while merging. A stack changed in the browser is removed from the suggestions; scan again to refresh it. Move Others rechecks the active account and server trash support before sending a recoverable delete, and refuses if trash support is disabled or unknown.
