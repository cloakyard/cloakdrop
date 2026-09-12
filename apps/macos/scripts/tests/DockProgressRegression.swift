import AppKit

/// Run with the production renderer; no app catalog, downloads or persistent settings are opened.
/// swiftc App/Ambient/DockProgressController.swift scripts/tests/DockProgressRegression.swift -o /tmp/dock-regression
@main
struct DockProgressRegression {
    @MainActor
    static func main() throws {
        let application = NSApplication.shared
        if CommandLine.arguments.count > 1 {
            application.applicationIconImage = NSImage(contentsOfFile: CommandLine.arguments[1])
        }
        let controller = DockProgressController()
        let tile = application.dockTile

        controller.update(fraction: 0.4949, activeCount: 2)
        let view = try require(tile.contentView)
        precondition(view.frame.size == tile.size && view.bounds.width > 0)
        precondition(tile.badgeLabel == "2")
        let beforeRounding = try snapshot(view)
        controller.update(fraction: 0.4951, activeCount: 2)
        let afterRounding = try snapshot(view)
        precondition(beforeRounding != afterRounding, "Crossing the displayed percentage must redraw")
        controller.update(fraction: 0.499, activeCount: 2)
        let coalesced = try snapshot(view)
        precondition(coalesced == afterRounding, "An unchanged displayed percentage should be coalesced")

        controller.update(fraction: 0.5, activeCount: 3)
        precondition(tile.badgeLabel == "3")
        controller.update(fraction: nil, activeCount: 2)
        precondition(tile.contentView == nil && tile.badgeLabel == "2")
        controller.update(fraction: 0.5, activeCount: 2)
        precondition(tile.contentView != nil, "Progress must return after an indeterminate state")
        if CommandLine.arguments.count > 2 {
            try snapshot(try require(tile.contentView)).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        controller.update(fraction: .nan, activeCount: 2)
        precondition(tile.contentView == nil)
        controller.update(fraction: .infinity, activeCount: 2)
        precondition(tile.contentView == nil)
        controller.update(fraction: 0.5, activeCount: 0)
        precondition(tile.contentView == nil && tile.badgeLabel == nil)
        print("Dock rendering regression checks passed")
    }

    @MainActor
    private static func snapshot(_ view: NSView) throws -> Data {
        let bitmap = try require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try require(bitmap.representation(using: .png, properties: [:]))
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure.missingValue }
        return value
    }

    private enum Failure: Error { case missingValue }
}
