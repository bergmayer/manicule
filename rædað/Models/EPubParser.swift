import Foundation

/// Parses ePub archives into an EPubBook model.
/// Handles container.xml, OPF (manifest/spine/metadata), NCX, and nav XHTML table of contents.
enum EPubParser: Sendable {

    nonisolated static func parse(data: Data) throws -> EPubBook {
        // 1. Extract ZIP archive
        let extractionDir = try ZipExtractor.extract(data: data)

        // 2. Parse META-INF/container.xml to find the OPF file path
        let containerURL = extractionDir
            .appendingPathComponent("META-INF")
            .appendingPathComponent("container.xml")
        guard let containerData = try? Data(contentsOf: containerURL) else {
            throw DocumentError.parsingFailed("Missing META-INF/container.xml")
        }
        let opfRelativePath = try parseContainer(data: containerData)

        // 3. Parse the OPF file
        let opfURL = extractionDir.appendingPathComponent(opfRelativePath)
        guard let opfData = try? Data(contentsOf: opfURL) else {
            throw DocumentError.parsingFailed("Cannot read OPF file at \(opfRelativePath)")
        }
        let opfDir = opfURL.deletingLastPathComponent()
        let opfResult = try parseOPF(data: opfData)

        // 4. Adjust manifest hrefs to be relative to extraction root
        let adjustedManifest = adjustManifestPaths(
            opfResult.manifest,
            opfDir: opfDir,
            extractionRoot: extractionDir
        )

        // 5. Parse Table of Contents (NCX for ePub 2, nav XHTML for ePub 3)
        let toc = parseTOC(
            manifest: adjustedManifest,
            tocID: opfResult.tocID,
            extractionDir: extractionDir
        )

        return EPubBook(
            extractionDirectory: extractionDir,
            metadata: opfResult.metadata,
            manifest: adjustedManifest,
            spine: opfResult.spine,
            tableOfContents: toc,
            coverMetaID: opfResult.coverMetaID
        )
    }

    // MARK: - Container.xml Parsing

    /// Parses container.xml to extract the OPF file path.
    nonisolated private static func parseContainer(data: Data) throws -> String {
        let delegate = ContainerParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        guard let path = delegate.opfPath else {
            throw DocumentError.parsingFailed("No rootfile found in container.xml")
        }
        return path
    }

    // MARK: - OPF Parsing

    struct OPFResult {
        let metadata: EPubBook.Metadata
        let manifest: [String: EPubBook.ManifestItem]
        let spine: [EPubBook.SpineItem]
        let tocID: String?
        let coverMetaID: String?
    }

    nonisolated private static func parseOPF(data: Data) throws -> OPFResult {
        let delegate = OPFParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        let metadata = EPubBook.Metadata(
            title: delegate.title ?? "Untitled",
            author: delegate.author,
            language: delegate.language
        )

        return OPFResult(
            metadata: metadata,
            manifest: delegate.manifest,
            spine: delegate.spine,
            tocID: delegate.tocID,
            coverMetaID: delegate.coverMetaID
        )
    }

    // MARK: - Path Resolution

    /// Converts manifest hrefs from OPF-relative to extraction-root-relative paths.
    nonisolated private static func adjustManifestPaths(
        _ manifest: [String: EPubBook.ManifestItem],
        opfDir: URL,
        extractionRoot: URL
    ) -> [String: EPubBook.ManifestItem] {
        var adjusted: [String: EPubBook.ManifestItem] = [:]
        let rootPath = extractionRoot.path

        for (id, item) in manifest {
            let absoluteURL = opfDir.appendingPathComponent(item.href).standardized
            var relativePath = absoluteURL.path
            if relativePath.hasPrefix(rootPath) {
                relativePath = String(relativePath.dropFirst(rootPath.count))
                if relativePath.hasPrefix("/") {
                    relativePath = String(relativePath.dropFirst())
                }
            }
            adjusted[id] = EPubBook.ManifestItem(
                id: item.id,
                href: relativePath,
                mediaType: item.mediaType,
                properties: item.properties
            )
        }
        return adjusted
    }

    // MARK: - TOC Parsing

