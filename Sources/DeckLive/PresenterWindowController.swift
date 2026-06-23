import AppKit
import SwiftUI
import PDFKit

/// Manages the fullscreen presenter window: a borderless window sized to
/// cover an entire screen, hosting the SwiftUI PresenterView, with arrow
/// keys / space / escape / ⌥Q / ⌥W / ⌥T wired up for navigation and
/// presenter actions.
@MainActor
final class PresenterWindowController: NSWindowController {

    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private let deckStore: DeckStore
    private let quizStore = QuizStore()
    private let formStore = GoogleFormStore()
    private let timerStore = TimerStore()
    private let annotations = AnnotationStore()
    private let viewport = WhiteboardViewport()
    private let canvasSize: CGSize

    init(deckStore: DeckStore, document: PDFDocument, screen: NSScreen) {
        self.deckStore = deckStore
        self.canvasSize = screen.frame.size

        // PresenterWindow overrides canBecomeKey/canBecomeMain so the
        // borderless window can host first-responder text input (e.g.
        // the text annotation tool's TextField). The default NSWindow
        // with .borderless returns false for both, which silently breaks
        // every keyboard-driven UI inside the presenter.
        let window = PresenterWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let hostingView = NSHostingView(
            rootView: PresenterView(
                document: document,
                deckStore: deckStore,
                quizStore: quizStore,
                formStore: formStore,
                timerStore: timerStore,
                annotations: annotations,
                viewport: viewport,
                canvasSize: screen.frame.size
            )
        )
        hostingView.frame = screen.frame
        window.contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
        installScrollMonitor()
    }

    override func close() {
        removeKeyMonitor()
        removeScrollMonitor()
        super.close()
    }

    // MARK: - Scroll wheel (infinite whiteboard pan + cmd-scroll zoom)

    /// Catches scroll-wheel + trackpad-scroll events while the presenter
    /// window is up. On whiteboard slides:
    ///   - scroll without modifiers → pan (two-finger swipe / mouse wheel)
    ///   - ⌘ + scroll              → zoom (one full notch ≈ 5 %)
    /// On PDF slides the events fall through untouched so any built-in
    /// scroll behavior keeps working.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            guard self.deckStore.isCurrentSlideWhiteboard else { return event }

            if event.modifierFlags.contains(.command) {
                // Cmd + scroll = zoom.
                let step = CGFloat(event.scrollingDeltaY) * 0.01
                self.viewport.setZoom(self.viewport.zoom + step)
            } else {
                // Plain scroll = pan. Trackpad swipes already arrive in
                // screen points (deltas are inverted, so we negate).
                self.viewport.pan(by: CGSize(
                    width:  CGFloat(event.scrollingDeltaX),
                    height: CGFloat(event.scrollingDeltaY)
                ))
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
    }

    // MARK: - Keyboard navigation

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }

            // While any first-responder text field is editing (e.g. the
            // text annotation tool, or any TextField popover), let plain
            // typed characters go straight through to it — only intercept
            // navigation keys with a modifier. This keeps Option+key
            // shortcuts working without swallowing typing.
            let isTyping = self.window?.firstResponder is NSText
            if isTyping {
                // Esc lets the field commit/cancel via the normal
                // responder chain.
                if event.keyCode == 53 {
                    self.window?.makeFirstResponder(nil)
                    return event
                }
                // Only consume Option-modified shortcuts; let everything
                // else (letters, digits, deletion, etc.) reach the field.
                if event.modifierFlags.contains(.option),
                   self.handleOptionShortcuts(event) {
                    return nil
                }
                return event
            }

            // Form overlay takes top priority — only Esc dismisses it,
            // everything else is swallowed so taps inside the WebView
            // don't accidentally flip slides behind it.
            if self.formStore.isShowing {
                if event.keyCode == 53 {
                    self.formStore.hide()
                    return nil
                }
                return event
            }

            // Quiz overlay takes priority — when it's up, navigation keys
            // shouldn't accidentally flip slides hidden behind it.
            if self.quizStore.isVisible {
                return self.handleKeyDuringQuiz(event)
            }

            // ⌘V — paste image from clipboard onto the current slide.
            if event.keyCode == 9,
               event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.shift) {
                if self.pasteImageFromPasteboard() {
                    return nil
                }
            }

            // Action shortcuts all require the Option modifier so plain
            // letters don't fire accidentally while the presenter is
            // navigating or typing somewhere.
            if event.modifierFlags.contains(.option),
               self.handleOptionShortcuts(event) {
                return nil
            }

            switch event.keyCode {
            case 123, 126: // left / up arrow — previous slide
                self.deckStore.previousPage()
                return nil
            case 124, 125, 49: // right / down arrow, space — next slide
                self.deckStore.nextPage()
                return nil
            case 53: // escape — close presenter
                self.close()
                return nil
            default:
                return event
            }
        }
    }

    /// Returns true when the Option-modified shortcut was recognised and
    /// handled — caller swallows the event in that case.
    private func handleOptionShortcuts(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 12: // ⌥Q — open the quiz options popup (or replay cached)
            triggerQuiz()
            return true
        case 13: // ⌥W — insert a new whiteboard slide after current
            deckStore.insertWhiteboardAfterCurrent(canvasSize: canvasSize)
            return true
        case 17: // ⌥T — start / focus the countdown timer
            if timerStore.isVisible {
                timerStore.toggle()
            } else {
                timerStore.start(minutes: 5)
            }
            return true
        default:
            return false
        }
    }

    private func handleKeyDuringQuiz(_ event: NSEvent) -> NSEvent? {
        // Results screen has its own minimal keyboard surface — Esc to
        // close, anything else passes through.
        if quizStore.isResultsPhase {
            if event.keyCode == 53 {
                quizStore.dismiss()
                return nil
            }
            return nil
        }

        switch event.keyCode {
        case 53: // escape — dismiss the quiz card, stay on the current slide
            quizStore.dismiss()
            return nil

        case 49, 36: // space / return — reveal, then advance through the quiz
            if !quizStore.isCurrentRevealed {
                quizStore.revealCurrent()
            } else if quizStore.isOnLastQuestion {
                quizStore.finish()
            } else {
                quizStore.nextQuestion()
            }
            return nil

        case 124, 125: // right / down arrow — next question / finish on last
            if quizStore.isOnLastQuestion {
                quizStore.finish()
            } else {
                quizStore.nextQuestion()
            }
            return nil

        case 123, 126: // left / up arrow — previous question
            quizStore.previousQuestion()
            return nil

        default:
            return event
        }
    }

    private func triggerQuiz() {
        quizStore.triggerQuiz(using: deckStore)
    }

    /// Reads an image off NSPasteboard (raw image bytes or a `public.image`
    /// URL) and drops it onto the current slide as a draggable annotation.
    /// Returns true if anything was inserted — caller swallows the event.
    @discardableResult
    private func pasteImageFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        var image: NSImage?
        if let direct = NSImage(pasteboard: pb) {
            image = direct
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                  let url = urls.first,
                  let fromURL = NSImage(contentsOf: url) {
            image = fromURL
        }
        guard let image else { return false }
        annotations.insertImage(
            image,
            on: deckStore.currentAnnotationKey,
            canvasSize: canvasSize
        )
        return true
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}

/// Borderless presenter window that's still allowed to become the key /
/// main window so first-responder UI (TextField, anything keyboard-driven)
/// actually receives keystrokes.
private final class PresenterWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
