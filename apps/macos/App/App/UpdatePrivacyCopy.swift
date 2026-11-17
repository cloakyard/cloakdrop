import SwiftUI

/// Keep this disclosure aligned with the app privacy policy and the other Cloakyard apps.
@MainActor
enum UpdatePrivacyCopy {
    static let details: LocalizedStringKey = """
    Automatic update checks and downloads are off by default. Manage updates in About.

    Checks contact this app’s Cloakyard website; downloads come from GitHub Releases. \
    These services receive ordinary request data, including your IP address and app/updater version.

    No files, app activity, analytics or system profile are uploaded. \
    Update preferences and the last check time stay on this Mac.
    """
}
