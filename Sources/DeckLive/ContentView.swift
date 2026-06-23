import SwiftUI
import AppKit

struct ContentView: View {

    @EnvironmentObject var deckStore: DeckStore
    @State private var presenterController: PresenterWindowController?

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
                        onPageChanged: { deckStore.goToPDFPage($0) }
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
