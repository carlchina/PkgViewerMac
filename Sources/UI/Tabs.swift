import SwiftUI
import AppKit

// MARK: - Overview

struct OverviewTab: View {
    let res: PkgResult
    @EnvironmentObject private var vm: PkgViewModel
    @EnvironmentObject private var l10n: L10n
    /// The key art scrim has to match the appearance: white text needs a dark
    /// wash, dark text needs a light one.
    @Environment(\.colorScheme) private var colorScheme
    /// Index into `vm.coverImages` of the thumbnail the user picked, or nil for
    /// the primary cover.
    ///
    /// An index, not the `Data` itself: the bytes belong to whichever package
    /// was open when the click happened, so holding them across an open would
    /// leave the previous package's cover on screen. Keying by index — and
    /// resetting when the result changes — keeps the selection meaningful.
    @State private var selectedCoverIndex: Int?

    private var cover: Data? {
        if let i = selectedCoverIndex, vm.coverImages.indices.contains(i) {
            return vm.coverImages[i].full ?? vm.coverImages[i].thumb
        }
        return vm.primaryCover
    }

    /// The wide key art behind the whole page.
    ///
    /// It sits in a `ZStack` behind the scroll view, so it fills the tab and
    /// stays put while the content scrolls. A scrim is required rather than
    /// optional: the art is high-contrast photography and the spec text sits
    /// straight on top of it.
    @ViewBuilder
    private var backdrop: some View {
        if let d = vm.backdropCover, let img = NSImage(data: d) {
            GeometryReader { geo in
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // Fill and crop, anchored to the top so the subject of the
                    // artwork stays visible rather than being centred away.
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
            // The scrim follows the appearance. A fixed black wash worked while
            // the app was dark-only; in Light mode it turned the artwork into a
            // grey smear, so Light gets a white wash that keeps the dark spec
            // text readable instead.
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: scrimColors,
                    startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .leading) {
                let base: Color = scrimColors[0]
                LinearGradient(
                    colors: [base.opacity(0.75), Color.clear],
                    startPoint: .leading, endPoint: .trailing)
            }
            .accessibilityHidden(true)
        }
    }

    /// Top-to-bottom wash over the key art, in the colour the text needs.
    ///
    /// The Light values are much lower than they look like they should be:
    /// white text on the artwork needs a strong wash, but *dark* text only needs
    /// enough to knock the artwork's midtones back. At 0.86 the art was
    /// effectively erased — the page read as plain white with a faint ghost.
    /// These keep the picture legible while still guaranteeing contrast for
    /// the label and value text sitting directly on it.
    private var scrimColors: [Color] {
        colorScheme == .dark
            ? [Color.black.opacity(0.82), Color.black.opacity(0.62), Color.black.opacity(0.55)]
            : [Color.white.opacity(0.62), Color.white.opacity(0.50), Color.white.opacity(0.42)]
    }

