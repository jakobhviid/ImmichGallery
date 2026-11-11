import SwiftUI

struct SearchView: View {
    @Environment(LibrarySession.self) private var session
    let text: String
    var chooseText: (String) -> Void = { _ in }
    @State private var query = SearchQuery()
    @State private var draft = SearchQuery()
    @Binding var showFilters: Bool
    @State private var ratingsEnabled = false
    @State private var history = SearchHistory()
    @State private var explore: [SearchExploreGroup] = []

    var body: some View {
        VStack(spacing: 0) {
            if query.text.isEmpty && query.chips.isEmpty {
                SearchLandingView(
                    pipeline: session.pipeline, query: query,
                    recent: history.entries, places: Array(explore.flatMap(\.items).filter { $0.data.visibility != "locked" }.prefix(12)),
                    controls: searchScopeControls, select: selectQuery, clearHistory: history.clear)
                .pageToolbar("searchLanding")
            } else {
                AssetGridContainer(source: .filteredSearch(query), title: Text("Search")) {
                    searchControls
                }
            }
        }
        .navigationTitle("Search")
        .navigationSubtitle(query.text)
        .onChange(of: showFilters) { _, showing in if showing { draft = query } }
        .sheet(isPresented: $showFilters) {
            SearchFiltersView(query: $draft, ratingsEnabled: ratingsEnabled) {
                query = draft; showFilters = false
            }
        }
        .task {
            query.text = text
            query.clampMode(smartEnabled: session.features.smartSearch, ocrEnabled: session.features.ocr)
            if showFilters { draft = query }
            history.load(session: session)
            history.remember(query)
            async let preferences = try? session.client.searchPreferences()
            async let suggestions = try? session.client.searchExplore()
            ratingsEnabled = await preferences?.ratings?.enabled ?? false
            // Explore is places in v3.3.5; only expose fields we can search accurately.
            explore = await suggestions?.filter { $0.fieldName == "exifInfo.city" } ?? []
        }
        .onChange(of: text) { _, value in query.text = value }
        .onChange(of: query) { _, value in history.remember(value) }
    }

    private func selectQuery(_ value: SearchQuery) {
        query = value
        query.clampMode(smartEnabled: session.features.smartSearch, ocrEnabled: session.features.ocr)
        chooseText(query.text)
    }

    private var searchScopeControls: some View {
        HStack(spacing: 10) {
            Text("Search by").foregroundStyle(.secondary)
            Picker("Search mode", selection: $query.mode) {
                ForEach(SearchMode.allCases.filter { ($0 != .context || session.features.smartSearch) && ($0 != .ocr || session.features.ocr) }) { mode in
                    Text(String(localized: mode.title)).tag(mode)
                }
            }
            .labelsHidden().frame(width: 170)
            .accessibilityLabel("Search mode")
            Button { draft = query; showFilters = true } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease")
            }
        }
    }

    private var resultOptions: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Sort Results", selection: $query.sort) {
                    ForEach(SearchSort.allCases) { sort in
                        Text(String(localized: sort.title)).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(String(localized: query.sort.title), systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()
            .accessibilityLabel("Sort Results")
            .help("Default order uses relevance for smart search and newest first for other searches. Date sorting uses up to the 500 most relevant smart search results.")
            Menu {
                ForEach(Array(history.entries.enumerated()), id: \.offset) { _, entry in
                    Button(([entry.text] + entry.chips).filter { !$0.isEmpty }.joined(separator: ", ")) { selectQuery(entry) }
                }
                Divider()
                Button("Clear History", role: .destructive) { history.clear() }
            } label: {
                Label("Recent Searches", systemImage: "clock").labelStyle(.iconOnly)
            }
            .disabled(history.entries.isEmpty)
            .help("Recent Searches")
        }
    }

    private var searchControls: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    searchScopeControls
                    Spacer(minLength: 16)
                    resultOptions
                }
                VStack(alignment: .leading, spacing: 10) {
                    searchScopeControls
                    HStack { Spacer(); resultOptions }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if !query.chips.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(query.filterChips, id: \.id) { chip in
                            HStack(spacing: 4) {
                                Button(chip.title) { draft = query; showFilters = true }
                                Button { query.remove(chip.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .accessibilityLabel("Remove \(chip.title) filter")
                            }
                            .buttonStyle(.plain).padding(6).background(.quaternary, in: Capsule())
                        }
                        Button("Clear Filters") {
                            let text = query.text; let mode = query.mode; let sort = query.sort
                            var cleared = SearchQuery(); cleared.text = text; cleared.mode = mode; cleared.sort = sort
                            query = cleared
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            if query.mode == .context && session.features.smartSearch && !query.text.isEmpty && query.sort != .automatic {
                Text("Showing up to the 500 most relevant smart search results, sorted by date.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
        }
    }
}
