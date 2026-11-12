# Native macOS integrations

Implemented for macOS 26 without new dependencies or targets. Since 0.2.0 the deployment target is macOS 15; `OSCompatibility.swift` provides the fallbacks.

- macOS 15 fallbacks: Liquid Glass becomes `.regularMaterial`; the toolbar's fixed spacer is omitted. The multi-item drag container (`dragContainer`, `dragContainerSelection`) is macOS 26 only, so on macOS 15 each grid cell drags an `NSItemProvider` (`legacyAssetDrag`) carrying the dragged photo's original as a file promise (under its real name and kind, see Transfer type below) and the selected asset IDs. Album rows read those IDs from the drag pasteboard case-insensitively (AppKit lowercases the custom type) in one combined drop handler (`AlbumRowUploadDrop`), because macOS 15 delivers drops only to the innermost of two stacked drop targets. The viewer drags its single original on both systems.
- macOS 15 SwiftUI pitfalls found on a Sequoia VM in 0.2.1 (0.2.0 crashed or froze at 100% CPU):
  - A toolbar item must not bind a popover straight to an `@Observable` property, or read changing observable state in its own body. Put the changing parts in child views and use local `@State` for the popover (`UploadToolbar`, `AccountNotificationBell`, `ExploreMapFiltersButton`).
  - Don't disable a whole popover with `.disabled(busy)` while it becomes key; it loops in AttributeGraph.
  - Toolbar items attached to the `NavigationSplitView` combined with a pushed page's own toolbar loop forever. On macOS 15 the global items live on the detail `NavigationStack` (`GlobalToolbar`), and the grid's zoom buttons aren't a `ControlGroup`.
  - An `AVPlayerView` draws above SwiftUI overlays; a sheet keeps the width it had while loading; a borderless `Menu` shows its own indicator.

- On macOS 26+ each grid cell has a single drag source, `OriginalTransfer`: the original file first (its kind and real filename, see Transfer type below), then the original-drag marker and, outside the Locked Folder, the asset's own ID for album drops. A container drag yields one item per selected asset; album rows merge their IDs in order without repeats. A second `draggable` of the asset IDs alone used to compete with the file, and the Finder saved that JSON as "Immich Gallery Asset Selection" (#44). `Tests/OriginalDragChecks.swift` (in `scripts/check-integration.py`) loads real item providers offline: representation order, advertised type and suggested name per kind, no detail requests until a drag, fallbacks for missing or slow details, details of a multi-item drag read at once, original bytes, the receiver's copy outliving the cache, same-named originals, album IDs, failed downloads and Locked Folder revocation. Finder and other apps' drops still need a manual UI check.
- Internal grid and viewer drags carry an original-drag marker alongside their file promise. Upload targets reject that marker and the album asset-ID type before highlighting or loading file URLs, including when AppKit lowercases the pasteboard types. macOS 15 viewer drags use the explicit item provider to preserve the marker. Album asset drops still use the existing selected IDs. `Tests/UploadDropChecks.swift` checks internal markers, file-only provider fallback through the pasteboard, and external file eligibility without loading contents.

- Drag promises download originals on demand. Downloads use the response's suggested filename, strip path components, map HTTP 401 to the session-expired error, and clean up failed moves. Receivers get their own copy rather than the cached file in place, so a file they keep doesn't vanish when the cache expires. Files expire after ten minutes; cleanup runs on startup, every minute, and termination. Preview files have a separate directory and remain leased while Quick Look uses them. Cleanup also handles the previous cache layout.
- Space previews selected items in grid order, with a maximum of 20 originals. Quick Look opens when the first original arrives and adds the others as they finish. Space during downloads cancels them. The originating window is captured before downloading. Return and double-click still open the viewer.
- AppModel owns one AccountServices for the signed-in account. Windows create a thin LibrarySession lazily, keyed by service identity. Bootstrap and notification polling run once per account. Pipeline, uploads, preferences and sharing data are shared; navigation, selection and presentations are per window. Commands resolve the active window through FocusedValues.librarySession. See Integration.md for integration verification.
- Album menus offer new windows and tabs. Scene windows get a common tabbing identifier; tab routes use native preferred tabbing rather than polling arbitrary NSApp windows. Command-T and Show Tab Bar are available.
- Search Photos and Open Album require a saved account through the small MacIntentAccount helper. Routes form a queue handled by the app's scene even when no library window exists. Sign-out clears the queue. Intent routing does not wait for bootstrap.
- Export completion always reveals saved files in Finder, including while the app is inactive. SystemNotifier is also available for opt-in background notifications. Denied notification permission shows a System Settings hint.
- Italian strings include explicit singular/plural forms in English and Italian, including separate substitutions for exported and failed counts. Archive's sidebar noun remains "Archivio"; its action uses "Archivia". Tabs use "scheda". Reviewed library, favorites, info, export, archive and recently deleted terminology.

