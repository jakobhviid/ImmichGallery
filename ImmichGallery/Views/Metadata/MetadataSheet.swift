import MapKit
import SwiftUI

struct MetadataSheet: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let request: MetadataState.Presentation
    @State private var asset: AssetResponse?
    @State private var loaded = false
    @State private var loadError: String?

    private var minimumWidth: CGFloat {
        switch request.kind {
        case .date: return 480
        case .location: return 580
        case .crop: return 680
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let loadError {
                Text(loadError)
                Button("Close") { dismiss() }
            } else if loaded {
                switch request.kind {
                case .date: MetadataDateEditor(ids: request.ids, asset: asset)
                case .location: MetadataLocationEditor(ids: request.ids, asset: asset)
                case .crop:
                    if let asset { MetadataCropEditor(asset: asset) }
                }
            } else { ProgressView().padding(40) }
        }
        .padding(20)
        // Sized for the editor from the start: a sheet keeps the width it had while loading
        // (seen on macOS 15 and 27), which clipped the location map and the crop canvas.
        .frame(minWidth: minimumWidth)
        .interactiveDismissDisabled(session.metadata.busy)
        .task {
            do {
                if let id = request.ids.first { asset = try await session.client.asset(id) }
                loaded = true
            } catch { loadError = error.localizedDescription }
        }
    }
}

struct MetadataDateEditor: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    let asset: AssetResponse?
    @State private var date = Date()
    @State private var zone = "UTC"
    @State private var zoneTouched = false
    @State private var relative = false
    @State private var minutes = 0
    private var timeZone: TimeZone { TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0)! }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adjust Date and Time").font(.title2)
            Text("\(ids.count) selected items").foregroundStyle(.secondary)
            Toggle("Shift each item's date by an offset", isOn: $relative.animation(.smooth(duration: 0.25)))
            if relative {
                TextField("Offset in minutes", value: $minutes, format: .number)
                Text("Positive values move dates later; negative values move them earlier.").font(.caption)
            } else {
                DatePicker("Date and time", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, timeZone)
                if ids.count > 1 { Text("All selected items will receive the same date and time.").font(.caption) }
            }
            Picker("Time zone", selection: Binding(get: { zone }, set: changeTimeZone)) {
                if !TimeZone.knownTimeZoneIdentifiers.contains(zone) { Text(zone).tag(zone) }
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { name in Text(name).tag(name) }
            }
            if relative && !zoneTouched { Text("Existing time zones will be preserved.").font(.caption) }
            Text("UTC offset: \(timeZone.secondsFromGMT(for: date) / 60) minutes").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Adjust") {
                    let formatter = ISO8601DateFormatter()
                    formatter.timeZone = timeZone
                    let update = relative
                        ? MetadataUpdate(ids: ids, dateTimeRelative: minutes, timeZone: zoneTouched ? zone : nil)
                        : MetadataUpdate(ids: ids, dateTimeOriginal: formatter.string(from: date), timeZone: zone)
                    Task { if await session.metadata.update(update, session: session) { dismiss() } }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .disabled(session.metadata.busy)
        .onAppear {
            if let name = asset?.exifInfo?.timeZone, TimeZone(identifier: name) != nil { zone = name }
            date = ImmichDate.parse(asset?.exifInfo?.dateTimeOriginal ?? asset?.fileCreatedAt ?? "") ?? Date()
        }
    }

    private func changeTimeZone(_ name: String) {
        guard let new = TimeZone(identifier: name) else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        calendar.timeZone = new
        if let adjusted = calendar.date(from: components) { date = adjusted }
        zoneTouched = true
        zone = name
    }
}

struct MetadataLocationEditor: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    let asset: AssetResponse?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .automatic
    @State private var error: String?
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assign Location").font(.title2)
            HStack {
                TextField("Search for a place", text: $query).onSubmit { search() }
                Button("Search", action: search).disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(results.indices, id: \.self) { i in
                            Button(results[i].name ?? "Place") {
                                coordinate = results[i].adaptiveCoordinate
                                if let coordinate { position = .region(.init(center: coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)) }
                            }.buttonStyle(.link)
                        }
                    }
                }.frame(maxHeight: 95)
            }
            MapReader { proxy in
                Map(position: $position) {
                    if let coordinate { Marker("Selected Location", coordinate: coordinate) }
                }
                .mapControls {
                    MapZoomStepper()
                    MapCompass()
                    MapScaleView()
                }
                .onTapGesture { point in
                    if let value = proxy.convert(point, from: .local) {
                        let normalized = metadataCoordinate(latitude: value.latitude, longitude: value.longitude)
                        coordinate = .init(latitude: normalized.latitude, longitude: normalized.longitude)
                    }
                }
            }
            .frame(minWidth: 540, maxWidth: .infinity).frame(height: 330).clipShape(.rect(cornerRadius: 10))
            HStack(alignment: .firstTextBaseline) {
                Text("Click the map to place a pin. Applies to \(ids.count) items.")
                Spacer()
                // Fixed decimal points, as in Immich: a comma decimal separator made "56,23, 9,68" ambiguous.
                if let coordinate {
                    Text(verbatim: String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                        .monospacedDigit().textSelection(.enabled)
                }
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Assign") {
                    guard let coordinate else { return }
                    Task {
                        if await session.metadata.update(.init(ids: ids, latitude: coordinate.latitude, longitude: coordinate.longitude), session: session) { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(coordinate == nil)
            }
        }
        .disabled(session.metadata.busy)
        .onAppear {
            if ids.count == 1, let lat = asset?.exifInfo?.latitude, let lon = asset?.exifInfo?.longitude {
                coordinate = .init(latitude: lat, longitude: lon)
                position = .region(.init(center: coordinate!, latitudinalMeters: 5000, longitudinalMeters: 5000))
            }
        }
    }

    private func search() {
        searching = true
        error = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        Task {
            defer { searching = false }
            do { results = try await MKLocalSearch(request: request).start().mapItems }
            catch { self.error = error.localizedDescription }
        }
    }
}
