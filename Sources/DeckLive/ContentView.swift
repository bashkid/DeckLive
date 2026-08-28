import SwiftUI
import AppKit

struct ContentView: View {

    @EnvironmentObject var deckStore: DeckStore
    @State private var presenterController: PresenterWindowController?
    @StateObject private var zoomController = SlideZoomController()

    var body: some View {
        Group {
            if let document = deckStore.pdfDocument {
                HSplitView {
                    ThumbnailSidebar(
                        document: document,
                        selectedPDFPageIndex: deckStore.currentPDFPageIndex,
                        onSelect: { deckStore.goToPDFPage($0) }
                    )

                    SlideViewer(
                        document: document,
                        pdfPageIndex: deckStore.currentPDFPageIndex,
                        onPageChanged: { deckStore.goToPDFPage($0) },
                        zoomController: zoomController
                    )
                    .frame(minWidth: 500, minHeight: 400)
                }
            } else {
                emptyState
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    deckStore.presentOpenPanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }

                if deckStore.pdfDocument != nil {
                    Button {
                        startPresenting()
                    } label: {
                        Label("Present", systemImage: "play.fill")
                    }
                }

                Spacer()

                if deckStore.slideCount > 0 {
                    Button {
                        deckStore.previousPage()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(deckStore.currentPageIndex == 0)

                    Text("\(deckStore.currentPageIndex + 1) / \(deckStore.slideCount)")
                        .monospacedDigit()
                        .frame(minWidth: 60)

                    Button {
                        deckStore.nextPage()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(deckStore.currentPageIndex + 1 >= deckStore.slideCount)
                }

                if deckStore.pdfDocument != nil {
                    Spacer()

                    Button {
                        zoomController.zoomOut()
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("Zoom Out")

                    Button {
                        zoomController.zoomIn()
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("Zoom In")

                    Menu {
                        Button("Fit Page") { zoomController.fitPage() }
                        Button("Fit Width") { zoomController.fitWidth() }
                        Button("Actual Size") { zoomController.actualSize() }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Zoom to Fit")

                    Button {
                        zoomController.continuousScroll.toggle()
                    } label: {
                        Image(systemName: zoomController.continuousScroll
                              ? "rectangle.grid.1x2.fill"
                              : "rectangle.grid.1x2")
                    }
                    .help(zoomController.continuousScroll
                          ? "Continuous scrolling on — showing all pages"
                          : "Continuous scrolling off — showing one page at a time")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let message = deckStore.statusMessage {
                statusBanner(message)
            }
        }
        .navigationTitle(deckStore.sourceFileName ?? "DeckLive")
    }

    private func startPresenting() {
        guard let document = deckStore.pdfDocument, let screen = NSScreen.main else { return }
        let controller = PresenterWindowController(deckStore: deckStore, document: document, screen: screen)
        presenterController = controller
        controller.show()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Open a PDF or PowerPoint to get started")
                .font(.title3)
                .foregroundStyle(.secondary)

            Button("Open File…") {
                deckStore.presentOpenPanel()
            }
            .buttonStyle(.borderedProminent)

            if deckStore.isConverting {
                ProgressView("Converting…")
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .padding(10)
            .background(.regularMaterial)
            .cornerRadius(8)
            .padding()
            .transition(.move(edge: .bottom))
    }
}
