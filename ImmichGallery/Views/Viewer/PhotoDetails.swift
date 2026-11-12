import MapKit
import SwiftUI

/// Where a photo was taken, for its Places section and the map it opens out to.
struct PhotoPlace: Equatable {
    let latitude: Double
    let longitude: Double
    /// "City, State, Country", or empty.
    let title: String

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// About a kilometre around it, as Immich's map takes a box: "west,south,east,north".
    var nearbyBox: String {
        let d = 0.01
        return "\(max(-180, longitude - d)),\(max(-90, latitude - d)),\(min(180, longitude + d)),\(min(90, latitude + d))"
    }
}

/// The people in a photo, by their faces, as Photos' People and Pets below a photo. A face shows the person's page with
/// the photo selected in it, through the way a Crosslink from another app shows a photo seen in a person.
struct PhotoPeopleRow: View {
    @Environment(LibrarySession.self) private var session
    let assetID: String
    let people: [AssetPerson]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 20) {
                ForEach(people) { person in
                    Button {
                        NotificationCenter.default.post(name: .crosslinkShow, object: session,
                                                        userInfo: ["item": Crosslink.Item.asset(assetID, .person(person.id)),
                                                                   "opensAsset": false])
                    } label: { PhotoPersonFace(person: person) }
                        .buttonStyle(.plain)
                        .help(person.name.isEmpty ? String(localized: "Unnamed Person") : person.name)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }
}

private struct PhotoPersonFace: View {
    @Environment(LibrarySession.self) private var session
    let person: AssetPerson
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.square").font(.largeTitle).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(.rect(cornerRadius: 10))
            Text(person.name.isEmpty ? String(localized: "Unnamed Person") : person.name)
                .font(.callout)
                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .frame(width: 110)
        }
        .task(id: person.id) { image = await session.pipeline.personThumbnail(person.id) }
    }
}

/// Where the photo was taken, as Photos shows it below a photo: the place, a picture of the map with the photo on it,
/// and the photos taken nearby. Double-clicking the map opens it out over the photo, to move around in.
struct PhotoPlaceSection: View {
    @Environment(LibrarySession.self) private var session
    @Environment(PageNavigation.self) private var navigation: PageNavigation?
    @Environment(\.colorScheme) private var colorScheme
    let assetID: String
    let place: PhotoPlace
    let onExpand: (PhotoPlace) -> Void
    @State private var snapshot: NSImage?
    @State private var pinPhoto: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Places").font(.title2)
                if !place.title.isEmpty { Text(place.title).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if navigation != nil {
                    Button("Nearby Photos") {
                        let query = ExploreMapQuery(bbox: place.nearbyBox, favorites: false, archived: false, partners: false,
                                                    after: nil, before: nil)
                        navigation?.open(GridRoute(source: .explore(.map(query)),
                                                   title: place.title.isEmpty ? String(localized: "Nearby Photos") : place.title))
                    }
                    .buttonStyle(.link)
                }
            }
            ZStack {
                if let snapshot {
                    Image(nsImage: snapshot).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
                pin
            }
            .frame(height: 260)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
            .onTapGesture(count: 2) { onExpand(place) }
            .help("Double-click to open the map")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(place.title.isEmpty ? String(localized: "Map") : place.title))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onExpand(place) }
        }
        .task(id: "\(place.latitude),\(place.longitude)-\(colorScheme == .dark)") { await loadSnapshot() }
        .task(id: assetID) {
            // The viewer shows the larger preview, so the thumbnail is often not cached yet.
            pinPhoto = session.pipeline.cachedThumbnail(assetID, size: .thumbnail)
            if pinPhoto == nil { pinPhoto = await session.pipeline.thumbnail(assetID, size: .thumbnail) }
        }
    }

    /// The photo on the map, where it was taken, as Photos marks it.
    private var pin: some View {
        VStack(spacing: 0) {
            Group {
                if let image = pinPhoto {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 8))
            .padding(3)
            .background(.white, in: .rect(cornerRadius: 10))
            Image(systemName: "arrowtriangle.down.fill").font(.caption).foregroundStyle(.white).offset(y: -3)
        }
        .shadow(radius: 3)
        .offset(y: -38) // The triangle's tip on the place.
    }

    private func loadSnapshot() async {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 2500, longitudinalMeters: 2500)
        options.size = CGSize(width: 960, height: 300)
        options.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        snapshot = try? await MKMapSnapshotter(options: options).start().image
    }
}

/// The map a photo's Places section opens out to, over the photo: to move around in, until Back.
struct ExpandedPhotoMap: View {
    let place: PhotoPlace

    var body: some View {
        PhotoLocationMap(coordinate: place.coordinate, leavesZoomKeys: false)
            .id("\(place.latitude),\(place.longitude)")
            .ignoresSafeArea(edges: .bottom)
    }
}

/// A photo's place on a map, MapKit's own view rather than SwiftUI's `Map`, so that in Info it can leave ⌘+ and ⌘− to
/// the View menu: AppKit offers key equivalents to every view in the window, and the map took them even while
/// scrolled out of sight, so they zoomed it instead of the open photo or the grid. It still zooms with the trackpad.
struct PhotoLocationMap: NSViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    /// Info's small map passes ⌘+ and ⌘− on; the opened-out map zooms with them.
    var leavesZoomKeys = true

    func makeNSView(context: Context) -> MapView {
        let map = MapView()
        map.leavesZoomKeys = leavesZoomKeys
        map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000), animated: false)
        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        map.addAnnotation(pin)
        return map
    }

    func updateNSView(_ map: MapView, context: Context) { map.leavesZoomKeys = leavesZoomKeys }

    final class MapView: MKMapView {
        var leavesZoomKeys = true

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if leavesZoomKeys, flags.contains(.command), let key = event.charactersIgnoringModifiers, ["+", "=", "-"].contains(key) {
                return false
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// The open photo's zoom in the toolbar, as Photos has it: a slider from fitted to eight times, on a scale that gives
/// the first steps room.
struct PhotoZoomSlider: View {
    let scale: Double
    let zoom: (Double) -> Void

    static let maximum = 8.0

    var body: some View {
        Slider(value: Binding(get: { log(max(1, scale)) / log(Self.maximum) },
                              set: { zoom(pow(Self.maximum, $0)) }),
               in: 0...1) {
            Text("Zoom")
        } minimumValueLabel: {
            Image(systemName: "minus").font(.caption2)
        } maximumValueLabel: {
            Image(systemName: "plus").font(.caption2)
        }
        .controlSize(.small)
        .frame(width: 140)
        // Its own capsule, apart from Back's, as in Photos.
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .adaptiveGlass(in: .capsule)
        .help("Zoom")
    }
}
