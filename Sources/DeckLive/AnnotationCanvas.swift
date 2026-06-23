import SwiftUI

/// Transparent drawing surface laid over the slide image in the presenter
/// window. Uses SwiftUI's Canvas for rendering and a single DragGesture
/// (minimumDistance: 0, so taps register too) for input.
///
/// - Pen/highlighter capture every sampled drag point.
/// - Shape tools (`.line` / `.arrow` / `.rectangle` / `.ellipse`) keep
///   `[start, end]` and update the endpoint as the drag continues, so
///   the live preview shows the shape growing under the cursor.
/// - The text tool spawns an inline `TextField` at the tap location.
/// - On the whiteboard, the pointer tool becomes drag-to-move: a drag on
///   an existing annotation translates that annotation under the cursor.
struct AnnotationCanvas: View {

    @ObservedObject var store: AnnotationStore
    /// Shared whiteboard zoom + pan viewport. Owned by the window
    /// controller so an NSEvent scroll-wheel monitor and the pinch
    /// gesture inside the canvas both mutate the same source of truth.
    @ObservedObject var viewport: WhiteboardViewport
    let pageIndex: Int
    /// True when the canvas is being shown over the whiteboard backdrop.
    /// Doesn't affect drag-to-move (which is now available on every
    /// slide); kept for backdrop-specific behavior elsewhere.
    var isWhiteboard: Bool = false
    /// Called when the user taps an empty area in pointer mode on a
    /// regular slide — lets the presenter advance without losing the
    /// drag-to-move capability on the same canvas.
    var onAdvanceOnEmptyTap: (() -> Void)? = nil

    @State private var inProgressStroke: AnnotationStroke?

    // Drag session for pointer / selector modes. Covers move + resize +
    // marquee + lasso, all driven through one DragGesture so they're
    // mutually exclusive.
    @State private var dragSession: DragSession?
    private struct DragSession {
        let startLocation: CGPoint
        var lastPoint: CGPoint
        var mode: Mode

        enum Mode {
            case moving                                                  // pointer drag on selected stroke
            case resizing(handle: ResizeHandle, startBounds: CGRect)     // pointer drag on a handle
            case marquee(rect: CGRect)                                   // selectorRect drag
            case lasso(points: [CGPoint])                                // selectorLasso drag
        }
    }

    /// One of the 8 resize handles drawn around the selected stroke.
    private enum ResizeHandle: CaseIterable {
        case nw, n, ne, e, se, s, sw, w
    }

    // Inline text editor state.
    @State private var textEditorAnchor: CGPoint?
    @State private var textEditorContent: String = ""
    @FocusState private var isTextEditorFocused: Bool

    private var whiteboardZoom: CGFloat { viewport.zoom }
    private var whiteboardPan: CGSize  { viewport.pan }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isWhiteboard {
                whiteboardZoomBadge
                    .padding(.top, 18)
                    .padding(.leading, 18)
                    .zIndex(2)
            }
            Canvas { context, _ in
                // Whiteboard zoom + pan: apply to the whole canvas so
                // stored world-coord strokes get scaled/translated.
                if isWhiteboard {
                    context.translateBy(x: whiteboardPan.width, y: whiteboardPan.height)
                    context.scaleBy(x: whiteboardZoom, y: whiteboardZoom)
                }
                for stroke in store.strokes(for: pageIndex) {
                    draw(stroke, in: &context)
                }
                if let inProgressStroke {
                    draw(inProgressStroke, in: &context)
                }
                drawSelectionOverlay(in: &context)
                drawSelectorPreview(in: &context)
            }
            .gesture(combinedGesture)

