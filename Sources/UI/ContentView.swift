import SwiftUI
import UniformTypeIdentifiers

// MARK: - App entry

@main
struct PkgViewerApp: App {
    @StateObject private var vm = PkgViewModel()
    @StateObject private var l10n = L10n()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let args = CommandLine.arguments

        // `--lang <code|system>` pins the interface language for the GUI.
        // The CLI diagnostics below deliberately stay in English: their field
        // names are a stable, greppable contract (verify.sh diffs them against
        // the Python original), so they are not localised.
        if let i = args.firstIndex(of: "--lang"), i + 1 < args.count {
            let v = args[i + 1]
            UserDefaults.standard.set(v == "system" ? nil : v, forKey: L10n.storageKey)
        }

        // `--info <path>` prints the package summary and exits; `--trophies
        // <path>` dumps the trophy pack, mirroring the Python tool's CLI mode.
        if let i = args.firstIndex(of: "--covers"), i + 1 < args.count {
            // `--export-to <dir>` is optional and writes the images out.
            var out: URL?
            if let e = args.firstIndex(of: "--export-to"), e + 1 < args.count {
                out = URL(fileURLWithPath: args[e + 1])
                try? FileManager.default.createDirectory(at: out!, withIntermediateDirectories: true)
            }
            InfoPrinter.printCovers(URL(fileURLWithPath: args[i + 1]), exportTo: out)
            exit(0)
        }
        if let i = args.firstIndex(of: "--info"), i + 1 < args.count {
            InfoPrinter.printInfo(URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--trophies"), i + 1 < args.count {
            // `--locale <tag>` may be repeated to force a specific language.
            var locales: [String] = []
            var j = i + 2
            while j + 1 < args.count, args[j] == "--locale" {
                locales.append(args[j + 1])
                j += 2
            }
            // `--ucp-dump` lists the pack's per-language metadata side by side.
            if args.contains("--ucp-dump") { TrophyPrinter.dumpUCP = true }
            TrophyPrinter.run(URL(fileURLWithPath: args[i + 1]), forcedLocales: locales)
            exit(0)
        }
        if args.contains("--languages") {
            printLanguages()
            exit(0)
        }
        if let i = args.firstIndex(of: "--lang-check") {
            LangCheck.run(i + 1 < args.count ? args[i + 1] : nil)
            exit(0)
        }

        // A bare path argument: the document scene only receives files handed
        // over by LaunchServices, so remember it for the first window.
        // args[0] is the executable path, so start the search at index 1.
        if let first = args.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            AppDelegate.launchURL = URL(fileURLWithPath: first)
        }
    }

    /// `--languages`: list the shipped localisations.
    @MainActor private func printLanguages() {
        print("Available languages:")
        for l in L10n.available {
            print(String(format: "  %-10@ %@ (%@)", l.code as NSString,
                         l.nativeName as NSString, l.englishName as NSString))
        }
        print("System preference: \(L10n.preferredLanguages().joined(separator: ", "))")
        print("Current: \(L10n.systemLanguage())")
    }

    var body: some Scene {
        // `for: URL.self` makes the scene document-based, so a double-clicked
        // file or an `open -a` request arrives through `onOpenURL`.
        WindowGroup(l10n.t("app.name"), for: URL.self) { $url in
            ContentView(initialURL: url)
                .environmentObject(vm)
                .environmentObject(l10n)
                // No forced scheme: the palette is built from semantic colours
                // and materials, so Light and Dark both work. Pinning `.dark`
                // here would fight the system and break the accessibility
                // settings that Theme now defers to.
                .frame(minWidth: 940, minHeight: 620)
                .onAppear {
                    vm.loadHistory()
                    vm.l10nTags = l10n.effectiveLanguageTags
                    SharedModel.instance = vm
                    if let u = appDelegate.pendingOpen {
                        appDelegate.pendingOpen = nil
                        vm.open(u)
                    } else if let u = AppDelegate.consumeLaunchURL() {
                        vm.open(u)
                    }
                }
                // A language change must reach the trophy text too: the packs
                // are read in the interface language, so a stale tag list would
                // leave the list in the previous language until the next reload.
                .onChange(of: l10n.languageCode) { _, _ in
                    vm.l10nTags = l10n.effectiveLanguageTags
                    vm.reloadTrophies()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(l10n.t("app.open") + "…") { openPanel() }
                    .keyboardShortcut("o")
            }
            // The Language menu lives here, so the stock About item is
            // replaced rather than added to — otherwise macOS would show two
            // "About" entries in the same menu.
            CommandGroup(replacing: .appInfo) {
                Button(l10n.t("about.title")) { AboutView.show(l10n) }
                Divider()
                LanguageMenu(l10n: l10n)
            }
        }
    }

    func openPanel() {
        // The panel is driven from a command, so read the string from the app
        // bundle rather than depending on an injected environment object.
        let message = NSLocalizedString("app.openPanel.message",
                                        tableName: nil,
                                        bundle: .module, value: "", comment: "")
        let prompt = NSLocalizedString("app.open", tableName: nil,
                                       bundle: .module, value: "Open", comment: "")
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = message
        panel.prompt = prompt
        if panel.runModal() == .OK {
            NotificationCenter.default.post(name: .pkgViewerOpen, object: panel.urls.first)
        }
    }
}

