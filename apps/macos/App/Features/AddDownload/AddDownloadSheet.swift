import SwiftUI
import AppKit
import DownloadModels

/// The "add download" sheet: URL (pre-filled from the clipboard when it holds a link),
/// destination, segment count, and an optional checksum to verify against.
struct AddDownloadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var fileName = ""
    /// The last filename we auto-derived from the URL. While the field still holds this value
    /// (or is empty) we keep syncing it as the URL changes; once the user types their own name
    /// it differs and we stop overwriting. This keeps derivation correct even when the URL is
    /// entered one character at a time, instead of locking onto an early partial value.
    @State private var lastAutoName = ""
    @State private var destinationURL = AppEnvironment.defaultDownloadsDirectory()
    @State private var destinationBookmark: Data?
    @State private var segmentCount = 8
    @State private var checksumAlgorithm: ChecksumAlgorithm = .sha256
    @State private var checksumHex = ""
    @State private var startImmediately = true
    @State private var scheduleEnabled = false
    @State private var scheduledDate = Date().addingTimeInterval(3600)
    @State private var recurrence: ScheduleRecurrence = .none
    @State private var username = ""
    @State private var password = ""
    @State private var rememberCredentials = false
    /// The host the currently-shown credentials were auto-filled for, so they can be cleared if the
    /// user then edits the URL to a different host (never send one host's saved password to another).
    @State private var autofilledHost: String?
    @State private var referrer = ""
    @State private var cookies = ""

    // On-device link intelligence: a debounced pre-flight of the entered URL, so the sheet shows
    // what's actually there (size, type, resumability, connection estimate) before the user commits.
    @State private var preview: LinkPreview?
    @State private var isInspecting = false
    @State private var previewFailed = false
    /// The URL a preview was last resolved (or attempted) for, so re-typing the same link doesn't reprobe.
    @State private var lastInspectedURL: URL?
    @State private var inspectionTask: Task<Void, Never>?

    private var resolvedURL: URL? { AppModel.normalizedURL(urlString) }
    private var canAdd: Bool { resolvedURL != nil }

    /// The video site this URL belongs to, when it's a recognized page the bundled extractor can
    /// resolve (and extraction is available) — a YouTube link, etc. When set, the sheet offers to grab
    /// the video (best quality, or the picker when "Ask me quality" is on) instead of saving the page.
    private var detectedVideoPage: VideoPageSite? {
        // Gate on the extractor's *presence* (as the browser's grab button does), not the async
        // launch-time version probe — otherwise a URL pasted in the first moments after launch would
        // be mis-probed as a file until the probe resolves.
        guard model.canExtractFromPages, let url = resolvedURL else { return nil }
        return VideoPageDetector.detect(url)
    }

    /// Any expiry deadline baked into a pre-signed / tokened URL, read purely from the query string
    /// (no network), so an already-dead link is flagged the instant it's entered — before the user
    /// waits on a download that can only fail.
    private var linkExpiry: LinkExpiry? { resolvedURL.flatMap(LinkExpiryDetector.detect(in:)) }

    /// True when the user typed something in the checksum field that isn't a valid digest, so
    /// we can warn that it won't be used rather than silently dropping it.
    private var checksumIsMalformed: Bool {
        let trimmed = checksumHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !ChecksumExpectation(algorithm: checksumAlgorithm, expectedHex: trimmed).isWellFormed
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "New Download", systemImage: "arrow.down.circle.fill")

            Form {
                Section("Source") {
                    TextField("URL", text: $urlString, prompt: Text("https://example.com/file.zip"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: urlString) { _, _ in
                            deriveFileNameIfNeeded()
                            scheduleInspection()
                        }
                    if let site = detectedVideoPage {
                        videoPageRow(site)
                    } else {
                        if isInspecting || preview != nil || previewFailed {
                            linkPreviewRow
                        }
                        if linkExpiry != nil {
                            expiryRow
                        }
                        TextField("Save As", text: $fileName, prompt: Text("File name"))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section("Destination") {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(destinationURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { chooseDestination() }
                    }
                }

                // Connections, scheduling, and checksum verification apply to a file download, not a
                // resolved video grab (the extractor plans its own segments and names from the title).
                if detectedVideoPage == nil {
                    Section("Options") {
                        Stepper(value: $segmentCount, in: 1...model.settings.maxSegmentCount) {
                            LabeledContent("Connections", value: "\(segmentCount)")
                        }
                        Toggle("Start immediately", isOn: $startImmediately)
                            .disabled(scheduleEnabled)
                        Toggle("Schedule for later", isOn: $scheduleEnabled.animation(.smooth(duration: 0.2)))
                        if scheduleEnabled {
                            DatePicker("Start at", selection: $scheduledDate, in: Date()...)
                                .datePickerStyle(.compact)
                            Picker("Repeat", selection: $recurrence) {
                                ForEach(ScheduleRecurrence.allCases) { Text($0.localizedLabel).tag($0) }
                            }
                            if let expiry = linkExpiry, scheduledDate >= expiry.expiresAt {
                                Label("This link expires before the scheduled start time.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                Section {
                    if detectedVideoPage == nil {
                        DisclosureGroup("Authentication") {
                            TextField("Username", text: $username)
                                .textFieldStyle(.roundedBorder)
                            SecureField("Password", text: $password, prompt: Text("HTTP Basic/Digest"))
                                .textFieldStyle(.roundedBorder)
                            Toggle("Remember for this site", isOn: $rememberCredentials)
                        }
                    }
                    // Referrer & cookies stay available for a video grab — a private or age-gated page
                    // needs them handed to the extractor.
                    DisclosureGroup("Referrer & cookies") {
                        TextField("Referrer", text: $referrer, prompt: Text("https://example.com"))
                            .textFieldStyle(.roundedBorder)
                        TextField("Cookies", text: $cookies, prompt: Text("name=value; name2=value2"))
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    }
                    if detectedVideoPage == nil {
                        DisclosureGroup("Verify checksum") {
                            Picker("Algorithm", selection: $checksumAlgorithm) {
                                ForEach(ChecksumAlgorithm.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            TextField("Expected hash", text: $checksumHex, prompt: Text("Optional hex digest"))
                                .textFieldStyle(.roundedBorder)
                                .font(.callout.monospaced())
                            if checksumIsMalformed {
                                Label("Not a valid \(checksumAlgorithm.displayName) digest — this file won’t be verified.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                // A video page always grabs immediately (the extractor has no scheduled-start path),
                // and its Options/schedule controls are hidden — so never show "Schedule" for one, even
                // if the toggle was left on from a previous file URL in the same sheet.
                Button(scheduleEnabled && detectedVideoPage == nil ? "Schedule" : "Add Download") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
        .onAppear(perform: prefill)
        .onDisappear { inspectionTask?.cancel() }
    }

    // MARK: Video page

    /// Shown in place of the file preview when the URL is a recognized video page: a play glyph, the
    /// site name, and what will happen on Add — the best quality straight away, or the quality picker
    /// when "Ask me quality" is on.
    private func videoPageRow(_ site: VideoPageSite) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(site.displayName) video")
                    .font(.callout)
                Text(model.askQualityEnabled
                     ? String(localized: "You’ll choose the quality after it’s read.")
                     : String(localized: "The best quality will be downloaded."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    // MARK: Link preview

    /// The pre-flight summary row shown under the URL field: a spinner while probing, a compact
    /// file card once resolved, or a muted note if the server couldn't be reached.
    @ViewBuilder
    private var linkPreviewRow: some View {
        if isInspecting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking link…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
        } else if let preview {
            HStack(spacing: 10) {
                Image(systemName: FileIcon.symbol(forFileName: preview.suggestedFileName))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.suggestedFileName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(previewDetailLine(preview))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if preview.wasRedirected, let host = preview.finalURL.host() {
                        Label("Redirects to \(host)", systemImage: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        } else if previewFailed {
            Label("Couldn’t preview this link — you can still add it.", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }

    /// Deadline warning for a pre-signed / tokened link, escalating with urgency: a red alert callout
    /// once expired (so the user never waits on a dead link), an amber callout when it expires within a
    /// day, and a quiet grey line when there's plenty of time left.
    @ViewBuilder
    private var expiryRow: some View {
        if let expiry = linkExpiry {
            let now = Date()
            let remaining = expiry.timeRemaining(asOf: now)
            if expiry.isExpired(asOf: now) {
                expiryCallout(tint: .red,
                              title: Text("This link has already expired"),
                              detail: Text(Format.relativeDeadline(expiry.expiresAt, asOf: now)))
            } else if remaining < 86_400 {
                expiryCallout(tint: .orange,
                              title: Text("Link expires \(Format.relativeDeadline(expiry.expiresAt, asOf: now))"),
                              detail: nil)
            } else {
                Label("Link expires \(Format.relativeDeadline(expiry.expiresAt, asOf: now))", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A tinted alert banner fronted by a warning triangle — red for an expired link, amber for one
    /// about to expire. Solid colour tint (not glass) so it reads as danger and respects the
    /// no-material-on-scrolling-content rule.
    private func expiryCallout(tint: Color, title: Text, detail: Text?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                title.font(.callout.weight(.semibold)).foregroundStyle(tint)
                if let detail { detail.font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Design.inlineRadius))
        .overlay(RoundedRectangle(cornerRadius: Design.inlineRadius).strokeBorder(tint.opacity(0.28)))
    }

    /// "1.4 GB · Resumable · 8 connections" — only the parts we actually know, joined by dots.
    private func previewDetailLine(_ preview: LinkPreview) -> String {
        var parts: [String] = []
        if preview.hasKnownSize { parts.append(Format.bytes(preview.totalBytes)) }
        parts.append(preview.isResumable ? String(localized: "Resumable") : String(localized: "Not resumable"))
        if preview.isMultiSegment { parts.append(String(localized: "\(preview.plannedSegmentCount) connections")) }
        return parts.joined(separator: " · ")
    }

    /// Debounced pre-flight: wait for typing to settle, then probe the (valid) URL once. Cancels any
    /// in-flight probe when the URL changes, and skips re-probing a URL already inspected.
    private func scheduleInspection() {
        inspectionTask?.cancel()
        guard let url = resolvedURL else {
            withAnimation(.smooth(duration: 0.2)) { preview = nil; isInspecting = false; previewFailed = false }
            lastInspectedURL = nil
            return
        }
        // A recognized video page is resolved by the extractor on Add — probing it as a file would just
        // show a misleading "watch.html · Not resumable" card, so skip the pre-flight for it.
        if detectedVideoPage != nil {
            withAnimation(.smooth(duration: 0.2)) { preview = nil; isInspecting = false; previewFailed = false }
            lastInspectedURL = url
            return
        }
        guard url != lastInspectedURL else { return }   // already have (or attempted) this exact URL
        autofillSavedCredentials(for: url)
        inspectionTask = Task {
            try? await Task.sleep(for: .milliseconds(500))   // debounce keystrokes
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.2)) { isInspecting = true; previewFailed = false }
            let result = await model.preview(
                url: url,
                referrer: trimmedOrNil(referrer),
                cookies: trimmedOrNil(cookies),
                username: trimmedOrNil(username),
                password: password.isEmpty ? nil : password
            )
            guard !Task.isCancelled else { return }
            lastInspectedURL = url
            withAnimation(.smooth(duration: 0.2)) {
                isInspecting = false
                preview = result
                previewFailed = (result == nil)
            }
            if let result { adoptPreviewFileName(result) }
        }
    }

    /// Adopt the server's file name when the user hasn't typed their own — the pre-flight often
    /// knows a better name (from `Content-Disposition`) than the raw URL's last path component.
    private func adoptPreviewFileName(_ preview: LinkPreview) {
        guard fileName.isEmpty || fileName == lastAutoName else { return }
        fileName = preview.suggestedFileName
        lastAutoName = preview.suggestedFileName
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Pre-fill saved credentials for this URL's host when the fields are still empty, so a returning
    /// user doesn't retype them. Flips the "remember" toggle on to reflect that they're stored.
    private func autofillSavedCredentials(for url: URL) {
        let host = url.host
        // If we auto-filled for a previous host and the user hasn't touched the fields, clear them
        // before the host changes — otherwise host A's password would ride along to host B (and get
        // re-stored under B's key on Add).
        if let prev = autofilledHost, prev != host, let saved = model.siteCredentials(forHost: prev),
           username == saved.username, password == saved.password {
            username = ""; password = ""; rememberCredentials = false; autofilledHost = nil
        }
        guard username.isEmpty, password.isEmpty, let host,
              let saved = model.siteCredentials(forHost: host) else { return }
        username = saved.username
        password = saved.password
        rememberCredentials = true
        autofilledHost = host
    }

    // MARK: Actions

    private func prefill() {
        // A pending URL (from a clipboard banner or drop) wins over the live clipboard.
        if let pending = model.pendingAddURL {
            urlString = pending
            model.pendingAddURL = nil
            deriveFileNameIfNeeded()
            return
        }
        guard urlString.isEmpty,
              let clip = NSPasteboard.general.string(forType: .string),
              AppModel.normalizedURL(clip) != nil else { return }
        urlString = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        deriveFileNameIfNeeded()
    }

    private func deriveFileNameIfNeeded() {
        guard let url = resolvedURL else { return }
        // Never clobber a name the user typed: only overwrite while the field still holds the
        // value we last derived (or is empty).
        guard fileName.isEmpty || fileName == lastAutoName else { return }
        let last = url.lastPathComponent
        let derived = (last.isEmpty || last == "/") ? "download" : last
        fileName = derived
        lastAutoName = derived
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destinationURL
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationURL = url
        destinationBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func add() {
        guard let url = resolvedURL else { return }
        // A recognized video page routes through the extractor: it resolves the real formats, then
        // downloads the best tier or opens the quality picker (per "Ask me quality").
        if detectedVideoPage != nil {
            model.grabPage(
                url: url,
                destinationDirectoryPath: destinationURL.path,
                destinationBookmark: destinationBookmark,
                referrer: trimmedOrNil(referrer),
                cookies: trimmedOrNil(cookies)
            )
            dismiss()
            return
        }
        let trimmedHex = checksumHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum: ChecksumExpectation? = {
            guard !trimmedHex.isEmpty else { return nil }
            let expectation = ChecksumExpectation(algorithm: checksumAlgorithm, expectedHex: trimmedHex)
            return expectation.isWellFormed ? expectation : nil
        }()

        let request = DownloadRequest(
            url: url,
            suggestedFileName: fileName.isEmpty ? nil : fileName,
            destinationDirectoryPath: destinationURL.path,
            destinationBookmark: destinationBookmark,
            segmentCount: segmentCount,
            checksum: checksum,
            scheduledStart: scheduleEnabled ? scheduledDate : nil,
            recurrence: scheduleEnabled ? recurrence : .none,
            startImmediately: scheduleEnabled ? false : startImmediately,
            username: trimmedOrNil(username),
            password: password.isEmpty ? nil : password,
            referrer: trimmedOrNil(referrer),
            cookies: trimmedOrNil(cookies)
        )
        // Only hand the pre-flight to duplicate detection if it's for the URL we're actually adding
        // (the user may have edited the URL after the last probe resolved).
        let effectivePreview = preview?.requestedURL == url ? preview : nil
        if rememberCredentials, let host = url.host {
            model.rememberSiteCredentials(host: host, username: username, password: password)
        }
        model.grab(request, preview: effectivePreview)
        dismiss()
    }
}
