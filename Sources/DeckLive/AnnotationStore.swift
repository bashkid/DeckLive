import SwiftUI
import AppKit

/// Drawing tools available in the presenter overlay. Pointer is the
/// default "no-drawing" mode — it lets the underlying tap-to-advance
/// gesture pass through to PresenterView, and on the whiteboard it
/// becomes the select-and-drag tool.
enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case pointer
    case selectorRect       // marquee: drag a rect, selects strokes inside it
    case selectorLasso      // freeform lasso: drag a closed path
    case pen
    case highlighter
    case text
    case line
    case arrow
    case rectangle
    case ellipse
    case eraser             // item eraser: removes whole strokes touched
    case brushEraser        // brush eraser: erases the touched pixels only
    /// Image annotation — never selectable from the palette directly; it
    /// shows up after the presenter pastes (⌘V) or inserts an image via
    /// the toolbar's Insert Image button.
    case image

    var id: String { rawValue }

    /// Tools shown in the toolbar palette, in display order. `.image` is
    /// intentionally excluded since it's only created programmatically.
    static let paletteOrder: [AnnotationTool] = [
        .pointer, .selectorRect, .selectorLasso,
        .pen, .highlighter, .text,
        .line, .arrow, .rectangle, .ellipse,
        .eraser, .brushEraser
    ]

    var systemImage: String {
        switch self {
        case .pointer:        return "hand.point.up.left.fill"
        case .selectorRect:   return "dashed.rectangle"
        case .selectorLasso:  return "lasso"
        case .pen:            return "pencil.tip"
        case .highlighter:    return "highlighter"
        case .text:           return "textformat"
        case .line:           return "line.diagonal"
        case .arrow:          return "arrow.up.right"
        case .rectangle:      return "rectangle"
        case .ellipse:        return "oval"
        case .eraser:         return "eraser.fill"
        case .brushEraser:    return "paintbrush.pointed"
        case .image:          return "photo"
        }
    }

    var label: String {
        switch self {
        case .pointer:        return "Pointer"
        case .selectorRect:   return "Marquee Select"
        case .selectorLasso:  return "Lasso Select"
        case .pen:            return "Pen"
        case .highlighter:    return "Highlighter"
        case .text:           return "Text"
        case .line:           return "Line"
        case .arrow:          return "Arrow"
        case .rectangle:      return "Rectangle"
        case .ellipse:        return "Ellipse"
        case .eraser:         return "Item Eraser"
        case .brushEraser:    return "Brush Eraser"
        case .image:          return "Image"
        }
    }

    /// Whether this is one of the selection (marquee / lasso) tools.
    var isSelector: Bool {
        self == .selectorRect || self == .selectorLasso
    }

    /// Drag-to-define geometric shapes. They share pen color/width and
    /// store only the start and end of the drag in `points`.
    var isShape: Bool {
        switch self {
        case .line, .arrow, .rectangle, .ellipse: return true
        default: return false
        }
    }

    /// Shapes that have an enclosed area and can be filled or just stroked.
    var supportsFill: Bool {
        switch self {
        case .rectangle, .ellipse: return true
        default: return false
        }
    }

    /// True for any tool that produces a committed annotation (vs. just
    /// triggering side effects like erasing or doing nothing at all).
    var producesStroke: Bool {
        switch self {
        case .pointer, .eraser, .brushEraser, .selectorRect, .selectorLasso:
            return false
        case .pen, .highlighter, .text, .line, .arrow, .rectangle, .ellipse, .image:
            return true
        }
    }
}

