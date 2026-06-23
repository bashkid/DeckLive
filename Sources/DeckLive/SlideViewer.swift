import SwiftUI
import PDFKit
import Foundation

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

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.backgroundColor = NSColor.black

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
