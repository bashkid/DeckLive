import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Exports the unified deck (PDF pages interleaved with whiteboard
/// slides) to a single PDF or PowerPoint (.pptx) file. The PDF path uses
/// PDFKit directly; the PPTX path writes a minimal but valid Office Open
/// XML directory and zips it with `/usr/bin/zip` (no third-party deps).
enum DeckExporter {

    enum ExportError: LocalizedError {
        case noDocument
        case writeFailed(String)
        case renderFailed(String)
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDocument:           return "Open a deck before exporting."
            case .writeFailed(let m):   return "Couldn't write the export file: \(m)"
            case .renderFailed(let m):  return "Couldn't render a slide for export: \(m)"
            case .zipFailed(let m):     return "PowerPoint export failed during zip: \(m)"
            }
        }
    }

    // MARK: - PDF export

    /// Builds a new `PDFDocument` from the deck's full slide order (PDF
    /// pages first, then any whiteboard slides interleaved in their
    /// inserted positions) and writes it to `outputURL`.
    @MainActor
    static func exportPDF(
        deckStore: DeckStore,
        document: PDFDocument,
        to outputURL: URL
    ) throws {
        let order = deckStore.slideOrder
        guard !order.isEmpty else { throw ExportError.noDocument }

        let newDoc = PDFDocument()

        for (index, ref) in order.enumerated() {
            let page: PDFPage?
            switch ref {
            case .pdf(let i):
                // Source pages are inserted at their own native size.
                page = document.page(at: i)?.copy() as? PDFPage
            case .whiteboard(let id):
                // Whiteboards must be rendered at the canvas size the
                // strokes were captured in — rendering them at the
                // source PDF's smaller page size would clip every
                // stroke whose coordinates exceeded the page bounds.
                guard let board = deckStore.whiteboardSlides
                    .first(where: { $0.id == id }) else {
                    throw ExportError.renderFailed("Whiteboard \(id) is missing.")
                }
                let renderSize = whiteboardRenderSize(for: board)
                guard let image = renderWhiteboard(board, size: renderSize) else {
                    throw ExportError.renderFailed("Whiteboard \(id) couldn't be rasterized.")
                }
                page = PDFPage(image: image)
            }
            guard let page else { throw ExportError.renderFailed("Slide \(index + 1) failed.") }
            newDoc.insert(page, at: newDoc.pageCount)
        }

        guard newDoc.write(to: outputURL) else {
            throw ExportError.writeFailed("PDFKit refused to write \(outputURL.lastPathComponent).")
        }
    }

    /// Picks a sensible rasterization size for a whiteboard. Falls back to
    /// 1920×1080 if no canvas size was captured (older sidecars).
    private static func whiteboardRenderSize(for board: WhiteboardSlide) -> CGSize {
        if let size = board.canvasSize,
           size.width >= 100, size.height >= 100 {
            return size
        }
        return CGSize(width: 1920, height: 1080)
    }

    // MARK: - PPTX export

    /// 914,400 EMU = 1 inch — PPTX dimensions are expressed in EMU.
    private static let emuPerInch: Int = 914_400
    /// Standard slide height (7.5 in). The width is derived from the
    /// source PDF's aspect ratio so exported decks match the original
    /// presentation (16:9, 4:3, A4, etc.) instead of always defaulting
    /// to 10×7.5.
    private static let pptxSlideHeightEMU: Int = 6_858_000

    /// Picks the aspect ratio (width/height) to use for an export.
    /// Samples the first PDF page's media box; falls back to 16:9 if
    /// there are no PDF pages.
    private static func sourceAspect(for document: PDFDocument) -> CGFloat {
        for i in 0..<document.pageCount {
            if let page = document.page(at: i) {
                let bounds = page.bounds(for: .mediaBox)
                if bounds.width > 0, bounds.height > 0 {
                    return bounds.width / bounds.height
                }
            }
        }
        return 16.0 / 9.0
    }

    /// Pixel size we rasterize each slide at, fixed to ~1080 px tall and
    /// matched to the source aspect ratio so the saved PNGs aren't
    /// stretched/letterboxed.
    private static func pptxPixelSize(for aspect: CGFloat) -> CGSize {
        let height: CGFloat = 1080
        let width = (height * aspect).rounded()
        return CGSize(width: width, height: height)
    }

    private static func pptxSlideSizeEMU(for aspect: CGFloat) -> (width: Int, height: Int) {
        let height = pptxSlideHeightEMU
        let width = Int((CGFloat(height) * aspect).rounded())
        return (width, height)
    }

    /// Builds a minimal valid PPTX (Office Open XML) archive in which each
    /// deck slide is a single full-bleed image. PowerPoint, Keynote, and
    /// Google Slides all open these. The archive is laid out in a temp
    /// directory and zipped with `/usr/bin/zip`.
    @MainActor
    static func exportPPTX(
        deckStore: DeckStore,
        document: PDFDocument,
        to outputURL: URL
    ) async throws {
        let order = deckStore.slideOrder
        guard !order.isEmpty else { throw ExportError.noDocument }

        let aspect = sourceAspect(for: document)
        let pixelSize = pptxPixelSize(for: aspect)
        let slideEMU = pptxSlideSizeEMU(for: aspect)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeckLive-PPTX-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Materialize every slide as a PNG inside ppt/media/.
        var imageFilenames: [String] = []
        for (idx, ref) in order.enumerated() {
            let image: NSImage
            switch ref {
            case .pdf(let i):
                guard let page = document.page(at: i),
                      let rendered = renderPDFPage(page, size: pixelSize) else {
                    throw ExportError.renderFailed("PDF page \(i + 1) failed.")
                }
                image = rendered
            case .whiteboard(let id):
                guard let board = deckStore.whiteboardSlides.first(where: { $0.id == id }),
                      let rendered = renderWhiteboard(board, size: pixelSize) else {
                    throw ExportError.renderFailed("Whiteboard slide failed to rasterize.")
                }
                image = rendered
            }

            let filename = "image\(idx + 1).png"
            let mediaDir = workDir.appendingPathComponent("ppt/media", isDirectory: true)
            try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            let pngURL = mediaDir.appendingPathComponent(filename)
            guard let pngData = pngData(from: image) else {
                throw ExportError.renderFailed("Couldn't encode slide \(idx + 1) as PNG.")
            }
            try pngData.write(to: pngURL)
            imageFilenames.append(filename)
        }

        // Write all the OOXML scaffolding.
        try writePPTXScaffolding(
            in: workDir,
            slideCount: order.count,
            imageFilenames: imageFilenames,
            slideWidthEMU: slideEMU.width,
            slideHeightEMU: slideEMU.height
        )

        // Zip the work directory into outputURL.
        try await zipDirectoryContents(at: workDir, into: outputURL)
    }

    // MARK: - Slide rasterization

    /// Renders a PDF page to a high-quality NSImage at the requested size.
    @MainActor
    private static func renderPDFPage(_ page: PDFPage, size: CGSize) -> NSImage? {
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            // Fill the background black so letterboxing matches the
            // presenter's look.
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(rect)

            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else {
                ctx.restoreGState()
                return true
            }
            let scale = min(rect.width / bounds.width, rect.height / bounds.height)
            let dx = (rect.width - bounds.width * scale) / 2
            let dy = (rect.height - bounds.height * scale) / 2
            ctx.translateBy(x: dx, y: dy)
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            return true
        }
        return image
    }

    /// Renders a whiteboard slide (background + grid + strokes) into an
    /// NSImage via SwiftUI's `ImageRenderer`.
    @MainActor
    static func renderWhiteboard(_ board: WhiteboardSlide, size: CGSize) -> NSImage? {
        let view = WhiteboardExportView(strokes: board.strokes)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = .init(size)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - PPTX scaffolding

    /// Writes every XML / rels file the OOXML reader expects, into the
    /// directory layout zip will eventually wrap up. Per-slide files are
    /// generated in a loop; everything else is a fixed template.
    private static func writePPTXScaffolding(
        in workDir: URL,
        slideCount: Int,
        imageFilenames: [String],
        slideWidthEMU: Int,
        slideHeightEMU: Int
    ) throws {
        let fm = FileManager.default

        // Directories
        let dirs = [
            "_rels",
            "ppt",
            "ppt/_rels",
            "ppt/slides",
            "ppt/slides/_rels",
            "ppt/slideLayouts",
            "ppt/slideLayouts/_rels",
            "ppt/slideMasters",
            "ppt/slideMasters/_rels",
            "ppt/theme",
            "ppt/media"
        ]
        for d in dirs {
            try fm.createDirectory(
                at: workDir.appendingPathComponent(d, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        // [Content_Types].xml — declare every part's MIME type.
        let slideTypes = (1...slideCount).map { i in
            "<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }.joined()
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        \(slideTypes)
        </Types>
        """
        try contentTypes.write(
            to: workDir.appendingPathComponent("[Content_Types].xml"),
            atomically: true,
            encoding: .utf8
        )

        // _rels/.rels — root relationships, points at presentation.xml.
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        </Relationships>
        """
        try rootRels.write(
            to: workDir.appendingPathComponent("_rels/.rels"),
            atomically: true,
            encoding: .utf8
        )

        // ppt/_rels/presentation.xml.rels — links presentation to master,
        // layout, and every slide.
        var presRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
        """
        for i in 1...slideCount {
            presRels += "<Relationship Id=\"rId\(2 + i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(i).xml\"/>"
        }
        presRels += "</Relationships>"
        try presRels.write(
            to: workDir.appendingPathComponent("ppt/_rels/presentation.xml.rels"),
            atomically: true,
            encoding: .utf8
        )

        // ppt/presentation.xml — slide list + slide size.
        var sldIdList = ""
        for i in 1...slideCount {
            sldIdList += "<p:sldId id=\"\(255 + i)\" r:id=\"rId\(2 + i)\"/>"
        }
        let presXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" saveSubsetFonts="1">
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:sldIdLst>\(sldIdList)</p:sldIdLst>
        <p:sldSz cx="\(slideWidthEMU)" cy="\(slideHeightEMU)"/>
        <p:notesSz cx="\(slideHeightEMU)" cy="\(slideWidthEMU)"/>
        </p:presentation>
        """
        try presXML.write(
            to: workDir.appendingPathComponent("ppt/presentation.xml"),
            atomically: true,
            encoding: .utf8
        )

        // Minimal theme.
        let theme = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">
        <a:themeElements>
        <a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>
        <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>
        <a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="9525" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="9525" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="9525" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>
        </a:themeElements>
        </a:theme>
        """
        try theme.write(
            to: workDir.appendingPathComponent("ppt/theme/theme1.xml"),
            atomically: true,
            encoding: .utf8
        )

        // Slide master.
        let master = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>
        <p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree>
        </p:cSld>
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        </p:sldMaster>
        """
        try master.write(
            to: workDir.appendingPathComponent("ppt/slideMasters/slideMaster1.xml"),
            atomically: true,
            encoding: .utf8
        )

        let masterRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """
        try masterRels.write(
            to: workDir.appendingPathComponent("ppt/slideMasters/_rels/slideMaster1.xml.rels"),
            atomically: true,
            encoding: .utf8
        )

        // Single blank slide layout.
        let layout = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
        <p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>
        </p:sldLayout>
        """
        try layout.write(
            to: workDir.appendingPathComponent("ppt/slideLayouts/slideLayout1.xml"),
            atomically: true,
            encoding: .utf8
        )

        let layoutRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """
        try layoutRels.write(
            to: workDir.appendingPathComponent("ppt/slideLayouts/_rels/slideLayout1.xml.rels"),
            atomically: true,
            encoding: .utf8
        )

        // One slide XML per image, each containing a full-bleed picture.
        for i in 1...slideCount {
            let slideXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
            <p:cSld><p:spTree>
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
            <p:pic>
            <p:nvPicPr><p:cNvPr id="2" name="Picture \(i)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
            <p:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
            <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(slideWidthEMU)" cy="\(slideHeightEMU)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
            </p:pic>
            </p:spTree></p:cSld>
            </p:sld>
            """
            try slideXML.write(
                to: workDir.appendingPathComponent("ppt/slides/slide\(i).xml"),
                atomically: true,
                encoding: .utf8
            )

            let slideRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/\(imageFilenames[i - 1])"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
            </Relationships>
            """
            try slideRels.write(
                to: workDir.appendingPathComponent("ppt/slides/_rels/slide\(i).xml.rels"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /// Zips the contents of `workDir` into `outputURL` using /usr/bin/zip.
    /// (PPTX is just a ZIP of the OOXML directory structure.)
    private static func zipDirectoryContents(
        at workDir: URL,
        into outputURL: URL
    ) async throws {
        // Remove an existing output so zip writes cleanly.
        try? FileManager.default.removeItem(at: outputURL)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.launchPath = "/usr/bin/zip"
                process.arguments = ["-r", "-X", outputURL.path, "."]
                process.currentDirectoryURL = workDir
                let errPipe = Pipe()
                process.standardError = errPipe
                process.standardOutput = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let stderrData = try? errPipe.fileHandleForReading.readToEnd()
                        let msg = stderrData.flatMap { String(data: $0, encoding: .utf8) }
                            ?? "zip exited with status \(process.terminationStatus)"
                        continuation.resume(throwing: ExportError.zipFailed(msg))
                        return
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: ExportError.zipFailed(error.localizedDescription))
                }
            }
        }
    }
}

// MARK: - Whiteboard export rendering

/// A read-only SwiftUI rendering of a whiteboard slide used by the
/// exporter. Mirrors `PresenterView`'s whiteboard backdrop (off-white
/// background + light grid) and draws every stored stroke using the same
/// path logic as `AnnotationCanvas`.
struct WhiteboardExportView: View {
    let strokes: [AnnotationStroke]

    var body: some View {
        Canvas { context, size in
            // Off-white background.
            var bg = Path()
            bg.addRect(CGRect(origin: .zero, size: size))
            context.fill(bg, with: .color(Color(white: 0.97)))

            // Light grid.
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

            // Strokes — pen, shapes, text, etc.
            for stroke in strokes {
                StrokeRenderer.draw(stroke, in: &context)
            }
        }
    }
}

/// Shared, read-only stroke drawing used by both the live presenter
/// canvas (via duplication in `AnnotationCanvas`) and the exporter's
/// `WhiteboardExportView`. Kept as a free helper so we don't drag in
/// gesture / state machinery just to redraw saved annotations.
enum StrokeRenderer {
    static func draw(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
        guard stroke.tool.producesStroke, !stroke.points.isEmpty else { return }

        switch stroke.tool {
        case .pen, .highlighter:
            drawFreehand(stroke, in: &context)
        case .line:
            guard stroke.points.count >= 2 else { return }
            var p = Path()
            p.move(to: stroke.points[0])
            p.addLine(to: stroke.points[1])
            drawStroked(p, stroke: stroke, in: &context)
        case .arrow:
            guard stroke.points.count >= 2 else { return }
            drawArrow(stroke, in: &context)
        case .rectangle:
            var p = Path()
            p.addRect(stroke.shapeRect)
            drawShape(p, stroke: stroke, in: &context)
        case .ellipse:
            var p = Path()
            p.addEllipse(in: stroke.shapeRect)
            drawShape(p, stroke: stroke, in: &context)
        case .text:
            drawText(stroke, in: &context)
        case .image:
            drawImage(stroke, in: &context)
        case .pointer, .eraser, .brushEraser, .selectorRect, .selectorLasso:
            return
        }
    }

    private static func drawImage(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
        guard stroke.points.count >= 2,
              let data = stroke.imageData,
              let nsImage = NSImage(data: data) else { return }
        let resolved = context.resolve(Image(nsImage: nsImage))
        context.draw(resolved, in: stroke.shapeRect)
    }

    private static func drawFreehand(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
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

    private static func drawStroked(_ path: Path, stroke: AnnotationStroke, in context: inout GraphicsContext) {
        let style = StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
        context.drawLayer { layer in
            layer.opacity = stroke.opacity
            layer.stroke(path, with: .color(stroke.color), style: style)
        }
    }

    private static func drawShape(_ path: Path, stroke: AnnotationStroke, in context: inout GraphicsContext) {
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

    private static func drawArrow(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
        let a = stroke.points[0], b = stroke.points[1]
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }

        let headLength = max(stroke.width * 4, 14)
        let headAngle: CGFloat = .pi / 6
        let theta = atan2(dy, dx)

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

    private static func drawText(_ stroke: AnnotationStroke, in context: inout GraphicsContext) {
        guard let text = stroke.text, !text.isEmpty, let anchor = stroke.points.first else { return }
        var resolved = context.resolve(
            Text(text).font(.system(size: stroke.fontSize, weight: .semibold))
        )
        resolved.shading = .color(stroke.color)
        context.draw(resolved, at: anchor, anchor: .topLeading)
    }
}
