import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// The actual fullscreen slide display. Renders the current slide — either
/// a rasterized PDF page or a whiteboard backdrop — and overlays the
/// annotation canvas + tool palette + AI quiz card + Google Form embed +
/// countdown timer on top.
///
/// When the current `SlideRef` is a `.whiteboard`, the slide image is
/// swapped for a gridded backdrop and the annotation canvas points at the
/// whiteboard's unique key (its `id`) so its strokes are stored
/// independently from PDF-page annotations.
struct PresenterView: View {

    let document: PDFDocument
    @ObservedObject var deckStore: DeckStore
    @ObservedObject var quizStore: QuizStore
    @ObservedObject var formStore: GoogleFormStore
    @ObservedObject var timerStore: TimerStore
    @ObservedObject var annotations: AnnotationStore
    @ObservedObject var viewport: WhiteboardViewport
    /// Logical canvas size (full screen) — used to size pasted/inserted
    /// images.
    let canvasSize: CGSize

    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottom) {
            slideBackdrop

            AnnotationCanvas(
                store: annotations,
                viewport: viewport,
                pageIndex: deckStore.currentAnnotationKey,
                isWhiteboard: deckStore.isCurrentSlideWhiteboard,
                onAdvanceOnEmptyTap: { advanceOnPointerTap() }
            )
            .ignoresSafeArea()

            PresenterToolbar(
                annotations: annotations,
                quizStore: quizStore,
                deckStore: deckStore,
                formStore: formStore,
                timerStore: timerStore,
                annotationKey: deckStore.currentAnnotationKey,
                canvasSize: canvasSize,
                onGenerateQuiz: { generateQuiz() },
                onExportPDF: { runExport(.pdf) },
                onExportPPTX: { runExport(.pptx) },
                onRemoveCurrentWhiteboard: { deckStore.removeCurrentWhiteboard() },
                onInsertImage: { insertImageViaPanel() }
            )
            .padding(.bottom, 28)

            if quizStore.isVisible {
                QuizOverlay(store: quizStore) {
                    quizStore.confirmGeneration(using: deckStore)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if let form = formStore.showingForm,
               let embedded = GoogleFormStore.embedded(form.url) {
                GoogleFormOverlay(form: form, url: embedded) { formStore.hide() }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if timerStore.isVisible {
                TimerBadge(store: timerStore)
                    .padding(.top, 28)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Whiteboard's Remove Slide button has to live above the
            // annotation canvas (which catches clicks everywhere now)
            // or it isn't tappable.
            if deckStore.isCurrentSlideWhiteboard {
                removeWhiteboardButton
                    .padding(.top, 18)
                    .padding(.trailing, 18)
            }
        }
        .overlay(alignment: .topLeading) {
            if let pdfIdx = deckStore.currentPDFPageIndex {
                let formsHere = deckStore.forms(forPage: pdfIdx)
                if !formsHere.isEmpty {
                    SlideInlineActions(
                        forms: formsHere,
                        onQuiz: { generateQuiz() },
                        onOpenForm: { formStore.show($0) }
                    )
                    .padding(.top, timerStore.isVisible ? 130 : 28)
                    .padding(.leading, 28)
                }
            }
        }
        .onChange(of: deckStore.currentPageIndex) { _ in
            // Persist whiteboard strokes for the slide we're leaving
            // before we re-render for the new one.
            persistCurrentWhiteboardStrokes()
            renderCurrentSlide()
        }
        .onChange(of: annotations.strokes(for: deckStore.currentAnnotationKey)) { _ in
            // Throttled persistence isn't necessary at this scale — strokes
            // are small and writes happen via the sidecar's atomic path.
            persistCurrentWhiteboardStrokes()
        }
        .task {
            restoreCurrentWhiteboardStrokes()
            renderCurrentSlide()
        }
    }

    // MARK: - Backdrop

    @ViewBuilder
    private var slideBackdrop: some View {
        switch deckStore.currentSlide {
        case .pdf:
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
        case .whiteboard:
            whiteboardBackdrop
        case .none:
            Color.black.ignoresSafeArea()
        }
    }

    private var whiteboardBackdrop: some View {
        ZStack {
            Color(white: 0.97).ignoresSafeArea()
            GeometryReader { geo in
                Canvas { context, size in
                    let spacing: CGFloat = 48
                    var x: CGFloat = 0
                    while x < size.width {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(p, with: .color(Color.black.opacity(0.05)), lineWidth: 1)
                        x += spacing
                    }
                    var y: CGFloat = 0
                    while y < size.height {
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(p, with: .color(Color.black.opacity(0.05)), lineWidth: 1)
                        y += spacing
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            // The grid canvas + label are decoration only — they must
            // never absorb mouse events, or the AnnotationCanvas above
            // can lose drag gestures (the bug behind "shape drawing and
            // text don't work on the whiteboard").
            .allowsHitTesting(false)

            VStack {
                HStack {
                    Label("Whiteboard", systemImage: "rectangle.dashed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.6)))
                    Spacer()
                }
                .padding(.top, 18)
                .padding(.horizontal, 18)
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }

    /// Prominent red button anchored to the whiteboard's top-right so it
    /// can't be missed. Deletes the current whiteboard slide from the
    /// deck order and lands the presenter on the slide that preceded it.
    private var removeWhiteboardButton: some View {
        Button {
            deckStore.removeCurrentWhiteboard()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash.fill")
                Text("Remove Slide")
                    .font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.red))
            .foregroundStyle(.white)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .help("Delete this whiteboard slide. The slide before it becomes the new current slide.")
    }

    // MARK: - Rendering / persistence

    private func renderCurrentSlide() {
        switch deckStore.currentSlide {
        case .pdf(let i):
            guard let page = document.page(at: i) else { image = nil; return }
            image = SlideImageRenderer.render(page: page)
        case .whiteboard, .none:
            image = nil
        }
    }

    /// Pulls strokes for every whiteboard slide out of the deck store
    /// (loaded from the sidecar) and seeds the annotation store. Runs once
    /// when the view appears.
    private func restoreCurrentWhiteboardStrokes() {
        for board in deckStore.whiteboardSlides {
            annotations.setStrokes(board.strokes, for: board.id)
        }
    }

    private func persistCurrentWhiteboardStrokes() {
        guard case .whiteboard(let id) = deckStore.currentSlide else { return }
        deckStore.updateWhiteboardStrokes(
            id: id,
            strokes: annotations.strokes(for: id)
        )
    }

    private func generateQuiz() {
        quizStore.triggerQuiz(using: deckStore)
    }

    /// Forwarded from the annotation canvas when the user taps empty
    /// space in pointer mode — advance the slide unless an overlay is
    /// already in front of the audience, or we're on a whiteboard.
    private func advanceOnPointerTap() {
        guard !quizStore.isVisible,
              !formStore.isShowing,
              !deckStore.isCurrentSlideWhiteboard else { return }
        deckStore.nextPage()
    }

    /// Shows an Open Panel filtered to images and drops the chosen file
    /// onto the active slide as an image annotation.
    ///
    /// The presenter window sits at `NSWindow.Level.mainMenu + 1`, which
    /// is *above* any standalone modal panel, so a plain `NSOpenPanel.begin`
    /// would open behind the slide and stay invisible. Attaching the
    /// panel as a sheet on the presenter window forces it to inherit the
    /// window's level and appear on top.
    private func insertImageViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Insert Image"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]

        let onCompletion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK,
                  let url = panel.url,
                  let image = NSImage(contentsOf: url) else { return }
            annotations.insertImage(
                image,
                on: deckStore.currentAnnotationKey,
                canvasSize: canvasSize
            )
        }

        if let presenterWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: presenterWindow, completionHandler: onCompletion)
        } else {
            panel.begin(completionHandler: onCompletion)
        }
    }

    // MARK: - Export

    enum ExportFormat { case pdf, pptx }

    private func runExport(_ format: ExportFormat) {
        let baseName = deckStore.sourceFileName
            .flatMap { URL(string: $0)?.deletingPathExtension().lastPathComponent ?? $0 }
            ?? "DeckLive"

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch format {
        case .pdf:
            panel.title = "Export as PDF"
            panel.nameFieldStringValue = "\(baseName) (with whiteboards).pdf"
            panel.allowedContentTypes = [.pdf]
        case .pptx:
            panel.title = "Export as PowerPoint"
            panel.nameFieldStringValue = "\(baseName) (with whiteboards).pptx"
            if let pptxType = UTType(filenameExtension: "pptx") {
                panel.allowedContentTypes = [pptxType]
            }
        }

        let onCompletion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await performExport(format: format, to: url) }
        }

        // The presenter window sits at NSWindow.Level.mainMenu + 1, which
        // is well above any modal panel. `NSSavePanel.begin` would land
        // behind it and the user would never see the dialog. Attaching
        // the panel as a sheet on the presenter window guarantees it
        // appears in front, on top of the slide.
        if let presenterWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: presenterWindow, completionHandler: onCompletion)
        } else {
            panel.begin(completionHandler: onCompletion)
        }
    }

    private func performExport(format: ExportFormat, to url: URL) async {
        deckStore.isExporting = true
        defer { deckStore.isExporting = false }
        do {
            switch format {
            case .pdf:
                try DeckExporter.exportPDF(
                    deckStore: deckStore,
                    document: document,
                    to: url
                )
            case .pptx:
                try await DeckExporter.exportPPTX(
                    deckStore: deckStore,
                    document: document,
                    to: url
                )
            }
            deckStore.statusMessage = "Exported to \(url.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            deckStore.statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

/// Floating action panel that appears on slides where the presenter has
/// attached one or more Google Forms. Surfaces a quick **Quiz** trigger
/// next to a button for each attached form so the presenter doesn't have
/// to hunt through the toolbar menu mid-presentation.
private struct SlideInlineActions: View {
    let forms: [SavedForm]
    let onQuiz: () -> Void
    let onOpenForm: (SavedForm) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            quizPill

            ForEach(forms) { form in
                formPill(for: form)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }

    private var quizPill: some View {
        Button(action: onQuiz) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Quiz (AI)")
                    .font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.accentColor.opacity(0.22)))
            .foregroundStyle(Color.accentColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Generate an AI quiz from this slide")
    }

    private func formPill(for form: SavedForm) -> some View {
        Button {
            onOpenForm(form)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                Text(form.label)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.green.opacity(0.22)))
            .foregroundStyle(Color.green)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open “\(form.label)”")
    }
}

