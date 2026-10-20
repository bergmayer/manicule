import SwiftUI
import PDFKit

#if os(iOS) || os(visionOS)
/// Each facing-page spread is one native scrolling page, so the outgoing and
/// incoming spreads follow the finger and cancelled turns return to their origin.
struct PaginatedPDFContainerView: View {
    let document: PDFDocument
    @Binding var currentPage: Int
    var coverOnRight: Bool = false
    var scaleFactor: Double?
    var highlightSelection: PDFSelection?
    let onToggleChrome: () -> Void
    let onNextPage: () -> Void
    let onPreviousPage: () -> Void

    var body: some View {
        PaginatedContainer<PDFSpreadViewController>(
            pageCount: PageNavigation.spreadCount(pageCount: document.pageCount, coverOnRight: coverOnRight),
            currentPage: Binding(
                get: { PageNavigation.spreadIndex(page: currentPage, coverOnRight: coverOnRight) },
                set: { currentPage = PageNavigation.spreadStart(index: $0, coverOnRight: coverOnRight) }),
            pageStep: 1,
            backgroundColor: .systemBackground,
            interPageSpacing: 0,
            supportsTrackpadPan: false,
            layoutKey: AnyHashable([AnyHashable(ObjectIdentifier(document)), AnyHashable(coverOnRight)]),
            onToggleChrome: onToggleChrome,
            handlesTapZones: false,
            updateViewController: { controller in
                controller.update(configuration(for: controller.pageIndex))
            }
        ) { index in
            let start = PageNavigation.spreadStart(index: index, coverOnRight: coverOnRight)
            guard (0..<document.pageCount).contains(start) else { return nil }
            return PDFSpreadViewController(pageIndex: index, configuration: configuration(for: index))
        }
        // Rebuild the native pager so prefetched neighbors use the new pairing too.
        .id(coverOnRight)
    }

    private func configuration(for ordinal: Int) -> PDFViewRepresentable {
        let index = PageNavigation.spreadStart(index: ordinal, coverOnRight: coverOnRight)
        let end = coverOnRight && index == 0 ? 1 : min(index + 2, document.pageCount)
        let selection = highlightSelection.flatMap { selection in
            selection.pages.contains { page in
                (index..<end).contains(document.index(for: page))
            } ? selection : nil
        }
        return PDFViewRepresentable(
            pdfDocument: document,
            currentPageIndex: .constant(index),
            paginated: true,
            twoUp: true,
            coverOnRight: coverOnRight,
            scaleFactor: scaleFactor,
            highlightSelection: selection,
            onToggleChrome: onToggleChrome,
            onNextPage: onNextPage,
            onPreviousPage: onPreviousPage
        )
    }
}

/// PDFKit keeps vector rendering, selection, and zoom within each spread. The
/// outer UIPageViewController handles transitions, without bitmap snapshots.
final class PDFSpreadViewController: UIViewController, PaginatedPageVC {
    let pageIndex: Int
    private var configuration: PDFViewRepresentable
    private(set) var pdfView: TouchReaderPDFView?
    private lazy var coordinator = configuration.makeCoordinator()

    init(pageIndex: Int, configuration: PDFViewRepresentable) {
        self.pageIndex = pageIndex
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let pdfView = configuration.makePDFView(coordinator: coordinator)
        self.pdfView = pdfView
        let page = configuration.currentPageIndex
        let isCover = configuration.coverOnRight && page == 0
        let isSinglePage = isCover || page + 1 >= configuration.pdfDocument.pageCount
        guard isSinglePage else { view = pdfView; return }

        // PDFKit centers a solitary cover. Give it one half of the spread so
        // the blank half remains visible and the page keeps its intended side.
        let spread = UIView()
        spread.backgroundColor = pdfView.backgroundColor
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        spread.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: spread.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: spread.bottomAnchor),
            pdfView.widthAnchor.constraint(equalTo: spread.widthAnchor, multiplier: 0.5),
            isCover ? pdfView.trailingAnchor.constraint(equalTo: spread.trailingAnchor)
                : pdfView.leadingAnchor.constraint(equalTo: spread.leadingAnchor),
        ])
        view = spread
    }

    func update(_ configuration: PDFViewRepresentable) {
        self.configuration = configuration
        guard let pdfView else { return }
        configuration.updatePDFView(pdfView, coordinator: coordinator)
    }
}
#endif