/// One annotation captured from the user's drag or tap.
///
/// - For `.pen` / `.highlighter`: `points` is a polyline of every sampled
///   drag location.
/// - For shape tools (`.line` / `.arrow` / `.rectangle` / `.ellipse`):
///   `points` is exactly `[start, end]` and the shape is derived from that
///   bounding pair at render time.
/// - For `.text`: `points` is `[anchor]` (top-left of the label) and the
///   stroke's `text` carries the typed content.
struct AnnotationStroke: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var points: [CGPoint]
    var color: Color
    var width: CGFloat
    var tool: AnnotationTool
    /// Per-point stylus pressure (0…1) captured from a pressure-sensitive
    /// tablet (e.g. Wacom) for `.pen` strokes. Parallel to `points` when
    /// present; nil for mouse/trackpad input, in which case the stroke is
    /// drawn at a constant `width`.
    var pressures: [CGFloat]? = nil
    /// Whether enclosed shape tools render filled or outlined.
    var isFilled: Bool = false
    /// Text content for `.text` annotations.
    var text: String? = nil
    /// Font size for `.text` annotations.
    var fontSize: CGFloat = 28
    /// PNG bytes for `.image` annotations. Serialized as base64 in the
    /// sidecar, so pasted/inserted images survive app restarts.
    var imageData: Data? = nil

    enum CodingKeys: String, CodingKey {
        case id, points, r, g, b, a, width, tool, isFilled, text, fontSize, imageData, pressures
    }

    init(
        id: UUID = UUID(),
        points: [CGPoint],
        color: Color,
        width: CGFloat,
        tool: AnnotationTool,
        pressures: [CGFloat]? = nil,
        isFilled: Bool = false,
        text: String? = nil,
        fontSize: CGFloat = 28,
        imageData: Data? = nil
    ) {
        self.id = id
        self.points = points
        self.color = color
        self.width = width
        self.tool = tool
        self.pressures = pressures
        self.isFilled = isFilled
        self.text = text
        self.fontSize = fontSize
        self.imageData = imageData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        points = try c.decode([CGPoint].self, forKey: .points)
        let r = try c.decode(Double.self, forKey: .r)
        let g = try c.decode(Double.self, forKey: .g)
        let b = try c.decode(Double.self, forKey: .b)
        let a = try c.decode(Double.self, forKey: .a)
        color = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
        width = try c.decode(CGFloat.self, forKey: .width)
        tool = try c.decode(AnnotationTool.self, forKey: .tool)
        pressures = try c.decodeIfPresent([CGFloat].self, forKey: .pressures)
        isFilled = try c.decodeIfPresent(Bool.self, forKey: .isFilled) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text)
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 28
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(points, forKey: .points)
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        try c.encode(Double(ns.redComponent), forKey: .r)
        try c.encode(Double(ns.greenComponent), forKey: .g)
        try c.encode(Double(ns.blueComponent), forKey: .b)
        try c.encode(Double(ns.alphaComponent), forKey: .a)
        try c.encode(width, forKey: .width)
        try c.encode(tool, forKey: .tool)
        try c.encodeIfPresent(pressures, forKey: .pressures)
        try c.encode(isFilled, forKey: .isFilled)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encodeIfPresent(imageData, forKey: .imageData)
    }

    var opacity: Double {
        tool == .highlighter ? 0.32 : 1.0
    }

    /// Rect used by rectangle/ellipse rendering and hit-testing — always
    /// has non-negative width/height regardless of drag direction.
    var shapeRect: CGRect {
        guard points.count >= 2 else { return .zero }
        let a = points[0], b = points[1]
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}

/// Holds all in-progress and committed annotations for the active
/// presentation. Strokes are keyed by page index so flipping back
/// and forth between slides preserves their annotations. A reserved
/// `DeckStore.whiteboardPageKey` is used while the presenter is on the
/// whiteboard. The store also owns the currently active tool, color,
/// stroke widths, and whether shapes are filled.
@MainActor
final class AnnotationStore: ObservableObject {

    // MARK: Tool selection

    @Published var tool: AnnotationTool = .pointer {
        didSet {
            // Selection state is only meaningful in pointer / selector
            // modes — swapping to a drawing tool drops it so the user
            // isn't confused by stale handles.
            switch tool {
            case .pointer, .selectorRect, .selectorLasso:
                break
            default:
                selectedStrokeIDs.removeAll()
            }
        }
    }

    /// Whether the floating presenter toolbar is on screen. Toggled by the
    /// ⌘T shortcut so the presenter can draw against a clean slide.
    @Published var isToolbarVisible: Bool = true

    // MARK: Selection (pointer + rect/lasso selectors)

    /// Identifiers of strokes currently selected. The blue selection
    /// rectangle + 8 resize handles wrap the combined bounding rect of
    /// every member, so moving/resizing acts on the whole group.
    @Published var selectedStrokeIDs: Set<UUID> = []

    /// Convenience for code paths that only care whether *anything* is
    /// selected (avoids allocating a Set check).
    var hasSelection: Bool { !selectedStrokeIDs.isEmpty }

    // MARK: Pen settings (shared with line/arrow/rectangle/ellipse/text)