## Toolbar, navigation and grid shape

- Every toolbar in the main window is customizable (`toolbar(id:)`): the window's own (`library`, Import) plus one per page (`assetGrid`, `album`, `person`, `locked`, `viewer`, …), each ending with the search item (`pageToolbar`). Mixing customizable and plain toolbars in one window isn't supported, so the only plain toolbars left are in other windows or sheets (Administration, the person sheet's Done). Item IDs are unique within each page.
- The search field is an `NSSearchField` in a plain toolbar item rather than `.searchable`, which made AppKit throw in a customizable toolbar; see `Search.md`.
- Below 980 points of detail width (`toolbarCompact`), segmented pickers such as Years / Months / All Photos become pop-up menus and the search field a button, before items move to the overflow menu.
- Library shows Years, Months or All Photos (⌘1–⌘3). The grid shows square thumbnails or each photo in its own shape (`gridAspectRatio`). Years and Months keep the grid's toolbar items, disabled, so the layout stays put.
- Zooming keeps the first visible photo in place with `ScrollViewProxy.scrollTo`. Each grid cell is a single view (`gridCell`, a `ZStack`), including the availability-based drag modifier inside that container: a cell that could be zero or several views (a `Group` around `if #available`) made the lazy grid build every cell before the target to count them, about 10 seconds on the first zoom deep in a large library. `Tests/GridScrollAnchorChecks.swift` counts the cells built by such a scroll.
- Pages open in place (`PageNavigation`): one `NavigationStack(path:)` per detail column, with a path per sidebar item, reset when the sidebar selection changes, and without the push animation. Crosslink navigates through it too (see Immich Crosslink below), not a path of its own. There is still exactly one detail stack, so the macOS 15 split-view/pushed-toolbar loop above is not reintroduced; `GlobalToolbar` still attaches to the split view on 26 and to the detail stack on 15.
- An open photo replaces the system Back with its own toolbar Back to the grid (`navigationBarBackButtonHidden(model.viewerID != nil)` on `AssetGridHost`); the page's Back reappears once the photo is closed. Only one Back is shown at a time.
- The Info inspector keeps the previous photo's details while the next one loads, dimmed, read-only and without its editing controls, so nothing can be written to a photo no longer selected. A failed load shows its own error with Try Again instead of the previous photo. A description being typed is saved to the photo it was started for when focus leaves or the controls go away. `Tests/InspectorEditingChecks.swift` drives the real load routine with late, cancelled and failed answers.
- Album names, album descriptions and person names (`InlineEditableText`) are plain buttons until edited, so they can be focused and activated from the keyboard (with Keyboard Navigation on) and VoiceOver, which reads the field name and its value. Return saves once, clicking away saves, Escape cancels without saving. Line breaks already in a description are kept. Which key, if any, types a new line in the multi-line field is the system's text-field behavior and has not been verified, so the app documents no shortcut for it. Owner checks are unchanged: non-owners see plain text.
- Static review for macOS 15 (no VM run): availability guards remain around `ToolbarSpacer`; the toolbar's changing parts (search field, upload, notifications) are child views with local state; no `ControlGroup` or popover bound to observable state was added. macOS 15 behavior of this toolbar has not been run.

## Transfer type and viewer gestures

File promises carry the original's suggested name, but a receiver using the drag's data flavor (including Mac Catalyst apps) may get only its type and bytes. Grid timeline DTOs have no original filename, so `OriginalFile` reads the asset's details (`GET /assets/{id}`) only for the dragged items when the drag starts. Multi-item drags start those requests together and wait at most one second; the first name/type decision is retained even if a response arrives later.

For JPEG, HEIC, HEIF, PNG, GIF, WebP, TIFF, QuickTime and MPEG-4, the original is advertised with its exact format from the filename extension, constrained to Immich's image or video kind. CoreTransferable has one static file representation for each supported format, and exactly one is exported. Other formats keep the generic image/movie/data kind; missing or late details fall back to data named after the asset ID. No bytes are converted. File, internal marker and album IDs remain in that order. The receiver receives a copy rather than access to the expiring cache.

The exact type lets data-only receivers decode supported images and derive a useful temporary extension without a suggested filename. `Tests/OriginalDragChecks.swift` checks the exported format, untouched bytes, and an unnamed data receiver's file, in addition to the existing drag invariants. The user confirmed Finder/Scrivania original-file export, then confirmed the WhatsApp image drop after the exact-format change in the local test4 build. Unsupported formats and slow metadata lookups retain the generic fallback.

The viewer's drag source is attached to the displayed image, not its container or navigation controls. It is disabled above 1× zoom; the pan gesture is enabled only when zoomed. Videos retain their own drag source.

Zoomed photos also pan with two-finger trackpad scrolling, including momentum, in the inline and presentation viewers. `ViewerScrollPan` consumes native scroll deltas on both axes only inside the visible photo viewport in its own window while zoomed. At 1×, scroll events pass through without panning the image. Photo details are accessed through the toolbar Info inspector. `Tests/ViewerScrollPanChecks.swift` covers both axes, event consumption, pointer/window scope, zoom reset and detached views. The updated Dev app was built, installed and opened; earlier automated UI scrolling confirmed vertical panning. The embedded details used for the former at-fit scrolling check were removed in 0.7.1. Physical trackpad gestures and horizontal UI movement remain manual checks; the automation produced no visible horizontal movement.

At fit, a completed two-finger swipe that is mostly horizontal shows the previous or next photo in the inline and presentation viewers (issue #50). `ViewerSwipeNavigation` watches phased, precise scroll events inside the visible photo viewport of the current viewer, in its own key window while the app is active. It changes photo once, when the fingers lift after at least 40 points of horizontal travel; short, cancelled, diagonal and vertical gestures do not navigate, and momentum never adds another change. Vertical gestures do not navigate; photo details live in the separate Info inspector. The direction follows the scroll deltas, which already reflect the user's scroll direction setting, so the photo moves with the content like any horizontal scroll view. When AppKit reports that two-finger Swipe between pages is off (`NSEvent.isSwipeTrackingFromScrollEventsEnabled` false), two-finger scrolls are left alone; separate three-finger swipe events are not handled. Mouse wheels, unphased scrolling, videos, zoomed photos (`ViewerScrollPan` keeps panning), other windows and inactive windows are untouched. Swipes reuse the existing previous/next navigation and stop at the first and last item, including in repeating slideshow sequences, where the arrow keys still wrap. AppKit's `trackSwipeEvent` was not used: it drives an animated page transition and cannot be exercised offline. `Tests/ViewerSwipeNavigationChecks.swift` feeds synthetic AppKit scroll events through the real view for threshold, dominance, phases, cancellation, momentum, the Swipe between pages setting, zoom, window/viewport scope, a replaced viewer and detaching; `scripts/check-viewer-state.py` covers the sequence boundaries. A physical trackpad check is still required.

## Verification for review fixes

The required Debug command was run without launching the app:

```
xcodebuild -project ImmichGallery.xcodeproj -scheme ImmichGallery -configuration Debug -derivedDataPath build/DerivedData build
```

Build succeeded with no warnings. Local logs and binaries remain ignored under build/.

- `python3 scripts/check-mac-localization.py`: checks extracted strings, catalog coverage and format placeholders, including plural substitutions.
- `swift scripts/check-mac-plurals.swift`: reads compiled localization resources, checks singular/plural output with different selected/total and exported/failed counts, and distinguishes archive noun/verb. It does not run the app executable.
- `scripts/check-mac-transfer-cache.swift`: compiled against the real API extension and checks fresh/expired drag files, leased previews, release and legacy cleanup in an isolated temporary directory. No network or Keychain access.
- Inspected Debug's generated `Metadata.appintents/extract.actionsdata`: both SearchPhotosIntent and OpenAlbumIntent, their parameters and both shortcuts are present with this Xcode toolchain. The reported Release-only extraction issue does not reproduce; no ENABLE_DEBUG_DYLIB or project-file change is needed.

No live server was contacted, no Keychain item was read, and no app was launched during this review-fix pass. Finder drops, Quick Look rendering, native tab attachment, no-window Shortcuts routing and notifications remain manual checks for the parent's single merged app. Do not launch individual worktree builds: they share the app bundle ID and saved account.

## Immich Crosslink

[Immich Crosslink](https://jakob.hviid.phd/immich-crosslink/) (draft 0.2) is an open protocol for links between Immich
apps on the same computer: each announces itself in its Info.plist, registers the `immich-crosslink` scheme, and names
an item by Immich's own web path and the server's address.

- **Announcing:** `Config/Info.plist` has `ImmichCrosslink` (`Version`, `Shows` asset, album, person, place and
  page) and the Crosslink URL type, from the project build settings `IMMICH_CROSSLINK_SCHEME` and
  `IMMICH_CROSSLINK_VERSION`. Release: `immich-crosslink`, `0.2`. Dev (Debug): `immich-crosslink-dev`, `0.2-dev`, so
  Dev never takes the public app's links nor appears to other apps as taking part; `Crosslink.scheme` (`#if DEBUG`)
  matches, and Dev sends, receives and finds apps by its own scheme only, so it lists no public participant.
  `Tests/DevelopmentAppChecks.py` checks both processed plists (Xcode's build settings, nothing built);
  `scripts/dev-app.py` checks the built Dev bundle.
- **The links:** `App/Crosslink.swift`, Foundation only: an item's Immich path, its crosslink and web address, and
  reading a link into the protocol's three results (show, cannot show, invalid), with the server compared as the
  protocol says. `Tests/CrosslinkChecks.swift` runs the protocol's test links (`Tests/Fixtures/crosslink-links.json`,
  `tests/links.json` of the draft at 8a3c16e): every link made byte for byte, every link read to the given result,
  in the protocol's scheme; a link in another scheme than the build's is invalid.
- **Sending:** photos (grid and viewer), albums (Albums page and sidebar), people and the Places page's cities get
  **Open in Immich** and **Copy Immich Link**, the
  item's web address (both off with Settings ▸ Other Apps ▸ Immich Web App, `crosslink.webLinks`), and **Show in *app*** for each other app announcing the item's kind, by the name (the bundle's display
  name) and icon macOS gives it, sent to that app alone (`NSWorkspace.open(_:withApplicationAt:configuration:)`). A photo's link carries the
  album, person, Favorites or Archive it is seen in. The list of apps (`CrosslinkDirectory`) is read again when the
  app becomes active and when another app launches; both builds of this app are left out.
- **Receiving:** `MacIntegrationLifecycle` queues the build's Crosslink URLs for the scene, which opens them once the
  account is known. A link only navigates, for the signed-in account and its user: a photo opens in the grid it was
  seen in (or All Photos), an album, person or page as in Immich's web app, a place as Immich's metadata search. A link
  for another server or user, one this app cannot show, or an invalid one gets an alert and nothing else; no link
  switches accounts or asks to sign in. The same alert shown again while on screen is not repeated.
- **Locked Folder:** a link to an asset whose `visibility` is `locked` is refused with an alert once its record is
  fetched, before any grid, image cache or window of its own; the folder is not unlocked or opened for it. The
  stand-alone photo window (`WidgetPhotoWindow`, also the widget's) refuses one too, before any image.
- **Only the latest link navigates:** `App/CrosslinkNavigation.swift` gives each link a ticket. A new link, the user
  choosing a page or pushing/popping one, the window closing, signing out or switching accounts make earlier tickets
  stale and cancel their tasks; after every wait (window lookup, person, asset, grid) a stale link stops with no
  navigation, window or alert. `CrosslinkReceiver.navigation` covers links looking for a window; in each window the
  detail column's `PageNavigation` owns the link (`links`) and its dispatch (`Views/PageNavigation+Crosslink.swift`),
  so there is no second navigation path in `MainView`. The user choosing another page (`selectionChanged`, `reset`),
  opening one from a page (`open`) or pushing/going back in the stack (`setPath` on the page shown) makes the link
  stale; the link's own page (`linkShow`) and push (`linkOpen`) do not, and a stack echoing back the same path or the
  old page's stack going away does not either. Choosing the page already shown is not a move. A link sets its page
  and pushes in the same turn (the person once fetched), so the page's new stack starts with the pushed page: no
  fixed delay. `Tests/CrosslinkNavigationChecks.swift` runs the steps with a fake server and window,
  `Tests/CrosslinkPageNavigationChecks.swift` the real `PageNavigation` and dispatch with a fake window: own pushes
  keep the link current, user moves, closing and a newer (even invalid) link make a late person answer do nothing.
- **Settings ▸ Other Apps:** the protocol's **Immich Crosslink** switch (`crosslink.enabled`, on by default), whose
  description ends in a **Learn more…** link to the protocol, then each app that takes part by its bundle's display
  name and icon, with its switch (`crosslink.hidden`), and a description of what they do. Apps seen are remembered
  (`crosslink.seen`: name and last-seen date per bundle id): one not found now is listed as Not found, keeps its
  switch, and has **Forget**, which removes it and its switch now; one unseen for 30 days is forgotten. With none seen, the section links to the protocol's participants page. With the main switch off, a
  received link only says so, with Turn On. **Immich Web App** has the switch for Open in Immich and Copy Immich Link
  (`crosslink.webLinks`).
- **Other apps are found in `/Applications` only:** the sandboxed app reads another app's Info.plist through
  `Bundle(url:)`, which on macOS 27 works for copies in `/Applications` and gives nothing for `~/Applications` or a
  build folder (found with Immich Mount Dev and two test apps).
- **Manual checks:** Show in Immich Mount and the test apps in the menus, and opening each kind of link with
  `open 'immich-crosslink:…'`.

## Deliberate omissions

Widgets are covered in `Widget.md`. A menu bar extra and unattended export intent remain outside this change. No project settings were changed by the review fixes.

## Locked Folder

Unlocked grids use a separate `LibrarySession` backed by `LockedFolderMedia`, an uncached client and a memory image cache. Quick Look, drag and clipboard originals use a per-unlock directory under `MacTransferCache.lockedRoot`. Locking revokes that directory before deleting it, preventing late downloads from recreating files. Copied content is cleared only while it still owns the pasteboard. Files are also removed at quit and at the next launch.

Touch ID unlocks the Locked Folder after one unlock with the PIN, because Immich accepts only the PIN. That PIN is kept per server URL and user ID in the login keychain, under the bundle's own service, so Dev and Release keep separate PINs. The keychain item has no biometric access control and no extra entitlement or signing change is used: the protection is the app's own Touch ID check, and otherwise the PIN has the same keychain protection as the saved account credential. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is requested, but its data-protection guarantees aren't verified for the file-based login keychain and aren't relied on.

A PIN is kept only when Touch ID has enrolled fingerprints, only after the server confirmed an elevated session for the same unlock attempt, account and window, with the setting still on and no PIN forgotten since the attempt started. It's stored with the enrollment state, and used only when that state matches before and after the fingerprint is read; a record without it, with another one, or unreadable is forgotten and the PIN field takes over. A wrong-PIN answer from the server (HTTP 400 from `auth/session/unlock`) forgets it; offline, timeouts, rate limits, server errors and an expired login keep it. Sign-out, removing an account, a saved login refused at launch, and turning the setting off or on forget the PINs concerned. A keychain failure while forgetting stops sign-out or removal like an account vault failure, and turning the setting on is undone; a failure while keeping the PIN still unlocks with an explanation. Switching accounts relocks and invalidates the pending fingerprint read without forgetting a still-saved account's PIN. The offline `locked-folder-touch-id` check replaces the keychain functions and Touch ID; hardware Touch ID needs a manual pass on a Mac with a sensor.

An unlock discarded by Lock, leaving the page, sign-out or an account switch is never shown and its error isn't reported. When the server may have unlocked for it (it answered, or the request was cancelled or failed in flight after being sent), one relock is sent with that attempt's own account from a task of its own, since the attempt's task may already be cancelled; a server that answered the unlock with an error gets no relock. A later unlock on the same server waits for such a relock, so it can't lock the new session. `scripts/check-locked-folder-discard.py` runs the real unlock against a fake URLSession server: an unlock cancelled in flight after reaching the server, a new unlock during the relock, a discarded successful answer, a relock started from a cancelled task, and a current wrong PIN.

Locking clears all windows sharing the account session. Screen lock, sleep, leaving the page and the Lock button lock immediately. Switching to another app allows a 15-minute grace period, enforced locally because background notification polling can extend the server unlock. Returning after that deadline still locks before cancelling the inactivity timer.
