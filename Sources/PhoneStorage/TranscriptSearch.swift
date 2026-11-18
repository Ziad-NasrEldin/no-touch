import Foundation
import RecorderContracts

// `TranscriptSearchHit` moved to RecorderContracts (I1) — the store's
// extended protocol surface exposes `searchTranscripts` across modules.

/// Deterministic tokenizer + normalizer for Arabic and English transcript
/// search. Applied identically at index time and query time, so a diacritized
/// query matches undiacritized text and vice versa.
///
/// Normalization (documented, intentionally conservative):
/// - Arabic tashkeel/harakat (U+064B–U+065F, U+0670, U+06D6–U+06ED) stripped
/// - tatweel/kashida (U+0640) stripped
/// - alef variants أ إ آ ٱ → ا
/// - alef maqsura ى → ي; ta marbuta ة → ه (recall-oriented, common in Arabic IR)
/// - hamza-on-waw/ya carriers ؤ → و, ئ → ي; lone hamza ء removed
/// - Latin text lowercased + diacritic-insensitive folded
/// - Everything else (digits, punctuation boundaries) passed through as-is
enum TranscriptNormalizer {

    /// Code-point ranges of Arabic combining marks to drop.
    private static let arabicDiacritics: [ClosedRange<UInt32>] = [
        0x064B...0x065F, // fathatan..waw hamza below + Quranic marks
        0x0670...0x0670, // superscript alef
        0x06D6...0x06ED, // Quranic annotation signs
    ]

    static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if arabicDiacritics.contains(where: { $0.contains(value) }) { continue }
            switch value {
            case 0x0640: continue                 // tatweel
            case 0x0621: continue                 // lone hamza
            case 0x0623, 0x0625, 0x0622, 0x0671:  // أ إ آ ٱ
                scalars.append("\u{0627}")        // → ا
            case 0x0649:                          // ى
                scalars.append("\u{064A}")        // → ي
            case 0x0629:                          // ة
                scalars.append("\u{0647}")        // → ه
            case 0x0624:                          // ؤ
                scalars.append("\u{0648}")        // → و
            case 0x0626:                          // ئ
                scalars.append("\u{064A}")        // → ي
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: nil
        )
    }

    /// Splits into lowercase-folded index tokens on letter/number boundaries.
    /// Uses CFStringTokenizer-free scalar scan so results are identical on
    /// iOS and macOS and independent of ICU version drift.
    static func tokens(from text: String) -> [String] {
        let normalized = normalize(text)
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// SQLite prefix range bounds for `term >= lower AND term <= upper`.
    /// The upper bound appends the highest scalar so `term` itself and all
    /// its extensions match (prefix search on the final token and exact-ish
    /// prefix behavior on earlier tokens).
    static func prefixBounds(_ term: String) -> (lower: String, upper: String) {
        (term, term + "\u{10FFFF}")
    }
}
