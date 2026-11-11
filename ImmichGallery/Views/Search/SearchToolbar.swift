import AppKit
import SwiftUI

/// The window's search field and what it searches for. The window owns one and hands it to its pages.
@MainActor @Observable final class SearchFieldModel {
    var text = ""
    private(set) var submissions = 0
    /// In a narrow window the field is a button until it is clicked, and again once it is left empty.
    var expanded = false
    /// The field takes the keyboard when it next updates (⌘F, or the button in a narrow window).
    var pendingFocus = false

    /// Return or the clear button.
    func submit(_ text: String) {
        self.text = text
        submissions += 1
    }

    func focus() {
        expanded = true
        pendingFocus = true
    }
}

/// A plain toolbar item rather than `.searchable`: in a customizable toolbar the system search item made AppKit throw
/// while laying out the toolbar. Each page ends its toolbar with it (see `pageToolbar`), so it stays at the trailing
/// edge, where every page puts it.
struct SearchToolbarItem: CustomizableToolbarContent {
    var body: some CustomizableToolbarContent {
        // Its own capsule, apart from the buttons before it.
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        ToolbarItem(id: "search") { SearchToolbarField() }
    }
}

private struct SearchToolbarField: View {
    @Environment(SearchFieldModel.self) private var model: SearchFieldModel?
    @Environment(LibrarySession.self) private var session
    @Environment(\.toolbarCompact) private var compact

    var body: some View {
        if let model, compact, !model.expanded, model.text.isEmpty {
            Button { model.focus() } label: { Label("Search", systemImage: "magnifyingglass") }
                .help("Search")
        } else if let model {
            NativeSearchField(model: model, prompt: session.features.smartSearch ? String(localized: "Search photos") : String(localized: "Search file names"))
                .frame(minWidth: 140, idealWidth: 200, maxWidth: 320)
                .help("Search")
        }
    }
}

private struct NativeSearchField: NSViewRepresentable {
    let model: SearchFieldModel
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsWholeSearchString = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.model = model
        if field.stringValue != model.text { field.stringValue = model.text }
        if field.placeholderString != prompt { field.placeholderString = prompt }
        if model.pendingFocus {
            DispatchQueue.main.async {
                model.pendingFocus = false
                field.window?.makeFirstResponder(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var model: SearchFieldModel

        init(model: SearchFieldModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            model.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField, field.stringValue.isEmpty else { return }
            model.expanded = false
        }

        @objc func submit(_ field: NSSearchField) {
            model.submit(field.stringValue)
        }
    }
}

extension View {
    /// A page's customizable toolbar, ending with the window's search field.
    func pageToolbar<Content: CustomizableToolbarContent>(_ id: String, @ToolbarContentBuilder content: () -> Content) -> some View {
        toolbar(id: id) {
            content()
            SearchToolbarItem()
        }
    }

    /// A page without toolbar items of its own still shows the search field.
    func pageToolbar(_ id: String) -> some View {
        toolbar(id: id) { SearchToolbarItem() }
    }
}

extension EnvironmentValues {
    /// The window is too narrow for the full toolbar: as Photos does, segmented controls become pop-up menus and the
    /// search field a button, before items move to the overflow menu.
    @Entry var toolbarCompact = false
}

/// What a page shows, in the middle of the toolbar where it stays put, as Photos' Years, Months and All Photos.
/// Segments, or a pop-up menu in a narrow window.
struct ToolbarModePicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> LocalizedStringResource
    @Environment(\.toolbarCompact) private var compact

    var body: some View {
        let picker = Picker("Show", selection: $selection) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        if compact { picker.pickerStyle(.menu) } else { picker.pickerStyle(.segmented) }
    }
}
