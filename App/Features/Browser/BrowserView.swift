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
        .toolbar(removing: .title)   // the favicon stands in for the title; the window/tab still carries it
        .toolbar { toolbarContent }
        .focusedSceneValue(\.browserSession, session)
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            session.sink = model
            session.searchEnabled = model.browserSearchEnabled
            session.searchEngine = model.browserSearchEngine
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
        .overlay(alignment: .trailing) { reloadControl }
    }

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
                    .padding(.trailing, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.isLoading ? String(localized: "Stop loading") : String(localized: "Reload this page"))
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
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(.tint, in: Capsule())
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

/// A borderless, single-line address field backed directly by `NSTextField` so its **focus ring is
/// removed** (`focusRingType = .none`). SwiftUI's plain `TextField` still paints a system focus ring
/// whose corner radius doesn't match our rounded container; owning the AppKit view lets the *only*
/// focus decoration be the ring `BrowserView` draws on the container, so highlight and container
/// share one shape exactly. Focus is bridged both ways: the field reports begin/end editing, and a
/// bumped `focusRequest` token asks it to become first responder (⌘L, clicking the idle bar).
private struct URLTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Drives what's visible: the field stays first-responder-capable (alpha 1) at all times, so
    /// hiding it via opacity — which would block `makeFirstResponder` and deadlock the idle→edit
    /// tap — is avoided; when idle we clear the text color instead and the bar's own overlay shows
    /// the favicon + domain.
    var isEditing: Bool
    var focusRequest: Int
    var onEditingChanged: (Bool) -> Void
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> FocusReportingTextField {
        let field = FocusReportingTextField()
        field.focusRingType = .none
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.font = .preferredFont(forTextStyle: .callout)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.allowsEditingTextAttributes = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // becomeFirstResponder fires reliably for programmatic focus (controlTextDidBeginEditing does
        // not); pair it with controlTextDidEndEditing for the resign edge.
        field.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEditingChanged(true)
        }
        return field
    }

    func updateNSView(_ field: FocusReportingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        // Idle: keep the field mounted and focusable but invisible (clear text, no placeholder) —
        // the overlay shows the favicon + domain. Editing: reveal the URL.
        field.textColor = isEditing ? .labelColor : .clear
        field.placeholderString = isEditing ? placeholder : ""
        // A new focus request (⌘L / idle-bar tap) makes the field first responder and selects all,
        // matching how clicking Safari's address bar reveals and highlights the whole URL.
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: URLTextField
        var lastFocusRequest = 0

        init(_ parent: URLTextField) { self.parent = parent }

        func controlTextDidEndEditing(_ obj: Notification) { parent.onEditingChanged(false) }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                control.window?.makeFirstResponder(nil)   // resign → idle state, like Safari after Return
                return true
            }
            return false
        }
    }
}

/// An `NSTextField` that reports when it becomes first responder — the reliable signal for
/// programmatic focus (`controlTextDidBeginEditing` doesn't fire for `makeFirstResponder`).
final class FocusReportingTextField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let began = super.becomeFirstResponder()
        if began { onBecomeFirstResponder?() }
        return began
    }
}
