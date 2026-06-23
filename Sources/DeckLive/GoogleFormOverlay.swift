import SwiftUI
import WebKit
import CoreImage.CIFilterBuiltins
import AppKit

/// Full-screen overlay that embeds a Google Form (or any URL the user
/// pasted) in a WKWebView for in-presentation use, with a side panel
/// showing a QR code of the form URL so students can scan with their
/// phones and answer from their own device.
struct GoogleFormOverlay: View {

    let form: SavedForm
    let url: URL
    let onClose: () -> Void

    /// The original URL stored on the form (without `embedded=true`), which
    /// is what we encode into the QR — students should land on the regular
    /// form, not the embedded variant.
    private var shareURL: URL? {
        URL(string: form.url)
    }

    private var qrImage: NSImage? {
        guard let raw = shareURL?.absoluteString ?? URL(string: form.url)?.absoluteString else { return nil }
        return Self.makeQRCode(from: raw, size: 360)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { /* swallow */ }

            VStack(spacing: 0) {
                header
                HStack(spacing: 16) {
                    FormWebView(url: url)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    qrPanel
                        .frame(width: 420)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 1400, maxHeight: 860)
        }
        .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(form.label, systemImage: "doc.text.fill")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            Button {
                if let openable = sanitized(url) {
                    NSWorkspace.shared.open(openable)
                }
            } label: {
                Label("Open in browser", systemImage: "arrow.up.right.square")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Close form (Esc)")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }

    private var qrPanel: some View {
        VStack(spacing: 14) {
            Text("Scan to attempt on phone")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 18)

            if let qrImage {
                Image(nsImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 340, height: 340)
                    .padding(10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 340, height: 340)
                    .overlay(
                        Text("QR unavailable")
                            .foregroundStyle(.white.opacity(0.6))
                    )
            }

            Text(form.url)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(form.url, forType: .string)
            } label: {
                Label("Copy link", systemImage: "doc.on.doc")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .padding(.bottom, 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    /// When opening externally, strip the `embedded=true` query so the
    /// user gets the normal Google Forms UI in their browser.
    private func sanitized(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = components.queryItems?.filter { $0.name != "embedded" }
        return components.url
    }

    /// Generates a crisp QR code image using Core Image's built-in
    /// generator. Returns nil if the input is empty or generation fails.
    static func makeQRCode(from string: String, size: CGFloat = 240) -> NSImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }

        let scale = size / outputImage.extent.width
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Minimal SwiftUI wrapper around WKWebView. Reloads when the URL changes.
private struct FormWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url {
            view.load(URLRequest(url: url))
        }
    }
}
