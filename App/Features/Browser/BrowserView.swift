import SwiftUI
import DownloadModels

/// One browser window: URL bar + navigation chrome around the web view, the media shelf, and the
/// interaction surfaces (JS dialogs, HTTP auth, load errors, start page).
struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var session: BrowserSession
    @State private var isShelfPresented = false
    @State private var promptText = ""
    @FocusState private var urlBarFocused: Bool

    private let initialURL: URL?

    init(launch: BrowserLaunch) {
        initialURL = launch.url
        _session = State(initialValue: BrowserSession(openedByPage: launch.openedByPage))
    }

    var body: some View {
        ZStack(alignment: .top) {
            BrowserWebViewHost(session: session)
            if session.isLoading {
                ProgressView(value: min(max(session.progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, -4)
            }
            if session.currentURL == nil && !session.isLoading && session.loadError == nil {
                startPage
            }
            if let error = session.loadError {
                loadErrorOverlay(error)
            }
        }
        .background(BrowserWindowConfigurator())
        .navigationTitle(session.pageTitle.isEmpty ? String(localized: "Browser") : session.pageTitle)
        .toolbar { toolbarContent }
        .focusedSceneValue(\.browserSession, session)
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            session.sink = model
            session.searchEnabled = model.browserSearchEnabled
            session.onOpenWindow = { openWindow(id: BrowserScene.windowID, value: BrowserLaunch(url: $0, openedByPage: true)) }
            BrowserStore.shared.applyProxy(model.settings.resolvedProxy)
            if let initialURL {
                session.urlText = initialURL.absoluteString
                session.load(initialURL)
            } else {
                urlBarFocused = true
            }
        }
        .onDisappear { session.teardown() }
        .onChange(of: session.shouldClose) { _, close in if close { dismiss() } }
        .onChange(of: session.urlBarFocusToken) { urlBarFocused = true }
        .onChange(of: urlBarFocused) { session.isEditingURLBar = urlBarFocused }
        .onChange(of: session.dialog?.id) { promptText = session.dialog?.promptDefault ?? "" }
        .onChange(of: model.browserSearchEnabled) { session.searchEnabled = model.browserSearchEnabled }
        .alert(dialogTitle, isPresented: dialogPresented, presenting: session.dialog) { dialog in
            dialogButtons(dialog)
        } message: { dialog in
            Text(dialog.message)
        }
        .sheet(item: authBinding) { request in
            BrowserAuthSheet(request: request, sink: model)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                session.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!session.canGoBack)
            .help("Show the previous page")

            Button {
                session.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!session.canGoForward)
            .help("Show the next page")
        }

        ToolbarItem(placement: .principal) {
            urlField
        }

        ToolbarItem(placement: .primaryAction) {
            shelfButton
        }
    }

    private var urlField: some View {
        HStack(spacing: 6) {
            Image(systemName: session.isSecure ? "lock.fill" : "globe")
                .font(.caption)
                .foregroundStyle(session.isSecure ? .secondary : .tertiary)
                .help(session.isSecure ? String(localized: "Secure connection") : String(localized: "Not a secure connection"))
            TextField("Search or enter website address", text: Bindable(session).urlText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($urlBarFocused)
                .onSubmit {
                    session.commitURLBar()
                    urlBarFocused = false
                }
            Button {
                session.reloadOrStop()
            } label: {
                Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(session.isLoading ? String(localized: "Stop loading") : String(localized: "Reload this page"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 240, idealWidth: 480, maxWidth: 500)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private var shelfButton: some View {
        Button {
            isShelfPresented.toggle()
        } label: {
            Label("Media", systemImage: "arrow.down.circle")
        }
        .help("Media and files detected on this page")
        .popover(isPresented: $isShelfPresented, arrowEdge: .bottom) {
            MediaShelfView(session: session)
        }
        .overlay(alignment: .topTrailing) {
            if shelfCount > 0 {
                Text(shelfCount, format: .number)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1.5)
                    .background(.tint, in: Capsule())
                    .offset(x: 6, y: -4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var shelfCount: Int { session.media.candidates.count }

    // MARK: - Overlays

    private var startPage: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Search or enter a website address")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Media and file downloads you start here are captured by CloakDrop automatically.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func loadErrorOverlay(_ error: BrowserLoadError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(error.message)
                .font(.title3.weight(.medium))
            if let host = error.failingURL?.host() {
                Text(host)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button("Try Again") { session.retryAfterError() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - JS dialogs

    private var dialogTitle: Text {
        Text(session.dialog.map { String(localized: "The page at \($0.host) says:") } ?? "")
    }

    private var dialogPresented: Binding<Bool> {
        Binding(
            get: { session.dialog != nil },
            set: { presented in
                if !presented { session.dialog?.cancel() }   // Escape/dismiss = the safe answer
            }
        )
    }

    @ViewBuilder
    private func dialogButtons(_ dialog: BrowserDialog) -> some View {
        switch dialog.kind {
        case .alert:
            Button("OK") { dialog.finish() }
        case .confirm:
            Button("OK") { dialog.finish(confirmed: true) }
            Button("Cancel", role: .cancel) { dialog.finish(confirmed: false) }
        case .prompt:
            TextField(dialog.promptDefault, text: $promptText)
            Button("OK") { dialog.finish(confirmed: true, text: promptText.isEmpty ? dialog.promptDefault : promptText) }
            Button("Cancel", role: .cancel) { dialog.finish(confirmed: false) }
        }
    }

    private var authBinding: Binding<BrowserAuthRequest?> {
        Binding(
            get: { session.authRequest },
            set: { request in
                if request == nil { session.authRequest?.cancel() }
            }
        )
    }
}

/// HTTP/proxy authentication prompt, with optional Keychain memory via the app's credential store.
private struct BrowserAuthSheet: View {
    let request: BrowserAuthRequest
    let sink: any BrowserCaptureSink

    @State private var username = ""
    @State private var password = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.isProxy ? String(localized: "The proxy requires a password.")
                                  : String(localized: "This site requires a password."),
                  systemImage: "lock.shield")
                .font(.headline)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.host)
                    .font(.callout.monospaced())
                if let realm = request.realm, !realm.isEmpty {
                    Text(realm)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("User Name", text: $username)
                SecureField("Password", text: $password)
                Toggle("Remember in my Keychain", isOn: $remember)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { request.cancel() }
                Button("Sign In") {
                    if remember { sink.rememberSiteCredentials(host: request.host, username: username, password: password) }
                    request.finish(username: username, password: password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if let saved = sink.siteCredentials(forHost: request.host) {
                username = saved.username
                password = saved.password
            }
        }
    }
}
