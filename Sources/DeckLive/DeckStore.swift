import Foundation
import PDFKit
import AppKit

/// Central app state. Owns the loaded deck (as a PDFDocument under the hood,
/// regardless of whether the source was a .pdf or a .pptx) and current position.
@MainActor
final class DeckStore: ObservableObject {

    @Published var pdfDocument: PDFDocument?
    @Published var currentPageIndex: Int = 0
    @Published var sourceFileName: String?
    @Published var isConverting: Bool = false
    @Published var isExporting: Bool = false
    @Published var statusMessage: String?

    /// URL the user actually picked (the original .pdf / .pptx, not the
    /// converted temp PDF). Used by the sidecar persistence layer so the
    /// quiz cache lives alongside the file the presenter recognizes.
    @Published private(set) var sourceURL: URL?

    /// Google Forms attached to this deck. Each form belongs to a specific
    /// slide (its `pageIndex`). A slide can own any number of forms.
    /// Persisted via the sidecar.
    @Published private(set) var savedForms: [SavedForm] = []

    /// Whiteboard slides inserted into the deck's slide order. Each has a
    /// unique negative `id` that doubles as its annotation storage key,
    /// plus the PDF page after which it sits. Persisted via the sidecar.
    @Published private(set) var whiteboardSlides: [WhiteboardSlide] = []

    /// Cache of quiz sets keyed by the 0-based last PDF page they were
    /// generated through. Lets us return the same questions the next time
    /// the presenter triggers a quiz with the same coverage instead of
    /// hitting the on-device model again. Cleared whenever a new deck is
    /// opened.
    private var quizCache: [Int: QuizSet] = [:]

    // MARK: - Slide order

    /// Number of slides in the combined order (PDF pages + whiteboards).
    var slideCount: Int { slideOrder.count }

    /// PDF page count alone — used when collecting slide text for the AI.
    var pdfPageCount: Int { pdfDocument?.pageCount ?? 0 }

    /// Combined slide order: PDF pages interleaved with the whiteboards
    /// the presenter inserted. A whiteboard with `insertAfterPDFPage = n`
    /// appears immediately after PDF page `n`; a value of `-1` places it
    /// before all PDF pages.
    var slideOrder: [SlideRef] {
        var result: [SlideRef] = []
        let pdfCount = pdfPageCount
        if pdfCount == 0 {
            for wb in whiteboardSlides { result.append(.whiteboard(id: wb.id)) }
            return result
        }
        for wb in whiteboardSlides where wb.insertAfterPDFPage == -1 {
            result.append(.whiteboard(id: wb.id))
        }
        for i in 0..<pdfCount {
            result.append(.pdf(pageIndex: i))
            for wb in whiteboardSlides where wb.insertAfterPDFPage == i {
                result.append(.whiteboard(id: wb.id))
            }
        }
        return result
    }

    /// The slide that's currently visible — either a PDF page or a
    /// whiteboard the presenter inserted.
    var currentSlide: SlideRef? {
        let order = slideOrder
        guard !order.isEmpty,
              currentPageIndex >= 0,
              currentPageIndex < order.count else { return nil }
        return order[currentPageIndex]
    }

    /// PDF page index of the current slide, if any. Nil while a whiteboard
    /// slide is on screen. Used by `SlideViewer` and quiz text extraction.
    var currentPDFPageIndex: Int? {
        if case .pdf(let i) = currentSlide { return i }
        return nil
    }

    /// Annotation storage key for the current slide. PDF slides use their
    /// 0-based page index; whiteboards use their negative `id`.
    var currentAnnotationKey: Int {
        switch currentSlide {
        case .pdf(let i): return i
        case .whiteboard(let id): return id
        case .none: return 0
        }
    }

    /// True when the currently visible slide is a whiteboard.
    var isCurrentSlideWhiteboard: Bool {
        if case .whiteboard = currentSlide { return true }
        return false
    }

    /// Legacy alias retained while we transition callers — equivalent to
    /// `slideCount`.
    var pageCount: Int { slideCount }