    nonisolated private static func parseTOC(
        manifest: [String: EPubBook.ManifestItem],
        tocID: String?,
        extractionDir: URL
    ) -> [EPubBook.TOCEntry] {
        // Try ePub 3 nav document first (look for properties="nav")
        if let navItem = manifest.values.first(where: { $0.properties?.contains("nav") == true }) {
            let navURL = extractionDir.appendingPathComponent(navItem.href)
            if let navData = try? Data(contentsOf: navURL),
               let entries = try? parseNavXHTML(data: navData, basePath: navItem.href) {
                if !entries.isEmpty { return entries }
            }
        }

        // Fall back to NCX (ePub 2)
        if let tocID, let tocItem = manifest[tocID] {
            let tocURL = extractionDir.appendingPathComponent(tocItem.href)
            if let tocData = try? Data(contentsOf: tocURL),
               let entries = try? parseNCX(data: tocData, basePath: tocItem.href) {
                return entries
            }
        }

        // Try to find NCX by media type
        if let ncxItem = manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }) {
            let ncxURL = extractionDir.appendingPathComponent(ncxItem.href)
            if let ncxData = try? Data(contentsOf: ncxURL),
               let entries = try? parseNCX(data: ncxData, basePath: ncxItem.href) {
                return entries
            }
        }

        return []
    }

    /// Parses an NCX (ePub 2) table of contents file.
    nonisolated private static func parseNCX(data: Data, basePath: String) throws -> [EPubBook.TOCEntry] {
        let delegate = NCXParserDelegate(basePath: basePath)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    /// Parses a nav XHTML (ePub 3) table of contents file.
    nonisolated private static func parseNavXHTML(data: Data, basePath: String) throws -> [EPubBook.TOCEntry] {
        // Nav XHTML is HTML with <nav epub:type="toc"> containing <ol>/<li>/<a> elements.
        // XMLParser can handle well-formed XHTML.
        let delegate = NavXHTMLParserDelegate(basePath: basePath)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }
}

// MARK: - XML Parser Delegates

/// Parses container.xml to find the OPF path.
private final class ContainerParserDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    nonisolated(unsafe) var opfPath: String?

    nonisolated override init() { super.init() }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "rootfile" || elementName.hasSuffix(":rootfile") {
            opfPath = attributeDict["full-path"]
        }
    }
}

/// Parses the OPF file to extract metadata, manifest, and spine.
private final class OPFParserDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    nonisolated(unsafe) var title: String?
    nonisolated(unsafe) var author: String?
    nonisolated(unsafe) var language: String?
    nonisolated(unsafe) var manifest: [String: EPubBook.ManifestItem] = [:]
    nonisolated(unsafe) var spine: [EPubBook.SpineItem] = []
    nonisolated(unsafe) var tocID: String?
    nonisolated(unsafe) var coverMetaID: String?

    nonisolated(unsafe) private var currentElement: String = ""
    nonisolated(unsafe) private var currentText: String = ""
    nonisolated(unsafe) private var inMetadata = false

    nonisolated override init() { super.init() }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = localName
        currentText = ""

        switch localName {
        case "metadata":
            inMetadata = true

        case "item":
            if let id = attributeDict["id"],
               let href = attributeDict["href"],
               let mediaType = attributeDict["media-type"] {
                let item = EPubBook.ManifestItem(
                    id: id,
                    href: href.removingPercentEncoding ?? href,
                    mediaType: mediaType,
                    properties: attributeDict["properties"]
                )
                manifest[id] = item
            }

        case "meta":
            if inMetadata,
               attributeDict["name"] == "cover",
               let content = attributeDict["content"] {
                coverMetaID = content
            }

        case "spine":
            tocID = attributeDict["toc"]

        case "itemref":
            if let idref = attributeDict["idref"] {
                let linear = attributeDict["linear"] != "no"
                spine.append(EPubBook.SpineItem(idref: idref, linear: linear))
            }

        default:
            break
        }
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inMetadata {
            currentText += string
        }
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if inMetadata {
            switch localName {
            case "title":
                if title == nil { title = trimmed }
            case "creator":
                if author == nil { author = trimmed }
            case "language":
                if language == nil { language = trimmed }
            case "metadata":
                inMetadata = false
            default:
                break
            }
        }
    }
}

