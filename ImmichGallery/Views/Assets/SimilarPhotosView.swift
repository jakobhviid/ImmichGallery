import SwiftUI

/// Find Similar Photos (#41): the grid utilities entry. The caller owns `isPresented` and attaches `similarPhotosSheet`.
struct SimilarPhotosMenuButton: View {
    @Binding var isPresented: Bool
    var body: some View { Button("Find Similar Photos…") { isPresented = true } }

    /// Pages showing the user's own photos. A date-range scan always covers the whole library, whatever page opened it.
    static func isAvailable(_ source: GridSource) -> Bool {
        switch source {
        case .library, .favorites, .archive, .person, .largeFiles, .geolocation: true
        default: false
        }
    }
}

extension View {
    func similarPhotosSheet(isPresented: Binding<Bool>, model: AssetGridModel) -> some View {
        sheet(isPresented: isPresented) { SimilarPhotosSheet(grid: model) }
    }
}

struct SimilarPhotosSheet: View {
    private enum Period: Hashable { case days(Int), custom }
    private struct StackRef: Identifiable { let id: String }

    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let grid: AssetGridModel
    @State private var model: SimilarPhotosModel?
    @State private var useSelection = false
    @State private var period = Period.days(30)
    @State private var start = SimilarPhotosRange.lastDays(30).start
    @State private var end = SimilarPhotosRange.lastDays(30).end
    @State private var options = SimilarPhotos.Options()
    @State private var confirming = false
    @State private var browsing: StackRef?

