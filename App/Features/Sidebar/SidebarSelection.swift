import Foundation
import DownloadModels

/// What the user has selected in the sidebar, driving the content list's filter.
enum SidebarSelection: Hashable {
    case smart(SmartFilter)
    case category(FileCategory)
    case queue(UUID)

    /// Whether a given download belongs in this selection, within `queues` context.
    func matches(_ download: Download) -> Bool {
        switch self {
        case .smart(let filter): return filter.matches(download)
        case .category(let category): return download.category == category
        case .queue(let id): return download.queueID == id
        }
    }

    var title: String {
        switch self {
        case .smart(let filter): return filter.localizedName
        case .category(let category): return category.localizedName
        case .queue: return String(localized: "Queue")
        }
    }

    /// SF Symbol for the "nothing in this section yet" empty state.
    var emptySymbol: String {
        switch self {
        case .smart(let filter): return filter.systemImage
        case .category(let category): return category.systemImage
        case .queue: return "tray"
        }
    }
}
