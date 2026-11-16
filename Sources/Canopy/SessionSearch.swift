import Foundation

/// The sidebar's session search: which rows a typed query keeps.
///
/// A query is split on whitespace and every term must appear somewhere in the
/// row's title or project, case- and diacritic-insensitively, in any order —
/// so `canopy mirror` finds "can you make mirror pane…" filed under Canopy.
///
/// Terms and text are folded first and then compared literally. Foundation's
/// insensitive `range(of:options:)` is not transitive ("ß" matches "ss" but not
/// "s"), and `narrows` depends on containment being transitive.
enum SessionSearch {
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
    }

    static func matches(_ terms: [String], _ row: SidebarRow) -> Bool {
        matches(terms, fields: [row.title, row.displayProject])
    }

    /// True when every row matching `terms` also matches `previous`: each
    /// previous term sits inside some new term. An empty `previous` is not a
    /// search, so nothing narrows it.
    static func narrows(_ terms: [String], _ previous: [String]) -> Bool {
        !previous.isEmpty && previous.allSatisfy { old in
            terms.contains { $0.range(of: old, options: .literal) != nil }
        }
    }

    /// `terms` must come from `terms(_:)`, which folds them.
    static func matches(_ terms: [String], fields: [String]) -> Bool {
        let haystack = fold(fields.joined(separator: "\n"))
        return terms.allSatisfy { haystack.range(of: $0, options: .literal) != nil }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