    private var selection: [String] { grid.selection.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Find Similar Photos").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let model {
                settings(model)
                Divider()
                status(model)
                results(model)
                footer(model)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 900, maxWidth: .infinity, minHeight: 520, idealHeight: 700, maxHeight: .infinity)
        .onAppear(perform: makeModel)
        // Closing the sheet stops analysis and any stacking not yet sent.
        .onDisappear { model?.cancel() }
        .sheet(item: $browsing) { ref in
            AssetsStackBrowser(stackID: ref.id, model: grid, didMutate: { model?.invalidateStack(ref.id) })
        }
    }

    private func makeModel() {
        guard model == nil else { return }
        useSelection = selection.count >= 2
        let services = session.services
        let client = session.client
        model = SimilarPhotosModel(
            client: client, userID: session.user?.id, analyzer: SimilarPhotosVisionAnalyzer(client: client),
            isCurrent: { [weak services] in services != nil && MacIntegrationRouter.shared.app?.services === services },
            didChangeLibrary: { [weak session] in session?.invalidateGrids() },
            handleError: { [weak session] in session?.handle($0) })
    }

    private var range: SimilarPhotosRange {
        switch period {
        case .days(let days): .lastDays(days)
        case .custom: SimilarPhotosRange(start: start, end: end)
        }
    }

    // MARK: Settings

    @ViewBuilder private func settings(_ model: SimilarPhotosModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if selection.count >= 2 {
                Picker("Look In", selection: $useSelection) {
                    Text("Selected Photos (\(selection.count))").tag(true)
                    Text("Date Range").tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
            }
            if !useSelection || selection.count < 2 {
                HStack {
                    Picker("Period", selection: $period) {
                        Text("Last 30 Days").tag(Period.days(30))
                        Text("Last 3 Months").tag(Period.days(91))
                        Text("Last 12 Months").tag(Period.days(365))
                        Text("Custom Range").tag(Period.custom)
                    }
                    .fixedSize()
                    if period == .custom {
                        DatePicker("From", selection: $start, in: ...end, displayedComponents: .date).fixedSize()
                        DatePicker("To", selection: $end, in: start..., displayedComponents: .date).fixedSize()
                    }
                }
            }
            // Side by side when the sheet is wide enough, stacked otherwise.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { matchingPickers }
                VStack(alignment: .leading, spacing: 8) { matchingPickers }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(useSelection && selection.count >= 2
                     ? "Only the selected photos are checked. Photos that aren't selected, including ones not loaded in this view, aren't."
                     : "Every photo of yours taken in this period is checked, including ones not loaded in this view. Videos, archived photos and photos already in a stack aren't.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Find Similar Photos") {
                    model.scan(useSelection && selection.count >= 2 ? .selection(selection) : .range(range), options: options)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
            }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder private var matchingPickers: some View {
        Picker("Sensitivity", selection: $options.sensitivity) {
            Text("Strict").tag(SimilarPhotos.Sensitivity.strict)
            Text("Normal").tag(SimilarPhotos.Sensitivity.normal)
            Text("Loose").tag(SimilarPhotos.Sensitivity.loose)
        }
        .fixedSize()
        .help("Strict groups only near-identical shots; Loose also groups shots with more movement.")
        Picker("Time Between Shots", selection: $options.maxGap) {
            ForEach(SimilarPhotos.gapChoices, id: \.self) { gap in
                Text(verbatim: "≤ " + Duration.seconds(gap).formatted(.units(allowed: [.seconds], width: .wide))).tag(gap)
            }
        }
        .fixedSize()
    }

    // MARK: Status

    @ViewBuilder private func status(_ model: SimilarPhotosModel) -> some View {
        switch model.phase {
        case .idle:
            Text("Photos taken within a few seconds of each other are compared on this Mac. Nothing changes until you stack the groups you choose.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .collecting(let found):
            progress(Text("Looking for photos… \(found) found"), value: nil, model: model)
        case .analyzing(let done, let total):
            progress(Text("Analyzing \(done) of \(total) photos…"), value: total > 0 ? Double(done) / Double(total) : nil, model: model)
        case .applying(let done, let total):
            progress(Text("Stacking \(done) of \(total) groups…"), value: total > 0 ? Double(done) / Double(total) : nil, model: model)
        case .ready:
            coverage(model)
        case .tooMany:
            Label("There are more than \(SimilarPhotos.candidateLimit) photos to check. Choose a shorter period or fewer photos so every one can be compared.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ text: Text, value: Double?, model: SimilarPhotosModel) -> some View {
        HStack {
            if let value { ProgressView(value: value).frame(maxWidth: 240) } else { ProgressView().controlSize(.small) }
            text.monospacedDigit()
            Spacer()
            Button("Stop") { model.cancel() }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func coverage(_ model: SimilarPhotosModel) -> some View {
        let coverage = model.coverage
        let excluded = coverage.excluded.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 4) {
            if model.needsRescan {
                Text("A stack changed. Find similar photos again to refresh the suggestions.").foregroundStyle(.secondary)
            } else {
                Text("Checked \(coverage.eligible) photos and found \(model.groups.count) groups.")
            }
            if excluded > 0 {
                Text("Skipped \(excluded) items: videos, other people's photos, and items in a stack, Recently Deleted or the Locked Folder.")
                    .foregroundStyle(.secondary)
            }
            if coverage.unreadable > 0 {
                Label("\(coverage.unreadable) selected items couldn't be loaded and weren't checked.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if coverage.analysisFailures > 0 {
                Label("\(coverage.analysisFailures) photos couldn't be analyzed and aren't in any group.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Groups

    @ViewBuilder private func results(_ model: SimilarPhotosModel) -> some View {
        if model.groups.isEmpty {
            if model.phase == .ready && !model.needsRescan {
                ContentUnavailableView("No Similar Photos", systemImage: "square.stack.3d.up.slash",
                                       description: Text("No photos taken close together look alike enough. Try a longer period or a looser sensitivity."))
            } else { Spacer(minLength: 0) }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.groups) { group in groupRow(group, model: model) }
                }
            }
        }
    }

    private func groupRow(_ group: SimilarPhotosModel.Group, model: SimilarPhotosModel) -> some View {
        let editable = group.status == .pending && model.phase == .ready
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: Binding(get: { group.included }, set: { model.setIncluded($0, groupID: group.id) })) {
                    Text(title(group)).font(.headline)
                }
                .toggleStyle(.checkbox)
                .disabled(!editable)
                .help("Include this group when stacking")
                Text("\(group.activeMembers.count) photos").foregroundStyle(.secondary)
                Spacer()
                if editable && !group.removed.isEmpty {
                    Button("Restore Removed Photos") { model.restoreMembers(of: group.id) }
                }
                statusLabel(group)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(group.activeMembers) { member in tile(member, group: group, editable: editable, model: model) }
                }
                .padding(.bottom, 4)
            }
            if group.activeMembers.count < SimilarPhotos.minMembers {
                Text("A stack needs at least two photos.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
        .opacity(group.included || !editable ? 1 : 0.55)
    }

    private func title(_ group: SimilarPhotosModel.Group) -> String {
        guard let first = group.members.first.flatMap({ model?.assets[$0.id] }), let date = ImmichDate.parse(first.localDateTime) else { return "" }
        return ImmichDate.long(date)
    }

    private func tile(_ member: SimilarPhotos.Candidate, group: SimilarPhotosModel.Group, editable: Bool, model: SimilarPhotosModel) -> some View {
        let isCover = group.cover == member.id
        let asset = model.assets[member.id]
        return Button { model.setCover(member.id, in: group.id) } label: {
            ThumbnailCell(asset: asset.map(AssetItem.init), isSelected: isCover, size: .thumbnail)
                .frame(width: 128, height: 128)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if isCover {
                        Label(member.id == group.suggestedCover ? "Suggested Cover" : "Cover", systemImage: "star.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: .capsule).padding(5)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!editable)
        .help(asset?.originalFileName ?? "")
        .accessibilityLabel(Text(asset?.originalFileName ?? ""))
        .accessibilityValue(isCover ? Text("Cover") : Text(verbatim: ""))
        .accessibilityHint(editable ? Text("Makes this photo the cover") : Text(verbatim: ""))
        .overlay(alignment: .topTrailing) {
            if editable {
                Button { model.remove(member.id, from: group.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(4)
                .help("Remove from Group")
                .accessibilityLabel("Remove from Group")
            }
        }
        .contextMenu {
            if editable {
                Button("Make Cover") { model.setCover(member.id, in: group.id) }.disabled(isCover)
                Button("Remove from Group") { model.remove(member.id, from: group.id) }
            }
        }
    }

    @ViewBuilder private func statusLabel(_ group: SimilarPhotosModel.Group) -> some View {
        switch group.status {
        case .pending: EmptyView()
        case .stacked(let stackID):
            Label("Stacked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Open Stack…") { browsing = StackRef(id: stackID) }
        case .coverNotSet(let stackID):
            Label("Stacked; the cover couldn't be set", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Button("Open Stack…") { browsing = StackRef(id: stackID) }
        case .changed:
            Label("Skipped: photos changed since the scan", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red).lineLimit(2).help(message)
        }
    }

    // MARK: Footer

    private func footer(_ model: SimilarPhotosModel) -> some View {
        let count = model.stackableGroups.count
        return HStack {
            Text("Suggestions can be wrong. Click a photo to make it the cover. Nothing is deleted.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Stack \(count) Groups…") { confirming = true }
                .disabled(count == 0 || model.phase != .ready)
        }
        .confirmationDialog("Stack \(count) groups?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Stack Groups") { Task { await model.apply() } }
        } message: {
            Text("Each group becomes a stack in Immich with its cover on top. You can change the cover or unstack later. No photo is deleted.")
        }
    }
}
