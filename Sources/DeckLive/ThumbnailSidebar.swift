import SwiftUI
import PDFKit

/// Page thumbnails for the original PDF deck. The editing window only
/// exposes PDF pages; whiteboards are presenter-time additions and don't
/// appear here.
struct ThumbnailSidebar: View {

    let document: PDFDocument
    /// PDF page index of the slide that's currently active in the deck
    /// store, or nil when a whiteboard slide is on screen.
    let selectedPDFPageIndex: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(0..<document.pageCount, id: \.self) { index in
                    ThumbnailCell(
                        document: document,
                        index: index,
                        isSelected: index == selectedPDFPageIndex
                    )
                    .onTapGesture {
                        onSelect(index)
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 160)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ThumbnailCell: View {
    let document: PDFDocument
    let index: Int
    let isSelected: Bool

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.05))
                    .aspectRatio(16/9, contentMode: .fit)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            Text("\(index + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task {
            await renderThumbnail()
        }
    }

    private func renderThumbnail() async {
        guard let page = document.page(at: index) else { return }
        let size = CGSize(width: 140, height: 90)
        let thumb = page.thumbnail(of: size, for: .mediaBox)
        await MainActor.run { self.image = thumb }
    }
}
