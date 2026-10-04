import SwiftUI

// MARK: - Theme

/// Colours and materials, following the system appearance.
///
/// The palette used to be hard-coded dark values. On macOS 26+ that fought the
/// platform: the window chrome, the menus and the desktop behind the app all
/// moved with the system, while the content stayed black. Everything here is
/// now a semantic colour or a material, so Light and Dark — and the
/// Reduce Transparency / Increase Contrast accessibility settings — are handled
/// by the system rather than by us.
enum Theme {
    /// Window background. A material rather than a colour so the desktop
    /// wallpaper shows through faintly, as it does in the rest of macOS.
    static var bg: Color { Color(nsColor: .windowBackgroundColor) }

    /// Panel fill. A *tint*, not a flat colour and not a bare material: a
    /// material alone over the key art lets the artwork's bright regions show
    /// through and the label text loses contrast. Layering a themed tint under
    /// the material keeps the translucency while pinning the luminance.
    static var panel: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    /// Raised surface (thumbnail placeholders, the version chip).
    static var panelHi: Color { Color(nsColor: .underPageBackgroundColor) }

    static var border: Color { Color(nsColor: .separatorColor) }

    /// Accent follows the user's system accent, like every other Mac app.
    static var accent: Color { Color.accentColor }

    /// Semantic status colours, taken from the system palette so they keep
    /// their meaning in both appearances and with increased contrast.
    static var ok: Color { Color(nsColor: .systemGreen) }
    static var warn: Color { Color(nsColor: .systemOrange) }

    static var textDim: Color { Color(nsColor: .secondaryLabelColor) }
    static var text: Color { Color(nsColor: .labelColor) }
}

// MARK: - Materials

/// The material used for panels and bars.
///
/// `.regularMaterial` is the semi-adaptive choice: it shifts with the
/// appearance and the transparency setting instead of being a fixed grey, which
/// is what makes the glass panels read as part of the window rather than as
/// cards floating on top of it.
enum Mat {
    static var panel: Material { .regularMaterial }
    static var bar: Material { .thinMaterial }
}

// MARK: - Glass helpers

extension View {
    /// Apply Liquid Glass on macOS 26+, and nothing on older systems.
    ///
    /// The modifier is wrapped rather than used directly because the deployment
    /// target is macOS 14: the code has to compile against the 27 SDK while
    /// still running on 14. Callers can therefore use this unconditionally.
    ///
    /// The glass style is an argument rather than a default because `Glass` is
    /// itself 26+, so it cannot appear in a default value at this deployment
    /// target — `.regular` is supplied by `glass()` below.
    @ViewBuilder
    func glassIfAvailable(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
        }
    }

    /// `.rect(cornerRadius:)` shaped glass, the common case.
    @ViewBuilder
    func glassIfAvailable(cornerRadius: CGFloat) -> some View {
        glassIfAvailable(in: .rect(cornerRadius: cornerRadius))
    }

    /// Liquid Glass bound to a shared namespace, so the glass *morphs* between
    /// segments instead of cross-fading.
    ///
    /// This is what makes a segmented control feel like the system tab bar:
    /// a single pane of glass slides from one segment to the next, carrying
    /// its highlight with it. Passing an id only for the selected segment is
    /// what drives that — the others get `nil` so they are not part of the
    /// morph.
    ///
    /// Both the modifier and the `Glass` value are 26+, hence the wrapper.
    @ViewBuilder
    func glassSegment(
        isSelected: Bool,
        id: Int,
        namespace: Namespace.ID,
        cornerRadius: CGFloat
    ) -> some View {
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .glassEffectID(isSelected ? id : nil, in: namespace)
        } else {
            self
        }
    }

    /// The material backing for a panel, honouring the system appearance.
    func panelSurface(cornerRadius: CGFloat = 10) -> some View {
        background(Mat.panel, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Enhanced Liquid Glass panel styling. On macOS 26+, uses native glassEffect
    /// with delicate specular rim lighting. Gracefully degrades to translucent
    /// Material on earlier systems.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            self
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Theme.panel.opacity(0.62))
                        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.08),
                                    Theme.border.opacity(0.4)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                }
        } else {
            self
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Theme.panel)
                }
                .panelSurface(cornerRadius: cornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Theme.border, lineWidth: 0.5)
                )
        }
    }

    /// Liquid Glass floating bar / capsule container (e.g. search bars, tool palettes).
    @ViewBuilder
    func glassBar(cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            self
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Theme.panel.opacity(0.55))
                        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.3), Color.white.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                }
        } else {
            self
                .background(Mat.bar, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Theme.border, lineWidth: 0.5)
                )
        }
    }
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
                .foregroundStyle(value.isEmpty ? Theme.textDim : Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

/// Crystal/Gel styled Pill with subtle specular rim for Liquid Glass aesthetic.
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.26), color.opacity(0.14)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.55),
                                color.opacity(0.4),
                                color.opacity(0.15)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.65
                    )
            }
            .foregroundStyle(color)
    }
}

/// Rounded card container with Liquid Glass styling.
struct Card<Content: View>: View {
    var cornerRadius: CGFloat = 12
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: cornerRadius)
    }
}

// MARK: - Glass Button Style

struct GlassButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonView(configuration: configuration, prominent: prominent, cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle { GlassButtonStyle(prominent: false) }
    static var glassProminent: GlassButtonStyle { GlassButtonStyle(prominent: true) }
    static func glass(prominent: Bool = false, cornerRadius: CGFloat = 7) -> GlassButtonStyle {
        GlassButtonStyle(prominent: prominent, cornerRadius: cornerRadius)
    }
}

private struct GlassButtonView: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .medium))
            .foregroundStyle(
                prominent
                    ? Color.white
                    : (isEnabled ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .background {
                if #available(macOS 26.0, *) {
                    if prominent {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(Theme.accent)
                            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(
                                configuration.isPressed
                                    ? Theme.panelHi
                                    : (isHovered ? Theme.panelHi.opacity(0.8) : Theme.panel.opacity(0.55))
                            )
                            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    }
                } else {
                    if prominent {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(Theme.accent)
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(configuration.isPressed ? Theme.panelHi : (isHovered ? Theme.panelHi.opacity(0.7) : Theme.panel))
                            .panelSurface(cornerRadius: cornerRadius)
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        prominent
                            ? LinearGradient(
                                colors: [Color.white.opacity(0.45), Theme.accent.opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                              )
                            : LinearGradient(
                                colors: [Color.white.opacity(0.3), Color.white.opacity(0.08), Theme.border.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                              ),
                        lineWidth: 0.65
                    )
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1.0) : 0.45)
            .onHover { h in isHovered = h }
    }
}

