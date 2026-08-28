import SwiftUI

/// Floating toolbar pinned near the bottom of the presenter window. Used
/// to switch drawing tools, pick a color/width, toggle whether shapes are
/// filled, undo/clear annotations, flip to the whiteboard, attach Google
/// Forms to the current slide, and trigger AI quiz generation.
struct PresenterToolbar: View {

    @ObservedObject var annotations: AnnotationStore
    @ObservedObject var quizStore: QuizStore
    @ObservedObject var deckStore: DeckStore
    @ObservedObject var formStore: GoogleFormStore
    @ObservedObject var timerStore: TimerStore
    /// Stroke storage key for the currently visible slide. For PDF slides
    /// this is the 0-based page index; for whiteboard slides it's the
    /// whiteboard's negative `id`. Used by the toolbar's undo / clear
    /// buttons so they operate on the right slide's annotations.
    let annotationKey: Int
    /// Screen-space canvas size, threaded down so the Whiteboard button
    /// can record where each new whiteboard slide's strokes will live.
    let canvasSize: CGSize
    let onGenerateQuiz: () -> Void
    let onExportPDF: () -> Void
    let onExportPPTX: () -> Void
    let onRemoveCurrentWhiteboard: () -> Void
    let onInsertImage: () -> Void

    @State private var isEditingFormURL = false
    @State private var formURLDraft: String = ""
    @State private var formLabelDraft: String = ""
    @State private var editingFormID: UUID?

    @State private var isShowingTimerPicker = false
    @State private var customTimerMinutes: String = "10"

    /// Tools shown as standalone buttons in the toolbar (in order). The
    /// `.selectorRect / .selectorLasso` and `.eraser / .brushEraser`
    /// pairs are rendered as grouped sub-menu buttons instead — see
    /// `selectorGroupButton` and `eraserGroupButton`.
    private static let standaloneTools: [AnnotationTool] = [
        .pointer,
        .pen, .highlighter, .text,
        .line, .arrow, .rectangle, .ellipse,
    ]

    var body: some View {
        HStack(spacing: 10) {
            toolButton(.pointer)
            selectorGroupButton
            ForEach([AnnotationTool.pen, .highlighter, .text,
                     .line, .arrow, .rectangle, .ellipse]) { tool in
                toolButton(tool)
            }
            eraserGroupButton

            if showsColorAndWidth {
                separator
                colorRow
                separator
                widthSlider
            }

            if annotations.tool.supportsFill {
                separator
                fillToggle
            }

            separator

            iconButton(systemImage: "arrow.uturn.backward", help: "Undo last stroke") {
                annotations.undo(page: annotationKey)
            }

            iconButton(systemImage: "trash", help: "Clear this slide") {
                annotations.clear(page: annotationKey)
            }

            separator

            insertImageButton

            whiteboardButton

            timerButton

            quizButton

            formMenuButton

            exportMenuButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(GlassyCapsule())
    }

    // MARK: - Pieces

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func toolButton(_ tool: AnnotationTool) -> some View {
        let isActive = annotations.tool == tool
        Button {
            annotations.tool = tool
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(isActive ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tool.label)
    }

    /// Grouped Selector button. Hosts both `.selectorRect` (marquee) and
    /// `.selectorLasso` (lasso) — clicking reveals the menu, picking an
    /// item makes it the active tool. The button's icon mirrors whichever
    /// sub-tool is currently selected so the user always sees what they
    /// have.
    private var selectorGroupButton: some View {
        toolGroupMenu(
            members: [.selectorRect, .selectorLasso],
            defaultMember: .selectorRect,
            helpWhenInactive: "Selector — pick marquee or lasso"
        )
    }

    /// Grouped Eraser button. Hosts both `.eraser` (item eraser, removes
    /// whole strokes) and `.brushEraser` (brush eraser, removes only the
    /// touched portion).
    private var eraserGroupButton: some View {
        toolGroupMenu(
            members: [.eraser, .brushEraser],
            defaultMember: .eraser,
            helpWhenInactive: "Eraser — pick item or brush"
        )
    }

    /// Generic "click-to-reveal sub-tools" group used by the selector
    /// and eraser families. Visually consistent with `toolButton(_:)`:
    /// 32×32 circular icon, accent-tinted when one of its members is the
    /// active tool.
    @ViewBuilder
    private func toolGroupMenu(
        members: [AnnotationTool],
        defaultMember: AnnotationTool,
        helpWhenInactive: String
    ) -> some View {
        let activeMember = members.first(where: { $0 == annotations.tool })
        let isActive = activeMember != nil
        let displayed = activeMember ?? defaultMember

        Menu {
            ForEach(members) { tool in
                Button {
                    annotations.tool = tool
                } label: {
                    Label(tool.label, systemImage: tool.systemImage)
                }
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: displayed.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(isActive ? Color.accentColor.opacity(0.25) : Color.clear)
                    )
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)

                // Small chevron in the corner so it's obvious this is a
                // group, not a single tool.
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .padding(2)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .offset(x: 2, y: 2)
            }
            .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isActive ? displayed.label : helpWhenInactive)
    }

