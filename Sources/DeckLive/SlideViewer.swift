import SwiftUI
import PDFKit
import Foundation

/// Zoom controller shared between `SlideViewer` and the window toolbar.
/// Holds a weak reference to the live `PDFView` so the toolbar's zoom
/// buttons can drive scaling directly. Every manual zoom action turns
/// off `autoScales` first — otherwise PDFKit keeps snapping the page
/// back to fit and the user's zoom appears to do nothing.
@MainActor
final class SlideZoomController: ObservableObject {

    weak var pdfView: PDFView? {
        didSet { applyDisplayMode() }
    }

    /// When on, the editor scrolls continuously through every page
    /// (`singlePageContinuous`) instead of snapping to one page at a time.
    /// Page breaks are shown in this mode so the boundaries stay clear.
    @Published var continuousScroll: Bool = false {
        didSet { applyDisplayMode() }
    }

    private func applyDisplayMode() {
        guard let pdfView else { return }
        pdfView.displayMode = continuousScroll ? .singlePageContinuous : .singlePage
        pdfView.displaysPageBreaks = continuousScroll
    }

    /// Zoom step used by the +/- buttons. PDFKit's own `zoomIn`/`zoomOut`
    /// use a 1.414× factor; we mirror that feel with an explicit multiply
    /// so the reported scale stays predictable.
    private let step: CGFloat = 1.25

    func zoomIn() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, pdfView.scaleFactor * step)
    }

    func zoomOut() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = max(pdfView.minScaleFactor, pdfView.scaleFactor / step)
    }

    /// Restores PDFKit's auto-fit behaviour — the whole page scaled to
    /// fit the view, tracking future window resizes.
    func fitPage() {
        pdfView?.autoScales = true
    }

    /// Scales the current page so its width fills the view. Leaves
    /// `autoScales` off so the chosen zoom holds until the user changes it.
    func fitWidth() {
        guard let pdfView, let page = pdfView.currentPage else { return }
        pdfView.autoScales = false
        let pageWidth = page.bounds(for: pdfView.displayBox).width
        guard pageWidth > 0 else { return }
        // Leave a small margin so the page edges aren't clipped by the frame.
        let target = (pdfView.bounds.width - 8) / pageWidth
        pdfView.scaleFactor = max(pdfView.minScaleFactor,
                                  min(pdfView.maxScaleFactor, target))
    }

    /// Renders the page at 100 % (one PDF point per screen point).
    func actualSize() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.0
    }
}

/// Wraps PDFKit's PDFView so SwiftUI can display the current PDF slide,
/// and keeps it in sync with the deck store. Whiteboard slides aren't
/// shown here — the editing window only previews the original PDF deck;
/// whiteboards are a presenter-time addition.
struct SlideViewer: NSViewRepresentable {

    let document: PDFDocument
    /// PDF page index to display, or nil when the active slide is a
    /// whiteboard (in which case the previously visible PDF page stays
    /// up so the user still has visual context).
    let pdfPageIndex: Int?
    let onPageChanged: (Int) -> Void
    /// Optional zoom controller the toolbar drives. Wired to the live
    /// PDFView in `makeNSView` so button taps reach this exact instance.
    var zoomController: SlideZoomController?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.backgroundColor = NSColor.black
        zoomController?.pdfView = view

        NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: view,
            queue: .main
        ) { _ in
            if let page = view.currentPage {
                let index = document.index(for: page)
                if index != NSNotFound {
                    context.coordinator.onPageChanged(index)
                }
            }
        }

        if let pdfPageIndex, let page = document.page(at: pdfPageIndex) {
            view.go(to: page)
        }

        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if zoomController?.pdfView !== view {
            zoomController?.pdfView = view
        }
        if view.document !== document {
            view.document = document
        }
        if let pdfPageIndex,
           let page = document.page(at: pdfPageIndex),
           view.currentPage !== page {
            view.go(to: page)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChanged: onPageChanged)
    }

    final class Coordinator {
        let onPageChanged: (Int) -> Void

        init(onPageChanged: @escaping (Int) -> Void) {
            self.onPageChanged = onPageChanged
        }
    }
}
