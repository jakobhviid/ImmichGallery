#!/usr/bin/env python3
"""Compile/run offline integration regressions without starting ImmichGallery.
All clients use URLProtocol fixtures; credential access uses in-memory stubs.
"""
from pathlib import Path
import subprocess
import concurrent.futures

repo = Path(__file__).resolve().parent.parent
out = repo / 'build/integration-checks'
out.mkdir(parents=True, exist_ok=True)
api = sorted(str(p.relative_to(repo)) for p in (repo / 'ImmichGallery/API').glob('*.swift'))
models = [f'ImmichGallery/API/{s}.swift' for s in ['Models', 'Models+Albums', 'Models+Assets', 'Models+People']]
app = lambda s: f'ImmichGallery/App/{s}.swift'
support = lambda s: f'ImmichGallery/Support/{s}.swift'
cases = {
    'quick-look-downloads': ['ImmichGallery/Views/MacIntegration/MacQuickLook.swift', 'Tests/QuickLookDownloadChecks.swift'],
    'password-banner': api + ['Tests/PasswordBannerChecks.swift'],
    'metadata-state': models + ['ImmichGallery/API/Models+Metadata.swift', app('MetadataState'), 'scripts/verify-metadata-state.swift'],
    'admin-refresh': models + ['ImmichGallery/API/Models+Admin.swift', 'ImmichGallery/API/ImmichClient+Admin.swift', app('AdminModel'), 'scripts/check-admin-refresh.swift'],
    'paging-and-services': api + [app(s) for s in ['AppModel', 'AssetGridModel', 'GridArrangement', 'AlbumsActions', 'LockedFolderMedia', 'LockedFolderTouchID', 'MetadataState', 'SharingModel', 'UploadQueue', 'FinderAccessModel']] + [support('ImagePipeline'), support('Formatters'), 'FileProviderShared/FinderAccessShared.swift', 'scripts/check-search-paging.swift'],
    'sharing': api + [app('SharingModel'), 'scripts/checks/SharingModelCheck.swift'],
    'upload': api + [app('UploadQueue'), 'scripts/verify-upload.swift'],
    'map-annotation': api + [support('ImagePipeline'), app('ExploreClustering'), 'ImmichGallery/Views/Albums/RemoteThumbnail.swift', 'ImmichGallery/Views/Explore/ExploreMapAnnotation.swift', 'Tests/MapAnnotationChecks.swift'],
    'explore': api + [support('ImagePipeline'), app('ExploreClustering'), app('ExploreFolders'), 'Tests/ExploreChecks.swift'],
    'people-cache': api + [support('ImagePipeline'), 'scripts/checks/people-network.swift'],
    'search': api + ['scripts/check-search.swift'],
    'oauth': api + ['Tests/OAuthChecks.swift'],
    'locked-folder-touch-id': api + [app('LockedFolderTouchID'), 'Tests/LockedFolderTouchIDChecks.swift'],
    'tag-picker': api + ['ImmichGallery/Views/Explore/ExploreTagPicker.swift', 'Tests/ExploreTagPickerChecks.swift'],
    'grid-context-menu': ['ImmichGallery/Views/Grid/DeferredContextMenu.swift', 'Tests/GridContextMenuChecks.swift'],
    'grid-scroll-anchor': ['ImmichGallery/Views/Grid/GridCell.swift', 'Tests/GridScrollAnchorChecks.swift'],
    'viewer-scroll-pan': ['ImmichGallery/Views/Viewer/ViewerScrollPan.swift', 'Tests/ViewerScrollPanChecks.swift'],
    'viewer-swipe': ['ImmichGallery/Views/Viewer/ViewerSwipeNavigation.swift', 'ImmichGallery/Views/Viewer/ViewerScrollPan.swift', 'Tests/ViewerSwipeNavigationChecks.swift'],
    'sidebar-layout': [app('SidebarLayout'), 'Tests/SidebarLayoutChecks.swift'],
    'library-overview': [app('LibraryOverviewArrangement'), 'Tests/LibraryOverviewChecks.swift'],
    'inspector-editing': models + [app('AssetInspectorState'), 'ImmichGallery/Views/InlineEditableText.swift', 'Tests/InspectorEditingChecks.swift'],
    'search-layout': ['ImmichGallery/Views/Grid/GridHeaderLayout.swift', 'Tests/SearchLayoutChecks.swift'],
    'search-landing': api + [support('ImagePipeline'), 'ImmichGallery/Views/Albums/RemoteThumbnail.swift', 'ImmichGallery/Views/Search/SearchLandingView.swift', 'Tests/SearchLandingChecks.swift'],
    'metadata': models + ['ImmichGallery/API/Models+Metadata.swift', 'scripts/verify-metadata.swift'],
    'transfer-cache': api + ['scripts/check-mac-transfer-cache.swift'],
    'original-drag': api + ['ImmichGallery/Views/Albums/AlbumAssetTransfer.swift', 'ImmichGallery/Views/Upload/UploadDropPolicy.swift', 'ImmichGallery/Views/MacIntegration/OriginalTransfer.swift', 'Tests/OriginalDragChecks.swift'],
    'album-review': api + [app('AlbumsActions'), 'ImmichGallery/Views/Albums/AlbumAssetTransfer.swift', 'scripts/verify-album-review.swift'],
    'albums-arrangement': models + ['ImmichGallery/API/Models+Metadata.swift', app('AlbumsArrangement'), app('CollapsedGroups'), support('Formatters'), 'Tests/AlbumsArrangementChecks.swift'],
    'grid-arrangement': api + [app('GridArrangement'), support('Formatters'), 'Tests/GridArrangementChecks.swift'],
    'shared-links-arrangement': api + [app('SharedLinksArrangement'), support('Formatters'), 'Tests/SharedLinksArrangementChecks.swift'],
    'places-arrangement': models + ['ImmichGallery/API/Models+Metadata.swift', app('PlacesArrangement'), 'Tests/PlacesArrangementChecks.swift'],
    'people-arrangement': models + [app('PeopleArrangement'), 'Tests/PeopleArrangementChecks.swift'],
    'duplicates-arrangement': models + [app('DuplicatesArrangement'), 'Tests/DuplicatesArrangementChecks.swift'],
    'crosslink': [app('Crosslink'), 'Tests/CrosslinkChecks.swift'],
    # Finder access: the File Provider's model, replica, engine and requests, with the API files its target shares.
    'file-provider': [f'ImmichGallery/API/{s}.swift' for s in ['ImmichClient', 'Models', 'Models+Albums', 'Models+Assets', 'Models+Upload',
                                                               'ImmichClient+Albums', 'ImmichClient+Upload']]
                     + sorted(str(p.relative_to(repo)) for p in (repo / 'ImmichGalleryFileProvider/Core').glob('*.swift'))
                     + ['FileProviderShared/FinderAccessShared.swift', 'Tests/FileProviderChecks.swift'],
    # The extension's framework-facing parts: its XPC listener over real XPC, SDK-built errors, capability bits.
    'file-provider-framework': [f'ImmichGallery/API/{s}.swift' for s in ['ImmichClient', 'Models', 'Models+Albums', 'Models+Assets', 'Models+Upload',
                                                                         'ImmichClient+Albums', 'ImmichClient+Upload']]
                               + sorted(str(p.relative_to(repo)) for p in (repo / 'ImmichGalleryFileProvider/Core').glob('*.swift'))
                               + [f'ImmichGalleryFileProvider/{name}.swift' for name in ['FinderAccessListener', 'FileProviderErrors', 'FileProviderItem']]
                               + ['FileProviderShared/FinderAccessShared.swift', 'Tests/FileProviderFrameworkChecks.swift'],
    'crosslink-navigation': [app('Crosslink'), app('CrosslinkNavigation'), 'Tests/CrosslinkNavigationChecks.swift'],
    'similar-photos': api + [app('SimilarPhotos'), app('SimilarPhotosAnalyzer'), app('SimilarPhotosModel'), app('AssetsStackMutation'), support('ImagePipeline'), support('Formatters'), 'Tests/SimilarPhotosChecks.swift'],
    'crosslink-page-navigation': [app('Crosslink'), app('CrosslinkNavigation'), 'ImmichGallery/Views/PageNavigation.swift', 'ImmichGallery/Views/PageNavigation+Crosslink.swift', 'Tests/CrosslinkPageNavigationChecks.swift'],
}

def check(item):
    name, sources = item
    if name == 'quick-look-downloads':
        # Open only access control for the offline harness; keep production download logic unchanged.
        exposed = out / 'MacQuickLook.swift'
        exposed.write_text((repo / sources[0]).read_text().replace('private ', ''))
        sources = [str(exposed), *sources[1:]]
    binary = out / name
    log = out / (name + '.log')
    with log.open('w') as stream:
        build = subprocess.run(['swiftc', '-parse-as-library', *sources, '-o', str(binary)], cwd=repo, stdout=stream, stderr=subprocess.STDOUT)
        result = build.returncode or subprocess.run([str(binary)], cwd=repo, stdout=stream, stderr=subprocess.STDOUT).returncode
    return name, result, log

with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    results = list(pool.map(check, cases.items()))
for name, result, log in results:
    print(f'{"FAIL" if result else "PASS"} {name}: {log.relative_to(repo)}')
    if result:
        print(log.read_text())
raise SystemExit(any(result for _, result, _ in results))
