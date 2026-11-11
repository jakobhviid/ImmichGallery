import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private enum Step { case server, credentials(ImmichClient, ServerFeatures, ServerVersion?) }
    private enum Method: String, CaseIterable { case password = "Email & Password", apiKey = "API Key" }

    @State private var step = Step.server
    private var isServerStep: Bool { if case .server = step { true } else { false } }
    #if DEBUG
    @State private var serverText = AccountStore.lastServer ?? "https://demo.immich.app"
    #else
    @State private var serverText = AccountStore.lastServer ?? ""
    #endif
    @State private var email = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var method = Method.password
    /// The server's single sign-on button text, when it offers OAuth.
    @State private var oauthButton: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    private enum Field { case server, email, password, apiKey }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Immich Gallery")
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Group {
                switch step {
                case .server: serverForm
                case .credentials(let client, let features, let version):
                    credentialsForm(client: client, features: features, version: version)
                }
            }
            .frame(width: 340)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        // The server step gives way to the sign-in step, and errors fade in, rather than the form jumping.
        .animation(.smooth(duration: 0.3), value: isServerStep)
        .animation(.smooth(duration: 0.25), value: errorMessage)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(isWorking)
        .onAppear { focused = .server }
    }

    private var subtitle: String {
        switch step {
        case .server: String(localized: "Enter the address of your Immich server.")
        case .credentials(let client, _, _): String(localized: "Sign in to \(client.serverURL.host() ?? client.serverURL.absoluteString)")
        }
    }

    private var serverForm: some View {
        VStack(spacing: 14) {
            TextField("Server", text: $serverText, prompt: Text("https://photos.example.com"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused, equals: .server)
                .onSubmit(connect)
            primaryButton("Continue", action: connect)
                .disabled(serverText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func credentialsForm(client: ImmichClient, features: ServerFeatures, version: ServerVersion?) -> some View {
        VStack(spacing: 14) {
            if let oauthButton {
                Button { signInWithBrowser(client) } label: {
                    Label(oauthButton, systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                HStack {
                    VStack { Divider() }
                    Text("or").font(.caption).foregroundStyle(.secondary)
                    VStack { Divider() }
                }
            }

            if features.passwordLogin {
                Picker("Method", selection: $method.animation(.smooth(duration: 0.25))) {
                    ForEach(Method.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if method == .password && features.passwordLogin {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .focused($focused, equals: .email)
                    .onSubmit { focused = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .onSubmit { signIn(client) }
            } else {
                SecureField("API Key", text: $apiKey)
                    .focused($focused, equals: .apiKey)
                    .onSubmit { signIn(client) }
                Text("Create an API key in Immich under Account Settings → API Keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            primaryButton("Sign In") { signIn(client) }

            HStack {
                Button("Change Server") {
                    errorMessage = nil
                    step = .server
                }
                .buttonStyle(.link)
                Spacer()
                if let version {
                    Text("Immich \(version.description)")
                        .foregroundStyle(version.isSupported ? Color.secondary : Color.orange)
                        .help(version.isSupported ? "" : String(localized: "This server is older than Immich 2.0 and may not work correctly."))
                }
            }
            .font(.caption)
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
    }

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private func connect() {
        run {
            let client = try await ImmichClient.discover(serverText)
            async let features = try? client.serverFeatures()
            async let version = try? client.serverVersion()
            let f = await features ?? ServerFeatures()
            if f.oauth { oauthButton = await client.oauthButtonText() } else { oauthButton = nil }
            method = f.passwordLogin ? .password : .apiKey
            step = .credentials(client, f, await version)
            focused = f.passwordLogin ? .email : .apiKey
        }
    }

    private func signIn(_ client: ImmichClient) {
        run {
            let credential: Credential
            if method == .password {
                let response = try await client.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
                credential = .accessToken(response.accessToken)
            } else {
                credential = .apiKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try await app.signIn(client: client, credential: credential)
        }
    }

    /// Single sign-on in a web authentication session, which ends at the redirect URI Immich's mobile app uses.
    private func signInWithBrowser(_ client: ImmichClient) {
        run {
            let attempt = try OAuthAttempt()
            let address = try await client.oauthAuthorize(attempt)
            let redirect: URL
            do {
                redirect = try await webAuthenticationSession.authenticate(
                    using: address, callbackURLScheme: OAuthAttempt.callbackScheme, preferredBrowserSession: nil)
            } catch ASWebAuthenticationSessionError.canceledLogin {
                return
            }
            let response = try await client.oauthCallback(redirect, attempt)
            try await app.signIn(client: client, credential: .accessToken(response.accessToken))
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        errorMessage = nil
        isWorking = true
        Task {
            do { try await work() } catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }
}