    static let penColors: [Color] = [.red, .yellow, .green, .blue, .black, .white]
    @Published var penColorIndex: Int = 0
    @Published var penWidth: CGFloat = 4

    /// Latest stylus pressure (0…1) reported by a pressure-sensitive
    /// tablet, refreshed by the presenter window's event monitor as the
    /// pen moves. Defaults to 1.0 so mouse/trackpad drawing keeps a
    /// constant width. Read by `AnnotationCanvas` when sampling pen points.
    var currentPressure: CGFloat = 1.0

    var penColor: Color { Self.penColors[penColorIndex] }

    // MARK: Highlighter settings

    static let highlighterColors: [Color] = [.yellow, .green, .pink, .cyan, .orange]
    @Published var highlighterColorIndex: Int = 0
    @Published var highlighterWidth: CGFloat = 22

    var highlighterColor: Color { Self.highlighterColors[highlighterColorIndex] }

    // MARK: Shape fill mode

    /// When true, rectangle/ellipse shapes are committed as filled. The
    /// other shape tools (line, arrow) ignore this flag.
    @Published var fillShapes: Bool = false

    // MARK: Text tool

    @Published var textFontSize: CGFloat = 28

    // MARK: Eraser

    let eraserRadius: CGFloat = 22

    // MARK: Strokes

    @Published private var strokesByPage: [Int: [AnnotationStroke]] = [:]

    /// Strokes removed by Undo, kept per page so Redo (⇧⌘Z) can restore
    /// them. Cleared for a page whenever a new stroke is committed there.
    private var redoByPage: [Int: [AnnotationStroke]] = [:]

    func strokes(for page: Int) -> [AnnotationStroke] {
        strokesByPage[page] ?? []
    }

    func append(stroke: AnnotationStroke, page: Int) {
        strokesByPage[page, default: []].append(stroke)
        // Committing a fresh stroke invalidates the redo history.
        redoByPage[page] = nil
    }

    /// Replaces all strokes for a page with the given list. Used when
    /// restoring whiteboard contents from the sidecar so the user can
    /// pick up where they left off across app launches.
    func setStrokes(_ strokes: [AnnotationStroke], for page: Int) {
        strokesByPage[page] = strokes.isEmpty ? nil : strokes
    }

    /// Erases any stored stroke whose outline comes within `eraserRadius`
    /// of `point`. For pen/highlighter we check the raw polyline; for
    /// shapes we sample N points along the shape's outline so a click on
    /// the middle of a long line still erases it. Text strokes use a
    /// rough bounding-box hit test. Returns true if anything was removed.
    @discardableResult
    func erase(at point: CGPoint, page: Int) -> Bool {
        guard let strokes = strokesByPage[page] else { return false }
        let kept = strokes.filter { stroke in
            !Self.testPoints(for: stroke).contains { p in
                hypot(p.x - point.x, p.y - point.y) <= eraserRadius + stroke.width / 2
            }
        }
        if kept.count != strokes.count {
            strokesByPage[page] = kept
            return true
        }
        return false
    }

    /// Hit-tests strokes on `page` from top to bottom and returns the
    /// identifier of the first one within drag-pickup range of `point`.
    /// Used by both the whiteboard and the regular slide drag-to-move
    /// flows. Text and image strokes are picked up by their entire
    /// bounding box (rather than just their anchor point) so they're
    /// easy to grab.
    func hitTestStroke(at point: CGPoint, page: Int) -> UUID? {
        guard let strokes = strokesByPage[page] else { return nil }
        let pickupRadius: CGFloat = 18
        for stroke in strokes.reversed() {
            // Filled shapes: hit-test as a region.
            if stroke.isFilled, stroke.tool.supportsFill {
                if stroke.tool == .rectangle, stroke.shapeRect.contains(point) {
                    return stroke.id
                }
                if stroke.tool == .ellipse, ellipseContains(rect: stroke.shapeRect, point: point) {
                    return stroke.id
                }
                continue
            }
            // Text: bounding box around the anchor (approximated from
            // font size + character count), padded for easy pickup.
            if stroke.tool == .text {
                let bbox = Self.approximateTextRect(for: stroke).insetBy(dx: -10, dy: -8)
                if bbox.contains(point) { return stroke.id }
                continue
            }
            // Image: full picture rect.
            if stroke.tool == .image {
                if stroke.shapeRect.insetBy(dx: -4, dy: -4).contains(point) {
                    return stroke.id
                }
                continue
            }
            for p in Self.testPoints(for: stroke) {
                if hypot(p.x - point.x, p.y - point.y) <= pickupRadius + stroke.width / 2 {
                    return stroke.id
                }
            }
        }
        return nil
    }