/// Floating countdown badge anchored to the top-center of the presenter
/// window when a timer is running. Pulses red during the final-five
/// alert window so the audience can see the warning across the room.
/// The pulse is driven by an explicit Task so we can cancel it cleanly
/// the moment the timer hits zero (a `.repeatForever` SwiftUI animation
/// otherwise tends to linger past the trigger).
private struct TimerBadge: View {
    @ObservedObject var store: TimerStore

    @State private var pulseOn: Bool = false
    @State private var pulseTask: Task<Void, Never>?

    private var backgroundColor: Color {
        if store.isFinished { return Color.red.opacity(0.92) }
        if store.isInAlertWindow { return Color.red.opacity(0.85) }
        return Color.black.opacity(0.75)
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: store.isRunning ? "timer" : "pause.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white)
            Text(store.formatted)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Button { store.toggle() } label: {
                Image(systemName: store.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            Button { store.dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(
            Capsule().fill(backgroundColor)
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .scaleEffect(pulseOn ? 1.06 : 1.0)
        .opacity(pulseOn ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.4), value: pulseOn)
        .onChange(of: store.isInAlertWindow) { active in
            updatePulse(active: active)
        }
        .onAppear { updatePulse(active: store.isInAlertWindow) }
        .onDisappear {
            pulseTask?.cancel()
            pulseTask = nil
        }
    }

    private func updatePulse(active: Bool) {
        pulseTask?.cancel()
        pulseTask = nil
        guard active else {
            pulseOn = false
            return
        }
        pulseTask = Task { @MainActor in
            while !Task.isCancelled {
                pulseOn.toggle()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }
}
