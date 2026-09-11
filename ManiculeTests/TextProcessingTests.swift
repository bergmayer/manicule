#if os(iOS) || os(visionOS)
import XCTest
@testable import Manicule

final class TextProcessingTests: XCTestCase {

    // MARK: - stripMarkdown

    func testStripMarkdownHeadings() {
        let input = "# Title\n## Subtitle\n### H3"
        let result = ReadAloudController.stripMarkdown(input)
        XCTAssertTrue(result.contains("Title"))
        XCTAssertFalse(result.contains("# "))
        XCTAssertFalse(result.contains("## "))
    }

    func testStripMarkdownBold() {
        XCTAssertTrue(ReadAloudController.stripMarkdown("**bold**").contains("bold"))
        XCTAssertFalse(ReadAloudController.stripMarkdown("**bold**").contains("**"))
    }

    func testStripMarkdownItalic() {
        XCTAssertTrue(ReadAloudController.stripMarkdown("*italic*").contains("italic"))
        XCTAssertFalse(ReadAloudController.stripMarkdown("*italic*").contains("*italic*"))
    }

    func testStripMarkdownLinks() {
        let result = ReadAloudController.stripMarkdown("[click here](https://example.com)")
        XCTAssertTrue(result.contains("click here"))
        XCTAssertFalse(result.contains("https://"))
    }

    func testStripMarkdownImages() {
        let result = ReadAloudController.stripMarkdown("![alt text](image.png)")
        XCTAssertTrue(result.contains("alt text"))
        XCTAssertFalse(result.contains("image.png"))
    }

    func testStripMarkdownLists() {
        let input = "- item one\n* item two\n+ item three"
        let result = ReadAloudController.stripMarkdown(input)
        XCTAssertTrue(result.contains("item one"))
        XCTAssertFalse(result.hasPrefix("- "))
    }

    func testStripMarkdownNumberedLists() {
        let result = ReadAloudController.stripMarkdown("1. First\n2. Second")
        XCTAssertTrue(result.contains("First"))
        XCTAssertFalse(result.contains("1."))
    }

    func testStripMarkdownInlineCode() {
        let result = ReadAloudController.stripMarkdown("Use `func hello()`")
        XCTAssertTrue(result.contains("func hello()"))
        XCTAssertFalse(result.contains("`"))
    }

    func testStripMarkdownHorizontalRules() {
        let result = ReadAloudController.stripMarkdown("Above\n---\nBelow")
        XCTAssertTrue(result.contains("Above"))
        XCTAssertTrue(result.contains("Below"))
        XCTAssertFalse(result.contains("---"))
    }

    func testStripMarkdownBlockquotes() {
        let result = ReadAloudController.stripMarkdown("> A quoted line")
        XCTAssertTrue(result.contains("A quoted line"))
        XCTAssertFalse(result.contains("> "))
    }

    func testStripMarkdownCollapsesNewlines() {
        let input = "A\n\n\n\n\nB"
        let result = ReadAloudController.stripMarkdown(input)
        XCTAssertFalse(result.contains("\n\n\n"))
    }

    func testStripMarkdownTrims() {
        let result = ReadAloudController.stripMarkdown("  \n  hello  \n  ")
        XCTAssertEqual(result, "hello")
    }

    // MARK: - stripHTML

    func testStripHTMLRemovesTags() {
        let result = ReadAloudController.stripHTML("<p>Hello <b>world</b></p>")
        XCTAssertEqual(result, "Hello world")
    }

    func testStripHTMLDecodesEntities() {
        let result = ReadAloudController.stripHTML("&amp; &lt; &gt; &quot; &#39; &nbsp;")
        XCTAssertTrue(result.contains("&"))
        XCTAssertTrue(result.contains("<"))
        XCTAssertTrue(result.contains(">"))
        XCTAssertTrue(result.contains("\""))
        XCTAssertTrue(result.contains("'"))
    }

    func testStripHTMLCollapsesNewlines() {
        let result = ReadAloudController.stripHTML("A\n\n\n\n\nB")
        XCTAssertFalse(result.contains("\n\n\n"))
    }

    func testStripHTMLTrims() {
        let result = ReadAloudController.stripHTML("  \n  <p>hello</p>  \n  ")
        XCTAssertEqual(result, "hello")
    }
}
#endif

import XCTest
@testable import Manicule