    /// Rough bounding box for a text annotation, derived from the anchor,
    /// the font size, and the character count. Good enough for hit testing
    /// and eraser sampling.
    static func approximateTextRect(for stroke: AnnotationStroke) -> CGRect {
        guard stroke.tool == .text, let anchor = stroke.points.first else { return .zero }
        let text = stroke.text ?? ""
        let charWidth = stroke.fontSize * 0.55
        let textWidth = max(stroke.fontSize, CGFloat(text.count) * charWidth)
        let textHeight = stroke.fontSize * 1.25
        return CGRect(x: anchor.x, y: anchor.y, width: textWidth, height: textHeight)
    }

    /// Shifts every point of the named stroke by the given delta. Used by
    /// the whiteboard's drag-to-move flow.
    func translateStroke(id: UUID, by delta: CGSize, page: Int) {
        guard var strokes = strokesByPage[page],
              let idx = strokes.firstIndex(where: { $0.id == id }) else { return }
        strokes[idx].points = strokes[idx].points.map {
            CGPoint(x: $0.x + delta.width, y: $0.y + delta.height)
        }
        strokesByPage[page] = strokes
    }

    /// Bounding rectangle of a stroke in the page's coordinate space —
    /// used to draw the selection rect + 8 resize handles when the user
    /// taps the stroke with the pointer tool.
    func boundingRect(forStrokeID id: UUID, page: Int) -> CGRect? {
        guard let strokes = strokesByPage[page],
              let stroke = strokes.first(where: { $0.id == id }) else { return nil }
        return Self.boundingRect(for: stroke)
    }

    /// Combined bounding rect for a set of selected strokes. Returns nil
    /// when nothing is selected or none of the IDs match.
    func boundingRect(forIDs ids: Set<UUID>, page: Int) -> CGRect? {
        guard !ids.isEmpty, let strokes = strokesByPage[page] else { return nil }
        var combined: CGRect?
        for stroke in strokes where ids.contains(stroke.id) {
            guard let r = Self.boundingRect(for: stroke) else { continue }
            combined = combined.map { $0.union(r) } ?? r
        }
        return combined
    }

    /// Selects every stroke whose bounding rect intersects `rect`. Used
    /// by the rectangular selector tool.
    func selectStrokes(inRect rect: CGRect, page: Int) {
        guard let strokes = strokesByPage[page] else {
            selectedStrokeIDs.removeAll()
            return
        }
        let picked: [UUID] = strokes.compactMap { stroke in
            guard let r = Self.boundingRect(for: stroke), r.intersects(rect) else { return nil }
            return stroke.id
        }
        selectedStrokeIDs = Set(picked)
    }

    /// Selects every stroke whose bounding-rect center sits inside the
    /// closed polygon `points`. Used by the lasso selector tool.
    func selectStrokes(inLasso points: [CGPoint], page: Int) {
        guard points.count >= 3, let strokes = strokesByPage[page] else {
            selectedStrokeIDs.removeAll()
            return
        }
        let picked: [UUID] = strokes.compactMap { stroke in
            guard let r = Self.boundingRect(for: stroke) else { return nil }
            let center = CGPoint(x: r.midX, y: r.midY)
            return Self.polygonContains(points, point: center) ? stroke.id : nil
        }
        selectedStrokeIDs = Set(picked)
    }

    /// Translates every selected stroke by the given delta.
    func translateSelection(by delta: CGSize, page: Int) {
        for id in selectedStrokeIDs {
            translateStroke(id: id, by: delta, page: page)
        }
    }

