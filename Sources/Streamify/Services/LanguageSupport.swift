import Foundation

enum LanguageSupport {
    /// Normalises any ISO 639-1/2 code, native name, or common alias to a canonical
    /// two-letter ISO 639-1 code (e.g. "rus" → "ru", "Japanese" → "ja").
    /// Returns the input unchanged if it is not recognised.
    static func normalise(_ rawCode: String) -> String {
        let value = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return aliases[value] ?? value
    }

    /// Returns a human-readable display name for a canonical ISO 639-1 code.
    /// Falls back to `Locale.current.localizedString(forLanguageCode:)`, then the code uppercased.
    static func displayName(for rawCode: String) -> String {
        let code = normalise(rawCode)
        guard code != "und" else { return "Unknown" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    /// Full sorted list of languages shown in pickers throughout the app.
    static let commonLanguages: [(name: String, code: String)] = [
        ("Arabic",     "ar"),
        ("Bengali",    "bn"),
        ("Bulgarian",  "bg"),
        ("Chinese",    "zh"),
        ("Croatian",   "hr"),
        ("Czech",      "cs"),
        ("Danish",     "da"),
        ("Dutch",      "nl"),
        ("English",    "en"),
        ("Estonian",   "et"),
        ("Filipino",   "tl"),
        ("Finnish",    "fi"),
        ("French",     "fr"),
        ("German",     "de"),
        ("Greek",      "el"),
        ("Hebrew",     "he"),
        ("Hindi",      "hi"),
        ("Hungarian",  "hu"),
        ("Indonesian", "id"),
        ("Italian",    "it"),
        ("Japanese",   "ja"),
        ("Korean",     "ko"),
        ("Latvian",    "lv"),
        ("Lithuanian", "lt"),
        ("Malay",      "ms"),
        ("Marathi",    "mr"),
        ("Norwegian",  "no"),
        ("Polish",     "pl"),
        ("Portuguese", "pt"),
        ("Punjabi",    "pa"),
        ("Romanian",   "ro"),
        ("Russian",    "ru"),
        ("Serbian",    "sr"),
        ("Slovak",     "sk"),
        ("Slovenian",  "sl"),
        ("Spanish",    "es"),
        ("Swedish",    "sv"),
        ("Tamil",      "ta"),
        ("Telugu",     "te"),
        ("Thai",       "th"),
        ("Turkish",    "tr"),
        ("Ukrainian",  "uk"),
        ("Vietnamese", "vi"),
    ]

    /// Shorter list used on the onboarding screen for quick selection.
    static let suggestedLanguages: [String] = [
        "English", "Spanish", "French", "German", "Italian",
        "Japanese", "Korean", "Portuguese", "Arabic", "Hebrew",
        "Russian", "Turkish",
    ]

    // MARK: - Alias table

    /// Maps any recognised code/alias to its canonical ISO 639-1 code.
    static let aliases: [String: String] = [
        "ar": "ar", "ara": "ar", "arabic": "ar",
        "bn": "bn", "ben": "bn", "bengali": "bn",
        "bg": "bg", "bul": "bg", "bulgarian": "bg",
        "zh": "zh", "chi": "zh", "zho": "zh", "chinese": "zh", "mandarin": "zh", "cantonese": "zh",
        "hr": "hr", "hrv": "hr", "croatian": "hr",
        "cs": "cs", "cze": "cs", "ces": "cs", "czech": "cs",
        "da": "da", "dan": "da", "danish": "da",
        "nl": "nl", "dut": "nl", "nld": "nl", "dutch": "nl",
        "en": "en", "eng": "en", "english": "en",
        "et": "et", "est": "et", "estonian": "et",
        "tl": "tl", "fil": "tl", "filipino": "tl",
        "fi": "fi", "fin": "fi", "finnish": "fi",
        "fr": "fr", "fre": "fr", "fra": "fr", "french": "fr", "francais": "fr",
        "de": "de", "ger": "de", "deu": "de", "german": "de", "deutsch": "de",
        "el": "el", "gre": "el", "ell": "el", "greek": "el",
        "he": "he", "heb": "he", "hebrew": "he",
        "hi": "hi", "hin": "hi", "hindi": "hi",
        "hu": "hu", "hun": "hu", "hungarian": "hu",
        "id": "id", "ind": "id", "indonesian": "id",
        "it": "it", "ita": "it", "italian": "it", "italiano": "it",
        "ja": "ja", "jpn": "ja", "japanese": "ja",
        "ko": "ko", "kor": "ko", "korean": "ko",
        "lv": "lv", "lav": "lv", "latvian": "lv",
        "lt": "lt", "lit": "lt", "lithuanian": "lt",
        "ms": "ms", "may": "ms", "msa": "ms", "malay": "ms",
        "mr": "mr", "mar": "mr", "marathi": "mr",
        "no": "no", "nor": "no", "norwegian": "no",
        "pl": "pl", "pol": "pl", "polish": "pl",
        "pt": "pt", "por": "pt", "portuguese": "pt", "portugues": "pt",
        "pa": "pa", "pan": "pa", "punjabi": "pa",
        "ro": "ro", "rum": "ro", "ron": "ro", "romanian": "ro",
        "ru": "ru", "rus": "ru", "russian": "ru",
        "sr": "sr", "srp": "sr", "serbian": "sr",
        "sk": "sk", "slk": "sk", "slo": "sk", "slovak": "sk",
        "sl": "sl", "slv": "sl", "slovenian": "sl",
        "es": "es", "spa": "es", "esp": "es", "spanish": "es", "espanol": "es",
        "sv": "sv", "swe": "sv", "swedish": "sv",
        "ta": "ta", "tam": "ta", "tamil": "ta",
        "te": "te", "tel": "te", "telugu": "te",
        "th": "th", "tha": "th", "thai": "th",
        "tr": "tr", "tur": "tr", "turkish": "tr",
        "uk": "uk", "ukr": "uk", "ukrainian": "uk",
        "vi": "vi", "vie": "vi", "vietnamese": "vi",
        "cat": "ca", "ca": "ca", "catalan": "ca",
        "und": "und",
    ]
}
