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
