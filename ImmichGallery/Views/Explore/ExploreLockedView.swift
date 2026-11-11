import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// Unlocks the Locked Folder with the account PIN and then shows it like any other grid. The grid runs in its
/// own session whose media skips the disk cache; locking discards that session with its media and files.
/// Like Immich, it stays unlocked while in use: it locks on leaving, on Lock, on screen lock or sleep, and when
/// the server's unlock expires.
struct ExploreLockedView: View {
    @Environment(LibrarySession.self) private var session
    @State private var status: ExploreAuthStatus?
    @State private var unlocked: LibrarySession?
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var busy = false
    @State private var verifying = false
    @State private var generation = UUID()
    @State private var expiryTask: Task<Void, Never>?
    @State private var inactivityTask: Task<Void, Never>?
    @State private var inactivity = LockedFolderInactivity()
    @AppStorage(LockedFolderTouchID.enabledKey) private var touchIDEnabled = true
    /// The PIN was chosen instead of Touch ID, until the folder locks again.
    @State private var usePIN = false
    /// Each Touch ID attempt has its own context, shown by the fingerprint view and checked by it.
    @State private var touchContext = LAContext()
    @State private var touchAttempt = 0
    @State private var touchFailed = false

    /// The kept PIN for this server and user.
    private var touchIDKey: String { LockedFolderTouchID.key(server: session.client.serverURL, userID: session.user?.id ?? "") }
    private var canUseTouchID: Bool {
        touchIDEnabled && status?.pinCode == true && LockedFolderTouchID.isAvailable && LockedFolderTouchID.hasPIN(for: touchIDKey)
    }