@MainActor
final class TextPreparationTests: XCTestCase {
    func testGeneratedTextRetainsUnicodeAndUsesLeasedResources() async throws {
        let prepared = try await Task.detached {
            try TextPreparation.prepare("# Café 👋\n\nA **bold** line.", reflow: false, markdown: true, hasFile: true)
        }.value
        let html = try String(contentsOf: prepared.directory.url.appendingPathComponent("content.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("<h1 id=\"toc-0\" data-source-line=\"0\">Café 👋</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("epub-local://document/"))
        XCTAssertEqual(prepared.chunks, ["# Café 👋\n\nA **bold** line."])
    }

    func testCancelledPreparationDoesNotPublishOutput() async {
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try TextPreparation.prepare("text", reflow: false, markdown: false, hasFile: false)
        }
        do {
            _ = try await worker.value
            XCTFail("Cancelled generation must not return a workspace")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

@MainActor
final class TextSearchTests: XCTestCase {
    func testUnicodeCaseMappingUsesRangesInTheOriginalText() throws {
        let text = "İstanbul 👋 café CAFÉ Cafe\u{301}"
        let matches = try TextSearch.matches(in: text, query: "café")
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.map { (text as NSString).substring(with: $0.range) }, ["café", "CAFÉ", "Cafe\u{301}"])
        XCTAssertTrue(matches.allSatisfy { $0.fraction > 0 && $0.fraction < 1 })
    }

    func testMatchAtChunkBoundaryBelongsToCorrectChunk() throws {
        let text = String(repeating: "line\n", count: 99) + "needle\nneedle"
        XCTAssertEqual(try TextSearch.matches(in: text, query: "needle").map(\.chunk), [0, 1])
        XCTAssertTrue(try TextSearch.matches(in: text, query: "").isEmpty)
    }
}

#if os(iOS) || os(visionOS)
@MainActor
final class NarrationOwnershipTests: XCTestCase {
    func testOnlyCurrentWindowCanDismissAndPreviousCallbacksAreReleased() {
        let controller = ReadAloudController()
        let first = UUID(), second = UUID()
        var released = 0
        controller.claim(for: first)
        controller.onOwnerReleased = { released += 1 }
        controller.claim(for: second)
        XCTAssertEqual(released, 1)
        XCTAssertEqual(controller.owner, second)
        controller.dismiss(for: first)
        XCTAssertEqual(controller.owner, second)
        controller.dismiss(for: second)
        XCTAssertNil(controller.owner)
    }
}
#endif

@MainActor
final class TextAnchorTests: XCTestCase {
    func testSourceLinesSurviveReflowAndRepeatedParagraphs() throws {
        let long = String(repeating: "a long line of text ", count: 6)
        let source = "Title\n\n\(long)\n\(long)\n\nSame ending\n\n\(long)\n\(long)"
        let displayed = TextReflow.reflow(source)
        let mapping = TextPreparation.sourceLineMap(source, displayedText: displayed)
        let lines = displayed.components(separatedBy: "\n")
        let repeated = lines.indices.filter { lines[$0].hasPrefix(long.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(repeated.map { mapping[$0] }, [2, 7])
        let prepared = try TextPreparation.prepare(source, reflow: true, markdown: false, hasFile: false)
        let html = try String(contentsOf: prepared.directory.url.appendingPathComponent("content.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("data-source-line=\"7\""))
    }

    func testAnchorRoundtripAndLegacyPercentageRemainReadable() throws {
        let anchor = TextAnchor(line: 7, offset: 12, quote: "Café 👋 日本語")
        let position = ReadingPosition.textAnchor(anchor, fraction: 0.314159)
        XCTAssertEqual(try JSONDecoder().decode(ReadingPosition.self, from: JSONEncoder().encode(position)), position)
        let old = try JSONDecoder().decode(ReadingPosition.self, from: Data(#"{"textOffset":{"_0":314}}"#.utf8))
        XCTAssertEqual(old.textFraction, 0.314)
        XCTAssertNil(old.textAnchor)
        let malformed = Data(#"{"line":-2,"offset":-4,"quote":"word"}"#.utf8)
        let bounded = try JSONDecoder().decode(TextAnchor.self, from: malformed)
        XCTAssertEqual(bounded.line, 0)
        XCTAssertEqual(bounded.offset, 0)
    }
}