    /// Resizes every selected stroke so its combined bounding rect maps
    /// from `oldCombined` into `newCombined`, scaling each member's
    /// position + size proportionally inside the group.
    func resizeSelection(from oldCombined: CGRect, to newCombined: CGRect, page: Int) {
        guard oldCombined.width > 0, oldCombined.height > 0 else { return }
        let scaleX = newCombined.width / oldCombined.width
        let scaleY = newCombined.height / oldCombined.height
        guard var strokes = strokesByPage[page] else { return }

        for idx in strokes.indices where selectedStrokeIDs.contains(strokes[idx].id) {
            guard let r = Self.boundingRect(for: strokes[idx]),
                  r.width > 0, r.height > 0 else { continue }
            // Map this member's bounding rect through the combined
            // before/after rects.
            let newX = newCombined.minX + (r.minX - oldCombined.minX) * scaleX
            let newY = newCombined.minY + (r.minY - oldCombined.minY) * scaleY
            let newW = r.width * scaleX
            let newH = r.height * scaleY
            let target = CGRect(x: newX, y: newY, width: max(8, newW), height: max(8, newH))
            // Reuse the per-stroke resize for the actual point math.
            applyResize(strokeAt: idx, in: &strokes, toBounds: target)
        }
        strokesByPage[page] = strokes
    }

    private func applyResize(strokeAt idx: Int, in strokes: inout [AnnotationStroke], toBounds newBounds: CGRect) {
        let stroke = strokes[idx]
        guard let oldBounds = Self.boundingRect(for: stroke),
              oldBounds.width > 0, oldBounds.height > 0 else { return }
        let scaleX = newBounds.width / oldBounds.width
        let scaleY = newBounds.height / oldBounds.height
        var updated = stroke
        updated.points = stroke.points.map { p in
            CGPoint(
                x: newBounds.minX + (p.x - oldBounds.minX) * scaleX,
                y: newBounds.minY + (p.y - oldBounds.minY) * scaleY
            )
        }
        if stroke.tool == .text {
            updated.fontSize = max(8, stroke.fontSize * min(scaleX, scaleY))
        }
        strokes[idx] = updated
    }

    /// Brush eraser — walks every pen/highlighter stroke on the page,
    /// drops any point within `radius` of `point`, and splits the stroke
    /// at the gaps so a single eraser pass through the middle of a line
    /// leaves two separate strokes. Shape/text/image strokes are *not*
    /// affected (use the item eraser for those).
    @discardableResult
    func brushErase(at point: CGPoint, radius: CGFloat, page: Int) -> Bool {
        guard var strokes = strokesByPage[page] else { return false }
        var changed = false

        var rebuilt: [AnnotationStroke] = []
        rebuilt.reserveCapacity(strokes.count)

        for stroke in strokes {
            guard stroke.tool == .pen || stroke.tool == .highlighter else {
                rebuilt.append(stroke)
                continue
            }
            // Group consecutive surviving points into runs separated by
            // erased gaps. Each run >= 2 points becomes its own stroke.
            var runs: [[CGPoint]] = [[]]
            for p in stroke.points {
                if hypot(p.x - point.x, p.y - point.y) <= radius {
                    if !runs[runs.count - 1].isEmpty { runs.append([]) }
                    changed = true
                } else {
                    runs[runs.count - 1].append(p)
                }
            }
            let validRuns = runs.filter { $0.count >= 2 }
            if validRuns.count == runs.count, !changed {
                // Stroke unchanged.
                rebuilt.append(stroke)
            } else {
                for run in validRuns {
                    var split = stroke
                    split.id = UUID()
                    split.points = run
                    rebuilt.append(split)
                }
            }
        }

        if changed {
            strokes = rebuilt
            strokesByPage[page] = rebuilt
        }
        return changed
    }

