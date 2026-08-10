import Foundation

/// A current Safari-compatible fallback for requests that do not carry a captured browser UA.
public enum DesktopUserAgent {
    public static func safariProduct(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        "Version/\(max(1, osVersion.majorVersion)).0 Safari/605.1.15"
    }

    public static func safari(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariProduct(osVersion: osVersion))"
    }
}
