# Viewer

View menu and toolbar actions open a separate native macOS full-screen window. Escape or Exit Full Screen closes it and leaves the current item selected in the original grid. Full-screen controls hide after 2.5 seconds without pointer movement, unless the pointer is over the controls or settings are open.

Start Slideshow uses multiple selected assets in grid order. Without a multiple selection, it follows the current collection, lazily loading adjacent buckets/pages. Shuffle loads collection metadata before building a shuffled sequence and an ID-to-index map. This costs O(n) memory and an initial O(n) load; subsequent sequence lookup is O(1). Large-library lazy bucket shuffling remains a future improvement. The settings popover offers a persistent interval, shuffle, fade/none, and a video time limit. Space pauses/resumes, arrows navigate. Videos normally finish before advancing. Playback failure advances immediately; 30 seconds without playback progress also advances, even when the video time limit is off. Repeating a single selected video restarts its player. Ordered collection playback pauses at the end; explicit selection/shuffle sequences repeat. Display sleep is inhibited while an unpaused slideshow runs, and the cursor hides with idle controls. Native video controls remain available, with persistent mute/volume and a playback-speed/loop menu. Slideshow completion takes precedence over video looping.

Edit offers Copy Image with Command-C handled by the focused grid/viewer, leaving text-field copying to the native responder, Copy Original Image, and Copy as File. Preview images use the existing image cache; original image copy downloads to a temporary file and decodes via ImageIO without buffering the compressed original as Data or applying the zoom pipeline's downsampling. File copy downloads into the app's temporary directory and publishes a file URL for Finder or other apps. Only the latest copy is retained, until the next copy or app launch.

View-only rotation is in View, without a keyboard shortcut. Rotation resets when navigating. No image or metadata is changed on the server. Show in All Photos works from View and grid context menus. It loads the target timeline month, switches to Library, selects the asset and scrolls to its cell. Assets excluded from the main timeline, including non-primary stack members, produce an explanatory message.

The opened photo's context menu reuses the grid's asset actions, including Info, albums, favorites, sharing, metadata edits, tags, export, archive and confirmed deletion. It always targets the displayed asset, even if the grid still has a multiple selection. Grid actions retain their selection-aware targets. Ownership, partner and trash restrictions remain shared. Info opens the existing inspector. Copy actions use the viewer's existing clipboard implementation; full-screen presentations also offer copy, export and Show in All Photos without exposing actions that need the grid's sheets or confirmation dialogs.

For issue #7, the updated isolated Dev app was built, installed and launched. Read-only UI checks against the public demo confirmed the opened-photo menu, Info opening the correct inspector, and the grid menu. The offline GridContextMenuChecks and localization checker passed. Server mutations, clipboard destinations, and the full-screen menu were not exercised; macOS 15 compatibility was reviewed from the APIs used without VM testing.

Neighbour preview prefetching uses the slideshow sequence for selection/shuffle and the grid order otherwise, through the existing pipeline. Face overlays belong to the People feature. Optional filmstrips were omitted.

The inline viewer dedicates its viewport to the photo or video. The toolbar's Info button, Command-I and the photo context menu open the existing side inspector with location, people, albums and camera metadata. Details are no longer duplicated below the image, and there is no Info overlay on the photo. The inspector scrolls independently and follows the displayed asset while navigating. Full-screen viewing and slideshows keep their existing layout. Text editing in the inspector does not trigger viewer keyboard shortcuts.

For the Info-inspector update in 0.7.1, all 39 offline integration checks, the viewer-state checks and localization checks passed. The isolated Dev app was built, installed and launched. Read-only demo UI checks confirmed the toolbar Info button opens the inspector, its details follow the next photo, Command-I closes it, and scrolling the photo no longer reveals embedded details. No server mutations were performed. Physical trackpad gestures and macOS 15 runtime behavior were not retested.

## HDR photos

Immich previews are SDR (the server tone maps HDR originals), so on a Mac with an EDR-capable display the viewer downloads the original and decodes it with `kCGImageSourceDecodeToHDR` (macOS 14+). That decode applies Apple and ISO 21496-1 gain maps (HEIC, JPEG, AVIF) and keeps HLG/PQ highlights. Only photos whose decoded image has a content headroom above 1 are shown in HDR; the others keep the SDR preview, and the pipeline remembers them for the session so their original isn't downloaded again. Before downloading, the viewer reads the asset's `originalMimeType` and skips RAW, GIF and other formats that can't carry HDR. On SDR-only displays, or with Settings › Show Photos in High Dynamic Range off, nothing changes.

