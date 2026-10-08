import SwiftUI
import AppKit

/// A summary badge: the coloured pills under the cover art and in the Specs
/// header.
///
/// The palette mirrors the original tool so a package reads at a glance:
/// platform-tinted, region in muted red, size in grey, type in green/blue/orange,
/// package in red (fake) or green (official). Empty values are dropped rather
/// than leaving a blank pill.
struct SummaryBadge: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case platform, region, size, type, package
    }

    let text: String
    let kind: Kind
    var id: String { "\(kind):\(text)" }

    var color: Color {
        switch kind {
        case .platform: return platformColor
        case .region: return Color.adaptive(dark: 0xE1_7B7B, light: 0xB4_4545)
        case .size: return Color.adaptive(dark: 0x6B_7280, light: 0x4B_5563)
        case .type: return typeColor
        case .package: return packageColor
        }
    }

    /// Platform-tinted, as in the original: exFAT teal, ffpfsc amber,
    /// ffpkg violet, PS3 orange, PS4 blue, PS5 near-white.
    ///
    /// Every entry declares a Light variant. Measured against the window
    /// background, *none* of the dark values reach 3:1 on light — the palette
    /// was picked for a dark UI, where the brighter end is what makes a pill
    /// legible. Guessing which ones "survived" was wrong: PS4 blue landed at
    /// 2.46:1 and PS3 orange at 2.15:1, both unreadable. So each Light value
    /// here is a darkened form of its dark counterpart, verified ≥ 3:1.
    private var platformColor: Color {
        switch format {
        case .exfat: return Color.adaptive(dark: 0x3D_D6B0, light: 0x0F_8A74)
        case .ffpfsc: return Color.adaptive(dark: 0xF2_B84B, light: 0xA5_6A_0B)
        case .ffpkg: return Color.adaptive(dark: 0x9B_6DDB, light: 0x6D_3FBF)
        case .ps3, .ps3Folder: return Color.adaptive(dark: 0xE8_A34C, light: 0x9A_5B_12)
        case .ps4: return Color.adaptive(dark: 0x5F_A8FF, light: 0x1D_63_B8)
        // Near-white on dark, as the original has it; a deep slate on light,
        // where white would be invisible.
        case .ps5: return Color.adaptive(dark: 0xF1_F3F8, light: 0x33_3B_47)
        case .appFolder: return Color.adaptive(dark: 0x6B_7280, light: 0x4B_5563)
        // Nintendo red, as the original marks Switch titles; darkened for
        // Light so the pill keeps its contrast against a light window.
        case .nsp, .xci: return Color.adaptive(dark: 0xE6_0012, light: 0xA6_0B_1C)
        }
    }

    /// Update / DLC / base game get distinct colours.
    private var typeColor: Color {
        let t = typeText.lowercased()
        if t.contains("update") { return Color.adaptive(dark: 0x5F_A8FF, light: 0x1D_63_B8) }
        if t.contains("dlc") || t.contains("patch") {
            return Color.adaptive(dark: 0xF5_9E5B, light: 0xB4_5F_1D)
        }
        return Color.adaptive(dark: 0x10_B981, light: 0x04_7A_57)
    }

    /// FPKG (fake) reads red, OFC (official) green.
    private var packageColor: Color {
        let p = packageText.lowercased()
        if p.contains("official") || p.contains("ofc") {
            return Color.adaptive(dark: 0x10_B981, light: 0x04_7A_57)
        }
        if p.contains("fake") || p.contains("fpkg") {
            return Color.adaptive(dark: 0xE1_7B7B, light: 0xB4_4545)
        }
        return Color.adaptive(dark: 0x6B_7280, light: 0x4B_5563)
    }

    /// Raw (unshortened) values the colours key off.
    var typeText: String = ""
    var packageText: String = ""
    var format: ContainerFormat = .ps4
}

