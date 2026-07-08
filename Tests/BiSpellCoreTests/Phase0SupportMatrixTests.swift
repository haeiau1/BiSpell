import XCTest
@testable import BiSpellCore

/// Phase 0: pure data model tests for support matrix (AX requires interactive run).
final class Phase0SupportMatrixTests: XCTestCase {
    func testSupportSampleCodable() throws {
        let sample = AppSupportSample(
            appName: "Notes",
            bundleID: "com.apple.Notes",
            canReadValue: true,
            canReadSelection: true,
            canReadBounds: false,
            notes: "role=AXTextArea",
            tier: .a
        )
        let data = try JSONEncoder().encode([sample])
        let decoded = try JSONDecoder().decode([AppSupportSample].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].tier, .a)
        XCTAssertEqual(decoded[0].bundleID, "com.apple.Notes")
    }

    func testTierLogicExpectationsDocumented() {
        // Tier A: read+selection, B: read only, C: neither
        XCTAssertEqual(SupportTier.a.rawValue, "A")
        XCTAssertEqual(SupportTier.b.rawValue, "B")
        XCTAssertEqual(SupportTier.c.rawValue, "C")
    }
}