    private func iconButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .foregroundStyle(Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Whether the current tool exposes color + width controls. Shape and
    /// text tools share the pen palette.
    private var showsColorAndWidth: Bool {
        switch annotations.tool {
        case .pen, .highlighter, .text, .line, .arrow, .rectangle, .ellipse:
            return true
        case .pointer, .eraser, .brushEraser, .selectorRect, .selectorLasso, .image:
            return false
        }
    }

    @ViewBuilder
    private var colorRow: some View {
        switch annotations.tool {
        case .pen, .text, .line, .arrow, .rectangle, .ellipse:
            colorSwatches(
                colors: AnnotationStore.penColors,
                selectedIndex: $annotations.penColorIndex
            )
        case .highlighter:
            colorSwatches(
                colors: AnnotationStore.highlighterColors,
                selectedIndex: $annotations.highlighterColorIndex
            )
        default:
            EmptyView()
        }
    }

    private func colorSwatches(colors: [Color], selectedIndex: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            ForEach(colors.indices, id: \.self) { i in
                Button {
                    selectedIndex.wrappedValue = i
                } label: {
                    Circle()
                        .fill(colors[i])
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle().strokeBorder(
                                selectedIndex.wrappedValue == i ? Color.accentColor : Color.white.opacity(0.4),
                                lineWidth: selectedIndex.wrappedValue == i ? 2.5 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var widthSlider: some View {
        switch annotations.tool {
        case .pen, .line, .arrow, .rectangle, .ellipse:
            sizeControl(value: $annotations.penWidth, range: 1...14)
        case .highlighter:
            sizeControl(value: $annotations.highlighterWidth, range: 8...44)
        case .text:
            sizeControl(value: $annotations.textFontSize, range: 14...72)
        default:
            EmptyView()
        }
    }

    /// A slider paired with a numeric entry field so the user can either
    /// drag or type an exact size. Typed values are clamped to the slider's
    /// range so the two controls never disagree.
    private func sizeControl(value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        HStack(spacing: 8) {
            Slider(value: value, in: range)
                .frame(width: 90)
            TextField("", value: clampedDouble(value, range), formatter: Self.sizeFormatter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 42)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .help("Type an exact size (\(Int(range.lowerBound))–\(Int(range.upperBound)))")
        }
    }

    /// Bridges the `CGFloat` size binding to the `Double` a `TextField`
    /// formatter expects, clamping typed input into the allowed range.
    private func clampedDouble(_ value: Binding<CGFloat>, _ range: ClosedRange<CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = min(max(CGFloat($0), range.lowerBound), range.upperBound) }
        )
    }

    private static let sizeFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.minimum = 1
        return f
    }()

    /// Toggle that switches the active shape between outlined and filled.
    /// Captured into each new stroke at creation time so existing strokes
    /// keep their original look.
    private var fillToggle: some View {
        Button {
            annotations.fillShapes.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: annotations.fillShapes ? "square.fill" : "square")
                    .font(.system(size: 13, weight: .medium))
                Text(annotations.fillShapes ? "Fill" : "Outline")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(annotations.fillShapes
                               ? Color.accentColor.opacity(0.22)
                               : Color.primary.opacity(0.08))
            )
            .foregroundStyle(annotations.fillShapes ? Color.accentColor : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(annotations.fillShapes ? "Shapes drawn filled" : "Shapes drawn as outlines")
    }

    // MARK: - Insert image

    private var insertImageButton: some View {
        Button {
            onInsertImage()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "photo.badge.plus")
                Text("Image")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Insert an image onto this slide. You can also paste with ⌘V.")
    }

    // MARK: - Whiteboard / Remove slide

    @ViewBuilder
    private var whiteboardButton: some View {
        if deckStore.isCurrentSlideWhiteboard {
            Button {
                onRemoveCurrentWhiteboard()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash.slash.fill")
                    Text("Remove Slide")
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.red.opacity(0.22)))
                .foregroundStyle(Color.red)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Delete this whiteboard slide and return to the slide before it")
        } else {
            Button {
                deckStore.insertWhiteboardAfterCurrent(canvasSize: canvasSize)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.dashed")
                    Text("Whiteboard")
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .foregroundStyle(Color.primary)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Insert a new whiteboard slide after this one (⌥W) — items are draggable, contents saved to the deck")
        }
    }

    // MARK: - Timer

    private var timerButton: some View {
        Button {
            isShowingTimerPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: timerStore.isVisible ? "timer.circle.fill" : "timer")
                Text(timerStore.isVisible ? timerStore.formatted : "Timer")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(timerStore.isVisible
                               ? Color.purple.opacity(0.22)
                               : Color.primary.opacity(0.08))
            )
            .foregroundStyle(timerStore.isVisible ? Color.purple : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingTimerPicker, arrowEdge: .top) {
            timerPicker
        }
        .help(timerStore.isVisible
              ? "Manage the running timer (⌥T)"
              : "Start a countdown timer (⌥T)")
    }

    private var timerPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Countdown timer")
                .font(.headline)
            HStack(spacing: 8) {
                ForEach([1, 5, 10, 15, 30], id: \.self) { mins in
                    Button("\(mins)m") {
                        timerStore.start(minutes: mins)
                        isShowingTimerPicker = false
                    }
                    .buttonStyle(.bordered)
                }
            }
            Divider()
            HStack {
                TextField("Custom (minutes)", text: $customTimerMinutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Button("Start") {
                    if let mins = Int(customTimerMinutes.trimmingCharacters(in: .whitespaces)), mins > 0 {
                        timerStore.start(minutes: mins)
                        isShowingTimerPicker = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            if timerStore.isVisible {
                Divider()
                HStack(spacing: 8) {
                    Button(timerStore.isRunning ? "Pause" : "Resume") {
                        timerStore.toggle()
                    }
                    Button("Reset") { timerStore.reset() }
                    Button("Dismiss", role: .destructive) {
                        timerStore.dismiss()
                        isShowingTimerPicker = false
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Quiz

    private var quizButton: some View {
        Button {
            onGenerateQuiz()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Quiz")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.18))
            )
            .foregroundStyle(Color.accentColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(quizStore.isVisible)
        .help("Generate an AI quiz (⌥Q)")
    }

    /// Forms attach to PDF pages, not whiteboard slides. When the
    /// presenter is on a whiteboard we associate any new form with the
    /// nearest preceding PDF page; if there isn't one yet we hide the
    /// form attachment options for clarity.
    private var formPageContext: Int? {
        if let pdfIdx = deckStore.currentPDFPageIndex { return pdfIdx }
        // Use the previous PDF page if we're currently on a whiteboard.
        let order = deckStore.slideOrder
        guard !order.isEmpty else { return nil }
        for i in stride(from: min(deckStore.currentPageIndex, order.count - 1), through: 0, by: -1) {
            if case .pdf(let p) = order[i] { return p }
        }
        return nil
    }

    // MARK: - Google Forms (per slide)

    private var formMenuButton: some View {
        let pageContext = formPageContext
        let slideForms = pageContext.map { deckStore.forms(forPage: $0) } ?? []

        // Every form attached anywhere in the deck — so the presenter can
        // open any of them from any slide.
        let otherForms = deckStore.savedForms
            .filter { form in
                guard let pageContext else { return true }
                return form.pageIndex != pageContext
            }
        let otherFormsByPage: [Int: [SavedForm]] = Dictionary(grouping: otherForms, by: \.pageIndex)
        let otherPages = otherFormsByPage.keys.sorted()

        return Menu {
            if !slideForms.isEmpty {
                Section("Forms on this slide") {
                    ForEach(slideForms) { form in
                        Button {
                            formStore.show(form)
                        } label: {
                            Label(form.label, systemImage: "play.fill")
                        }
                    }
                }
                Divider()
            }

            if !otherPages.isEmpty {
                Section("Forms on other slides") {
                    ForEach(otherPages, id: \.self) { page in
                        Menu {
                            ForEach(otherFormsByPage[page] ?? []) { form in
                                Button {
                                    formStore.show(form)
                                } label: {
                                    Label(form.label, systemImage: "play.fill")
                                }
                            }
                        } label: {
                            Label("Slide \(page + 1) — \((otherFormsByPage[page]?.count ?? 0)) form\(((otherFormsByPage[page]?.count ?? 0) == 1) ? "" : "s")",
                                  systemImage: "doc.text")
                        }
                    }
                }
                Divider()
            }

            if !deckStore.savedForms.isEmpty {
                Menu {
                    ForEach(deckStore.savedForms) { form in
                        Button("Slide \(form.pageIndex + 1): \(form.label)…") {
                            beginEditing(form)
                        }
                    }
                } label: {
                    Label("Edit form…", systemImage: "pencil")
                }
                Menu {
                    ForEach(deckStore.savedForms) { form in
                        Button("Slide \(form.pageIndex + 1): \(form.label)", role: .destructive) {
                            deckStore.removeForm(id: form.id)
                        }
                    }
                } label: {
                    Label("Remove form…", systemImage: "trash")
                }
                Divider()
            }

            if pageContext != nil {
                Button {
                    beginAdding()
                } label: {
                    Label("Add form to this slide…", systemImage: "plus")
                }
            }
        } label: {
            let totalForms = deckStore.savedForms.count
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                Text(totalForms == 0
                     ? "Form"
                     : (slideForms.isEmpty
                        ? "Forms (\(totalForms))"
                        : "Forms (\(slideForms.count) here · \(totalForms) total)"))
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(totalForms == 0
                               ? Color.primary.opacity(0.08)
                               : Color.green.opacity(0.18))
            )
            .foregroundStyle(totalForms == 0 ? Color.primary : Color.green)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $isEditingFormURL, arrowEdge: .top) {
            formEditor
        }
        .help(deckStore.savedForms.isEmpty
              ? "Attach a Google Form to this slide"
              : "Open any Google Form attached to this deck, or attach more")
    }

    private var formEditor: some View {
        let labelPage = (formPageContext ?? 0) + 1
        return VStack(alignment: .leading, spacing: 12) {
            Text(editingFormID == nil ? "Add Google Form" : "Edit Google Form")
                .font(.headline)
            Text("Forms appear in the menu for slide \(labelPage). Multiple forms per slide are supported.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Label (e.g. Warm-up quiz)", text: $formLabelDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
            TextField("https://docs.google.com/forms/d/e/.../viewform", text: $formURLDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
            HStack {
                Button("Cancel") {
                    isEditingFormURL = false
                    editingFormID = nil
                }
                Spacer()
                Button(editingFormID == nil ? "Add" : "Save") {
                    if let id = editingFormID {
                        deckStore.updateForm(id: id, label: formLabelDraft, url: formURLDraft)
                    } else if let target = formPageContext {
                        _ = deckStore.addForm(
                            label: formLabelDraft,
                            url: formURLDraft,
                            pageIndex: target
                        )
                    }
                    isEditingFormURL = false
                    editingFormID = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(URL(string: formURLDraft.trimmingCharacters(in: .whitespaces)) == nil)
            }
        }
        .padding(16)
    }

    private func beginAdding() {
        editingFormID = nil
        formLabelDraft = ""
        formURLDraft = ""
        isEditingFormURL = true
    }

    private func beginEditing(_ form: SavedForm) {
        editingFormID = form.id
        formLabelDraft = form.label
        formURLDraft = form.url
        isEditingFormURL = true
    }

    // MARK: - Export

    private var exportMenuButton: some View {
        Menu {
            Button {
                onExportPDF()
            } label: {
                Label("Export as PDF…", systemImage: "doc.richtext")
            }
            Button {
                onExportPPTX()
            } label: {
                Label("Export as PowerPoint (.pptx)…", systemImage: "rectangle.stack")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                Text(deckStore.isExporting ? "Exporting…" : "Export")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(Color.primary)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(deckStore.isExporting)
        .help("Export the entire deck — including whiteboard slides — as PDF or PowerPoint")
    }
}

/// Applies a Liquid Glass capsule background to the floating toolbar on
/// macOS 26+, with a hand-rolled material+highlight+specular fallback
/// for earlier OSes (so the toolbar still feels glassy when the system
/// can't render real Liquid Glass).
private struct GlassyCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
                .shadow(color: .black.opacity(0.32), radius: 18, y: 6)
        } else {
            content
                .background(
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.28),
                                        Color.white.opacity(0.04),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                    }
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.45),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        }
    }
}
