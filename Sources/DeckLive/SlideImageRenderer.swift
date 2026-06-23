import PDFKit
import AppKit

/// Renders a PDFPage into a bitmap at a higher resolution than its native
/// size, so it looks sharp blown up to fill an external display.
struct SlideImageRenderer {

    static func render(page: PDFPage, scale: CGFloat = 3.0) -> NSImage {
        let pageRect = page.bounds(for: .mediaBox)
        let outputSize = CGSize(
            width: max(pageRect.width, 1) * scale,
            height: max(pageRect.height, 1) * scale
        )

        return NSImage(size: outputSize, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: outputSize))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            return true
        }
    }
}