            if let anchor = textEditorAnchor {
                textEditorOverlay(anchor: anchor)
            }
        }
        .allowsHitTesting(allowsHits)
    }

    /// Combines the standard pen/marquee drag with a pinch-to-zoom
    /// magnify gesture (only meaningful on whiteboard slides).
    private var combinedGesture: some Gesture {
        let zoom = MagnificationGesture()
            .onChanged { scale in
                guard isWhiteboard else { return }
                viewport.applyPinch(scale: scale)
            }
            .onEnded { _ in
                viewport.commitPinch()
            }
        return drawGesture.simultaneously(with: zoom)
    }

    /// Converts a gesture point (window-space) into world-space (the
    /// coordinate system stored strokes live in). On non-whiteboard
    /// slides this is the identity.
    private func toWorld(_ p: CGPoint) -> CGPoint {
        guard isWhiteboard, whiteboardZoom > 0 else { return p }
        return CGPoint(
            x: (p.x - whiteboardPan.width) / whiteboardZoom,
            y: (p.y - whiteboardPan.height) / whiteboardZoom
        )
    }

    /// Hit-testing is always on now — the canvas needs to receive both
    /// drag-to-move events and "empty tap" events so it can either move
    /// strokes or forward an advance request to the presenter.
    private var allowsHits: Bool { true }

    // MARK: - Gesture

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if store.tool == .text {
                    // Defer text editor placement to onEnded so SwiftUI's
                    // focus system isn't fighting the drag gesture.
                    return
                }
                let p = toWorld(value.location)
                let start = toWorld(value.startLocation)
                handle(point: p,
                       startLocation: start,
                       starting: inProgressStroke == nil && dragSession == nil)
            }
            .onEnded { value in
                let endPt = toWorld(value.location)
                let startPt = toWorld(value.startLocation)

                if store.tool == .text {
                    textEditorContent = ""
                    textEditorAnchor = endPt
                    isTextEditorFocused = true
                    return
                }

                // Selector tools commit on release: collect strokes that
                // fell inside the marquee/lasso and write them into the
                // store's selection set.
                if let session = dragSession {
                    switch session.mode {
                    case .marquee(let rect):
                        store.selectStrokes(inRect: normalized(rect), page: pageIndex)
                    case .lasso(let pts):
                        store.selectStrokes(inLasso: pts, page: pageIndex)
                    case .moving, .resizing:
                        break
                    }
                    dragSession = nil
                    return
                }

                if store.tool == .pointer {
                    let dx = endPt.x - startPt.x
                    let dy = endPt.y - startPt.y
                    if abs(dx) < 4, abs(dy) < 4 {
                        onAdvanceOnEmptyTap?()
                    }
                    return
                }
                commitInProgressStroke()
            }
    }

    private func normalized(_ r: CGRect) -> CGRect {
        CGRect(x: min(r.minX, r.maxX), y: min(r.minY, r.maxY),
               width: abs(r.width), height: abs(r.height))
    }

    private func handle(point: CGPoint, startLocation: CGPoint, starting: Bool) {
        switch store.tool {
        case .pointer:
            // Pointer mode: empty-tap (advance) / tap stroke (select) /
            // drag stroke (move group) / drag handle of combined
            // selection bounds (resize group).
            if dragSession == nil, starting {
                // 1) Drag a corner / edge handle of the current selection.
                if let bounds = store.boundingRect(forIDs: store.selectedStrokeIDs, page: pageIndex),
                   let handle = handleHit(at: startLocation, in: bounds) {
                    dragSession = DragSession(
                        startLocation: startLocation,
                        lastPoint: startLocation,
                        mode: .resizing(handle: handle, startBounds: bounds)
                    )
                } else if let id = store.hitTestStroke(at: startLocation, page: pageIndex) {
                    // 2) Hit a stroke body. If it's already in the
                    //    selection set, keep the group; otherwise reset
                    //    the selection to just that stroke.
                    if !store.selectedStrokeIDs.contains(id) {
                        store.selectedStrokeIDs = [id]
                    }
                    dragSession = DragSession(
                        startLocation: startLocation,
                        lastPoint: startLocation,
                        mode: .moving
                    )
                } else {
                    // 3) Empty space → drop the selection.
                    store.selectedStrokeIDs.removeAll()
                }
            }
            guard let session = dragSession else { return }
            switch session.mode {
            case .moving:
                let delta = CGSize(
                    width: point.x - session.lastPoint.x,
                    height: point.y - session.lastPoint.y
                )
                store.translateSelection(by: delta, page: pageIndex)
                dragSession?.lastPoint = point
            case .resizing(let handle, let startBounds):
                let dx = point.x - session.startLocation.x
                let dy = point.y - session.startLocation.y
                let newBounds = resized(startBounds, handle: handle, dx: dx, dy: dy)
                store.resizeSelection(from: startBounds, to: newBounds, page: pageIndex)
                dragSession?.lastPoint = point
            case .marquee, .lasso:
                break // covered by their own tool cases below
            }

        case .selectorRect:
            if starting {
                dragSession = DragSession(
                    startLocation: startLocation,
                    lastPoint: point,
                    mode: .marquee(rect: CGRect(origin: startLocation, size: .zero))
                )
            } else if var session = dragSession,
                      case .marquee = session.mode {
                let newRect = CGRect(
                    x: min(session.startLocation.x, point.x),
                    y: min(session.startLocation.y, point.y),
                    width: abs(point.x - session.startLocation.x),
                    height: abs(point.y - session.startLocation.y)
                )
                session.mode = .marquee(rect: newRect)
                session.lastPoint = point
                dragSession = session
            }

        case .selectorLasso:
            if starting {
                dragSession = DragSession(
                    startLocation: startLocation,
                    lastPoint: point,
                    mode: .lasso(points: [startLocation])
                )
            } else if var session = dragSession,
                      case .lasso(var pts) = session.mode {
                // Sample the path every few pixels so we don't bloat the
                // point list — the polygon test only needs vertices.
                if let last = pts.last,
                   hypot(point.x - last.x, point.y - last.y) >= 3 {
                    pts.append(point)
                }
                session.mode = .lasso(points: pts)
                session.lastPoint = point
                dragSession = session
            }

        case .brushEraser:
            // The "brush" radius scales with the configured pen width so
            // it feels like an inverse pen — narrow pen → narrow erase.
            let radius = max(10, store.penWidth * 4)
            store.brushErase(at: point, radius: radius, page: pageIndex)
            if starting {
                inProgressStroke = AnnotationStroke(
                    points: [point], color: .clear, width: 0, tool: .brushEraser
                )
            }

        case .pen:
            if starting {
                inProgressStroke = AnnotationStroke(
                    points: [point],
                    color: store.penColor,
                    width: store.penWidth,
                    tool: .pen
                )
            } else {
                inProgressStroke?.points.append(point)
            }

        case .highlighter:
            if starting {
                inProgressStroke = AnnotationStroke(
                    points: [point],
                    color: store.highlighterColor,
                    width: store.highlighterWidth,
                    tool: .highlighter
                )
            } else {
                inProgressStroke?.points.append(point)
            }

        case .line, .arrow, .rectangle, .ellipse:
            if starting {
                inProgressStroke = AnnotationStroke(
                    points: [point, point],
                    color: store.penColor,
                    width: store.penWidth,
                    tool: store.tool,
                    isFilled: store.tool.supportsFill && store.fillShapes
                )
            } else if inProgressStroke != nil {
                inProgressStroke?.points[1] = point
            }

        case .text:
            // Handled in onEnded.
            return

        case .image:
            // Image annotations are created programmatically (paste /
            // Insert Image) — drags on them are routed through pointer
            // mode for moving, not drawing.
            return

        case .eraser:
            store.erase(at: point, page: pageIndex)
            if starting {
                inProgressStroke = AnnotationStroke(
                    points: [point], color: .clear, width: 0, tool: .eraser
                )
            }
        }
    }

    private func commitInProgressStroke() {
        defer { inProgressStroke = nil }
        guard let stroke = inProgressStroke, stroke.tool.producesStroke else { return }

        if stroke.tool.isShape,
           stroke.points.count >= 2,
           hypot(stroke.points[1].x - stroke.points[0].x,
                 stroke.points[1].y - stroke.points[0].y) < 2 {
            return
        }

        store.append(stroke: stroke, page: pageIndex)
    }

    // MARK: - Text editor

    private func textEditorOverlay(anchor: CGPoint) -> some View {
        let width: CGFloat = 280
        return HStack(spacing: 8) {
            TextField("your text...", text: $textEditorContent)
                .textFieldStyle(.plain)
                .font(.system(size: store.textFontSize, weight: .semibold))
                .foregroundStyle(store.penColor)
                .focused($isTextEditorFocused)
                .onSubmit { commitTextAnnotation() }
            Button {
                commitTextAnnotation()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            Button {
                cancelTextAnnotation()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
        .frame(width: width)
        .position(x: anchor.x + width / 2, y: anchor.y)
    }

    private func commitTextAnnotation() {
        guard let anchor = textEditorAnchor else { return }
        let trimmed = textEditorContent.trimmingCharacters(in: .whitespacesAndNewlines)
        textEditorAnchor = nil
        textEditorContent = ""
        isTextEditorFocused = false
        guard !trimmed.isEmpty else { return }
        let stroke = AnnotationStroke(
            points: [anchor],
            color: store.penColor,
            width: store.penWidth,
            tool: .text,
            text: trimmed,
            fontSize: store.textFontSize
        )
        store.append(stroke: stroke, page: pageIndex)
    }

    private func cancelTextAnnotation() {
        textEditorAnchor = nil
        textEditorContent = ""
        isTextEditorFocused = false
    }

    // MARK: - Rendering

    private func draw(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
        guard stroke.tool.producesStroke, !stroke.points.isEmpty else { return }

        switch stroke.tool {
        case .pen, .highlighter:
            drawFreehand(stroke, in: &context)
        case .line:
            guard stroke.points.count >= 2 else { return }
            drawStroked(path: linePath(stroke), stroke: stroke, in: &context)
        case .arrow:
            guard stroke.points.count >= 2 else { return }
            drawArrow(stroke, in: &context)
        case .rectangle:
            var p = Path()
            p.addRect(stroke.shapeRect)
            drawShape(path: p, stroke: stroke, in: &context)
        case .ellipse:
            var p = Path()
            p.addEllipse(in: stroke.shapeRect)
            drawShape(path: p, stroke: stroke, in: &context)
        case .text:
            drawText(stroke, in: &context)
        case .image:
            drawImage(stroke, in: &context)
        case .pointer, .eraser, .brushEraser, .selectorRect, .selectorLasso:
            return
        }
    }

    private func drawImage(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
        guard stroke.points.count >= 2,
              let data = stroke.imageData,
              let nsImage = NSImage(data: data) else { return }
        let resolved = context.resolve(Image(nsImage: nsImage))
        context.draw(resolved, in: stroke.shapeRect)
    }

    private func drawFreehand(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
        var path = Path()
        let isDot = stroke.points.count == 1
        if isDot {
            let p = stroke.points[0]
            let r = stroke.width / 2
            path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: stroke.width, height: stroke.width))
        } else {
            path.move(to: stroke.points[0])
            for p in stroke.points.dropFirst() { path.addLine(to: p) }
        }
        context.drawLayer { layer in
            layer.opacity = stroke.opacity
            if isDot {
                layer.fill(path, with: .color(stroke.color))
            } else {
                let style = StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
                layer.stroke(path, with: .color(stroke.color), style: style)
            }
        }
    }

    private func linePath(_ stroke: AnnotationStroke) -> Path {
        var p = Path()
        p.move(to: stroke.points[0])
        p.addLine(to: stroke.points[1])
        return p
    }

    private func drawStroked(path: Path, stroke: AnnotationStroke, in context: inout GraphicsContext) {
        let style = StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
        context.drawLayer { layer in
            layer.opacity = stroke.opacity
            layer.stroke(path, with: .color(stroke.color), style: style)
        }
    }

    /// Rectangles and ellipses: either filled or just stroked, based on
    /// the per-stroke `isFilled` flag captured at creation time.
    private func drawShape(path: Path, stroke: AnnotationStroke, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.opacity = stroke.opacity
            if stroke.isFilled {
                layer.fill(path, with: .color(stroke.color))
            } else {
                let style = StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
                layer.stroke(path, with: .color(stroke.color), style: style)
            }
        }
    }

    /// Arrow: a line from start to end with a small triangular head at end.
    private func drawArrow(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
        let a = stroke.points[0], b = stroke.points[1]
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }

        let headLength = max(stroke.width * 4, 14)
        let headAngle: CGFloat = .pi / 6 // 30°
        let theta = atan2(dy, dx)

        // The visible shaft stops short of the tip so the round line cap
        // doesn't poke past the arrowhead's seam.
        let shaftEnd = CGPoint(
            x: b.x - cos(theta) * (headLength * 0.55),
            y: b.y - sin(theta) * (headLength * 0.55)
        )

        var shaft = Path()
        shaft.move(to: a)
        shaft.addLine(to: shaftEnd)

        var head = Path()
        let leftWing = CGPoint(
            x: b.x - headLength * cos(theta - headAngle),
            y: b.y - headLength * sin(theta - headAngle)
        )
        let rightWing = CGPoint(
            x: b.x - headLength * cos(theta + headAngle),
            y: b.y - headLength * sin(theta + headAngle)
        )
        head.move(to: b)
        head.addLine(to: leftWing)
        head.addLine(to: rightWing)
        head.closeSubpath()

        context.drawLayer { layer in
            layer.opacity = stroke.opacity
            let style = StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
            layer.stroke(shaft, with: .color(stroke.color), style: style)
            layer.fill(head, with: .color(stroke.color))
        }
    }

    private func drawText(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
        guard let text = stroke.text, !text.isEmpty, let anchor = stroke.points.first else { return }
        var resolved = context.resolve(
            Text(text).font(.system(size: stroke.fontSize, weight: .semibold))
        )
        resolved.shading = .color(stroke.color)
        context.draw(resolved, at: anchor, anchor: .topLeading)
    }

    // MARK: - Selection overlay

    /// Visual size of a corner/edge handle. The hit area used by
    /// `handleHit(at:in:)` is slightly larger so the handles are easy to
    /// grab with a mouse.
    private static let handleSize: CGFloat = 11
    private static let handleHitSize: CGFloat = 22

    /// Draws the dashed selection rect + 8 resize handles around the
    /// combined bounds of the current selection, plus a softer outline
    /// for each individual member. Only visible while the pointer or a
    /// selector tool is active.
    private func drawSelectionOverlay(in context: inout GraphicsContext) {
        guard store.tool == .pointer || store.tool.isSelector,
              !store.selectedStrokeIDs.isEmpty,
              let combined = store.boundingRect(forIDs: store.selectedStrokeIDs, page: pageIndex)
        else { return }

        // Soft per-member outlines so the user sees what's in the group.
        for id in store.selectedStrokeIDs {
            guard let r = store.boundingRect(forStrokeID: id, page: pageIndex) else { continue }
            var p = Path()
            p.addRect(r.insetBy(dx: -2, dy: -2))
            context.stroke(
                p, with: .color(Color.accentColor.opacity(0.4)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
            )
        }

        let inflated = combined.insetBy(dx: -4, dy: -4)
        var rect = Path()
        rect.addRect(inflated)
        context.stroke(
            rect,
            with: .color(Color.accentColor),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
        )

        // Only the pointer tool can grab handles; lasso/marquee tools
        // shouldn't show grab affordances they don't react to.
        guard store.tool == .pointer else { return }
        for (_, pos) in handlePositions(for: combined) {
            let h = CGRect(
                x: pos.x - Self.handleSize / 2,
                y: pos.y - Self.handleSize / 2,
                width: Self.handleSize,
                height: Self.handleSize
            )
            var handle = Path()
            handle.addRect(h)
            context.fill(handle, with: .color(.white))
            context.stroke(handle, with: .color(Color.accentColor), lineWidth: 1.5)
        }
    }

    /// Live marquee rect / lasso path drawn while the user is dragging
    /// the corresponding selector tool.
    private func drawSelectorPreview(in context: inout GraphicsContext) {
        guard let session = dragSession else { return }
        switch session.mode {
        case .marquee(let rect):
            var p = Path()
            p.addRect(normalized(rect))
            context.fill(p, with: .color(Color.accentColor.opacity(0.10)))
            context.stroke(
                p, with: .color(Color.accentColor),
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
            )
        case .lasso(let pts):
            guard pts.count >= 2 else { return }
            var p = Path()
            p.move(to: pts[0])
            for pt in pts.dropFirst() { p.addLine(to: pt) }
            p.closeSubpath()
            context.fill(p, with: .color(Color.accentColor.opacity(0.10)))
            context.stroke(
                p, with: .color(Color.accentColor),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
        case .moving, .resizing:
            break
        }
    }

    /// Where each of the 8 handles sits relative to a selection rect.
    private func handlePositions(for bounds: CGRect) -> [(ResizeHandle, CGPoint)] {
        let r = bounds.insetBy(dx: -4, dy: -4)
        return [
            (.nw, CGPoint(x: r.minX, y: r.minY)),
            (.n,  CGPoint(x: r.midX, y: r.minY)),
            (.ne, CGPoint(x: r.maxX, y: r.minY)),
            (.e,  CGPoint(x: r.maxX, y: r.midY)),
            (.se, CGPoint(x: r.maxX, y: r.maxY)),
            (.s,  CGPoint(x: r.midX, y: r.maxY)),
            (.sw, CGPoint(x: r.minX, y: r.maxY)),
            (.w,  CGPoint(x: r.minX, y: r.midY)),
        ]
    }

    /// Returns the handle (if any) under `point` for a selection rect.
    private func handleHit(at point: CGPoint, in bounds: CGRect) -> ResizeHandle? {
        let half = Self.handleHitSize / 2
        for (handle, pos) in handlePositions(for: bounds) {
            if abs(point.x - pos.x) <= half, abs(point.y - pos.y) <= half {
                return handle
            }
        }
        return nil
    }

    // MARK: - Whiteboard zoom badge

    /// Top-left zoom indicator that doubles as a control panel — shows
    /// the current scale and offers +/–/reset buttons + a pan button.
    private var whiteboardZoomBadge: some View {
        HStack(spacing: 6) {
            Button { viewport.zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)

            Text("\(Int(round(viewport.zoom * 100)))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 44)

            Button { viewport.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)

            Divider().frame(height: 14)

            Button {
                viewport.reset()
            } label: {
                Text("Reset")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Reset zoom to 100% and recenter")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }

    /// Applies a drag delta to a starting bounds rect based on which
    /// handle is being dragged. Negative widths/heights are normalized
    /// so the rect always stays well-formed.
    private func resized(_ start: CGRect, handle: ResizeHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = start.minX, maxX = start.maxX
        var minY = start.minY, maxY = start.maxY

        switch handle {
        case .nw: minX += dx; minY += dy
        case .n:  minY += dy
        case .ne: maxX += dx; minY += dy
        case .e:  maxX += dx
        case .se: maxX += dx; maxY += dy
        case .s:  maxY += dy
        case .sw: minX += dx; maxY += dy
        case .w:  minX += dx
        }

        // Normalize so width/height can never go below a small minimum.
        let nx = min(minX, maxX), nw = max(8, abs(maxX - minX))
        let ny = min(minY, maxY), nh = max(8, abs(maxY - minY))
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }
}
