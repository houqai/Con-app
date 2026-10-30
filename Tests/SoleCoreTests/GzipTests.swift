import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(zlib)
import zlib
#endif
@testable import SoleCore

final class GzipTests: XCTestCase {
    private func packed(_ base64: String) -> Data { Data(base64Encoded: base64)! }
    private let hello = "H4sIAAAAAAAC//NIzcnJ11Fwzs9TBADKur28CwAAAA=="
    private let repeated = "H4sIAAAAAAAC/wvISawMLkksyczPU0jOyS9NUUhOLEnMyU8vTVUIGJUblRuVG5UblRuVG5UblRuEcgAqMM5qwAgAAA=="
    private let stored = "H4sIAAAAAAAA/wEsAdP+AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYKDhIWGh4iJiouMjY6PkJGSk5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq+wsbKztLW2t7i5uru8vb6/wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t/g4eLj5OXm5+jp6uvs7e7v8PHy8/T19vf4+fr7/P3+/wABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSor7vy8OiwBAAA="
    private let named = "H4sICAAAAAAC/3BhZ2UuaHRtbADzSM3JyddRcM7PUwQAyrq9vAsAAAA="
    private let empty = "H4sIAAAAAAAC/wMAAAAAAAAAAAA="
    private let catalogue = "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"
    private let fixed = "H4sIAAAAAAACEwvISawMLkksyczPU0jOyS9NUUhOLEnMyU8vTVUIGEJyADVyOE3IAAAA"
    private var repeatedText: Data { Data(String(repeating: "PlayStation cloud catalogue ", count: 80).utf8) }
    private var catalogueText: Data { Data((0..<600).map { "{\"id\":\($0),\"title\":\"Game \($0 % 97)\"}" }.joined(separator: ",").utf8) }

    func testEveryKindOfBlockIsUnpacked() {
        XCTAssertEqual(Gzip.unpack(packed(hello)), Data("Hello, Con!".utf8))
        XCTAssertEqual(Gzip.unpack(packed(repeated)), repeatedText, "Dynamic Huffman codes and back-references")
        XCTAssertEqual(Gzip.unpack(packed(fixed)), repeatedText.prefix(200), "Fixed Huffman codes")
        XCTAssertEqual(Gzip.unpack(packed(stored)), Data((0..<300).map { UInt8($0 % 256) }), "Stored blocks")
        XCTAssertEqual(Gzip.unpack(packed(named)), Data("Hello, Con!".utf8), "A file name in the header is skipped")
        XCTAssertEqual(Gzip.unpack(packed(empty)), Data())
        XCTAssertEqual(Gzip.unpack(packed(catalogue)), catalogueText)
    }

    func testWhatIsNotASoundGzipBodyIsRefused() {
        let valid = packed(catalogue)
        XCTAssertNil(Gzip.unpack(Data("{\"plain\":true}".utf8)), "Plain text is not gzip")
        XCTAssertFalse(Gzip.isGzip(Data("<html>".utf8)))
        XCTAssertNil(Gzip.unpack(valid.prefix(valid.count / 2)), "Cut short")
        XCTAssertNil(Gzip.unpack(valid.dropLast(1)), "Without its last byte")
        var broken = valid; broken[broken.count - 6] ^= 0x01
        XCTAssertNil(Gzip.unpack(broken), "The checksum does not match")
        var damaged = valid; damaged[40] ^= 0xFF
        XCTAssertNotEqual(Gzip.unpack(damaged), catalogueText, "Corrupted data never decodes to the original")
        XCTAssertNil(Gzip.unpack(valid, limit: 1000), "Output larger than the limit")
        let inside = Data([0xAA, 0xBB]) + packed(hello)
        XCTAssertEqual(Gzip.unpack(inside.dropFirst(2)), Data("Hello, Con!".utf8))
    }

    func testAnAnswerIsUnpackedOnlyWhenTheSystemLeftItPacked() throws {
        let url = URL(string: "https://example.com/")!
        func response(_ headers: [String: String]) -> HTTPURLResponse { HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)! }
        let page = packed(catalogue)
        XCTAssertEqual(HTTPBody.plain(page, response(["Content-Encoding": "gzip"])), catalogueText, "Left compressed by the system: decompressed here")
        XCTAssertEqual(HTTPBody.plain(page, response(["content-encoding": "GZIP"])), catalogueText)
        XCTAssertEqual(HTTPBody.plain(catalogueText, response(["Content-Encoding": "gzip"])), catalogueText, "Already decompressed by the system: passed through")
        XCTAssertEqual(HTTPBody.plain(page, response([:])), page, "No Content-Encoding: the gzip file itself was requested")
        XCTAssertEqual(HTTPBody.plain(Data(), response(["Content-Encoding": "gzip"])), Data())
    }

    #if canImport(zlib)
    func testWhatZlibPacksIsUnpackedToTheSame() throws {
        var generator = SystemRandomNumberGenerator()
        var bodies: [Data] = [Data(), Data([0]), catalogueText, repeatedText]
        bodies.append(Data((0..<70_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
        bodies.append(Data((0..<120_000).map { UInt8(truncatingIfNeeded: ($0 / 7) ^ ($0 % 251)) }))
        bodies.append(Data((0..<40_000).map { _ in UInt8.random(in: 97...101, using: &generator) }))
        bodies.append(Data(String(repeating: "a", count: 100_000).utf8))
        for (index, body) in bodies.enumerated() {
            for level in [Int32(0), 1, 6, 9] {
                let packed = try XCTUnwrap(Self.gzip(body, level: level), "body \(index), level \(level)")
                XCTAssertEqual(Gzip.unpack(packed), body, "body \(index) of \(body.count) bytes, level \(level)")
            }
            XCTAssertEqual(Gzip.checksum([UInt8](body)), UInt32(truncatingIfNeeded: body.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) }))
        }
    }

    private static func gzip(_ data: Data, level: Int32) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(data.count))) + 64)
        var input = [UInt8](data)
        let result: Int32 = input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                stream.next_in = source.baseAddress; stream.avail_in = UInt32(source.count)
                stream.next_out = target.baseAddress; stream.avail_out = UInt32(target.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { return nil }
        return Data(output.prefix(Int(stream.total_out)))
    }
    #endif
}
