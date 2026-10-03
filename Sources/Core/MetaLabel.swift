import Foundation

/// Translation of the metadata field labels the parsers emit.
///
/// The parsers produce stable English keys ("Title ID", "Min. System", …) so
/// that logic such as `rowDict["Region"]` keeps working regardless of the UI
/// language. Localisation happens at display time: `key` is looked up as
/// `meta.<key>`, and unknown keys fall through unchanged.
enum MetaLabel {
    /// Metadata label -> localisation key. Keys with spaces or dots are the
    /// ones the parsers actually emit; the rest are defensive.
    private static let keys: [String: String] = [
        "Platform": "meta.platform",
        "Package": "meta.package",
        "Signature": "meta.signature",
        "Size": "meta.size",
        "PFS image": "meta.pfsImage",
        "Entries": "meta.entries",
        "Title ID": "meta.titleId",
        "Content ID": "meta.contentId",
        "Region": "meta.region",
        "Type": "meta.type",
        "Content Ver": "meta.contentVer",
        "Master Ver": "meta.masterVer",
        "Concept ID": "meta.conceptId",
        "Min. System": "meta.minSystem",
        "DRM": "meta.drm",
        "SDK": "meta.sdk",
        "Version": "meta.version",
        "Base Version": "meta.baseVersion",
        "Languages": "meta.languages",
        "Built": "meta.built",
        "Passcode": "meta.passcode",
        "Assets": "meta.assets",
        "Note": "meta.note",
        "Inner file": "meta.innerFile",
    ]

    /// True when `label` is one of the translatable metadata labels (as
    /// opposed to a raw SFO/JSON key shown in the Details tab).
    static func isKnown(_ label: String) -> Bool {
        keys[label] != nil
    }

    /// Localised display text for a metadata label.
    static func display(_ label: String, _ t: (String) -> String) -> String {
        guard let k = keys[label] else { return label }
        return t(k)
    }
}