/// Parses NCX (ePub 2) table of contents.
private final class NCXParserDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    let basePath: String
    nonisolated(unsafe) var entries: [EPubBook.TOCEntry] = []

    nonisolated(unsafe) private var entryStack: [[EPubBook.TOCEntry]] = [[]]
    nonisolated(unsafe) private var currentTitle: String = ""
    nonisolated(unsafe) private var currentSrc: String = ""
    nonisolated(unsafe) private var inNavLabel = false
    nonisolated(unsafe) private var inText = false
    nonisolated(unsafe) private var navPointCounter = 0

    nonisolated init(basePath: String) {
        self.basePath = basePath
        super.init()
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "navPoint":
            currentTitle = ""
            currentSrc = ""
            entryStack.append([])

        case "navLabel":
            inNavLabel = true

        case "text":
            if inNavLabel { inText = true; currentTitle = "" }

        case "content":
            currentSrc = attributeDict["src"] ?? ""

        default:
            break
        }
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText {
            currentTitle += string
        }
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch elementName {
        case "text":
            inText = false

        case "navLabel":
            inNavLabel = false

        case "navPoint":
            navPointCounter += 1
            let children = entryStack.removeLast()
            let resolvedHref = resolveHref(currentSrc)
            let entry = EPubBook.TOCEntry(
                id: "ncx-\(navPointCounter)",
                title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                href: resolvedHref,
                children: children
            )
            if entryStack.isEmpty {
                entryStack.append([entry])
            } else {
                entryStack[entryStack.count - 1].append(entry)
            }

        case "navMap":
            entries = entryStack.last ?? []

        default:
            break
        }
    }

    nonisolated private func resolveHref(_ src: String) -> String {
        // NCX src is relative to the NCX file location
        let ncxDir = (basePath as NSString).deletingLastPathComponent
        if ncxDir.isEmpty { return src }
        return ncxDir + "/" + src
    }
}

/// Parses nav XHTML (ePub 3) table of contents.
private final class NavXHTMLParserDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    let basePath: String
    nonisolated(unsafe) var entries: [EPubBook.TOCEntry] = []

    nonisolated(unsafe) private var inTocNav = false
    nonisolated(unsafe) private var listDepth = 0
    nonisolated(unsafe) private var entryStack: [[EPubBook.TOCEntry]] = [[]]
    nonisolated(unsafe) private var currentHref: String = ""
    nonisolated(unsafe) private var currentTitle: String = ""
    nonisolated(unsafe) private var inAnchor = false
    nonisolated(unsafe) private var entryCounter = 0

    nonisolated init(basePath: String) {
        self.basePath = basePath
        super.init()
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch localName {
        case "nav":
            let epubType = attributeDict["epub:type"] ?? attributeDict["type"] ?? ""
            if epubType == "toc" {
                inTocNav = true
            }

        case "ol":
            if inTocNav {
                listDepth += 1
                entryStack.append([])
            }

        case "a":
            if inTocNav {
                inAnchor = true
                currentHref = attributeDict["href"] ?? ""
                currentTitle = ""
            }

        default:
            break
        }
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inAnchor {
            currentTitle += string
        }
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch localName {
        case "a":
            inAnchor = false

        case "li":
            guard inTocNav else { return }
            // When a <li> closes, the last entryStack level has any children from nested <ol>
            // But we need to handle the case where children were collected
            // The entry for this <li> was already formed when its <a> closed
            // Children come from any nested <ol> that was inside this <li>

        case "ol":
            guard inTocNav else { return }
            let children = entryStack.removeLast()
            listDepth -= 1

            if listDepth == 0 {
                // Top-level list closed — these are root entries
                entries = children
                inTocNav = false
            } else {
                // Nested list — attach as children to the last entry at the parent level
                if !entryStack.isEmpty, var parentList = entryStack.last, !parentList.isEmpty {
                    let lastIdx = parentList.count - 1
                    let parent = parentList[lastIdx]
                    parentList[lastIdx] = EPubBook.TOCEntry(
                        id: parent.id,
                        title: parent.title,
                        href: parent.href,
                        children: parent.children + children
                    )
                    entryStack[entryStack.count - 1] = parentList
                }
            }

        case "nav":
            inTocNav = false

        default:
            break
        }

        // When an anchor finishes, create a preliminary entry (children may be added later by nested <ol>)
        if localName == "a" && inTocNav {
            entryCounter += 1
            let resolvedHref = resolveHref(currentHref)
            let entry = EPubBook.TOCEntry(
                id: "nav-\(entryCounter)",
                title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                href: resolvedHref,
                children: []
            )
            if !entryStack.isEmpty {
                entryStack[entryStack.count - 1].append(entry)
            }
        }
    }

    nonisolated private func resolveHref(_ href: String) -> String {
        let navDir = (basePath as NSString).deletingLastPathComponent
        if navDir.isEmpty { return href }
        return navDir + "/" + href
    }
}
