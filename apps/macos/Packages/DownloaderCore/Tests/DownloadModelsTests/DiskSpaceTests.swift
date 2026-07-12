import Foundation
import Testing
@testable import DownloadModels

@Suite("Disk-space preflight decision")
struct DiskSpaceTests {

    @Test("Insufficient only when a known capacity is smaller than the need")
    func decision() {
        #expect(DiskSpace.isInsufficient(needed: 100, available: 50))
        #expect(!DiskSpace.isInsufficient(needed: 100, available: 200))
        #expect(!DiskSpace.isInsufficient(needed: 100, available: 100))   // an exact fit is fine
        #expect(!DiskSpace.isInsufficient(needed: 0, available: 0))
        #expect(!DiskSpace.isInsufficient(needed: 100, available: nil))   // unknown capacity never blocks
    }
}
