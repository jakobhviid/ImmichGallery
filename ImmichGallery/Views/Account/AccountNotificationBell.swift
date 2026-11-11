import SwiftUI

struct AccountNotificationBell: View {
    let session: AccountServices
    @State private var showing = false
    // Owned here so an operation outlives a closed popover; only the popover reads its state.
    @State private var operation = AccountOperation()

    // On macOS 15 a toolbar item is rebuilt whenever its root view reads data that changes,
    // which dismisses its popover (e.g. right after the popover reloads notifications).
    // Changing data is therefore read only by the child views below.
    var body: some View {
        if session.notificationsAvailable {
            Button { showing.toggle() } label: { AccountNotificationBellLabel(session: session) }
                .popover(isPresented: $showing) { AccountNotificationsPopover(session: session, operation: operation) }
        }
    }
}

private struct AccountNotificationBellLabel: View {
    let session: AccountServices
    var body: some View {
        let unreadCount = session.notifications.filter { $0.readAt == nil }.count
        HStack(spacing: 4) {
            Image(systemName: unreadCount == 0 ? "bell" : "bell.badge")
            if unreadCount > 0 { Text(unreadCount.formatted()).monospacedDigit() }
        }
        .accessibilityLabel("Notifications, \(unreadCount) unread")
        .help("\(unreadCount) unread notifications")
    }
}

/// Reloads when opened and every minute while the app is active, so there is no Refresh button.
private struct AccountNotificationsPopover: View {
    let session: AccountServices
    let operation: AccountOperation
    private var notifications: [AccountNotification] { session.notifications }
    private var unread: [AccountNotification] { notifications.filter { $0.readAt == nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Notifications").font(.headline)
                if operation.busy { ProgressView().controlSize(.small) }
                Spacer()
                if !unread.isEmpty {
                    Button("Mark All Read") { markRead(unread.map(\.id)) }.buttonStyle(.link)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if notifications.isEmpty {
                ContentUnavailableView("No Notifications", systemImage: "bell")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(notifications) { notification in
                    AccountNotificationRow(notification: notification,
                                           markRead: { markRead([notification.id]) },
                                           delete: { delete(notification.id) })
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            if let error = operation.error ?? session.notificationError {
                Divider()
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .frame(width: 340, height: notifications.isEmpty ? 200 : 380)
        // Read and deleted notifications leave the list, and the popover resizes, with an animation.
        .animation(.smooth(duration: 0.3), value: notifications.map(\.id))
        .animation(.smooth(duration: 0.3), value: notifications.map { $0.readAt == nil })
        .modifier(BusyDisabled(busy: operation.busy))
        .task { operation.run { try await session.reloadNotifications() } }
    }

    private func markRead(_ ids: [String]) {
        operation.run {
            try await session.client.readAccountNotifications(ids)
            try await session.reloadNotifications()
        }
    }

    private func delete(_ id: String) {
        operation.run {
            try await session.client.deleteAccountNotification(id)
            try await session.reloadNotifications()
        }
    }
}

/// Unread rows show a dot; clicking one marks it read. Delete appears on hover, and both
/// actions are also in the context menu, as swipe actions and as accessibility actions.
private struct AccountNotificationRow: View {
    let notification: AccountNotification
    let markRead: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    private var isUnread: Bool { notification.readAt == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title).fontWeight(isUnread ? .semibold : .regular)
                if let description = notification.description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary)
                }
                Text(date).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            ZStack {
                if hovering {
                    Button(action: delete) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete")
                } else if isUnread {
                    Circle().fill(.tint).frame(width: 8, height: 8)
                }
            }
            .frame(width: 16, height: 16)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if isUnread { markRead() } }
        .contextMenu {
            if isUnread { Button("Mark Read", action: markRead) }
            Button("Delete", role: .destructive, action: delete)
        }
        .swipeActions(edge: .trailing) { Button("Delete", role: .destructive, action: delete) }
        .swipeActions(edge: .leading) {
            if isUnread { Button("Mark Read", action: markRead).tint(.accentColor) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Delete", delete)
        .modifier(MarkReadAccessibilityAction(enabled: isUnread, markRead: markRead))
    }

    private var date: String {
        guard let value = accountDateValue(notification.createdAt) else { return notification.createdAt }
        return value.formatted(.relative(presentation: .named))
    }

    private var symbol: String {
        switch notification.level {
        case "success": "checkmark.circle.fill"
        case "warning": "exclamationmark.triangle.fill"
        case "error": "xmark.octagon.fill"
        default: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch notification.level {
        case "success": .green
        case "warning": .orange
        case "error": .red
        default: .accentColor
        }
    }
}

private struct MarkReadAccessibilityAction: ViewModifier {
    let enabled: Bool
    let markRead: () -> Void
    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(named: "Mark Read", markRead) } else { content }
    }
}

/// Disables the popover while busy. Not on macOS 15: disabling the focused button while the
/// popover becomes key loops forever there; `operation.run` already ignores taps while busy.
private struct BusyDisabled: ViewModifier {
    let busy: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.disabled(busy) } else { content }
    }
}