    // MARK: - Opening files

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Open a Slide Deck"
        panel.message = "Choose a PDF or PowerPoint (.pptx/.ppt) file"

        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { await self?.load(url: url) }
        }
    }

    func load(url: URL) async {
        statusMessage = nil
        sourceFileName = url.lastPathComponent
        sourceURL = url

        let ext = url.pathExtension.lowercased()

        if ext == "pdf" {
            openPDF(at: url)
            restoreSidecar()
            return
        }

        if ext == "pptx" || ext == "ppt" || ext == "key" {
            await convertAndOpen(url: url)
            restoreSidecar()
            return
        }

        statusMessage = "Unsupported file type: .\(ext)"
    }

    private func openPDF(at url: URL) {
        guard let doc = PDFDocument(url: url) else {
            statusMessage = "Couldn't open that PDF — it may be corrupted."
            return
        }
        pdfDocument = doc
        currentPageIndex = 0
        quizCache.removeAll()
        savedForms = []
        whiteboardSlides = []
    }

    /// Pulls cached quiz sets + form URL from the deck's sidecar (next to
    /// the file, or Application Support fallback) and applies them to the
    /// store. Safe to call after either the .pdf or .pptx load path
    /// finishes — it no-ops if there's no sidecar yet.
    private func restoreSidecar() {
        guard let url = sourceURL,
              let sidecar = QuizPersistence.load(for: url) else { return }
        quizCache = sidecar.quizzesByPage
        savedForms = sidecar.normalizedForms
        whiteboardSlides = sidecar.whiteboards ?? []
    }

    private func persistSidecar() {
        guard let url = sourceURL else { return }
        let sidecar = DeckSidecar(
            sourceFileName: sourceFileName,
            forms: savedForms,
            whiteboards: whiteboardSlides,
            quizzes: quizCache
        )
        QuizPersistence.save(sidecar, for: url)
    }

    // MARK: - Quiz cache

    func cachedQuizSet(throughPage: Int) -> QuizSet? {
        quizCache[throughPage]
    }

    func cacheQuizSet(_ set: QuizSet, throughPage: Int) {
        quizCache[throughPage] = set
        persistSidecar()
    }

    // MARK: - Google Forms

    /// Returns the forms attached to a specific slide (0-based index), in
    /// the order they were added.
    func forms(forPage page: Int) -> [SavedForm] {
        savedForms.filter { $0.pageIndex == page }
    }

    @discardableResult
    func addForm(label: String, url: String, pageIndex: Int) -> SavedForm? {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, URL(string: trimmedURL) != nil else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = trimmedLabel.isEmpty
            ? "Form \(forms(forPage: pageIndex).count + 1)"
            : trimmedLabel
        let form = SavedForm(label: resolvedLabel, url: trimmedURL, pageIndex: pageIndex)
        savedForms.append(form)
        persistSidecar()
        return form
    }

    func updateForm(id: UUID, label: String, url: String) {
        guard let idx = savedForms.firstIndex(where: { $0.id == id }) else { return }
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty, URL(string: trimmedURL) != nil {
            savedForms[idx].url = trimmedURL
        }
        if !trimmedLabel.isEmpty {
            savedForms[idx].label = trimmedLabel
        }
        persistSidecar()
    }

    func removeForm(id: UUID) {
        savedForms.removeAll { $0.id == id }
        persistSidecar()
    }

    // MARK: - PPTX → PDF conversion
    //
    // Preferred path: drive real Microsoft PowerPoint via AppleScript, since
    // it's the actual rendering engine and needs no extra install if Office
    // is already on the machine. Falls back to LibreOffice headless if
    // PowerPoint isn't found.

    private func convertAndOpen(url: URL) async {
        isConverting = true
        statusMessage = "Converting \(url.lastPathComponent)…"
        defer { isConverting = false }

        let outputDir = pickConversionFolder()

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            statusMessage = "Couldn't create a temp folder for conversion: \(error.localizedDescription)"
            return
        }

        let convertedName = url.deletingPathExtension().lastPathComponent + ".pdf"
        let convertedURL = outputDir.appendingPathComponent(convertedName)

        do {
            if Self.powerPointIsInstalled() {
                try await Self.convertWithPowerPoint(sourceURL: url, outputURL: convertedURL)
            } else if let sofficePath = Self.locateSoffice() {
                try await Self.runSoffice(sofficePath: sofficePath, sourceURL: url, outputDir: outputDir)
            } else {
                statusMessage = "Couldn't find Microsoft PowerPoint or LibreOffice to convert this file. " +
                    "Install LibreOffice (`brew install --cask libreoffice`) or open a PDF instead."
                return
            }
        } catch {
            statusMessage = "Conversion failed: \(error.localizedDescription)"
            return
        }

        guard FileManager.default.fileExists(atPath: convertedURL.path) else {
            statusMessage = "Conversion finished but the output PDF wasn't found."
            return
        }

        openPDF(at: convertedURL)
        statusMessage = nil
    }

    /// Returns a writable temp folder for the PPTX → PDF conversion.
    ///
    /// Primary location is `~/.decklive/conversions/<uuid>/` — the
    /// centralized DeckLive processing folder in the user's home. On
    /// the first PowerPoint conversion the user may see a one-time
    /// "Grant File Access" dialog because PowerPoint runs sandboxed
    /// and has no standing grant for `~/.decklive`; after they allow
    /// it once, subsequent conversions write there silently.
    ///
    /// We fall back to Office's own group container if `~/.decklive`
    /// can't be created, since that path is always writable by every
    /// Office app without prompting.
    private func pickConversionFolder() -> URL {
        let id = UUID().uuidString
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let storageRoot = home.appendingPathComponent(".decklive", isDirectory: true)
        let conversionsDir = storageRoot.appendingPathComponent("conversions", isDirectory: true)
        if (try? fm.createDirectory(at: conversionsDir, withIntermediateDirectories: true)) != nil,
           fm.isWritableFile(atPath: conversionsDir.path) {
            return conversionsDir.appendingPathComponent(id, isDirectory: true)
        }

        let officeGroupContainer = home
            .appendingPathComponent("Library/Group Containers/UBF8T346G9.Office", isDirectory: true)
        if fm.fileExists(atPath: officeGroupContainer.path),
           fm.isWritableFile(atPath: officeGroupContainer.path) {
            return officeGroupContainer
                .appendingPathComponent("DeckLive/conversions/\(id)", isDirectory: true)
        }

        return fm.temporaryDirectory.appendingPathComponent("DeckLive-\(id)", isDirectory: true)
    }

    // MARK: PowerPoint (AppleScript) path

    private static func powerPointIsInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Microsoft PowerPoint.app")
    }

    private static func convertWithPowerPoint(sourceURL: URL, outputURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try runPowerPointAppleScript(sourceURL: sourceURL, outputURL: outputURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs synchronously on a background queue — NSAppleScript itself is blocking.
    /// Tells real PowerPoint to open the file, export it as PDF, and close it
    /// again without prompting to save (so your original file is untouched).
    private static func runPowerPointAppleScript(sourceURL: URL, outputURL: URL) throws {
        let escapedSource = sourceURL.path.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedOutput = outputURL.path.replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
        tell application "Microsoft PowerPoint"
            launch
            open POSIX file "\(escapedSource)"
            set activePres to active presentation
            save activePres in (POSIX file "\(escapedOutput)") as save as PDF
            close active presentation saving no
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            throw NSError(
                domain: "DeckLive.Conversion",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't compile the PowerPoint AppleScript."]
            )
        }

        var errorDict: NSDictionary?
        script.executeAndReturnError(&errorDict)

        if let errorDict {
            let rawMessage = (errorDict[NSAppleScript.errorMessage] as? String)
                ?? "PowerPoint reported an unknown error while converting."
            // macOS denies the Apple Event with a -1743 / 1002 error code
            // when Automation permission hasn't been granted. Surface a
            // clearer fix path than the raw system string.
            let lowered = rawMessage.lowercased()
            let isPermission = lowered.contains("not authorized")
                || lowered.contains("apple events")
                || lowered.contains("permission")
            let message = isPermission
                ? """
                  DeckLive can't control PowerPoint yet. Open System Settings → \
                  Privacy & Security → Automation, find DeckLive in the list and \
                  toggle on "Microsoft PowerPoint", then try opening the file again. \
                  (Underlying error: \(rawMessage))
                  """
                : rawMessage
            throw NSError(
                domain: "DeckLive.Conversion",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    // MARK: LibreOffice (fallback) path

    /// Checks a handful of common install locations for LibreOffice's `soffice` binary.
    private static func locateSoffice() -> String? {
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    private static func runSoffice(sofficePath: String, sourceURL: URL, outputDir: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sofficePath)
            process.arguments = [
                "--headless",
                "--convert-to", "pdf",
                "--outdir", outputDir.path,
                sourceURL.path
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let log = String(data: data, encoding: .utf8) ?? "unknown error"
                    continuation.resume(throwing: NSError(
                        domain: "DeckLive.Conversion",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: log]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Navigation

    func nextPage() {
        guard currentPageIndex + 1 < slideCount else { return }
        currentPageIndex += 1
    }

    func previousPage() {
        guard currentPageIndex - 1 >= 0 else { return }
        currentPageIndex -= 1
    }

    func goToPage(_ index: Int) {
        guard index >= 0 && index < slideCount else { return }
        currentPageIndex = index
    }

    /// Jumps directly to a specific PDF page (in the unified slide order).
    /// Used by `SlideViewer` and `ThumbnailSidebar` so user-driven PDF
    /// page changes there don't accidentally land on a whiteboard slot.
    func goToPDFPage(_ pdfIndex: Int) {
        if let slot = slideOrder.firstIndex(of: .pdf(pageIndex: pdfIndex)) {
            currentPageIndex = slot
        }
    }

    // MARK: - Whiteboards

    /// Inserts a new whiteboard slide directly after the slide currently
    /// on screen and navigates to it. `canvasSize` records the screen-space
    /// canvas the strokes will be drawn against, so exports can render the
    /// whiteboard back out at the right dimensions.
    @discardableResult
    func insertWhiteboardAfterCurrent(canvasSize: CGSize? = nil) -> WhiteboardSlide {
        let order = slideOrder
        var afterPDFPage = -1
        if !order.isEmpty {
            for i in stride(from: min(currentPageIndex, order.count - 1), through: 0, by: -1) {
                if case .pdf(let p) = order[i] {
                    afterPDFPage = p
                    break
                }
            }
        }
        let nextID = (whiteboardSlides.map(\.id).min() ?? 0) - 1
        let board = WhiteboardSlide(
            id: nextID,
            insertAfterPDFPage: afterPDFPage,
            canvasSize: canvasSize
        )
        whiteboardSlides.append(board)
        if let slot = slideOrder.firstIndex(of: .whiteboard(id: nextID)) {
            currentPageIndex = slot
        }
        persistSidecar()
        return board
    }

    /// Removes the named whiteboard. If the deleted slide was on screen,
    /// the index is clamped so the next/previous slide takes over.
    func removeWhiteboard(id: Int) {
        let oldSlot = slideOrder.firstIndex(of: .whiteboard(id: id))
        whiteboardSlides.removeAll { $0.id == id }
        if let oldSlot {
            currentPageIndex = max(0, min(oldSlot - 1, max(0, slideCount - 1)))
        }
        persistSidecar()
    }

    /// Replaces the stored strokes for a whiteboard. The presenter calls
    /// this whenever a whiteboard's annotations change so the sidecar
    /// stays in sync.
    func updateWhiteboardStrokes(id: Int, strokes: [AnnotationStroke]) {
        guard let idx = whiteboardSlides.firstIndex(where: { $0.id == id }) else { return }
        whiteboardSlides[idx].strokes = strokes
        persistSidecar()
    }

    /// Removes the whiteboard slide that's currently on screen — used by
    /// the toolbar's **Remove Slide** action. The slide order shrinks and
    /// the index lands on the slot just before the removed whiteboard.
    func removeCurrentWhiteboard() {
        guard case .whiteboard(let id) = currentSlide else { return }
        removeWhiteboard(id: id)
    }

    // MARK: - Text extraction (PDF only)

    /// Plain-text content of the currently visible slide. Returns "" for
    /// whiteboard slides since they don't carry source text.
    func currentPageText() -> String {
        guard let pdfIdx = currentPDFPageIndex,
              let doc = pdfDocument,
              let page = doc.page(at: pdfIdx) else { return "" }
        return page.string ?? ""
    }

    /// Per-PDF-page text from page 0 up to and including the PDF page the
    /// presenter has shown most recently (whiteboard slides in between
    /// are skipped). Each entry's text is trimmed and capped so the
    /// combined prompt stays well within the on-device model's 4096-token
    /// context window even for long decks.
    func coveredSlidesText(
        perSlideCharCap: Int = 600,
        totalCharCap: Int = 6000
    ) -> [(pageNumber: Int, text: String)] {
        guard let doc = pdfDocument else { return [] }

        // Determine the highest PDF page index covered so far. If the
        // presenter is on a whiteboard, use the nearest preceding PDF
        // page (or 0 if there isn't one).
        let order = slideOrder
        var lastPDF = -1
        if !order.isEmpty {
            for i in 0...min(currentPageIndex, order.count - 1) {
                if case .pdf(let p) = order[i] {
                    lastPDF = max(lastPDF, p)
                }
            }
        }
        guard lastPDF >= 0 else { return [] }

        var collected: [(Int, String)] = []
        var runningTotal = 0

        for index in 0...lastPDF {
            guard let page = doc.page(at: index),
                  let rawText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawText.isEmpty else { continue }

            let cleaned = rawText
                .replacingOccurrences(of: "\n\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let snippet = cleaned.count > perSlideCharCap
                ? String(cleaned.prefix(perSlideCharCap)) + "…"
                : cleaned

            collected.append((index + 1, snippet))
            runningTotal += snippet.count

            while runningTotal > totalCharCap, collected.count > 1 {
                let dropped = collected.removeFirst()
                runningTotal -= dropped.1.count
            }
        }

        return collected
    }
}
