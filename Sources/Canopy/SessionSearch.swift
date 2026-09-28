import Foundation

/// The sidebar's session search: which rows a typed query keeps.
///
/// A query is split on whitespace and every term must appear somewhere in the
/// row's title or project, case- and diacritic-insensitively, in any order —
/// so `canopy mirror` finds "can you make mirror pane…" filed under Canopy.
enum SessionSearch {
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(_ terms: [String], _ row: SidebarRow) -> Bool {
        matches(terms, fields: [row.title, row.displayProject, row.project])
    }

    static func matches(_ terms: [String], fields: [String]) -> Bool {
        let haystack = fields.joined(separator: "\n")
        return terms.allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