/// Language picker. macOS has no per-app language override in System Settings
/// (only per-document), so the app provides its own menu.
///
/// The instance is **injected** rather than looked up. An earlier version read
/// `SharedModel.l10n`, which is only assigned in the window's `onAppear` — but
/// the menu bar is built before the window exists, so the menu captured a
/// throwaway `L10n` and every click updated an object nothing was observing
/// (the choice was persisted, so it appeared to work "next launch"). Passing the
/// app's own `@StateObject` removes the ordering dependency entirely.
struct LanguageMenu: View {
    @ObservedObject var l10n: L10n

    var body: some View {
        Menu(l10n.t("lang.menu")) {
            Toggle(l10n.t("lang.follow"), isOn: Binding(
                get: { l10n.followsSystem },
                set: { on in l10n.select(on ? nil : l10n.languageCode) }
            ))
            Divider()
            ForEach(L10n.available) { lang in
                Button {
                    l10n.select(lang.code)
                } label: {
                    if lang.code == l10n.languageCode {
                        Label(lang.nativeName, systemImage: "checkmark")
                    } else {
                        Text(lang.nativeName)
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set when a document arrives before the first window exists.
    var pendingOpen: URL?
    /// A bare path from the command line, consumed by the first window.
    nonisolated(unsafe) static var launchURL: URL?

    static func consumeLaunchURL() -> URL? {
        defer { launchURL = nil }
        return launchURL
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // The document scene forwards these to `onOpenURL`; this hook only
        // needs to cover files opened before any window is on screen.
        guard let u = urls.first else { return }
        Task { @MainActor in
            if SharedModel.instance == nil { pendingOpen = u }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

/// Lets the app delegate reach the shared view model without threading it
/// through the scene; set once the first window appears.
@MainActor
enum SharedModel {
    static var instance: PkgViewModel?
}

extension Notification.Name {
    static let pkgViewerOpen = Notification.Name("pkgviewer.open")
}

// MARK: - Root view

struct ContentView: View {
    @EnvironmentObject private var vm: PkgViewModel
    @EnvironmentObject private var l10n: L10n
    /// A file the scene was opened with (double-click, `open -a`, or a path
    /// given on the command line).
    var initialURL: URL?
    @State private var isTargeted = false
    @State private var showingRename = false

    var body: some View {
        VStack(spacing: 0) {
            ToolbarBar(showingRename: $showingRename)
            Divider().overlay(Theme.border)

            if let res = vm.result {
                if let err = res.failed, res.rows.isEmpty {
                    ErrorPane(message: err, path: res.path)
                } else {
                    TabStrip()
                    Divider().overlay(Theme.border)
                    content(for: res)
                }
            } else if vm.isLoading {
                LoadingPane()
            } else {
                DropPane(isTargeted: $isTargeted)
            }
        }
        .background(Theme.bg)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showingRename) { RenameSheet() }
        .onOpenURL { url in
            // Double-click / `open -a` / a document reopened from the Dock.
            vm.open(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pkgViewerOpen)) { n in
            if let u = n.object as? URL { vm.open(u) }
        }
        .onChange(of: initialURL) { _, u in
            // A path handed to the app on the command line, or the document the
            // window was created for.
            if let u = u, vm.result?.path != u {
                vm.open(u)
            }
        }
        .task {
            // Fires once on first appearance, covering a launch-time document.
            if let u = initialURL, vm.result?.path != u {
                vm.open(u)
            }
        }
    }

    @ViewBuilder
    private func content(for res: PkgResult) -> some View {
        switch vm.selectedTab {
        case .overview: OverviewTab(res: res)
        case .files: FilesTab()
        case .trophies: TrophiesTab()
        case .details: DetailsTab(res: res)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            DispatchQueue.main.async { vm.open(url) }
        }
        return true
    }
}

// MARK: - Toolbar

struct ToolbarBar: View {
    @EnvironmentObject private var vm: PkgViewModel
    @EnvironmentObject private var l10n: L10n
    @Binding var showingRename: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
            Text(l10n.t("app.name"))
                .font(.system(size: 13, weight: .semibold))
            // Version sits next to the name rather than in a menu only, so it
            // is visible without opening About — handy when someone reports a
            // bug against a build.
            Text(AppInfo.version)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.panelHi, in: Capsule())
                .textSelection(.enabled)

            Spacer()

            if vm.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 44)
            }

            // Language picker in the toolbar as well as the menu bar: on the
            // empty state there is no tab strip, and hunting the macOS menu bar
            // for it is not discoverable. `menuStyle(.borderlessButton)` keeps
            // it looking like a value rather than a button.
            Menu {
                Toggle(l10n.t("lang.follow"), isOn: Binding(
                    get: { l10n.followsSystem },
                    set: { on in l10n.select(on ? nil : l10n.languageCode) }
                ))
                Divider()
                ForEach(L10n.available) { lang in
                    Button { l10n.select(lang.code) } label: {
                        if lang.code == l10n.languageCode {
                            Label(lang.nativeName, systemImage: "checkmark")
                        } else {
                            Text(lang.nativeName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.system(size: 9))
                    Text(l10n.current.nativeName)
                }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .font(.system(size: 10))
            .foregroundStyle(Theme.textDim)
            .help(l10n.t("lang.menu"))

            Button { takeScreenshot() } label: {
                Label(l10n.t("app.screenshot"), systemImage: "camera")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(l10n.t("app.screenshotHelp"))

            if let res = vm.result, res.failed == nil {
                Button { showingRename = true } label: {
                    Label(l10n.t("app.rename"), systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(PkgLoader.buildCleanName(res).isEmpty)

                Button { copyInfo(res) } label: {
                    Label(l10n.t("app.copyInfo"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button { openFiles() } label: {
                Label(l10n.t("app.open"), systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Mat.bar)
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = l10n.t("app.openPanel.message")
        if panel.runModal() == .OK, let u = panel.url { vm.open(u) }
    }

    private func copyInfo(_ res: PkgResult) {
        var lines = [res.title, res.path.path, ""]
        lines += res.rows.map { "\($0.0): \($0.1)" }
        if !res.entries.isEmpty {
            lines.append("")
            lines.append("Files (\(res.entries.count)):")
            lines += res.entries.prefix(500).map { "  \($0.name)  \(Fmt.size($0.size))" }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Capture the window and offer to save it as a PNG.
    private func takeScreenshot() {
        guard let data = WindowCapture.pngOfFrontmostWindow() else {
            presentError(key: "shot.failed")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = WindowCapture.suggestedFilename(for: vm.result?.title)
        panel.message = l10n.t("shot.saveMessage")
        panel.prompt = l10n.t("shot.savePrompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            presentError(key: "shot.saveFailed", error.localizedDescription)
        }
    }

    /// Show a localised failure dialog.
    private func presentError(key: String, _ arg: String? = nil) {
        let msg = arg.map { Message(key, $0) } ?? Message(key)
        let alert = NSAlert()
        alert.messageText = l10n.t("error.title")
        alert.informativeText = msg.text { l10n.t($0) }
        alert.alertStyle = .warning
        alert.addButton(withTitle: l10n.t("alert.ok"))
        alert.runModal()
    }
}

// MARK: - Tabs

struct TabStrip: View {
    @EnvironmentObject private var vm: PkgViewModel
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PkgViewModel.Tab.allCases) { tab in
                let active = vm.selectedTab == tab
                Button {
                    vm.selectedTab = tab
                    if tab == .trophies { vm.loadTrophiesIfNeeded() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icon(tab)).font(.system(size: 11))
                        Text(l10n.t(tab.titleKey))
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(active ? Theme.panelHi : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(active ? Color.white : Theme.textDim)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.bg)
    }

    private func icon(_ t: PkgViewModel.Tab) -> String {
        switch t {
        case .overview: return "info.circle"
        case .files: return "doc.text"
        case .trophies: return "trophy"
        case .details: return "list.bullet.rectangle"
        }
    }
}

// MARK: - Panes

struct LoadingPane: View {
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(l10n.t("loading.reading"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorPane: View {
    let message: Message
    let path: URL
    @EnvironmentObject private var vm: PkgViewModel
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(Theme.warn)
            Text(l10n.t("error.title"))
                .font(.system(size: 15, weight: .semibold))
            Text(message.text { l10n.t($0) })
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text(path.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .lineLimit(2)
                .truncationMode(.middle)
            Button(l10n.t("error.chooseAnother")) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                if panel.runModal() == .OK, let u = panel.url { vm.open(u) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

struct DropPane: View {
    @EnvironmentObject private var l10n: L10n
    @Binding var isTargeted: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.8))
            VStack(spacing: 6) {
                Text(l10n.t("drop.title"))
                    .font(.system(size: 16, weight: .medium))
                Text(l10n.t("drop.formats"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }
            Text(l10n.t("drop.blurb"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            // Repeated here because this is what people see first: an About
            // window is easier to miss than a version line on the empty state.
            Text(AppInfo.versionWithBuild)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim.opacity(0.8))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
