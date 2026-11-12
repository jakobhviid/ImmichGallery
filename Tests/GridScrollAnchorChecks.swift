// Offline hidden-window check. Does not launch or interact with the installed app.
// swiftc -parse-as-library ImmichGallery/Views/Grid/GridCell.swift Tests/GridScrollAnchorChecks.swift -o build/check-grid-scroll-anchor && build/check-grid-scroll-anchor
import AppKit
import SwiftUI

private struct Key: Hashable { let section: Int; let index: Int }

@MainActor @Observable private final class Probe {
    var size: CGFloat = 80
    @ObservationIgnored var target = Key(section: 0, index: 0)
    @ObservationIgnored var builds = 0
    @ObservationIgnored var scrolled = false
}

private let sections = 40, items = 300

/// The grid's shape: sections of cells keyed by section and index, zoomed by scrolling to the first visible cell
/// (`AssetGridView.grid`).
private struct AnchorGrid<Cell: View>: View {
    let probe: Probe
    @ViewBuilder let cell: (Key) -> Cell

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: probe.size, maximum: probe.size * 1.8), spacing: 2)],
                          spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(0..<sections, id: \.self) { s in
                        Section {
                            ForEach((0..<items).map { Key(section: s, index: $0) }, id: \.self) { key in
                                let _ = probe.builds += 1
                                cell(key).onTapGesture {}
                            }
                        } header: {
                            if s.isMultiple(of: 2) { Text("Section \(s)") }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .onChange(of: probe.size) {
                probe.builds = 0
                proxy.scrollTo(probe.target, anchor: .topLeading)
                probe.scrolled = true
            }
        }
    }
}

/// As the grid's cell: availability branches inside an optional asset's branch.
@MainActor @ViewBuilder private func content(_ key: Key) -> some View {
    if key.index.isMultiple(of: 7) {
        Color.gray.aspectRatio(1, contentMode: .fit)
    } else if #available(macOS 26, *) {
        Color.blue.aspectRatio(1, contentMode: .fit)
    } else {
        Color.green.aspectRatio(1, contentMode: .fit).opacity(0.9)
    }
}

// Match the cell's outer availability-based drag modifier, without starting an actual drag.
private extension View {
    @ViewBuilder func conditionalDrag() -> some View {
        if #available(macOS 26, *) { draggable("fixture") } else { self }
    }
}

@main private struct GridScrollAnchorChecks {
    /// The cells built, and the seconds taken, by the zoom's scroll to `target`.
    @MainActor static func zoom<Cell: View>(to target: Key, @ViewBuilder cell: @escaping (Key) -> Cell) -> (Int, TimeInterval) {
        let probe = Probe()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnchorGrid(probe: probe, cell: cell).frame(width: 800, height: 600))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        probe.target = target
        let start = Date()
        probe.size = 100
        let deadline = Date().addingTimeInterval(10)
        while !probe.scrolled, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(probe.scrolled, "The zoom must scroll to its anchor")
        let result = (probe.builds, Date().timeIntervalSince(start))
        window.orderOut(nil)
        return result
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let deep = Key(section: sections - 1, index: items - 10), total = sections * items
        let (baseline, baselineTime) = zoom(to: deep) { key in Group { content(key) }.overlay { Color.clear }.conditionalDrag() }
        print(String(format: "Group cells, scroll to the last section: %d of %d cells built, %.3fs", baseline, total, baselineTime))
        precondition(baseline >= total * 9 / 10, "Baseline must reproduce building the cells before the anchor")
        for target in [Key(section: 0, index: 3), Key(section: sections / 2, index: items / 2), deep] {
            let (builds, time) = zoom(to: target) { key in gridCell { Group { content(key) }.overlay { Color.clear }.conditionalDrag() } }
            print(String(format: "gridCell cells, scroll to section %d item %d: %d cells built, %.3fs", target.section, target.index, builds, time))
            precondition(builds < 1_000, "Scrolling to a cell must not build the cells before it")
        }
        let grid = try! String(contentsOfFile: "ImmichGallery/Views/Grid/AssetGridView.swift", encoding: .utf8)
        precondition(grid.contains("return gridCell {"), "AssetGridView's cell must be a gridCell")
        let cell = grid.components(separatedBy: "return gridCell {")[1].components(separatedBy: ".onAppear")[0]
        precondition(cell.contains(".macOriginalContainerItem") && cell.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}"), "The conditional drag modifier must be inside gridCell")
        print("Grid scroll anchor checks passed")
    }
}