    var body: some View {
        ZStack {
            backdrop
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 10) {
                        coverView
                        if vm.coverImages.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(vm.coverImages.enumerated()), id: \.offset) { i, item in
                                        thumb(item, index: i)
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                            }
                            .glassBar(cornerRadius: 8)
                            .frame(height: 48)
                        }
                        // Format badge + title, as a card under the cover.
                        HStack(alignment: .center, spacing: 9) {
                            FormatBadge(format: format)
                            Text(res.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassPanel(cornerRadius: 10)

                        if let d = cover {
                            HStack(spacing: 6) {
                                Button { saveCover(d) } label: { Label(l10n.t("overview.save"), systemImage: "square.and.arrow.down") }
                                    .buttonStyle(.glass)
                                Button { copyImage(d) } label: { Label(l10n.t("overview.copy"), systemImage: "doc.on.clipboard") }
                                    .buttonStyle(.glass)
                            }
                        }
                    }
                    .frame(width: 232)

                    VStack(alignment: .leading, spacing: 12) {
                        // Publisher logo, when the package ships one. Most
                        // retail packages do not, so the title simply moves up.
                        if let d = vm.logoCover, let img = NSImage(data: d) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 220, maxHeight: 64)
                                .accessibilityLabel(l10n.t("overview.logo"))
                        }
                        // Big title, as in the original's Specs tab.
                        Text(res.title)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        titleBlock
                        specCard
                        if !vm.coverImages.isEmpty { galleryNote }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
        }
        // Opening another package replaces the cover list, so any thumbnail the
        // user had picked refers to a row that no longer means what it did.
        // `loadGeneration` covers reopening the *same* path too, which
        // `res.path` alone would not notice.
        .onChange(of: vm.loadGeneration) { _ in selectedCoverIndex = nil }
    }

    private var coverView: some View {
        ZStack {
            if let d = cover, let img = NSImage(data: d) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.textDim)
                    Text(l10n.t("overview.noCover"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
        .frame(width: 232, height: 232)
        .glassPanel(cornerRadius: 14)
    }

    private func thumb(_ item: CoverArt, index: Int) -> some View {
        Button {
            selectedCoverIndex = index
            // The thumbnail only holds a small preview; pull the full-res bytes
            // for the big cover so save/copy/display act on the real image.
            vm.loadCoverFull(index)
        } label: {
            if let d = item.thumb ?? item.full, let img = NSImage(data: d) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selectedCoverIndex == index ? Theme.accent : Color.white.opacity(0.15), lineWidth: selectedCoverIndex == index ? 1.5 : 0.75)
        )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Colour-coded summary pills, mirroring the original's five slots:
            // platform, region, size, type, package. Empty values are dropped.
            if !badges.isEmpty {
                HStack(spacing: 6) {
                    ForEach(badges) { b in
                        Pill(text: b.text, color: b.color)
                    }
                }
            }
            Text(res.path.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(onArtwork)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    /// Text that sits directly on the key art rather than on a card.
    ///
    /// `secondaryLabelColor` is tuned for a plain window background; over a
    /// photograph it is too faint to read in either appearance, so it is
    /// strengthened and the Light case — dark text on a light wash — goes all
    /// the way to `labelColor`.
    private var onArtwork: Color {
        colorScheme == .dark
            ? Color(nsColor: .secondaryLabelColor)
            : Color(nsColor: .labelColor).opacity(0.75)
    }

    private var badges: [SummaryBadge] { SummaryBadges.make(for: res) }

    private var format: ContainerFormat { ContainerFormat.detect(for: res) }

    private var specCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text(l10n.t("overview.spec"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .padding(.bottom, 8)
                ForEach(Array(specRows.enumerated()), id: \.offset) { _, kv in
                    SpecRow(key: kv.0, value: kv.1, mono: isMonoKey(kv.0))
                }
            }
        }
    }

    /// The pills already surface platform, region, size, type and package, so
    /// the grid skips them unless the pill was dropped for being empty.
    private var specRows: [(String, String)] {
        let shown: Set<String> = Set(
            badges.map { b in
                switch b.kind {
                case .platform: return "Platform"
                case .region: return "Region"
                case .size: return "Size"
                case .type: return "Type"
                case .package: return res.rowDict["Signature"] != nil && res.rowDict["Package"] == nil
                    ? "Signature" : "Package"
                }
            }
        )
        return res.rows.filter { kv in
            // Keep a row when its pill is missing because the value was empty.
            !shown.contains(kv.0) || kv.1.isEmpty || kv.1 == "-"
        }
    }

    private var galleryNote: some View {
        Text(l10n.t("overview.galleryNote", vm.coverImages.count))
            .font(.system(size: 10))
            .foregroundStyle(onArtwork)
    }

    private func isMonoKey(_ k: String) -> Bool {
        ["Title ID", "Content ID", "Concept ID", "PFS image", "Built", "SDK"].contains(k)
    }


    private func saveCover(_ d: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (res.rows.first { $0.0 == "Title ID" }?.1.isEmpty == false
                                       ? res.rows.first { $0.0 == "Title ID" }!.1 : res.title) + "-cover.png"
        if panel.runModal() == .OK, let u = panel.url { try? d.write(to: u) }
    }

    private func copyImage(_ d: Data) {
        guard let img = NSImage(data: d),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
    }
}

// MARK: - Files

struct FilesTab: View {
    @EnvironmentObject private var vm: PkgViewModel
    @EnvironmentObject private var l10n: L10n
    @State private var selected: PkgEntry?
    @State private var preview: Data?
    @State private var previewIsImage = false

    private var entries: [PkgEntry] { vm.filteredEntries }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                TextField(l10n.t("files.filter"), text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !vm.searchText.isEmpty {
                    Button { vm.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textDim)
                }
                Divider().frame(height: 12)
                Text(l10n.t("files.count", entries.count, vm.result?.entries.count ?? 0))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassBar(cornerRadius: 8)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Text(l10n.t("files.noMatch"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitViewCompat(
                    leading: { fileList },
                    trailing: { detail }
                )
            }
        }
        .onChange(of: selected) { e in
            guard let e = e else { preview = nil; return }
            let d = vm.read(e)
            preview = d
            previewIsImage = d?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
        }
        // The selected entry belongs to the package that was open when it was
        // picked; without this the detail pane would keep showing its bytes
        // (and its name) after another package is loaded.
        .onChange(of: vm.loadGeneration) { _ in
            selected = nil
            preview = nil
            previewIsImage = false
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { e in
                    HStack(spacing: 8) {
                        Image(systemName: e.isTrophyPack ? "trophy" : (e.codec != nil ? "cube.box" : "doc"))
                            .font(.system(size: 10))
                            .foregroundStyle(e.isTrophyPack ? Theme.warn : Theme.textDim)
                            .frame(width: 14)
                        Text(e.name)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Fmt.size(e.size))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        if selected == e {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.accent.opacity(0.2))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 0.5)
                                )
                        }
                    }
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = e }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minWidth: 380)
    }

    @ViewBuilder
    private var detail: some View {
        if let e = selected {
            VStack(alignment: .leading, spacing: 10) {
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        SpecRow(key: l10n.t("detail.name"), value: e.name, mono: true)
                        SpecRow(key: l10n.t("detail.size"), value: Fmt.size(e.size))
                        SpecRow(key: l10n.t("detail.id"), value: String(e.id), mono: true)
                        if let c = e.codec { SpecRow(key: l10n.t("detail.codec"), value: c) }
                        if e.isTrophyPack { SpecRow(key: l10n.t("detail.type"), value: l10n.t("detail.trophyPack")) }
                    }
                }
                if let d = preview, !d.isEmpty {
                    if previewIsImage, let img = NSImage(data: d) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Card {
                            Text(hexDump(d))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textDim)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 240)
                    }
                    HStack {
                        Button { saveEntry(e, d) } label: {
                            Label(l10n.t("overview.save"), systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.glass)
                    }
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.textDim)
                Text(l10n.t("files.selectOne"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func hexDump(_ d: Data) -> String {
        let n = min(d.count, 2048)
        var lines: [String] = []
        let bytes = [UInt8](d.prefix(n))
        for i in stride(from: 0, to: n, by: 16) {
            let row = Array(bytes[i..<min(i + 16, n)])
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = row.map { b in (b >= 32 && b < 127) ? String(UnicodeScalar(b)) : "." }.joined()
            lines.append(String(format: "%08x  %-47@  %@", i, hex as NSString, ascii as NSString))
        }
        if d.count > n { lines.append(l10n.t("files.moreBytes", d.count - n)) }
        return lines.joined(separator: "\n")
    }

    private func saveEntry(_ e: PkgEntry, _ d: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (e.name as NSString).lastPathComponent
        if panel.runModal() == .OK, let u = panel.url { try? d.write(to: u) }
    }
}

/// HSplitView with a sane minimum width for the leading pane.
struct HSplitViewCompat<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HSplitView {
            leading
                .frame(minWidth: 380)
            trailing
                .frame(minWidth: 320)
        }
    }
}

