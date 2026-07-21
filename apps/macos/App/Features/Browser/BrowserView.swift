import AppKit
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
    /// Whether the address field is being edited (reported by the AppKit field, which owns focus).
    @State private var isEditingURL = false
    /// Bumped to ask the address field to become first responder (⌘L, clicking the idle bar).
    @State private var focusRequestToken = 0

    private let initialURL: URL?

    init(launch: BrowserLaunch) {
        initialURL = launch.url
        _session = State(initialValue: BrowserSession(openedByPage: launch.openedByPage))
    }

    var body: some View {
        ZStack(alignment: .top) {
            BrowserWebViewHost(session: session)
            // Load progress lives inside the address pill (see `loadingFill`), not as a separate bar.
            if session.currentURL == nil && !session.isLoading && session.loadError == nil {
                startPage
            }
            if let error = session.loadError {
                loadErrorOverlay(error)
            }
        }
        .background(BrowserWindowConfigurator())
        .navigationTitle(session.pageTitle.isEmpty ? String(localized: "Browser") : session.pageTitle)
        .toolbar(removing: .title)   // the favicon stands in for the title; the window/tab still carries it
        .toolbar { toolbarContent }
        .focusedSceneValue(\.browserSession, session)
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            session.sink = model
            session.searchEnabled = model.browserSearchEnabled
            session.searchEngine = model.browserSearchEngine
            session.setAdBlock(model.browserAdBlockEnabled)
            session.onOpenWindow = { openWindow(id: BrowserScene.windowID, value: BrowserLaunch(url: $0, openedByPage: true)) }
            BrowserStore.shared.applyProxy(model.settings.resolvedProxy)
            if let initialURL {
                session.urlText = initialURL.absoluteString
                session.load(initialURL)
            } else {
                beginEditingURL()   // a fresh window opens ready to type an address
            }
        }
        .onDisappear { session.teardown() }
        .onChange(of: session.shouldClose) { _, close in if close { dismiss() } }
        .onChange(of: session.urlBarFocusToken) { beginEditingURL() }
        .onChange(of: session.dialog?.id) { promptText = session.dialog?.promptDefault ?? "" }
        .onChange(of: model.browserSearchEnabled) { session.searchEnabled = model.browserSearchEnabled }
        .onChange(of: model.browserSearchEngine) { session.searchEngine = model.browserSearchEngine }
        .onChange(of: model.browserAdBlockEnabled) { session.setAdBlock(model.browserAdBlockEnabled) }
        // Re-attach when the compiled lists change (a compile finished, the blocklist source
        // switched, or an update landed) — setAdBlock always reflects the current lists.
        .onChange(of: model.browserContentRulesGeneration) { session.setAdBlock(model.browserAdBlockEnabled) }
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

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                session.onOpenWindow?(nil)
            } label: {
                Label("New Tab", systemImage: "plus")
            }
            .help("Open a new tab")

            shelfButton
        }
    }

    // MARK: - Address bar (Safari-style)

    /// The unified address/search field, modelled on Safari: the site's favicon + bare domain when
    /// idle, a search glyph + centered prompt on the start page, and the full, editable URL once
    /// focused. It draws **no background or ring of its own** — the macOS toolbar already gives the
    /// principal item a Liquid Glass pill, so anything we added would stack into a second, mismatched
    /// pill. Focus is shown the way Safari shows it: the content becomes the editable, selected URL.
    private var urlField: some View {
        ZStack {
            // Editable layer — always mounted so focusing it is reliable; its text hides while idle.
            // The field is a borderless AppKit NSTextField with its focus ring removed so nothing is
            // drawn on top of the toolbar's own pill.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .opacity(isEditingURL ? 1 : 0)   // idle uses the overlay's glyph; avoid two glasses
                URLTextField(
                    text: Bindable(session).urlText,
                    placeholder: String(localized: "Search or enter website address"),
                    isEditing: isEditingURL,
                    focusRequest: focusRequestToken,
                    onEditingChanged: { editing in
                        isEditingURL = editing
                        session.isEditingURLBar = editing
                    },
                    onSubmit: { session.commitURLBar() }
                )
            }

            // Idle layer — favicon + bare domain (or the search prompt on the start page). Tapping it
            // reveals the full URL for editing, the way clicking Safari's field does.
            if !isEditingURL {
                Button(action: beginEditingURL) {
                    idleAddressContent
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .frame(height: 20)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minWidth: 280, idealWidth: 540, maxWidth: 640)
        .background { loadingFill }
        .overlay(alignment: .trailing) { reloadControl }
    }

    /// The page-load indicator, drawn *inside* the address pill: a soft accent gradient capsule that
    /// grows from the leading edge as `estimatedProgress` climbs, then fades away when the load
    /// finishes. It sits behind the pill's content (the URL/domain stays fully legible on top).
    ///
    /// Corner-radius fit: the fill is its own `Capsule` — a true half-height radius — inset a uniform
    /// `fillInset` from the field's frame so it nests *concentrically* inside the toolbar's Liquid
    /// Glass pill (also a capsule) with an even margin on all sides. That even inset is what makes it
    /// sit cleanly; matching the system pill edge-to-edge isn't possible (the glass bounds aren't
    /// exposed), and overshooting would spill colour past the pill. No separate progress bar — this
    /// is the only load affordance.
    private var loadingFill: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.10)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: max(0, geometry.size.width * loadProgress))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Self.fillInset)
        .opacity(session.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: loadProgress)
        .animation(.easeInOut(duration: 0.3), value: session.isLoading)
    }

    /// Uniform inset of the loading fill from the field frame, so the fill's capsule nests inside the
    /// toolbar's glass pill with an even margin.
    private static let fillInset: CGFloat = 2.5

    /// WebKit's estimated load progress, clamped to 0…1 for the fill width.
    private var loadProgress: Double { min(max(session.progress, 0), 1) }

    /// What the idle (unfocused) bar shows: favicon + bare domain on a page, or a centered search
    /// prompt on the start page.
    @ViewBuilder
    private var idleAddressContent: some View {
        if let url = session.currentURL {
            HStack(spacing: 6) {
                siteGlyph
                    .help(session.isSecure ? String(localized: "Secure connection")
                                           : String(localized: "Not a secure connection"))
                Text(Self.prettyDomain(url))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search or enter website address")
            }
            .foregroundStyle(.secondary)
        }
    }

    /// The site's favicon when we have one, else a lock (secure) or globe (not) — Safari's identity glyph.
    @ViewBuilder
    private var siteGlyph: some View {
        if let favicon = session.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: session.isSecure ? "lock.fill" : "globe")
                .foregroundStyle(.secondary)
        }
    }

    /// Reload / stop, pinned to the trailing edge and layered above the idle button so it stays
    /// clickable. Hidden while editing, matching Safari.
    @ViewBuilder
    private var reloadControl: some View {
        if !isEditingURL, session.currentURL != nil {
            Button {
                session.reloadOrStop()
            } label: {
                Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // A comfortable click target (the bare glyph alone is ~14 pt).
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .padding(.trailing, 3)
            }
            .buttonStyle(.plain)
            .help(session.isLoading ? String(localized: "Stop loading") : String(localized: "Reload this page"))
            .accessibilityLabel(session.isLoading ? Text("Stop loading") : Text("Reload this page"))
        }
    }

    private func beginEditingURL() {
        if let url = session.currentURL { session.urlText = url.absoluteString }
        isEditingURL = true          // reveal the editable field at once; the field confirms/ends focus
        focusRequestToken += 1
    }

    /// Safari-style bare host: drop a leading `www.`, and fall back to the full string for URLs
    /// without a host (`file:`, `about:`).
    private static func prettyDomain(_ url: URL) -> String {
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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
                    .font(.system(size: 9, weight: .bold))
                    // The system's "text on accent" color — stays legible even with a light user
                    // accent (yellow, graphite), where forced white would wash out.
                    .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(.tint, in: Capsule())
                    .allowsHitTesting(false)
            }
        }
    }

    private var shelfCount: Int { session.shelfItems.count }

    // MARK: - Overlays

    // Both full-pane states go through the shared `EmptyStateView`, so the browser speaks with the
    // same empty-state voice (and title line height) as the main window's panes.
    private var startPage: some View {
        EmptyStateView("Search or enter a website address", systemImage: "globe") {
            Text("Media and file downloads you start here are captured by CloakDrop automatically.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 380)
        }
        .background(.background)
    }

    private func loadErrorOverlay(_ error: BrowserLoadError) -> some View {
        EmptyStateView(Text(error.message), systemImage: "wifi.exclamationmark") {
            if let host = error.failingURL?.host() {
                Text(host)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button("Try Again") { session.retryAfterError() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
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
        VStack(spacing: 0) {
            // The same header band as every other sheet, with the host (and realm) as context.
            SheetHeader(
                title: request.isProxy ? "The proxy requires a password." : "This site requires a password.",
                systemImage: "lock.shield",
                subtitle: realmSubtitle
            )
            VStack(alignment: .leading, spacing: 14) {
                Form {
                    TextField("User Name", text: $username)
                    SecureField("Password", text: $password)
                    Toggle("Remember in my Keychain", isOn: $remember)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { request.cancel() }
                        .keyboardShortcut(.cancelAction)
                    Button("Sign In") {
                        if remember { sink.rememberSiteCredentials(host: request.host, username: username, password: password) }
                        request.finish(username: username, password: password)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(username.isEmpty)
                }
            }
            .padding(20)
        }
        .frame(width: 380)
        .onAppear {
            if let saved = sink.siteCredentials(forHost: request.host) {
                username = saved.username
                password = saved.password
            }
        }
    }

    /// "host" or "host — realm", the context line under the header title.
    private var realmSubtitle: Text {
        if let realm = request.realm, !realm.isEmpty {
            return Text(verbatim: "\(request.host) — \(realm)")
        }
        return Text(verbatim: request.host)
    }
}
