import Foundation

/// Helpers for parsing Anthropic model identifiers and aliases.
enum ModelNameFormatter {
    /// Split a model ID or alias into its base and a display-ready variant suffix.
    ///
    /// Examples:
    ///   "claude-opus-4-7[1m]" → (base: "claude-opus-4-7", displaySuffix: " (1M)")
    ///   "opus[1m]"            → (base: "opus",            displaySuffix: " (1M)")
    ///   "claude-opus-4-6"     → (base: "claude-opus-4-6", displaySuffix: "")
    ///   "opus[beta]"          → (base: "opus",            displaySuffix: " [beta]")
    ///
    /// Assumes a single, well-formed `[variant]` suffix at the end. Nested or
    /// malformed brackets fall through to the no-variant path.
    static func splitVariant(_ model: String) -> (base: String, displaySuffix: String) {
        guard let bracketStart = model.firstIndex(of: "["),
              let bracketEnd = model[bracketStart...].firstIndex(of: "]")
        else { return (model, "") }
        let variant = String(model[model.index(after: bracketStart)..<bracketEnd])
        let base = String(model[..<bracketStart])
        // Anthropic markets the long-context tier as "(1M)"; pass other variants through verbatim.
        let suffix = variant.uppercased() == "1M" ? " (1M)" : " [\(variant)]"
        return (base, suffix)
    }
}