/// Builds the badge strip from a parsed result.
///
/// Five slots, matching the original: platform, region, size, type, package.
/// Values are omitted when absent, so a PS5 folder dump (no Package row) shows
/// four pills instead of a blank one.
enum SummaryBadges {
    static func make(for res: PkgResult) -> [SummaryBadge] {
        let rd = res.rowDict
        let format = ContainerFormat.detect(for: res)
        let plat = rd["Platform"] ?? ""
        let region = rd["Region"] ?? ""
        let size = (rd["Size"].flatMap { $0.isEmpty ? nil : $0 }) ?? Fmt.size(res.fileSize)
        let type = rd["Type"] ?? ""
        let pkg = rd["Package"] ?? rd["Signature"] ?? ""
        var out: [SummaryBadge] = []

        func add(_ text: String, _ kind: SummaryBadge.Kind) {
            var b = SummaryBadge(text: text, kind: kind)
            b.typeText = type
            b.packageText = pkg
            b.format = format
            out.append(b)
        }

        if !plat.isEmpty, plat != "-" { add(shortPlatform(plat), .platform) }
        if !region.isEmpty, region != "-" { add(region, .region) }
        if !size.isEmpty { add(size, .size) }
        if !type.isEmpty, type != "-" { add(type, .type) }
        if !pkg.isEmpty, pkg != "-" { add(shortPackage(pkg), .package) }
        return out
    }

    /// "PS4 (CNT metadata)" -> "PS4"; "PS5 (finalized FIH)" -> "PS5".
    static func shortPlatform(_ value: String) -> String {
        let upper = value.uppercased()
        for p in ["PS5", "PS4", "PS3"] where upper.contains(p) { return p }
        return value.split(separator: " ").first.map(String.init) ?? value
    }

    /// "FPKG (Fake)" -> "FPKG"; "OFC (Official)" -> "OFC".
    static func shortPackage(_ value: String) -> String {
        let upper = value.uppercased()
        if upper.contains("FPKG") { return "FPKG" }
        if upper.contains("OFC") { return "OFC" }
        return value.split(separator: " ").first.map(String.init) ?? value
    }
}

// MARK: - Format badge (left of the title)

/// The small square format badge shown next to the title under the cover.
///
/// The original loads a per-format `.ico`; SF Symbols are used here instead so
/// the badge stays crisp at any size with no bundled artwork.
struct FormatBadge: View {
    let format: ContainerFormat

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            )
            .frame(width: 26, height: 26)
            .accessibilityLabel(Text(format.rawValue))
    }

    private var symbol: String {
        switch format {
        case .ps5, .ps4, .ps3: return "shippingbox.fill"
        case .exfat: return "externaldrive.fill"
        case .ffpfsc, .ffpkg: return "archivebox.fill"
        case .appFolder: return "folder.fill"
        case .ps3Folder: return "gamecontroller.fill"
        case .nsp: return "shippingbox.fill"
        case .xci: return "gamecontroller.fill"
        }
    }

}

/// The container flavours the badge can show.
enum ContainerFormat: String {
    case ps5, ps4, ps3
    case exfat, ffpfsc, ffpkg
    case appFolder, ps3Folder
    /// Nintendo Switch: NSP package / XCI gamecard image.
    case nsp, xci

    /// Derive the format from the file extension / parse result.
    /// Kept off the View so it can be called from any isolation domain.
    static func detect(for res: PkgResult) -> ContainerFormat {
        switch res.path.pathExtension.lowercased() {
        case "exfat": return .exfat
        case "ffpfsc": return .ffpfsc
        case "ffpkg": return .ffpkg
        case "nsp": return .nsp
        case "xci": return .xci
        case "pkg": return res.kind == "ps3" ? .ps3 : (res.kind == "ps5" ? .ps5 : .ps4)
        default:
            // A folder: an app dump or an extracted PS3 game.
            return res.kind == "ps3" ? .ps3Folder : .appFolder
        }
    }
}

// MARK: - Colour helper

extension Color {
    /// Build from a 0xRRGGBB literal, matching the original's palette.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// The same palette entry in both appearances.
    ///
    /// The badge colours were picked for the original dark UI: the PS5 pill is
    /// near-white because white reads as "newest" against a dark window. In
    /// Light mode that same value is white-on-white — the pill all but
    /// disappears. Rather than desaturating the dark palette (which would cost
    /// the badges their meaning there), each colour declares a variant for the
    /// appearance that cannot show it.
    ///
    /// Dynamic rather than sampled from the environment, so the colour is
    /// correct wherever it is used without threading `colorScheme` through.
    static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

extension NSColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// Packed 0xRRGGBB, for CLI output and tests. SwiftUI's `Color` has no
    /// public component accessors, so go through NSColor.
    var rgbHexValue: UInt32 {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = UInt32(max(0, min(1, c.redComponent)) * 255)
        let g = UInt32(max(0, min(1, c.greenComponent)) * 255)
        let b = UInt32(max(0, min(1, c.blueComponent)) * 255)
        return (r << 16) | (g << 8) | b
    }
}
