import WebKit
import DownloadModels

// The four WebKit delegate conformances. State/intents live in BrowserSession.swift.

// MARK: - Navigation

extension BrowserSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // ⌥-click and `<a download>` — the page explicitly asked for a download.
        if navigationAction.shouldPerformDownload { return .download }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        switch scheme {
        case "http", "https", "about", "blob", "data", "javascript":
            return .allow
        case "ftp", "ftps":
            // The engine speaks FTP natively — a browser can't. Straight to the engine.
            takeOver(url: url, suggestedFilename: nil, mimeType: nil, kind: .file)
            return .cancel
        case "mailto", "cloakdrop":
            NSWorkspace.shared.open(url)
            return .cancel
        default:
            return .cancel   // never bounce the user into arbitrary external apps from a page
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard let response = navigationResponse.response as? HTTPURLResponse else { return .allow }
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition")
        // IDM-style takeover, scoped to what the *browser* would download anyway: an explicit
        // attachment, or a type WebKit can't render. Inline-playable media stays in the page —
        // grabbing that is the shelf's job, not navigation's.
        if !navigationResponse.canShowMIMEType || MediaSniffer.attachmentFilename(disposition) != nil {
            return .download
        }
        // A renderable subframe response is still a sighting (an iframe navigating to media).
        // Main-frame responses are skipped: `didCommit` resets page state right after this, and a
        // renderable main-frame document is never itself a candidate.
        if !navigationResponse.isForMainFrame, let url = response.url?.absoluteString {
            let length = response.expectedContentLength
            applySniff(SniffEnvelope(frameURL: url, isTopFrame: false, events: [SniffEvent(
                kind: .response,
                url: url,
                contentType: response.mimeType,
                contentLength: length > 0 ? length : nil,
                contentDisposition: disposition
            )]))
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        clearLoadError()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        markCommitted(url: webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        captureUserAgentIfNeeded()
        refreshFavicon()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        handleLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        handleLoadFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // One quiet recovery, then honesty: a crash-looping page gets the error state instead of
        // a reload storm.
        if shouldAutoRecoverFromCrash() {
            webView.reload()
        } else {
            presentLoadError(String(localized: "This page keeps crashing."), failingURL: webView.url)
        }
    }

    func webView(
        _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let interactiveMethods = [
            NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM
        ]
        guard interactiveMethods.contains(space.authenticationMethod) else {
            return (.performDefaultHandling, nil)   // server trust etc. — never bypassed, never customized
        }
        // Saved credentials answer the first challenge silently; a failure falls through to the sheet.
        if challenge.previousFailureCount == 0, let saved = sink?.siteCredentials(forHost: space.host) {
            return (.useCredential, URLCredential(user: saved.username, password: saved.password, persistence: .forSession))
        }
        guard authRequest == nil else { return (.cancelAuthenticationChallenge, nil) }
        let credential = await withCheckedContinuation { (continuation: CheckedContinuation<URLCredential?, Never>) in
            authRequest = BrowserAuthRequest(host: space.host, realm: space.realm, isProxy: space.isProxy()) {
                continuation.resume(returning: $0)
            }
        }
        authRequest = nil
        if let credential { return (.useCredential, credential) }
        return (.cancelAuthenticationChallenge, nil)
    }

    private func handleLoadFailure(_ error: any Error) {
        let nsError = error as NSError
        // -999: superseded/stopped by the user. WebKit 102: navigation became a download — that's
        // takeover working, not a failure.
        if nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? currentURL
        presentLoadError(Self.friendlyLoadMessage(nsError), failingURL: failingURL)
    }

    static func friendlyLoadMessage(_ error: NSError) -> String {
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
            return String(localized: "You appear to be offline.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return String(localized: "Can’t find that server.")
        case NSURLErrorTimedOut:
            return String(localized: "The server took too long to respond.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid:
            return String(localized: "A secure connection couldn’t be made.")
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - UI (popups, dialogs, permissions)

extension BrowserSession: WKUIDelegate {
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // With blocking on, drop popups aimed at a known ad/tracker host outright — pop-unders and
        // redirect ads target those, and they never reach the network rules (a popup is a brand-new
        // top-level load). Checked against the curated hosts AND the active downloaded blocklist.
        // Legit popups (OAuth, "open in new window") target content hosts and pass.
        if adBlockEnabled, let host = navigationAction.request.url?.host,
           BrowserStore.shared.isBlockedPopupHost(host) {
            return nil
        }
        // Popups become real sibling windows (opened via SwiftUI, not this configuration), with a
        // storm guard so an abusive page can't spray windows. Returning nil tells the page the
        // popup was blocked — fine: window.opener scripting isn't a capability this browser sells.
        let now = Date()
        popupTimestamps = popupTimestamps.filter { now.timeIntervalSince($0) < 10 }
        guard popupTimestamps.count < 3 else { return nil }
        popupTimestamps.append(now)
        onOpenWindow?(navigationAction.request.url)
        return nil
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo
    ) async {
        guard dialog == nil else { return }   // one dialog at a time; extras resolve immediately
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dialog = BrowserDialog(message: message, host: frame.securityOrigin.host,
                                   kind: .alert { continuation.resume() })
        }
        dialog = nil
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        guard dialog == nil else { return false }
        let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            dialog = BrowserDialog(message: message, host: frame.securityOrigin.host,
                                   kind: .confirm { continuation.resume(returning: $0) })
        }
        dialog = nil
        return confirmed
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        guard dialog == nil else { return nil }
        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            dialog = BrowserDialog(message: prompt, host: frame.securityOrigin.host,
                                   kind: .prompt(defaultText: defaultText ?? "") { continuation.resume(returning: $0) })
        }
        dialog = nil
        return text
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .deny   // a download manager's browser has no business with camera or microphone
    }
}

// MARK: - Sniffer bridge

extension BrowserSession: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mediaSniffer", var envelope = SniffEnvelope.parse(messageBody: message.body) else { return }
        // The JS reports whether it *thinks* it's the top frame, but page scripts share that world —
        // WebKit's frame info is the authority.
        envelope.isTopFrame = message.frameInfo.isMainFrame
        applySniff(envelope)
    }
}

// MARK: - Download takeover (WKDownload)

extension BrowserSession: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        if let url = response.url ?? download.originalRequest?.url {
            let http = response as? HTTPURLResponse
            let classified = MediaSniffer.classifyByContentType(
                url.absoluteString,
                contentType: response.mimeType,
                contentLength: response.expectedContentLength > 0 ? response.expectedContentLength : nil,
                contentDisposition: http?.value(forHTTPHeaderField: "Content-Disposition")
            )
            // A downloaded manifest routes as a stream (quality picker); everything else is a file.
            takeOver(url: url, suggestedFilename: suggestedFilename, mimeType: response.mimeType,
                     kind: classified?.type == .stream ? .stream : .file)
        }
        return nil   // no destination: WebKit cancels — the engine owns every byte
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        // Expected: we cancel every WKDownload by returning a nil destination. Nothing to do.
    }
}
