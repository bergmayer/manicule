import XCTest
@testable import rædað

final class FileHasherTests: XCTestCase {

    func testHashDeterministic() {
        let data = "Hello, World!".data(using: .utf8)!
        let h1 = FileHasher.hash(data: data)
        let h2 = FileHasher.hash(data: data)
        XCTAssertEqual(h1, h2)
    }

    func testHashDifferentForDifferentData() {
        let a = FileHasher.hash(data: "AAA".data(using: .utf8)!)
        let b = FileHasher.hash(data: "BBB".data(using: .utf8)!)
        XCTAssertNotEqual(a, b)
    }

    func testHashTruncatedTo32Chars() {
        let hash = FileHasher.hash(data: "test".data(using: .utf8)!)
        XCTAssertEqual(hash.count, 32)
    }

    func testHashUsesPrefix() {
        // Two data blobs that share the first 64KB but differ after should hash the same
        var base = Data(repeating: 0xAA, count: 65_536)
        let hashA = FileHasher.hash(data: base)
        base.append(Data(repeating: 0xBB, count: 1000))
        let hashB = FileHasher.hash(data: base)
        XCTAssertEqual(hashA, hashB)
    }

    func testHashSmallData() {
        // Data smaller than 64KB prefix should still hash correctly
        let hash = FileHasher.hash(data: Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(hash.count, 32)
        XCTAssertFalse(hash.isEmpty)
    }

    func testHashHexCharacters() {
        let hash = FileHasher.hash(data: "test".data(using: .utf8)!)
        let validChars = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(hash.unicodeScalars.allSatisfy { validChars.contains($0) })
    }
}
