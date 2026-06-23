import SwiftUI
import AppKit

/// Shared zoom + pan state for the active whiteboard slide. Owned by the
/// presenter window controller, observed by `AnnotationCanvas` (for
/// rendering + gesture coordinate conversion) and the toolbar's zoom
/// badge so an NSEvent scroll-wheel monitor and a SwiftUI pinch gesture
/// can both mutate the same viewport without fighting each other.
@MainActor
final class WhiteboardViewport: ObservableObject {

    /// Current zoom factor — 1.0 means 100 %. Clamped to a sensible range
    /// so the user can't get lost at 0.0001×.
    @Published var zoom: CGFloat = 1.0

    /// Pan offset applied *after* the zoom transform. Represented in
    /// screen-space points so the scroll handler can add raw delta values
    /// without thinking about world coordinates.
    @Published var pan: CGSize = .zero

    /// Saved zoom value used by `MagnificationGesture` so pinch deltas
    /// layer on top of the current zoom instead of compounding.
    var pinchBaseline: CGFloat = 1.0

    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 10.0

    func zoomIn() { setZoom(zoom + 0.2) }
    func zoomOut() { setZoom(zoom - 0.2) }

    func setZoom(_ newValue: CGFloat) {
        zoom = max(Self.minZoom, min(Self.maxZoom, newValue))
        pinchBaseline = zoom
    }

    /// Pinch-driven zoom — the caller's `scale` value is multiplied by
    /// `pinchBaseline` so successive `.onChanged` callbacks don't stack
    /// on each other. Call `commitPinch()` from `.onEnded`.
    func applyPinch(scale: CGFloat) {
        zoom = max(Self.minZoom, min(Self.maxZoom, pinchBaseline * scale))
    }

    func commitPinch() {
        pinchBaseline = zoom
    }

    /// Scroll-wheel delta translates straight into pan offset. Adds the
    /// raw delta without normalising because trackpad swipes already
    /// arrive in screen points.
    func pan(by delta: CGSize) {
        pan = CGSize(width: pan.width + delta.width,
                     height: pan.height + delta.height)
    }

    func reset() {
        zoom = 1.0
        pinchBaseline = 1.0
        pan = .zero
    }
}
