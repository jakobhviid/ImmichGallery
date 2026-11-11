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
    'password-banner': api + ['Tests/PasswordBannerChecks.swift'],
    'metadata-state': models + ['ImmichGallery/API/Models+Metadata.swift', app('MetadataState'), 'scripts/verify-metadata-state.swift'],
    'admin-refresh': models + ['ImmichGallery/API/Models+Admin.swift', 'ImmichGallery/API/ImmichClient+Admin.swift', app('AdminModel'), 'scripts/check-admin-refresh.swift'],
    'paging-and-services': api + [app(s) for s in ['AppModel', 'AssetGridModel', 'GridArrangement', 'AlbumsActions', 'LockedFolderMedia', 'MetadataState', 'SharingModel', 'UploadQueue']] + [support('ImagePipeline'), support('Formatters'), 'scripts/check-search-paging.swift'],
    'sharing': api + [app('SharingModel'), 'scripts/checks/SharingModelCheck.swift'],
    'upload': api + [app('UploadQueue'), 'scripts/verify-upload.swift'],
    'map-annotation': api + [support('ImagePipeline'), app('ExploreClustering'), 'ImmichGallery/Views/Albums/RemoteThumbnail.swift', 'ImmichGallery/Views/Explore/ExploreMapAnnotation.swift', 'Tests/MapAnnotationChecks.swift'],
    'explore': api + [support('ImagePipeline'), app('ExploreClustering'), app('ExploreFolders'), 'Tests/ExploreChecks.swift'],
    'people-cache': api + [support('ImagePipeline'), 'scripts/checks/people-network.swift'],
    'search': api + ['scripts/check-search.swift'],
    'oauth': api + ['Tests/OAuthChecks.swift'],
    'tag-picker': api + ['ImmichGallery/Views/Explore/ExploreTagPicker.swift', 'Tests/ExploreTagPickerChecks.swift'],
    'grid-context-menu': ['ImmichGallery/Views/Grid/DeferredContextMenu.swift', 'Tests/GridContextMenuChecks.swift'],
    'viewer-scroll-pan': ['ImmichGallery/Views/Viewer/ViewerScrollPan.swift', 'Tests/ViewerScrollPanChecks.swift'],
    'sidebar-layout': [app('SidebarLayout'), 'Tests/SidebarLayoutChecks.swift'],
    'library-overview': [app('LibraryOverviewArrangement'), 'Tests/LibraryOverviewChecks.swift'],
    'search-layout': ['ImmichGallery/Views/Grid/GridHeaderLayout.swift', 'Tests/SearchLayoutChecks.swift'],
    'search-landing': api + [support('ImagePipeline'), 'ImmichGallery/Views/Albums/RemoteThumbnail.swift', 'ImmichGallery/Views/Search/SearchLandingView.swift', 'Tests/SearchLandingChecks.swift'],
    'metadata': models + ['ImmichGallery/API/Models+Metadata.swift', 'scripts/verify-metadata.swift'],
    'transfer-cache': api + ['scripts/check-mac-transfer-cache.swift'],
    'album-review': api + [app('AlbumsActions'), 'ImmichGallery/Views/Albums/AlbumAssetTransfer.swift', 'scripts/verify-album-review.swift'],
    'albums-arrangement': models + ['ImmichGallery/API/Models+Metadata.swift', app('AlbumsArrangement'), app('CollapsedGroups'), support('Formatters'), 'Tests/AlbumsArrangementChecks.swift'],
    'grid-arrangement': api + [app('GridArrangement'), support('Formatters'), 'Tests/GridArrangementChecks.swift'],
    'shared-links-arrangement': api + [app('SharedLinksArrangement'), support('Formatters'), 'Tests/SharedLinksArrangementChecks.swift'],
    'places-arrangement': models + ['ImmichGallery/API/Models+Metadata.swift', app('PlacesArrangement'), 'Tests/PlacesArrangementChecks.swift'],
    'people-arrangement': models + [app('PeopleArrangement'), 'Tests/PeopleArrangementChecks.swift'],
    'duplicates-arrangement': models + [app('DuplicatesArrangement'), 'Tests/DuplicatesArrangementChecks.swift'],
    'crosslink': [app('Crosslink'), 'Tests/CrosslinkChecks.swift'],
}

def check(item):
    name, sources = item
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
