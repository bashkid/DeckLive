import Foundation
import CoreGraphics

/// One slide position in the unified slide order — either a page from the
/// original PDF deck, or a whiteboard slide the presenter inserted while
/// presenting.
enum SlideRef: Equatable, Hashable {
    case pdf(pageIndex: Int)
    case whiteboard(id: Int)
}

/// A blank whiteboard slide that lives inside the deck's slide order.
///
/// Its `id` is a negative integer (so it can never collide with a PDF page
/// index) and doubles as the annotation-storage key for the strokes drawn
/// on it. `insertAfterPDFPage` defines its position in the deck (slide
/// follows that PDF page; `-1` places it before all PDF pages).
///
/// `canvasSize` remembers the screen-space size the strokes were captured
/// in, so the exporter can render the whiteboard back out at the right
/// dimensions instead of cropping it to the source PDF's smaller page
/// size.
struct WhiteboardSlide: Identifiable, Equatable, Codable {
    let id: Int
    var insertAfterPDFPage: Int
    /// Strokes drawn on this whiteboard. Persisted via the sidecar so
    /// reopening the deck restores everything the presenter drew.
    var strokes: [AnnotationStroke] = []
    /// Screen-space canvas size at the time the strokes were captured.
    /// Optional for back-compat with v3 sidecars that predate the field.
    var canvasSize: CGSize?

    init(
        id: Int,
        insertAfterPDFPage: Int,
        strokes: [AnnotationStroke] = [],
        canvasSize: CGSize? = nil
    ) {
        self.id = id
        self.insertAfterPDFPage = insertAfterPDFPage
        self.strokes = strokes
        self.canvasSize = canvasSize
    }
}
