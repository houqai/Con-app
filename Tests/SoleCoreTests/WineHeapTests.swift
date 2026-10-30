import CConPlatform
import Foundation
import XCTest
#if os(Windows)
import WinSDK
#endif

final class WineHeapTests: XCTestCase {
    private var underWine: Bool {
        #if os(Windows)
        let ntdll = "ntdll.dll".withCString(encodedAs: UTF16.self) { GetModuleHandleW($0) }
        return ntdll != nil && GetProcAddress(ntdll, "wine_get_version") != nil
        #else
        return false
        #endif
    }

    func testTheHeapIsActiveUnderWineOnly() {
        XCTAssertEqual(con_wine_heap_active() != 0, underWine)
    }

    func testSmallAllocationsLieAboveTheLowTwoGigabytesUnderWine() throws {
        try XCTSkipUnless(underWine, "Only Wine puts the C runtime's heap in the low 2 GB")
        let block = UnsafeMutableRawPointer.allocate(byteCount: 48, alignment: 8)
        defer { block.deallocate() }
        XCTAssertGreaterThan(UInt(bitPattern: block), 0x7fff_ffff)
    }

    func testUTF16OffsetsOfANonASCIITextAreRight() {
        let text = String(repeating: "Größe ", count: 50)
        let index = text.index(text.startIndex, offsetBy: 200)
        XCTAssertEqual(text.utf16.distance(from: text.utf16.startIndex, to: index), 200)
        XCTAssertEqual((text as NSString).range(of: "Größe", options: .backwards).location, 294)
        XCTAssertEqual(text.range(of: "ße", options: .backwards).map { text.utf16.distance(from: text.utf16.startIndex, to: $0.lowerBound) }, 297)
    }
}