    /// Point-in-polygon (ray casting) test used by the lasso selector.
    private static func polygonContains(_ polygon: [CGPoint], point p: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i], pj = polygon[j]
            if (pi.y > p.y) != (pj.y > p.y),
               p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y + 0.000001) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Resizes a stroke so its content occupies `newBounds` instead of
    /// its current bounding rect. Every point is remapped proportionally
    /// (so a freehand scribble stays recognizable). Text strokes also
    /// have their `fontSize` scaled by the smaller of the two axes so
    /// the glyphs grow/shrink alongside the box.
    func resizeStroke(id: UUID, toBounds newBounds: CGRect, page: Int) {
        guard newBounds.width >= 8, newBounds.height >= 8 else { return }
        guard var strokes = strokesByPage[page],
              let idx = strokes.firstIndex(where: { $0.id == id }) else { return }

        let stroke = strokes[idx]
        guard let oldBounds = Self.boundingRect(for: stroke),
              oldBounds.width > 0, oldBounds.height > 0 else { return }

        let scaleX = newBounds.width / oldBounds.width
        let scaleY = newBounds.height / oldBounds.height

        var updated = stroke
        updated.points = stroke.points.map { p in
            CGPoint(
                x: newBounds.minX + (p.x - oldBounds.minX) * scaleX,
                y: newBounds.minY + (p.y - oldBounds.minY) * scaleY
            )
        }
        if stroke.tool == .text {
            updated.fontSize = max(8, stroke.fontSize * min(scaleX, scaleY))
        }

        strokes[idx] = updated
        strokesByPage[page] = strokes
    }

    /// Shared bounding-rect calculation used by hit-testing, selection
    /// rendering, and resize math. Returns nil for non-renderable tools
    /// (pointer, eraser).
    static func boundingRect(for stroke: AnnotationStroke) -> CGRect? {
        switch stroke.tool {
        case .pointer, .eraser, .brushEraser, .selectorRect, .selectorLasso:
            return nil
        case .text:
            return approximateTextRect(for: stroke)
        case .rectangle, .ellipse, .image:
            return stroke.shapeRect
        case .line, .arrow:
            guard stroke.points.count >= 2 else { return nil }
            let a = stroke.points[0], b = stroke.points[1]
            return CGRect(
                x: min(a.x, b.x), y: min(a.y, b.y),
                width: abs(b.x - a.x), height: abs(b.y - a.y)
            )
        case .pen, .highlighter:
            guard !stroke.points.isEmpty else { return nil }
            let xs = stroke.points.map(\.x)
            let ys = stroke.points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    private func ellipseContains(rect: CGRect, point: CGPoint) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let dx = (point.x - rect.midX) / (rect.width / 2)
        let dy = (point.y - rect.midY) / (rect.height / 2)
        return dx * dx + dy * dy <= 1
    }

    // MARK: Eraser sampling

    private static func testPoints(for stroke: AnnotationStroke) -> [CGPoint] {
        switch stroke.tool {
        case .pen, .highlighter:
            return stroke.points
        case .text:
            // Sample across the rough text bounding box so the eraser
            // catches the body of the text, not just its anchor.
            return rectanglePerimeterSamples(
                approximateTextRect(for: stroke),
                count: 24
            )
        case .image:
            return rectanglePerimeterSamples(stroke.shapeRect, count: 48)
        case .line, .arrow:
            guard stroke.points.count >= 2 else { return stroke.points }
            return lineSamples(from: stroke.points[0], to: stroke.points[1], count: 32)
        case .rectangle:
            return rectanglePerimeterSamples(stroke.shapeRect, count: 64)
        case .ellipse:
            return ellipsePerimeterSamples(stroke.shapeRect, count: 64)
        case .eraser, .brushEraser, .pointer, .selectorRect, .selectorLasso:
            return []
        }
    }

    private static func lineSamples(from a: CGPoint, to b: CGPoint, count: Int) -> [CGPoint] {
        guard count > 1 else { return [a, b] }
        return (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    private static func rectanglePerimeterSamples(_ rect: CGRect, count: Int) -> [CGPoint] {
        guard count >= 4, rect.width > 0 || rect.height > 0 else {
            return [rect.origin]
        }
        let perSide = max(1, count / 4)
        let tl = CGPoint(x: rect.minX, y: rect.minY)
        let tr = CGPoint(x: rect.maxX, y: rect.minY)
        let br = CGPoint(x: rect.maxX, y: rect.maxY)
        let bl = CGPoint(x: rect.minX, y: rect.maxY)
        return lineSamples(from: tl, to: tr, count: perSide)
            + lineSamples(from: tr, to: br, count: perSide)
            + lineSamples(from: br, to: bl, count: perSide)
            + lineSamples(from: bl, to: tl, count: perSide)
    }

    private static func ellipsePerimeterSamples(_ rect: CGRect, count: Int) -> [CGPoint] {
        guard count > 0, rect.width > 0 || rect.height > 0 else {
            return [CGPoint(x: rect.midX, y: rect.midY)]
        }
        let rx = rect.width / 2
        let ry = rect.height / 2
        let cx = rect.midX
        let cy = rect.midY
        return (0..<count).map { i in
            let theta = (CGFloat(i) / CGFloat(count)) * 2 * .pi
            return CGPoint(x: cx + rx * cos(theta), y: cy + ry * sin(theta))
        }
    }

    func undo(page: Int) {
        guard var strokes = strokesByPage[page], !strokes.isEmpty else { return }
        let removed = strokes.removeLast()
        strokesByPage[page] = strokes.isEmpty ? nil : strokes
        redoByPage[page, default: []].append(removed)
    }

    /// Restores the most recently undone stroke on the page, if any.
    func redo(page: Int) {
        guard var stack = redoByPage[page], !stack.isEmpty else { return }
        let stroke = stack.removeLast()
        redoByPage[page] = stack.isEmpty ? nil : stack
        // Insert directly (not via `append`) so the redo history survives.
        strokesByPage[page, default: []].append(stroke)
    }

    func clear(page: Int) {
        strokesByPage[page] = nil
        redoByPage[page] = nil
    }

    func clearAll() {
        strokesByPage.removeAll()
        redoByPage.removeAll()
    }

    // MARK: - Keyboard-shortcut helpers

    /// Tool order used by the Tab "cycle tool" shortcut.
    private static let cycleOrder: [AnnotationTool] = [
        .pen, .highlighter, .line, .arrow, .rectangle, .ellipse, .text, .pointer
    ]

    /// Advances to the next drawing tool (wraps around). Bound to Tab.
    func cycleTool() {
        let order = Self.cycleOrder
        let idx = order.firstIndex(of: tool) ?? -1
        tool = order[(idx + 1) % order.count]
    }

    /// Toggles between two related tools, selecting `a` first if neither is
    /// currently active. Used by the paired tool shortcuts (⌘2 line/arrow,
    /// ⌘3 rectangle/ellipse).
    func toggleTool(_ a: AnnotationTool, _ b: AnnotationTool) {
        tool = (tool == a) ? b : a
    }

    func enlargeThickness() { adjustThickness(by: +1) }
    func reduceThickness() { adjustThickness(by: -1) }

    /// Nudges the active tool's size within its allowed range. Highlighter
    /// width and text size move in larger steps to match their wider ranges.
    private func adjustThickness(by step: CGFloat) {
        switch tool {
        case .highlighter:
            highlighterWidth = min(44, max(8, highlighterWidth + step * 2))
        case .text:
            textFontSize = min(72, max(14, textFontSize + step * 2))
        default:
            penWidth = min(14, max(1, penWidth + step))
        }
    }

    /// Cycles to the next color swatch for the active tool. Bound to ⌘E.
    func cycleColor() {
        switch tool {
        case .highlighter:
            highlighterColorIndex = (highlighterColorIndex + 1) % Self.highlighterColors.count
        default:
            penColorIndex = (penColorIndex + 1) % Self.penColors.count
        }
    }

    /// Selects every stroke on the page and switches to the pointer tool so
    /// the selection is immediately movable/resizable. Bound to ⌘A.
    func selectAll(page: Int) {
        let ids = strokes(for: page).map(\.id)
        selectedStrokeIDs = Set(ids)
        if !ids.isEmpty { tool = .pointer }
    }

    // MARK: - Image insertion

    /// Drops a new image annotation onto the given page, sized to fit
    /// roughly half the canvas (preserving the image's aspect ratio) and
    /// centered.
    @discardableResult
    func insertImage(_ image: NSImage, on page: Int, canvasSize: CGSize) -> AnnotationStroke? {
        guard let data = image.pngData() else { return nil }

        let imageAspect = (image.size.height > 0)
            ? image.size.width / image.size.height
            : 16.0 / 9.0
        let maxWidth = min(canvasSize.width * 0.55, 800)
        let maxHeight = min(canvasSize.height * 0.6, 600)
        let width: CGFloat
        let height: CGFloat
        if maxWidth / imageAspect <= maxHeight {
            width = maxWidth
            height = maxWidth / imageAspect
        } else {
            height = maxHeight
            width = maxHeight * imageAspect
        }
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let topLeft = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
        let bottomRight = CGPoint(x: center.x + width / 2, y: center.y + height / 2)

        let stroke = AnnotationStroke(
            points: [topLeft, bottomRight],
            color: .clear,
            width: 0,
            tool: .image,
            imageData: data
        )
        append(stroke: stroke, page: page)
        return stroke
    }
}

private extension NSImage {
    /// Lossy roundtrip via TIFF → NSBitmapImageRep → PNG. Fine for the
    /// in-app annotation use case; preserves transparency.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
