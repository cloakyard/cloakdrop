import Foundation

/// Outbound links surfaced in the UI (About tab, menu bar). Kept in one place so the author,
/// project, and bug-report destinations stay consistent wherever they appear.
///
/// These are the *only* non-download URLs the app ever opens, and each is user-initiated (a
/// click) — consistent with the privacy posture that network egress is limited to what the
/// user asks for.
enum AppLinks {
    /// The author's GitHub — "find out what Sumit is up to now".
    static let author = URL(string: "https://github.com/sumitsahoo")!

    /// The CloakDrop source repository (part of the Cloakyard suite).
    static let repository = URL(string: "https://github.com/cloakyard/cloakdrop")!

    /// A plain, pre-labeled "new bug" issue on the project repo. The **Report a Bug** actions use
    /// `BugReport.issueURL` instead, which adds a filled-in template and diagnostics; this bare URL
    /// is the fallback and the "ask a question or report an issue" link.
    static let reportBug = URL(string: "https://github.com/cloakyard/cloakdrop/issues/new?labels=bug")!
}
