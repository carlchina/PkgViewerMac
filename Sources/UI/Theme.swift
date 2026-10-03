import SwiftUI

// MARK: - Theme

enum Theme {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let panelHi = Color(red: 0.15, green: 0.15, blue: 0.17)
    static let border = Color.white.opacity(0.10)
    static let accent = Color(red: 0.35, green: 0.62, blue: 0.98)
    static let ok = Color(red: 0.30, green: 0.78, blue: 0.53)
    static let warn = Color(red: 0.95, green: 0.68, blue: 0.27)
    static let textDim = Color.white.opacity(0.55)
    /// Primary foreground, matching the original's #f1f3f8.
    static let text = Color(red: 0.945, green: 0.953, blue: 0.973)
}



// MARK: - Small building blocks

struct SpecRow: View {
    let key: String
    let value: String
    var mono = false
    /// Set when `key` is a metadata label the parsers emit, so it can be
    /// translated. Raw SFO/JSON keys pass through untouched.
    ///
    /// Only the *label* is ever translated. The value is the package's own
    /// data — `debug`, `Standard`, `paid` — and showing it verbatim keeps this
    /// pane consistent with the file itself, the CLI output and `copyInfo`.
    var localize = true

    @EnvironmentObject private var l10n: L10n

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(localize ? MetaLabel.display(key) { l10n.t($0) } : key)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .frame(width: 108, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundStyle(value.isEmpty ? Theme.textDim : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.5))
            .foregroundStyle(color)
    }
}

/// Rounded card container used for every panel.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    /// Fill behind the content. The default is opaque; a card sitting on the
    /// Overview key art needs a translucent fill instead, otherwise it hides
    /// the very backdrop it is meant to sit on.
    var fill: Color = Theme.panel
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5))
    }
}
