import Foundation

/// Builds the pre-filled GitHub "new issue" URL for the Report a Bug action: a structured template
/// the reporter fills in (what happened, steps, expected vs. actual, screenshot), plus the
/// environment facts triage always needs — app + macOS version, Mac model, chip, architecture,
/// locale — gathered automatically so a user never has to dig for them.
///
/// The body is intentionally English (the repository's issue-tracker language, read by the
/// maintainers) and is a plain `String` used to build a URL, not in-app `Text` — so it sits outside
/// the String Catalog on purpose.
enum BugReport {
    /// A GitHub new-issue URL carrying the `bug` label, a title prefix, and the pre-filled body.
    /// Opening it lands the reporter on a ready-to-complete issue form.
    static var issueURL: URL {
        var components = URLComponents(string: "https://github.com/cloakyard/cloakdrop/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "labels", value: "bug"),
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: "body", value: templateBody)
        ]
        // Fall back to the plain new-issue page if the query somehow can't be encoded.
        return components.url ?? AppLinks.reportBug
    }

    /// The Markdown issue body: guidance comments (hidden once posted) around sections the reporter
    /// fills in, ending with the auto-filled environment table.
    private static var templateBody: String {
        """
        <!-- Thanks for helping improve CloakDrop! Please fill in the sections below. -->

        ### What happened?
        <!-- A clear one- or two-sentence description of the bug. -->

        ### Steps to reproduce
        1. …
        2. …
        3. …

        ### What you expected
        <!-- What should have happened instead. -->

        ### What actually happened
        <!-- The actual result — include any error message text. -->

        ### Screenshot
        <!-- Drag and drop an image here to attach a screenshot of the error, if you have one. -->

        ### Environment
        <!-- Filled in automatically — please leave as-is. -->
        \(environmentTable)
        """
    }

    /// A Markdown table of the diagnostic facts, read from the running system.
    static var environmentTable: String {
        """
        | | |
        |---|---|
        | CloakDrop | \(appVersion) |
        | macOS | \(macOSVersion) |
        | Mac | \(sysctlString("hw.model") ?? "—") |
        | Chip | \(sysctlString("machdep.cpu.brand_string") ?? "—") |
        | Architecture | \(machineArchitecture) |
        | Locale | \(Locale.current.identifier) |
        """
    }

    // MARK: Facts

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// CPU architecture as the kernel reports it (e.g. "arm64").
    private static var machineArchitecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return bytes.isEmpty ? "—" : String(bytes: bytes, encoding: .utf8) ?? "—"
        }
    }

    /// A string-valued `sysctl` (e.g. "hw.model" → "Mac15,3"), or nil if unavailable.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8)
        }
    }
}
