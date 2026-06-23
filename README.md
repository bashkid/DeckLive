# DeckLive — Phase 1: Core Viewer

A standalone Mac app that opens **PDF** and **PowerPoint (.pptx/.ppt)** files
and displays them as a slide deck with thumbnail navigation. This is the
foundation the later phases (presenter mode, drawing, AI quizzes, live
polls) will build on top of.

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15 or later
- Microsoft PowerPoint (you've got this via your 365 subscription) — used
  automatically in the background to convert `.pptx`/`.ppt` files to PDF
  for rendering. PDFs need nothing extra.
  - If PowerPoint isn't found, the app falls back to LibreOffice headless
    if you have it installed (`brew install --cask libreoffice`).

### One-time permission prompt

The first time you open a `.pptx`, macOS will ask you to grant DeckLive
permission to control PowerPoint via Automation (this is how it tells
PowerPoint to export a PDF in the background). Click **OK** — without it,
PPTX conversion will silently fail. You can manage this later under
**System Settings → Privacy & Security → Automation**.

## Install as a Mac app (.dmg)

Two scripts in `scripts/` build a redistributable, double-clickable Mac
app from the source:

```bash
bash scripts/build-app.sh    # → dist/DeckLive.app   (universal, ad-hoc signed)
bash scripts/build-dmg.sh    # → dist/DeckLive-1.0.0.dmg
```

What `build-app.sh` does:

1. Pins the Swift toolchain to Xcode's (Command-Line-Tools' Swift ships
   without the FoundationModels macro plugins the AI quiz module needs).
2. Builds a **universal arm64 + x86_64** release binary.
3. Pads `Sources/Images/decklive_logo.png` onto a 1024×1024 canvas with
   `sips`, generates the standard macOS icon set (16…1024 @1×/@2×),
   compiles it with `iconutil` → `AppIcon.icns`.
4. Lays out `dist/DeckLive.app/{Contents/MacOS,Contents/Resources}/`,
   copies the binary in, writes a complete `Info.plist` (icon, bundle
   identifier, document types for PDF and PowerPoint, min macOS 13).
5. Ad-hoc signs the bundle with `codesign --force --deep --sign -`.

`build-dmg.sh` then stages `DeckLive.app` + a `/Applications` symlink
and uses `hdiutil create` to produce a compressed disk image.

### Installing

1. Open `dist/DeckLive-1.0.0.dmg`.
2. Drag **DeckLive** to **Applications**.
3. Eject, then launch from Launchpad.
4. macOS will prompt "DeckLive is an app downloaded from the internet —
   open?" (because of ad-hoc signing rather than a Developer ID). Click
   Open. From then on it launches normally.

The icon you see in the Dock and Launchpad is the supplied logo, padded
onto a white square.

## How to open and run this project

1. Unzip the project folder.
2. Open **Xcode** → `File` → `Open…` → select the `DeckLive` folder
   (Xcode reads `Package.swift` directly, no `.xcodeproj` needed).
3. Wait a moment for Xcode to resolve the package.
4. At the top of the Xcode window, make sure the run target is set to
   **"My Mac"**.
5. Press `Cmd + R` to build and run.
6. Use `File → Open PDF or PowerPoint…` (`Cmd+O`) or the toolbar **Open**
   button to load a deck.

If you'd rather use the terminal instead of Xcode's UI:
```
cd DeckLive
swift run
```

## What's in this phase

- `DeckLiveApp.swift` — app entry point, menu commands, AppDelegate fix for
  window activation
- `DeckStore.swift` — file opening, PPTX→PDF conversion (PowerPoint via
  AppleScript, LibreOffice fallback), page navigation state
- `SlideViewer.swift` — renders the current slide in the main window using
  PDFKit
- `ThumbnailSidebar.swift` — scrollable thumbnail strip for jumping
  between slides
- `ContentView.swift` — toolbar + layout tying it together, including the
  new **Present** button
- `SlideImageRenderer.swift` — renders a page to a high-resolution image
  for crisp fullscreen display
- `PresenterView.swift` — the actual fullscreen slide view (click to
  advance)
- `PresenterWindowController.swift` — borderless fullscreen window +
  keyboard navigation (← → ↑ ↓ / space / escape)

## Trying Phase 2

Open a deck, click **Present** (▶) in the toolbar. You should get a
black, edge-to-edge fullscreen window on your main display showing the
current slide. Try:
- Left/right arrow keys, up/down arrow keys, and space bar to navigate
- Clicking anywhere on the slide to advance
- Escape to exit back to the main window

## A note on this code

I wrote this without being able to compile it myself (my environment can't
build macOS apps), so treat it as a strong first draft rather than
guaranteed-perfect code. If Xcode flags an error when you build, paste the
error message back to me and I'll fix it immediately — that's a normal
part of this kind of back-and-forth.

## What's next (Phase 3)

A drawing/annotation layer on top of the presenter view — pens,
highlighters, and an eraser, so you can mark up slides live while
presenting, the same way ClassPoint's whiteboard tools work.

Let me know once you've got this building and running, and we'll move on.
