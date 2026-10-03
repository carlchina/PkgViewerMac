import Foundation

/// Headless inspection matching the Python tool's `--info` mode, so the same
/// packages can be checked from a terminal or a script.
enum InfoPrinter {
    static func printInfo(_ url: URL) {
        let res = PkgLoader.load(url: url)
        print("FILE: \(url.lastPathComponent)")
        if let f = res.failed {
            // CLI output stays English by design (stable, greppable contract).
            print("ERROR: \(f.english())")
            return
        }
        print("TITLE: \(res.title)")
        for (k, v) in res.rows {
            print("\(k): \(v)")
        }
        print("--- entries (\(res.entries.count)) ---")
        for e in res.entries {
            var extra = ""
            if let c = e.codec { extra = " codec=\(c)" }
            if e.isTrophyPack { extra += " trophy" }
            print("  id=\(e.id) size=\(e.size) name='\(e.name)'\(extra)")
        }
        let clean = PkgLoader.buildCleanName(res)
        if !clean.isEmpty { print("--- rename: \(clean)") }
        let sum = PkgLoader.summaryLine(res)
        if !sum.isEmpty { print("--- summary: \(sum)") }
        // Summary pills, as shown under the cover art.
        let badges = SummaryBadges.make(for: res)
        print("--- badges (\(badges.count)) ---")
        for b in badges {
            let hex = String(format: "#%06X", b.color.rgbHexValue)
            print(String(format: "  %-10@ %-10@ %@", b.kind.rawValue as NSString, b.text as NSString, hex as NSString))
        }
        print("--- format badge: \(ContainerFormat.detect(for: res).rawValue)")
    }

    /// `--covers <path>`: list the cover art the GUI would show, and optionally
    /// write it out. Cover extraction needs a handle on the file that was
    /// actually parsed, which is not always the path the user passed (an exFAT
    /// wrapper is a directory) — so this mirrors the view model's logic rather
    /// than re-deriving it.
    static func printCovers(_ url: URL, exportTo dir: URL?) {
        let res = PkgLoader.load(url: url)
        guard let handle = FileHandleReader(url: res.path) else {
            print("ERROR: cannot open \(res.path.lastPathComponent) for reading")
            return
        }
        defer { handle.close() }
        let ex = res.kind == "unknown" ? nil : try? ExfatImage(reader: handle)
        let covers = PkgLoader.extractCovers(res, reader: handle, exfat: ex)
        print("resolved path: \(res.path.path)")
        print("icon entry    : \(res.iconName)")
        print("candidates    : \(res.entries.filter { $0.name.lowercased().hasSuffix(".png") }.count)")
        print("--- covers (\(covers.count)) ---")
        for c in covers {
            print(String(format: "  %-16@ %8d bytes", c.name as NSString, c.data.count))
            if let dir {
                // Entry names can contain subdirectories (USRDIR/data/...),
                // so the destination folder has to be created for each file.
                let out = dir.appendingPathComponent(c.name)
                try? FileManager.default.createDirectory(
                    at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try c.data.write(to: out, options: .atomic)
                    print("      -> \(out.path)")
                } catch {
                    print("      !! \(error.localizedDescription)")
                }
            }
        }
    }
}