The HDR bitmap is drawn by `HDRImageLayer`, a layer-backed view over the SDR preview. On macOS 26 the layer sets `preferredDynamicRange = .high`; on macOS 15 it sets `wantsExtendedDynamicRangeContent`. SwiftUI's `Image` tone maps `CGImage` content to SDR even with `allowedDynamicRange(.high)`, which is why a layer is used. The layer ignores mouse events, so zoom, pan, drag-out and face overlays still work on the SDR image underneath. Rotation, zoom and slideshow transitions apply to both. The HDR bitmap uses 8 bytes per pixel, so it's sized to the largest screen, re-decoded at up to 6144 px when zooming in, and not kept in the memory cache; the compressed original stays in the URL cache.

`scripts/check-hdr.sh` compiles the production `ImagePipeline` and `HDRImage` against an in-memory client, generates a gain-map HEIC and an SDR JPEG, and checks the HDR decode, the SDR memo, eviction, failed downloads and the layer's EDR settings. It doesn't launch the app or contact a server.

## Protocol and platform references

Checked the v3.3.5 OpenAPI document at https://raw.githubusercontent.com/immich-app/immich/v3.3.5/open-api/immich-openapi-specs.json:

- POST /auth/login, LoginCredentialDto and LoginResponseDto.
- GET /assets/{id}, AssetResponseDto, originalFileName and localDateTime.
- GET /assets/{id}/thumbnail, size=preview, authenticated binary response.
- GET /assets/{id}/original, authenticated original binary response.
- GET /assets/{id}/video/playback, authenticated video/range playback.
- GET /timeline/buckets and /timeline/bucket, timeBucket, visibility, withPartners and withStacked; TimeBucketsResponseDto and columnar TimeBucketAssetResponseDto.

Cross-checked https://api.immich.app and https://immich.app/docs, and official v3.3.5 web sources SlideshowBar.svelte, SlideshowSettingsModal.svelte, slideshow.store.ts and slideshow-history.ts. These establish persisted timing/transition/order controls, idle hiding, pause and navigation behavior. No upload or sync code is involved.

Apple documentation checked: NSWindow.toggleFullScreen, NSPasteboard.writeObjects, AVPlayer playback/rate/volume/KVO, SwiftUI onContinuousHover and NSHostingView, with macOS availability covered by the deployment target. The full-screen API is available since macOS 10.7. No new framework dependency is needed.

No new server endpoints or feature flags are required. The feature reuses existing v2-compatible media and timeline APIs. Missing/unauthorized resources produce errors rather than enabling any server mutation. Full compatibility with every v2 server was not tested.

## Verification

Debug xcodebuild completed successfully. No new compiler warnings; Xcode emits its standard AppIntents metadata-skipped warning because this app has no AppIntents dependency. git diff --check passes.

Read-only demo.immich.app checks logged in with the public demo account, fetched timeline buckets, a columnar bucket, asset detail, preview and original bytes, and decoded the JSON with the unmodified production Models.swift DTOs. Preview was 161164 bytes and original was 1779462 bytes at test time. A separate metadata search found a video; its playback endpoint returned HTTP 206, video/mp4, for a 1024-byte range. Both one-shot API sessions were logged out. The repeatable assertion check is scripts/check-viewer-responses.sh, accepting a directory of saved demo fixtures. It verifies column lengths, production DTO decoding, video type and ImageIO decoding of preview/original.

Before UI testing was prohibited, an isolated temporary harness explicitly created a demo-only ImmichClient and reused the production viewer/grid. It confirmed image display, native full-screen slideshow entry, Space changing Pause to Play, and idle control hiding. A window-reference error prevented a complete settings-popover check. No further UI runs were made after the user's stop instruction. Clipboard paste destinations, video playback controls, timeline scroll placement and the merged app's menus remain for the parent's single merged UI test.

## Review-fix verification

The review fixes are checked by Debug xcodebuild and `scripts/check-viewer-state.py`, which compiles the production navigation and window-close methods into an isolated assertion executable with an in-memory grid. It does not launch ImmichGallery, create windows, read credentials, access the clipboard, or contact any server. It covers presentation Space/Return/Escape handling, wraparound and prefetch order, coalesced navigation during an async load, same-item video restart generation, boundary pause, close cleanup and preserved selection.

Presentation menu routing also uses the NSWindow delegate's key-window state, since an NSHostingView has no SwiftUI Window scene. Command-C is attached to focused view content rather than a global menu shortcut and explicitly rejects text responders. These UI paths, cursor behavior and AVPlayer failure behavior were inspected and compiled; interactive verification remains deferred under the no-launch instruction.