    var body: some View {
        Group {
            if !session.client.exploreSupportsLockedFolder {
                ContentUnavailableView("Session Login Required", systemImage: "lock", description: Text("Sign in with email and password, or with single sign-on, to use Locked Folder. API keys cannot unlock a session."))
                    .pageToolbar("lockedUnavailable")
            } else if let unlocked {
                AssetGridContainer(source: .locked, title: Text("Locked Folder"))
                    .environment(unlocked)
                    .toolbar(id: "locked") {
                        // Beside the title, labelled and tinted, apart from the photo actions.
                        ToolbarItem(id: "lock", placement: .navigation) {
                            Button { lock() } label: { Label("Lock", systemImage: "lock.fill") }
                                .labelStyle(.titleAndIcon)
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut("l", modifiers: [.command, .control])
                                .help("Lock (⌃⌘L)")
                        }
                    }
            } else {
                Group {
                    if canUseTouchID && !usePIN { touchIDPrompt } else { pinForm }
                }
                .pageToolbar("lockedPIN")
            }
        }
        .task {
            session.lockFolder = { lock() }
            guard session.client.exploreSupportsLockedFolder else { return }
            do { status = try await Self.uncached(session.client) { try await $0.exploreAuth() } }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear {
            touchContext.invalidate()
            session.lockFolder = {}
            generation = UUID()
            lock()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in startInactivityTimer() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            inactivityTask?.cancel()
            inactivityTask = nil
            if inactivity.becomeActive() { lock() }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked"))) { _ in lock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in lock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in lock() }
        .alert("Locked Folder", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    /// Status, unlock and lock requests skip the URL cache so a stale status is never reused.
    /// Callers pass the account client, read before any await: the view may be gone afterwards.
    private static func uncached<T>(_ account: ImmichClient, _ request: (ImmichClient) async throws -> T) async throws -> T {
        let client = account.explorePrivateClient()
        defer { client.session.finishTasksAndInvalidate() }
        return try await request(client)
    }

    /// After the first unlock with the PIN: the fingerprint, in the page, read as soon as it shows. Touching the sensor
    /// unlocks; Use PIN is there if Touch ID can't be used.
    private var touchIDPrompt: some View {
        VStack(spacing: 16) {
            LockedFolderTouchIDView(context: touchContext)
                .frame(width: 72, height: 72)
                .id(touchAttempt)
            Text("Unlock Locked Folder").font(.title2)
            Text(touchFailed ? "Touch ID didn't unlock the Locked Folder." : "Touch ID to unlock")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                if touchFailed { Button("Try Again") { retryTouchID() } }
                Button("Use PIN") { touchContext.invalidate(); usePIN = true }
            }
            .buttonStyle(.link)
            .disabled(busy)
            Text("Locks when you leave the Locked Folder, lock the screen, or keep the app inactive for 15 minutes.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: touchAttempt) { await unlockWithTouchID() }
    }

    /// Setting up the PIN, the first unlock, and the fallback from Touch ID.
    private var pinForm: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(status?.pinCode == false ? "Set Up Locked Folder" : "Unlock Locked Folder").font(.title2)
            SecureField("Six-digit PIN", text: $pin).frame(width: 220)
            if status?.pinCode == false { SecureField("Confirm PIN", text: $confirmation).frame(width: 220) }
            Button(status?.pinCode == false ? "Set PIN and Unlock" : "Unlock") { Task { await unlock() } }
                .keyboardShortcut(.defaultAction)
                .disabled(status == nil || busy || pin.range(of: "^[0-9]{6}$", options: .regularExpression) == nil || (status?.pinCode == false && pin != confirmation))
            if canUseTouchID {
                Button("Use Touch ID") { usePIN = false; retryTouchID() }.buttonStyle(.link)
            }
            Text("Locks when you leave the Locked Folder, lock the screen, or keep the app inactive for 15 minutes.").font(.caption).foregroundStyle(.secondary)
            if touchIDEnabled && LockedFolderTouchID.isAvailable && !canUseTouchID {
                Text("Unlock with the PIN once, and Touch ID unlocks it from then on.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Reads the fingerprint in the page, then unlocks with the kept PIN.
    private func unlockWithTouchID() async {
        guard canUseTouchID, !usePIN, !busy else { return }
        touchFailed = false
        switch await LockedFolderTouchID.pin(for: touchIDKey, context: touchContext) {
        case .pin(let code):
            await unlock(code, viaTouchID: true)
            if unlocked == nil { touchFailed = true }
        case .cancelled:
            touchFailed = true
        case .unavailable:
            // The fingerprints changed, or Touch ID isn't available now: the PIN, once.
            usePIN = true
        }
    }

    /// A fresh context for the next fingerprint.
    private func retryTouchID() {
        touchContext.invalidate()
        touchContext = LAContext()
        touchFailed = false
        touchAttempt += 1
    }

    private func unlock() async { await unlock(pin, viaTouchID: false) }

    private func unlock(_ code: String, viaTouchID: Bool) async {
        busy = true
        let attempt = generation
        let account = session.client, services = session.services, key = touchIDKey
        defer { busy = false; pin = ""; confirmation = "" }
        do {
            let setup = status?.pinCode == false
            let status: ExploreAuthStatus
            do {
                status = try await Self.uncached(account) { client in
                    try await client.exploreUnlock(code, setup: setup)
                    return try await client.exploreAuth()
                }
            } catch {
                // A kept PIN the server turns down has been changed: forget it, and the PIN field takes over.
                if viaTouchID, case ImmichError.http(400..<500, _) = error { LockedFolderTouchID.forget(key) }
                if viaTouchID, case ImmichError.unauthorized = error { LockedFolderTouchID.forget(key) }
                throw error
            }
            // Touch ID unlocks with this PIN from now on.
            if touchIDEnabled, !viaTouchID, LockedFolderTouchID.isAvailable { LockedFolderTouchID.save(code, for: key) }
            self.status = status
            // Left the Locked Folder while unlocking.
            guard attempt == generation else { try? await Self.uncached(account) { try await $0.exploreLock() }; return }
            guard status.isElevated else { throw ImmichError.http(403, String(localized: "The server did not unlock this session.")) }
            let media = LockedFolderMedia(account: account)
            media.onRequestFailed = { Task { await verify() } }
            unlocked = LibrarySession(services: services, lockedFolder: media)
            scheduleCheck(status.pinExpiresAt)
            if !NSApp.isActive { startInactivityTimer() }
        } catch { self.error = error.localizedDescription }
    }

    private func startInactivityTimer() {
        guard unlocked != nil else { return }
        inactivityTask?.cancel()
        inactivity.resignActive()
        inactivityTask = Task {
            do { try await Task.sleep(for: .seconds(LockedFolderInactivity.timeout)) } catch { return }
            lock()
        }
    }

    /// The server extends an unlock while it's used, so check again just after it would have expired.
    private func scheduleCheck(_ expiry: String?) {
        expiryTask?.cancel()
        let date = expiry.flatMap(ImmichDate.parse) ?? Date().addingTimeInterval(15 * 60)
        expiryTask = Task {
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow) + 2)) } catch { return }
            await verify()
        }
    }

    /// Locks unless the server still has the session unlocked. Also runs when a Locked Folder request fails.
    private func verify() async {
        guard let media = unlocked?.lockedFolder, !verifying else { return }
        verifying = true
        defer { verifying = false }
        do {
            let status = try await media.client.exploreAuth()
            guard unlocked?.lockedFolder === media else { return }
            if status.isElevated {
                scheduleCheck(status.pinExpiresAt)
            } else {
                lock()
                error = String(localized: "Locked Folder access expired. Unlock again to continue.")
            }
        } catch {
            guard unlocked?.lockedFolder === media else { return }
            lock()
            switch error {
            case ImmichError.unauthorized, ImmichError.http(401, _), ImmichError.http(403, _):
                self.error = String(localized: "Locked Folder access expired. Unlock again to continue.")
            default:
                self.error = String(localized: "Could not verify Locked Folder access. Unlock again to continue.")
            }
        }
    }

    /// Closes the viewer and Quick Look, then drops the session's grid, cached images, temporary files and any
    /// copied item still on the pasteboard, and locks the server session.
    private func lock() {
        // A screen lock must invalidate an unlock that is still waiting for the server.
        generation = UUID()
        // Ready for the fingerprint again.
        usePIN = false
        retryTouchID()
        inactivityTask?.cancel()
        inactivityTask = nil
        inactivity = LockedFolderInactivity()
        expiryTask?.cancel()
        expiryTask = nil
        guard let locked = unlocked else { return }
        unlocked = nil
        locked.endSession()
        MacQuickLook.shared.dismiss()
        locked.lockedFolder?.discard()
        // All windows share the server's unlock, so clear their local media together.
        for window in session.services.windows.allObjects where window !== session && window !== locked {
            window.lockFolder()
        }
        let account = locked.services.client
        Task {
            do { try await Self.uncached(account) { try await $0.exploreLock() } }
            catch { self.error = String(localized: "Media was cleared locally, but the server session could not be locked: \(error.localizedDescription)") }
        }
    }
}
