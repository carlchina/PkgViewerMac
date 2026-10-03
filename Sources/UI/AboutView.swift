import SwiftUI
import AppKit

// MARK: - About

/// The About window, shown from the application menu.
///
/// A plain sheet-free `NSWindow` rather than `WindowGroup`: an About box is
/// singleton by nature, and SwiftUI would otherwise allow a second copy.
struct AboutView: View {
    @EnvironmentObject private var l10n: L10n
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                icon
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppInfo.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(l10n.t("about.version", AppInfo.versionWithBuild))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(20)

            Divider().overlay(Theme.border)

            VStack(alignment: .leading, spacing: 10) {
                Text(l10n.t("about.blurb"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(l10n.t("about.formats"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                // Attribution is two lines on purpose: the original project and
                // the macOS port are separate claims, and merging them (as a
                // single "native port of X" line) obscures who did what.
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.t("about.credit"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(l10n.t("about.portAuthor"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().overlay(Theme.border)

            HStack {
                Spacer()
                Button(l10n.t("about.ok")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.regular)
            }
            .padding(16)
        }
        .frame(width: 420)
        .background(Theme.bg)
    }

    /// The app icon from the bundle, falling back to a drawn box so the window
    /// still looks right if the icon resource is ever missing.
    @ViewBuilder
    private var icon: some View {
        if let img = NSApp.applicationIconImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.panelHi)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.accent)
                )
        }
    }

    /// Show the About window, centring it on screen.
    ///
    /// The `L10n` instance is injected here because the hosting view is built
    /// outside the scene, so it never inherits the environment object.
    @MainActor
    static func show(_ l10n: L10n) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = l10n.t("about.title")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView().environmentObject(l10n))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
