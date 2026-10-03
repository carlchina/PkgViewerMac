import AppKit
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

    /// PNG data for the given window, or nil if it cannot be captured.
    @MainActor
    static func png(of window: NSWindow?) -> Data? {
        guard let view = window?.contentView, view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }
        // The window must be on screen for its backing store to be valid.
        if let window = window, !window.isVisible { window.makeKeyAndOrderFront(nil) }
        // Let any in-flight layout settle so the capture is not a stale frame.
        window?.displayIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
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
