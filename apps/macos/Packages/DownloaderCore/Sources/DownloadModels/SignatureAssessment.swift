import Foundation

/// The result of assessing a finished file's *code signature* — CloakDrop's on-device trust check
/// for installable downloads. Purely local and in-process: it reads the signature already embedded
/// in the file (via the Security framework, in the engine) and never contacts a network service.
///
/// A value type so it persists on the `Download` and crosses actor boundaries freely.
public struct SignatureAssessment: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable {
        /// A code signature is present and passed validation.
        case valid
        /// A code signature is present but failed validation — tampered, broken, or expired.
        case invalid
        /// The file carries no code signature at all.
        case unsigned
    }

    public var status: Status
    /// The signing authority: the leaf certificate's common name, e.g.
    /// "Developer ID Application: Acme Inc. (AB12CD34EF)". `nil` when unsigned or unavailable.
    public var authority: String?

    public init(status: Status, authority: String? = nil) {
        self.status = status
        self.authority = authority
    }

    /// The file types whose signature CloakDrop assesses in-process. App bundles and disk images
    /// carry a signature that `SecStaticCode` validates directly. Other installers (notably `.pkg`,
    /// whose CMS signature needs the installer/`pkgutil`) are intentionally left *unassessed* rather
    /// than reported misleadingly as unsigned.
    public static func isAssessable(fileName: String) -> Bool {
        assessableExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    private static let assessableExtensions: Set<String> = ["app", "dmg"]
}
