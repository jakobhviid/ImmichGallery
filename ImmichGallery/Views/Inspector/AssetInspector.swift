import MapKit
import SwiftUI

struct AssetInspector: View {
    @Environment(LibrarySession.self) private var session
    let assetID: String?
    var scrollable = true

    @State private var state = AssetInspectorState()
    @State private var attempt = 0 // Retry
    @State private var peopleRevision = 0 // People

    var body: some View {
        Group {
            switch state.phase(for: assetID) {
            case .none:
                ContentUnavailableView("No Selection", systemImage: "info.circle",
                                       description: Text("Select a single photo to see its details."))
            case .failed:
                ContentUnavailableView {
                    Label("Couldn't Load Info", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Try Again") { attempt += 1 }
                }
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .current, .stale:
                if let asset = state.asset {
                    // The previous photo's details stay, read-only and dimmed, until the next one's arrive, instead
                    // of a spinner flashing at every step through the photos. Its editing controls go: they would
                    // write to the photo no longer selected.
                    let editable = state.canEdit(assetID)
                    Group {
                        if scrollable {
                            ScrollView { details(asset, editable: editable) }
                        } else {
                            details(asset, editable: editable)
                        }
                    }
                    .opacity(editable ? 1 : 0.5)
                    .allowsHitTesting(editable)
                    .accessibilityHidden(!editable)
                    .overlay(alignment: .top) {
                        if !editable { ProgressView().controlSize(.small).padding(.top, 8) }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .peopleChanged, object: session.services)) { _ in peopleRevision += 1 }
        .task(id: "\(assetID ?? "")-\(session.metadata.revision)-\(attempt)") { // Metadata: reload after edits.
            await AssetInspectorState.load(assetID, asset: { try await session.client.asset($0) },
                                           albums: { (try? await session.client.albums(containing: $0)) ?? [] },
                                           update: { $0(&state) })
        }
        .task(id: "\(assetID ?? "")-\(peopleRevision)") {
            guard peopleRevision > 0, let assetID else { return }
            if let loaded = try? await session.client.asset(assetID), !Task.isCancelled {
                state.loaded(loaded, for: assetID)
            }
        }
    }

    private func details(_ asset: AssetResponse, editable: Bool) -> some View {
        let exif = asset.exifInfo
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.originalFileName)
                    .font(.headline)
                    .textSelection(.enabled)
                if let date = ImmichDate.parse(asset.localDateTime) {
                    Text(ImmichDate.long(date)).foregroundStyle(.secondary)
                }
            }

            if editable {
                MetadataInspectorControls(asset: asset).id(asset.id) // Metadata
            } else if let description = asset.exifInfo?.description, !description.isEmpty {
                Text(description)
            }

            if let exif, exif.make != nil || exif.model != nil || exif.lensModel != nil {
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text([exif.make, exif.model].compactMap { $0 }.joined(separator: " "))
                            .font(.callout.weight(.semibold))
                        if let lens = exif.lensModel {
                            Text(lens).font(.caption).foregroundStyle(.secondary)
                        }
                        let specs = exposureSpecs(exif)
                        if !specs.isEmpty {
                            HStack(spacing: 0) {
                                ForEach(Array(specs.enumerated()), id: \.offset) { i, spec in
                                    if i > 0 { Divider().frame(height: 14) }
                                    Text(spec).font(.caption.monospacedDigit()).frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 6) {
                    row("Type", asset.originalMimeType ?? asset.type.rawValue.capitalized)
                    if let w = exif?.exifImageWidth ?? asset.width, let h = exif?.exifImageHeight ?? asset.height {
                        row("Dimensions", "\(w) × \(h)")
                        row("Resolution", "\(String(format: "%.1f", Double(w * h) / 1_000_000)) MP")
                    }
                    if let bytes = exif?.fileSizeInByte {
                        row("Size", bytes.formatted(.byteCount(style: .file)))
                    }
                    if let duration = asset.duration?.milliseconds, asset.type == .video {
                        row("Duration", Duration.formatMilliseconds(duration))
                    }
                }
            }

            if let lat = exif?.latitude, let lon = exif?.longitude {
                VStack(alignment: .leading, spacing: 6) {
                    let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    InspectorMap(coordinate: coordinate)
                    .frame(height: 180)
                    .clipShape(.rect(cornerRadius: 10))
                    .id("\(lat),\(lon)")
                    let place = [exif?.city, exif?.state, exif?.country].compactMap { $0 }.joined(separator: ", ")
                    if !place.isEmpty { Text(place).font(.callout) }
                }
            }

            section("People") {
                InspectorPeopleList(people: asset.people ?? [])
            }

            if !state.albums.isEmpty {
                section("Albums") {
                    FlowText(state.albums.map(\.albumName), symbol: "rectangle.stack")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exposureSpecs(_ exif: Exif) -> [String] {
        var specs: [String] = []
        if let iso = exif.iso { specs.append("ISO \(iso)") }
        if let focal = exif.focalLength { specs.append("\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm") }
        if let f = exif.fNumber { specs.append("ƒ\(f.formatted(.number.precision(.fractionLength(0...1))))") }
        if let t = exif.exposureTime { specs.append("\(t) s") }
        return specs
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct FlowText: View {
    let items: [String]
    let symbol: String

    init(_ items: [String], symbol: String) {
        self.items = items
        self.symbol = symbol
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { Label($0, systemImage: symbol).font(.callout) }
        }
    }
}

/// The photo's place. MapKit's own view rather than SwiftUI's `Map`, so it can leave ⌘+ and ⌘− to the View menu: AppKit
/// offers key equivalents to every view in the window, and the map took them even while scrolled out of sight, so
/// they zoomed it instead of the open photo or the grid. It still zooms with the trackpad.
private struct InspectorMap: NSViewRepresentable {
    let coordinate: CLLocationCoordinate2D

    func makeNSView(context: Context) -> MapView {
        let map = MapView()
        map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000), animated: false)
        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        map.addAnnotation(pin)
        return map
    }

    func updateNSView(_ map: MapView, context: Context) {}

    final class MapView: MKMapView {
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if flags.contains(.command), let key = event.charactersIgnoringModifiers, ["+", "=", "-"].contains(key) {
                return false
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