// MARK: - Details

struct DetailsTab: View {
    let res: PkgResult
    @EnvironmentObject private var l10n: L10n
    @State private var showAll = false
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle(l10n.t("details.showAll"), isOn: $showAll)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                if showAll {
                    Divider().frame(height: 12)
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    TextField(l10n.t("details.filterKeys"), text: $filter)
                        .textFieldStyle(.plain).font(.system(size: 11))
                        .frame(maxWidth: 200)
                }
                Spacer()
                Text(l10n.t("details.fieldCount", flat.count))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassBar(cornerRadius: 8)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if flat.isEmpty {
                Text(l10n.t("details.none"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(flat, id: \.key) { item in
                            // Raw SFO / param.json keys — shown verbatim.
                            SpecRow(key: item.key, value: item.value, mono: true, localize: false)
                            Divider().overlay(Theme.border.opacity(0.4))
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var flat: [(key: String, value: String)] {
        let meta = res.meta
        guard !meta.isEmpty else { return [] }
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [(String, String)] = []
        // Curated view: only the fields the spec card highlights.
        let curated = ["TITLE", "TITLE_ID", "CONTENT_ID", "CATEGORY", "VERSION", "APP_VER",
                       "SYSTEM_VER", "PUBTOOLINFO", "titleId", "contentId", "contentVersion",
                       "masterVersion", "conceptId", "applicationCategoryType",
                       "applicationDrmType", "requiredSystemSoftwareVersion", "sdkVersion"]
        func add(_ k: String, _ v: MetaValue, indent: Int = 0) {
            let key = indent > 0 ? String(repeating: "  ", count: indent) + k : k
            if case .nested(let d) = v {
                if !showAll { return }
                out.append((key, l10n.t("details.nestedFields", d.count)))
                for nk in d.keys.sorted() { add(nk, d[nk]!, indent: indent + 1) }
            } else {
                out.append((key, v.displayString))
            }
        }
        for (k, v) in meta.sorted(by: { $0.key < $1.key }) {
            if q.isEmpty ? true : (k.lowercased().contains(q) || v.displayString.lowercased().contains(q)) {
                if showAll || curated.contains(k) || k.hasPrefix("TITLE") { add(k, v) }
            }
        }
        return out
    }
}

// MARK: - Rename

struct RenameSheet: View {
    @EnvironmentObject private var vm: PkgViewModel
    @EnvironmentObject private var l10n: L10n
    @Environment(\.dismiss) private var dismiss
    @State private var useTitle = true
    @State private var useTid = true
    @State private var useVer = true
    @State private var useRegion = true
    @State private var custom = ""
    @State private var useCustom = false
    @State private var errorMsg: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.t("rename.title"))
                .font(.system(size: 15, weight: .semibold))

            if let res = vm.result {
                Text(res.path.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)

                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.t("rename.include"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                    toggle(l10n.t("rename.part.title"), $useTitle)
                    toggle(l10n.t("rename.part.tid"), $useTid)
                    toggle(l10n.t("rename.part.version"), $useVer)
                    toggle(l10n.t("rename.part.region"), $useRegion)
                }

                Divider().overlay(Theme.border)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(l10n.t("rename.custom"), isOn: $useCustom)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 11))
                    TextField(l10n.t("rename.customPlaceholder"), text: $custom)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!useCustom)
                        .font(.system(size: 12))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t("rename.preview"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                    Text(preview)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(preview.isEmpty ? Theme.warn : .primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(cornerRadius: 10)

                if let e = errorMsg {
                    Text(e).font(.system(size: 11)).foregroundStyle(Theme.warn)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button(l10n.t("rename.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button(l10n.t("rename.confirm")) { perform() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(preview.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(Theme.bg)
    }

    private func toggle(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(label, isOn: binding)
            .toggleStyle(.switch).controlSize(.mini)
            .font(.system(size: 11))
    }

    private var preview: String {
        if useCustom { return Fmt.sanitizeFilenamePart(custom) }
        guard let res = vm.result else { return "" }
        return PkgLoader.buildCleanName(res, parts: (useTitle, useTid, useVer, useRegion))
    }

    private func perform() {
        guard let res = vm.result else { return }
        let base = preview
        guard !base.isEmpty else { return }
        let dir = res.path.deletingLastPathComponent()
        let ext = res.path.pathExtension
        // Keep split sets together: only the first part takes the new name.
        let siblings = PkgLoader.splitSiblings(res.path)
        let target = dir.appendingPathComponent(base + (ext.isEmpty ? "" : ".\(ext)"))
        guard target != res.path else { errorMsg = l10n.t("rename.err.unchanged"); return }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            errorMsg = l10n.t("rename.err.exists", target.lastPathComponent)
            return
        }
        do {
            for s in siblings {
                let suffix = s.pathExtension == res.path.pathExtension ? ".\(s.pathExtension)" : ""
                let dest = dir.appendingPathComponent(base + suffix)
                try FileManager.default.moveItem(at: s, to: dest)
            }
            vm.open(target)
            dismiss()
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
