import Foundation

/// Every language whisper can transcribe, for the searchable picker in Settings.
///
/// The menu bar keeps a short list of the common ones — a 99-item submenu is unusable —
/// so this table is what makes the rest reachable, and what turns a stored code back
/// into a name wherever one is shown.
struct Language {
    let code: String        // whisper's own two- or three-letter code
    let english: String
    let native: String      // "" when it matches the English name

    /// Both names on one line: what the picker shows and what search matches against.
    var label: String { native.isEmpty ? english : "\(english) — \(native)" }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return english.lowercased().contains(q)
            || native.lowercased().contains(q)
            || code.lowercased() == q
    }

    /// Codes offered directly in the menu bar. Everything else is reachable from
    /// Settings, which is also where a selection outside this list gets made.
    static let common = ["en", "zh", "ja", "ko", "es", "fr", "de"]

    static func named(_ code: String) -> Language? { all.first { $0.code == code } }

    /// A stored code always renders as something readable, even one this build predates.
    static func label(_ code: String) -> String { named(code)?.label ?? code }

    /// Short form for status lines, where "English — English" would be noise.
    static func shortLabel(_ code: String) -> String {
        guard let lang = named(code) else { return code }
        return lang.native.isEmpty ? lang.english : lang.native
    }

    static let all: [Language] = [
        Language(code: "en", english: "English", native: ""),
        Language(code: "zh", english: "Chinese", native: "中文"),
        Language(code: "de", english: "German", native: "Deutsch"),
        Language(code: "es", english: "Spanish", native: "Español"),
        Language(code: "ru", english: "Russian", native: "Русский"),
        Language(code: "ko", english: "Korean", native: "한국어"),
        Language(code: "fr", english: "French", native: "Français"),
        Language(code: "ja", english: "Japanese", native: "日本語"),
        Language(code: "pt", english: "Portuguese", native: "Português"),
        Language(code: "tr", english: "Turkish", native: "Türkçe"),
        Language(code: "pl", english: "Polish", native: "Polski"),
        Language(code: "ca", english: "Catalan", native: "Català"),
        Language(code: "nl", english: "Dutch", native: "Nederlands"),
        Language(code: "ar", english: "Arabic", native: "العربية"),
        Language(code: "sv", english: "Swedish", native: "Svenska"),
        Language(code: "it", english: "Italian", native: "Italiano"),
        Language(code: "id", english: "Indonesian", native: "Bahasa Indonesia"),
        Language(code: "hi", english: "Hindi", native: "हिन्दी"),
        Language(code: "fi", english: "Finnish", native: "Suomi"),
        Language(code: "vi", english: "Vietnamese", native: "Tiếng Việt"),
        Language(code: "he", english: "Hebrew", native: "עברית"),
        Language(code: "uk", english: "Ukrainian", native: "Українська"),
        Language(code: "el", english: "Greek", native: "Ελληνικά"),
        Language(code: "ms", english: "Malay", native: "Bahasa Melayu"),
        Language(code: "cs", english: "Czech", native: "Čeština"),
        Language(code: "ro", english: "Romanian", native: "Română"),
        Language(code: "da", english: "Danish", native: "Dansk"),
        Language(code: "hu", english: "Hungarian", native: "Magyar"),
        Language(code: "ta", english: "Tamil", native: "தமிழ்"),
        Language(code: "no", english: "Norwegian", native: "Norsk"),
        Language(code: "th", english: "Thai", native: "ไทย"),
        Language(code: "ur", english: "Urdu", native: "اردو"),
        Language(code: "hr", english: "Croatian", native: "Hrvatski"),
        Language(code: "bg", english: "Bulgarian", native: "Български"),
        Language(code: "lt", english: "Lithuanian", native: "Lietuvių"),
        Language(code: "la", english: "Latin", native: "Latina"),
        Language(code: "mi", english: "Maori", native: "Māori"),
        Language(code: "ml", english: "Malayalam", native: "മലയാളം"),
        Language(code: "cy", english: "Welsh", native: "Cymraeg"),
        Language(code: "sk", english: "Slovak", native: "Slovenčina"),
        Language(code: "te", english: "Telugu", native: "తెలుగు"),
        Language(code: "fa", english: "Persian", native: "فارسی"),
        Language(code: "lv", english: "Latvian", native: "Latviešu"),
        Language(code: "bn", english: "Bengali", native: "বাংলা"),
        Language(code: "sr", english: "Serbian", native: "Српски"),
        Language(code: "az", english: "Azerbaijani", native: "Azərbaycan"),
        Language(code: "sl", english: "Slovenian", native: "Slovenščina"),
        Language(code: "kn", english: "Kannada", native: "ಕನ್ನಡ"),
        Language(code: "et", english: "Estonian", native: "Eesti"),
        Language(code: "mk", english: "Macedonian", native: "Македонски"),
        Language(code: "br", english: "Breton", native: "Brezhoneg"),
        Language(code: "eu", english: "Basque", native: "Euskara"),
        Language(code: "is", english: "Icelandic", native: "Íslenska"),
        Language(code: "hy", english: "Armenian", native: "Հայերեն"),
        Language(code: "ne", english: "Nepali", native: "नेपाली"),
        Language(code: "mn", english: "Mongolian", native: "Монгол"),
        Language(code: "bs", english: "Bosnian", native: "Bosanski"),
        Language(code: "kk", english: "Kazakh", native: "Қазақ"),
        Language(code: "sq", english: "Albanian", native: "Shqip"),
        Language(code: "sw", english: "Swahili", native: "Kiswahili"),
        Language(code: "gl", english: "Galician", native: "Galego"),
        Language(code: "mr", english: "Marathi", native: "मराठी"),
        Language(code: "pa", english: "Punjabi", native: "ਪੰਜਾਬੀ"),
        Language(code: "si", english: "Sinhala", native: "සිංහල"),
        Language(code: "km", english: "Khmer", native: "ខ្មែរ"),
        Language(code: "sn", english: "Shona", native: "chiShona"),
        Language(code: "yo", english: "Yoruba", native: "Yorùbá"),
        Language(code: "so", english: "Somali", native: "Soomaali"),
        Language(code: "af", english: "Afrikaans", native: ""),
        Language(code: "oc", english: "Occitan", native: ""),
        Language(code: "ka", english: "Georgian", native: "ქართული"),
        Language(code: "be", english: "Belarusian", native: "Беларуская"),
        Language(code: "tg", english: "Tajik", native: "Тоҷикӣ"),
        Language(code: "sd", english: "Sindhi", native: "سنڌي"),
        Language(code: "gu", english: "Gujarati", native: "ગુજરાતી"),
        Language(code: "am", english: "Amharic", native: "አማርኛ"),
        Language(code: "yi", english: "Yiddish", native: "ייִדיש"),
        Language(code: "lo", english: "Lao", native: "ລາວ"),
        Language(code: "uz", english: "Uzbek", native: "Oʻzbek"),
        Language(code: "fo", english: "Faroese", native: "Føroyskt"),
        Language(code: "ht", english: "Haitian Creole", native: "Kreyòl ayisyen"),
        Language(code: "ps", english: "Pashto", native: "پښتو"),
        Language(code: "tk", english: "Turkmen", native: "Türkmen"),
        Language(code: "nn", english: "Norwegian Nynorsk", native: "Nynorsk"),
        Language(code: "mt", english: "Maltese", native: "Malti"),
        Language(code: "sa", english: "Sanskrit", native: "संस्कृतम्"),
        Language(code: "lb", english: "Luxembourgish", native: "Lëtzebuergesch"),
        Language(code: "my", english: "Burmese", native: "မြန်မာ"),
        Language(code: "bo", english: "Tibetan", native: "བོད་སྐད"),
        Language(code: "tl", english: "Tagalog", native: ""),
        Language(code: "mg", english: "Malagasy", native: ""),
        Language(code: "as", english: "Assamese", native: "অসমীয়া"),
        Language(code: "tt", english: "Tatar", native: "Татар"),
        Language(code: "haw", english: "Hawaiian", native: "ʻŌlelo Hawaiʻi"),
        Language(code: "ln", english: "Lingala", native: "Lingála"),
        Language(code: "ha", english: "Hausa", native: ""),
        Language(code: "ba", english: "Bashkir", native: "Башҡорт"),
        Language(code: "jw", english: "Javanese", native: "Basa Jawa"),
        Language(code: "su", english: "Sundanese", native: "Basa Sunda"),
        Language(code: "yue", english: "Cantonese", native: "粵語"),
    ]
}
