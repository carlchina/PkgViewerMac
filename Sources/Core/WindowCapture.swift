import AppKit
import CoreImage
import SwiftUI

/// Captures the app window as a PNG.
///
/// Uses `NSView.cacheDisplay(in:to:)`, which reads the window's real backing
/// store. That means the screenshot matches what is on screen — current scroll
/// offset, selected row, active tab — rather than re-rendering the view tree
/// from scratch, and unlike ScreenCaptureKit it needs no screen-recording
/// permission.
///
/// Only the window's content view is captured, so the title bar is not
/// included. A modal sheet is a separate window and is likewise excluded.
enum WindowCapture {

    /// Liquid glass watermark capsule badge for the bottom-left corner of screenshots.
    private struct WatermarkBadge: View {
        var body: some View {
            HStack(spacing: 9) {
                // Icon with subtle glass glow
                ZStack {
                    Circle()
                        .fill(Color(red: 0.22, green: 0.55, blue: 1.0).opacity(0.25))
                        .frame(width: 24, height: 24)
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.45, green: 0.78, blue: 1.0), Color(red: 0.18, green: 0.52, blue: 1.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(AppInfo.name)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .shadow(color: Color.black.opacity(0.6), radius: 2, y: 1)

                    Text("v\(AppInfo.version)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .shadow(color: Color.black.opacity(0.5), radius: 2, y: 1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.20),
                                Color(white: 0.12, opacity: 0.45),
                                Color(white: 0.05, opacity: 0.65)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                // Specular rim: crisp and bright along top curve, smoothly fading down
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                Gradient.Stop(color: Color.white.opacity(0.95), location: 0.0),
                                Gradient.Stop(color: Color.white.opacity(0.45), location: 0.25),
                                Gradient.Stop(color: Color.white.opacity(0.12), location: 0.65),
                                Gradient.Stop(color: Color.white.opacity(0.35), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.2
                    )
            )
            .overlay(
                // Soft inner highlight that hugs the upper rim
                Capsule()
                    .inset(by: 1.2)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.45), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
            .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
            .padding(10)
        }
    }

    /// Composes a liquid glass watermark badge in the bottom-left corner.
    @MainActor
    private static func addWatermark(to cgImage: CGImage, scale: CGFloat, logicalWidth: CGFloat, logicalHeight: CGFloat) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: WatermarkBadge())
        renderer.scale = scale
        guard let watermarkImg = renderer.nsImage else { return nil }

        let logicalSize = NSSize(width: logicalWidth, height: logicalHeight)
        let baseRep = NSBitmapImageRep(cgImage: cgImage)
        let baseNSImage = NSImage(size: logicalSize)
        baseNSImage.addRepresentation(baseRep)

        let output = NSImage(size: logicalSize)
        output.lockFocus()
        baseNSImage.draw(in: NSRect(origin: .zero, size: logicalSize))

        let margin: CGFloat = 16
        let drawRect = NSRect(x: margin, y: margin, width: watermarkImg.size.width, height: watermarkImg.size.height)
        watermarkImg.draw(in: drawRect)
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let finalRep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return finalRep
    }

    /// PNG data for the given window, or nil if it cannot be captured.
    /// Excludes the system title bar and navigation toolbar to produce a clean card image,
    /// and adds a frosted glass watermark in the bottom-left corner.
    @MainActor
    static func png(of window: NSWindow?) -> Data? {
        guard let window = window,
              let view = window.contentView,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return nil
        }
        // The window must be on screen for its backing store to be valid.
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        // Let any in-flight layout settle so the capture is not a stale frame.
        window.displayIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let cgImage = rep.cgImage else {
            return rep.representation(using: .png, properties: [:])
        }

        // Determine top crop offset in points.
        // SharedModel.contentTopOffset is the exact global minY where the main content starts,
        // which cleanly excludes the window title bar, custom toolbar, and navigation tab strip.
        let cropTopPoints = SharedModel.contentTopOffset > 0 ? SharedModel.contentTopOffset : 112
        let scale = CGFloat(cgImage.height) / view.bounds.height
        let cropPixels = round(cropTopPoints * scale)
        let targetHeight = CGFloat(cgImage.height) - cropPixels

        guard cropPixels > 0, targetHeight > 0 else {
            return rep.representation(using: .png, properties: [:])
        }

        // In CGImage coordinates from cacheDisplay, y=0 is at the top of the window.
        let cropRect = CGRect(x: 0, y: cropPixels, width: CGFloat(cgImage.width), height: targetHeight)
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            return rep.representation(using: .png, properties: [:])
        }

        let logicalWidth = view.bounds.width
        let logicalHeight = targetHeight / scale

        if let watermarkedRep = addWatermark(to: croppedCGImage, scale: scale, logicalWidth: logicalWidth, logicalHeight: logicalHeight) {
            return watermarkedRep.representation(using: .png, properties: [:])
        }

        let croppedRep = NSBitmapImageRep(cgImage: croppedCGImage)
        croppedRep.size = NSSize(width: logicalWidth, height: logicalHeight)
        return croppedRep.representation(using: .png, properties: [:])
    }

    /// PNG data for the frontmost window belonging to this app.
    @MainActor
    static func pngOfFrontmostWindow() -> Data? {
        png(of: frontmostWindow())
    }

    /// The window a screenshot should target: whatever the user is looking at.
    @MainActor
    static func frontmostWindow() -> NSWindow? {
        let own = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        if let key = own.first(where: { $0.isKeyWindow }) { return key }
        if let main = own.first(where: { $0.isMainWindow }) { return main }
        // Skip the tiny menu-utility windows some apps install.
        let sized = own.filter { $0.frame.width > 200 && $0.frame.height > 200 }
        return sized.first ?? own.first
    }

    /// A sensible default filename: "<name> - 2026-10-03 14.05.png".
    @MainActor
    static func suggestedFilename(for title: String?) -> String {
        let stamp = timestamp()
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let safe = Fmt.sanitizeFilenamePart(t, limit: 80)
            return "\(safe) - \(stamp).png"
        }
        return "PKG Viewer \(stamp).png"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
