import Foundation
import RecorderContracts

/// Derives `LanguageSpan`s (`ar` / `en`) for a transcript segment. Whisper
/// detects one dominant language per decode window; code-switching inside a
/// window is recovered here by classifying each word-timed token by Unicode
/// script — Arabic scalars → `ar`, Latin → `en`. Digits, punctuation, and
/// neutral tokens inherit the surrounding language. Spans carry exact
/// UTF-16 text ranges and source timing, so ar/en switching stays inspectable
/// even when the engine emits only word-level timing.
public enum LanguageSpanDeriver {

    /// Classifies text by dominant script. Returns "ar" when the string
    /// contains Arabic scalars, "en" when it contains only non-Arabic letters
    /// (Latin and others — the product only distinguishes ar/en), or nil for
    /// digit/punctuation-only strings that carry no language evidence.
    public static func classify(_ text: String) -> String? {
        var sawArabic = false
        var sawLetter = false
        for scalar in text.unicodeScalars {
            if (0x0600...0x06FF).contains(scalar.value)
                || (0x0750...0x077F).contains(scalar.value)
                || (0x08A0...0x08FF).contains(scalar.value)
                || (0xFB50...0xFDFF).contains(scalar.value)
                || (0xFE70...0xFEFF).contains(scalar.value)
            {
                sawArabic = true
            } else if CharacterSet.letters.contains(scalar) {
                sawLetter = true
            }
        }
        if sawArabic { return "ar" }
        if sawLetter { return "en" }
        return nil
    }

    /// Builds spans for a segment. Prefers per-word timing when `words` is
    /// non-empty; otherwise emits a single segment-wide span from
    /// `detectedLanguage` (or script-majority of `text`, or "und") covering
    /// `segmentStart...segmentEnd`.
    public static func spans(
        text: String,
        words: [EngineWord]?,
        detectedLanguage: String?,
        segmentStart: TimeInterval = 0,
        segmentEnd: TimeInterval = 0
    ) -> [LanguageSpan] {
        guard !text.isEmpty else { return [] }
        let utf16Count = (text as NSString).length

        guard let words, !words.isEmpty else {
            let code = detectedLanguage ?? majorityLanguage(of: text) ?? "und"
            return [LanguageSpan(
                languageCode: code,
                startTime: segmentStart, endTime: segmentEnd,
                textRangeStart: 0, textRangeEnd: utf16Count
            )]
        }

        // Locate each word's UTF-16 range in the segment text. Whisper word
        // strings may carry leading spaces, so match on the trimmed word and
        // advance a cursor; unmatched words absorb into the previous span.
        let nsText = text as NSString
        var raw: [(code: String?, start: TimeInterval, end: TimeInterval, r0: Int, r1: Int)] = []
        var cursor = 0
        for word in words {
            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            var r0 = cursor
            var r1 = cursor
            if !trimmed.isEmpty, cursor < utf16Count,
               let found = nsText.range(
                   of: trimmed,
                   options: [],
                   range: NSRange(location: cursor, length: utf16Count - cursor)
               ).nonNil
            {
                r0 = found.location
                r1 = found.location + found.length
                cursor = r1
            }
            raw.append((classify(trimmed), word.start, word.end, r0, r1))
        }

        // Assign neutral tokens to the nearest language: prefer previous,
        // else next, else detected language.
        for i in raw.indices where raw[i].code == nil {
            if i > 0, let prev = raw[i - 1].code {
                raw[i].code = prev
            } else if let next = raw[i...].first(where: { $0.code != nil })?.code {
                raw[i].code = next
            } else {
                raw[i].code = detectedLanguage
            }
        }

        // Merge consecutive same-language runs into spans.
        var merged: [LanguageSpan] = []
        for word in raw {
            guard let code = word.code else { continue }
            if let last = merged.last, last.languageCode == code {
                var updated = last
                updated.endTime = word.end
                updated.textRangeEnd = max(last.textRangeEnd, word.r1)
                merged[merged.count - 1] = updated
            } else {
                merged.append(LanguageSpan(
                    languageCode: code,
                    startTime: word.start,
                    endTime: word.end,
                    textRangeStart: word.r0,
                    textRangeEnd: word.r1
                ))
            }
        }
        if merged.isEmpty {
            let code = detectedLanguage ?? majorityLanguage(of: text) ?? "und"
            merged.append(LanguageSpan(
                languageCode: code,
                startTime: segmentStart, endTime: segmentEnd,
                textRangeStart: 0, textRangeEnd: utf16Count
            ))
        }
        return merged
    }

    private static func majorityLanguage(of text: String) -> String? {
        var arCount = 0
        var enCount = 0
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            switch classify(String(word)) {
            case "ar": arCount += 1
            case "en": enCount += 1
            default: break
            }
        }
        if arCount == 0 && enCount == 0 { return nil }
        return arCount >= enCount ? "ar" : "en"
    }
}

private extension NSRange {
    var nonNil: NSRange? { location == NSNotFound ? nil : self }
}
