import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Trophies

struct TrophiesTab: View {
    @EnvironmentObject private var vm: PkgViewModel
    @EnvironmentObject private var l10n: L10n
    /// The selection tint has to be stronger on a light list: the same 28%
    /// accent that reads clearly over black is nearly invisible over white.
    @Environment(\.colorScheme) private var colorScheme
    /// The row whose art is shown in the preview pane.
    @State private var selectedID: String?
    /// Drag position of the splitter, in points from the left edge.
    @State private var splitWidth: CGFloat = 520

    private let minListWidth: CGFloat = 400
    private let minPreviewWidth: CGFloat = 260

    /// Wash behind the selected row. Light needs more of it to register at all.
    private var selectionTint: Double { colorScheme == .dark ? 0.28 : 0.42 }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if let msg = vm.trophyStatus {
                    statusBar(msg)
                }
                // The two-pane layout is kept whatever the trophy count is: a
                // pack whose selected language has no metadata, or no metadata
                // at all, must not make the interface jump to a different shape.
                let listW = min(max(splitWidth, minListWidth),
                                max(minListWidth, geo.size.width - minPreviewWidth))
                HStack(spacing: 0) {
                    list.frame(width: listW)
                    Splitter(width: listW, total: geo.size.width,
                             minLeft: minListWidth,
                             minRight: minPreviewWidth) { splitWidth = $0 }
                    preview.frame(maxWidth: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Reloading (language switch, opening another pack) can drop the row
        // that was selected. A stale id would keep the export button pinned to
        // "save this image" with nothing to save, so clear it. Ids rather than
        // the array itself: `Trophy` is not Equatable.
        .onChange(of: vm.trophies.map(\.id)) { _, ids in
            if let id = selectedID, !ids.contains(id) {
                selectedID = nil
            }
        }
    }

    // MARK: Status

    private func statusBar(_ msg: Message) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trophy")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warn)
            Text(msg.text { l10n.t($0) })
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Mat.bar)
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            listHeader
            headerRow
            Divider().overlay(Theme.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.trophies) { t in
                        row(t)
                    }
                    if vm.trophies.isEmpty {
                        // Keep the column header and the pane in place; the
                        // status bar above already explains what is missing.
                        Text(l10n.t("trophy.list.empty"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Title, counts and NPCommID, mirroring the original's header line.
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !vm.trophyTitle.isEmpty {
                Text(vm.trophyTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(l10n.t("trophy.header.count", vm.trophies.count))
                if hiddenCount > 0 {
                    Text(l10n.t("trophy.header.hidden", hiddenCount))
                }
                Spacer()
                if !vm.trophyNpCommId.isEmpty {
                    Text(vm.trophyNpCommId)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 8) {
                localePicker
                Spacer()
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var hiddenCount: Int { vm.trophies.filter(\.hidden).count }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text(l10n.t("trophy.col.id"))
                .frame(width: 40, alignment: .leading)
            Text(l10n.t("trophy.col.grade"))
                .frame(width: 62, alignment: .leading)
            Text(l10n.t("trophy.col.name"))
            Spacer()
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.bg)
    }

    private func row(_ t: Trophy) -> some View {
        let active = selectedID == t.id
        return Button {
            // Clicking a row shows its art; clicking again clears the preview.
            selectedID = active ? nil : t.id
        } label: {
            HStack(spacing: 10) {
                Text(t.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(active ? selectionText : Theme.text)
                    .frame(width: 40, alignment: .leading)
                Text(t.gradeText { l10n.t($0) })
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(gradeColor(t.type))
                    .frame(width: 62, alignment: .leading)
                Text(t.name)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? selectionText : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if t.hidden {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Theme.accent.opacity(selectionTint) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.detail)    }

    /// Text colour for the selected row.
    ///
    /// White was correct when the selection was a light accent tint on a dark
    /// list. On the light appearance the same white-on-pale-blue was unreadable,
    /// so the selected row now uses the plain label colour and leans on weight
    /// plus the tint for emphasis.
    private var selectionText: Color { Theme.text }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        Group {
            if let id = selectedID, let t = vm.trophies.first(where: { $0.id == id }) {
                detail(t)
            } else if !vm.trophyIcons.isEmpty {
                iconGallery
            } else {
                hint
            }
        }
        .padding(12)
        // Clamping the height is what keeps a long gallery inside the pane
        // instead of letting it push past the window and over the toolbar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func detail(_ t: Trophy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let img = vm.trophyIconMap[t.id].flatMap(NSImage.init(data:)) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 260)
                        .background(Theme.panelHi, in: RoundedRectangle(cornerRadius: 8))
                    // A per-image save next to the art, so the selected trophy
                    // can be written out without going back to the gallery.
                    Button { saveSelectedImage() } label: {
                        Label(l10n.t("trophy.export.saveOne"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 10))
                } else {
                    noArt
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(t.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                    if !t.detail.isEmpty {
                        Text(t.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Pill(text: t.gradeText { l10n.t($0) }, color: gradeColor(t.type))
                        Text(t.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                        if t.hidden {
                            Pill(text: l10n.t("trophy.hidden"), color: Theme.textDim)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var noArt: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.textDim)
            Text(l10n.t("trophy.noArt"))
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private var hint: some View {
        VStack(spacing: 6) {
            Image(systemName: "trophy")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.textDim)
            Text(l10n.t("trophy.selectHint"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    /// The unselected state: every icon in the pack as a scrollable grid.
    ///
    /// The scroll view is essential — a pack can carry 40+ icons, and without
    /// one the grid grows past the window and spills over the toolbar. The card
    /// and its title are pinned outside so the count stays visible.
    private var iconGallery: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                Text(l10n.t("trophy.icons", vm.trophyIcons.count))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                // Bulk export lives here as well as in the header, so pinning
                // the header button to the selected trophy never takes the
                // "save everything" option away.
                Button { saveIcons() } label: {
                    Label(l10n.t("trophy.export.all"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
                .help(l10n.t("trophy.export.help.all"))
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 6)

            ScrollView {
                // Adaptive columns, but capped so a very wide pane does not
                // stretch the tiles into banners.
                let columns = [GridItem(.adaptive(minimum: 76, maximum: 104), spacing: 8)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(Array(vm.trophyIcons.enumerated()), id: \.offset) { _, d in
                        if let img = NSImage(data: d) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 64)
                                .frame(maxWidth: .infinity)
                                .background(Theme.panelHi, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }


    /// Shows which language the trophy text is in and lets it be changed.
    @ViewBuilder
    private var localePicker: some View {
        if vm.trophyLocales.count > 1 {
            Menu {
                ForEach(vm.trophyLocales) { c in
                    Button {
                        vm.trophyLocaleOverride = c.tag
                        vm.reloadTrophies()
                    } label: {
                        let name = displayName(c)
                        if c.tag == vm.trophyLocale {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.system(size: 9))
                    Text(vm.trophyLocale.map(displayName(for:)) ?? l10n.t("trophy.locale.auto"))
                }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .font(.system(size: 10))
            .foregroundStyle(Theme.textDim)
            .help(l10n.t("trophy.locale.help"))
        } else if let tag = vm.trophyLocale {
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 9))
                Text(displayName(for: tag))
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.textDim)
        }
    }

    /// "ja-JP" -> localized display name, falling back to the tag.
    private func displayName(for tag: String) -> String {
        let key = "locale." + tag.lowercased()
        let v = l10n.t(key)
        return v == key ? tag : v
    }

    /// Label a candidate, preferring the language's localized name over the tag.
    private func displayName(_ c: TrophyLanguage.Candidate) -> String {
        displayName(for: c.tag)
    }

    // MARK: Helpers

    /// Colours follow the console's own trophy colours: platinum is the
    /// brightest, then gold, silver, bronze. `S` is used for both platinum
    /// (the reduced UCP schema) and silver (the .trp XML), so silver falls
    /// through to the default bronze-free grey.
    ///
    /// Declared per appearance: the metal tints are light, chosen against the
    /// dark list background. On the light appearance platinum was white on
    /// white and every tier lost its edge, so each has a darkened counterpart.
    private func gradeColor(_ t: String) -> Color {
        switch t.uppercased() {
        case "P", "PLATINUM": return Color.adaptive(dark: 0xE8_ECF5, light: 0x5A_6472)
        case "G", "GOLD": return Color.adaptive(dark: 0xF2_C46B, light: 0x8A_6318)
        case "S", "SILVER": return Color.adaptive(dark: 0xC7_CAE0, light: 0x5F_6376)
        case "B", "BRONZE": return Color.adaptive(dark: 0xCC_8C6B, light: 0x8A_4F_2C)
        case "": return Theme.textDim   // the pack carries no grade
        default: return Theme.textDim
        }
    }

    /// Save just the selected trophy's image.
    ///
    /// Unlike the bulk path this asks for a single file, so the user names it:
    /// the default is the pack's own `trop<id>.png` naming with the trophy
    /// name folded in, because a saved file should say what it is once it is
    /// outside the app.
    private func saveSelectedImage() {
        guard let id = selectedID, let data = vm.trophyIconMap[id] else { return }
        let trophy = vm.trophies.first { $0.id == id }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.singleFileName(id: id, name: trophy?.name)
        panel.allowedContentTypes = [.png]
        panel.prompt = l10n.t("shot.savePrompt")
        panel.message = l10n.t("trophy.export.oneMessage", id)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            reveal(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = l10n.t("trophy.export.failedTitle")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: l10n.t("alert.ok"))
            alert.runModal()
        }
    }

    /// `TROP00_Platinum.png` — id first so files sort like the list does, then
    /// the trophy name with characters that are illegal in a filename removed.
    static func singleFileName(id: String, name: String?) -> String {
        var s = id.uppercased()
        if let name {
            let cleaned = name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { s += "_" + cleaned }
        }
        return s + ".png"
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Write every icon to a folder the user picks.
    ///
    /// A folder (not a single file) is needed because a pack carries dozens of
    /// images, so the panel is configured for directory selection — asking for
    /// one file would make it impossible to choose anywhere to put them.
    private func saveIcons() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = l10n.t("shot.savePrompt")
        panel.message = l10n.t("trophy.export.message")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let result = Self.exportIcons(from: vm, to: dir, l10n: l10n)

        let alert = NSAlert()
        alert.messageText = result.failed == 0
            ? l10n.t("trophy.export.done", result.written, dir.lastPathComponent)
            : l10n.t("trophy.export.failedTitle")
        alert.informativeText = result.failed == 0
            ? l10n.t("trophy.export.doneDetail", dir.path)
            : l10n.t("trophy.export.partial", result.written, result.failed)
        alert.addButton(withTitle: l10n.t("alert.ok"))
        if result.failed == 0 {
            alert.addButton(withTitle: l10n.t("trophy.export.reveal"))
        }
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    /// Write every icon into `dir` and report how many landed.
    ///
    /// Images that map to a trophy id are named `trop<id>.png`; anything left
    /// over keeps its gallery position as `trophy-NNN.png`. Failures are
    /// counted rather than swallowed — a silent `try?` left the user with no
    /// idea the export had done nothing.
    static func exportIcons(from vm: PkgViewModel, to dir: URL,
                             l10n: L10n) -> (written: Int, failed: Int) {
        // Index the flat icon list so the id-keyed map can name its files.
        var indexOf: [Data: Int] = [:]
        for (i, d) in vm.trophyIcons.enumerated() where indexOf[d] == nil {
            indexOf[d] = i
        }
        var written = 0
        var failed = 0
        var named: Set<Int> = []
        for (id, data) in vm.trophyIconMap {
            guard let i = indexOf[data], !named.contains(i) else { continue }
            named.insert(i)
            if write(data, to: dir, name: "trop\(id).png") { written += 1 } else { failed += 1 }
        }
        for (i, d) in vm.trophyIcons.enumerated() where !named.contains(i) {
            if write(d, to: dir, name: String(format: "trophy-%03d.png", i)) {
                written += 1
            } else {
                failed += 1
            }
        }
        return (written, failed)
    }

    @discardableResult
    private static func write(_ data: Data, to dir: URL, name: String) -> Bool {
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            NSLog("PkgViewer: could not write %@: %@", name, error.localizedDescription)
            return false
        }
    }
}

// MARK: - Splitter

/// Draggable divider between the list and the preview pane.
private struct Splitter: View {
    let width: CGFloat
    let total: CGFloat
    let minLeft: CGFloat
    let minRight: CGFloat
    let onChange: (CGFloat) -> Void

    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)   // generous hit area
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { g in
                                let base = dragStart ?? width
                                if dragStart == nil { dragStart = base }
                                onChange(min(max(base + g.translation.width, minLeft),
                                            max(minLeft, total - minRight)))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            )
    }
}
