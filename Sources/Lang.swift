import AppKit
import SwiftUI

// Язык окна. Фразы в коде — на русском; перевод берётся из Resources/Lang/<код>.json.
// Нет перевода фразы — английский, нет и его — русский.
enum Lang {
    static let all = ["ru", "en", "zh", "ja", "hi"]
    private(set) static var code = "ru"
    private static var table: [String: String] = [:]
    private static var english: [String: String] = [:]

    // Языки системы — из общих настроек macOS, а не из настроек самой программы (там может стоять выбранный в ней язык).
    static var systemLanguages: [String] {
        (CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String])
            ?? Locale.preferredLanguages
    }

    static func resolve(_ setting: String) -> String {
        if all.contains(setting) { return setting }
        for l in systemLanguages {
            let p = String(l.prefix(2))
            if all.contains(p) { return p }
        }
        return "en"
    }

    // Системные пункты меню macOS («Автозаполнение», «Диктовка»…) macOS переводит при запуске программы:
    // запоминаем, на каком языке они собраны, и задаём программе её язык на следующий запуск.
    private(set) static var launchedMenuLang = ""
    static func captureLaunchMenuLanguage() {
        if launchedMenuLang.isEmpty { launchedMenuLang = Bundle.main.preferredLocalizations.first ?? "en" }
    }
    static func menuLang(_ c: String) -> String { c == "zh" ? "zh-Hans" : c }
    static var menuNeedsRestart: Bool { !launchedMenuLang.isEmpty && menuLang(code) != launchedMenuLang }
    static func syncSystemMenus(_ setting: String) {
        if all.contains(setting) { UserDefaults.standard.set([menuLang(setting)], forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
    }

    static func apply(_ setting: String) {
        code = resolve(setting)
        english = load("en")
        table = code == "ru" ? [:] : (code == "en" ? english : load(code))
        TimeFormat.reset()
    }

    // Переводы любого языка (для служебных слов в файлах, когда язык меняется). Читаются один раз.
    private static var cache: [String: [String: String]] = [:]
    static func words(_ c: String) -> [String: String] {
        if let d = cache[c] { return d }
        let d = load(c); cache[c] = d; return d
    }

    private static func load(_ c: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: c, withExtension: "json", subdirectory: "Lang")
                ?? Bundle.main.url(forResource: c, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }

    static func lookup(_ s: String) -> String? {
        if code == "ru" { return nil }
        return table[s] ?? english[s]
    }

    // Шрифт: Bellota — для русского и английского; для остальных — встроенные шрифты в том же мягком стиле.
    static func fontName(bold: Bool) -> String {
        switch code {
        case "hi": return bold ? "Baloo2-SemiBold" : "Baloo2-Regular"
        case "ja": return bold ? "RoundedMplus1c-Bold" : "RoundedMplus1c-Regular"
        case "zh": return "ZCOOLKuaiLe-Regular"
        default: return bold ? "Bellota-Bold" : "Bellota-Regular"
        }
    }

    static var scale: CGFloat { 1 }

    // Латиница, кириллица и цифры — всегда Bellota; знаки, которых в ней нет, — из шрифта языка.
    static func nsFont(_ size: CGFloat, bold: Bool) -> NSFont {
        let base = NSFont(name: bold ? "Bellota-Bold" : "Bellota-Regular", size: size) ?? .systemFont(ofSize: size)
        guard ["zh", "ja", "hi"].contains(code) else { return base }
        let fallback = NSFontDescriptor(name: fontName(bold: bold), size: size)
        let desc = base.fontDescriptor.addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: desc, size: size) ?? base
    }

    static var locale: Locale { Locale(identifier: code == "zh" ? "zh-Hans" : code) }
}

func tr(_ s: String) -> String { Lang.lookup(s) ?? s }
func trf(_ s: String, _ args: CVarArg...) -> String { String(format: tr(s), arguments: args) }

// Записи истории в тесте хранятся готовым русским текстом — переводим при показе.
// (В настоящей программе история будет храниться по смыслу, а текст — собираться на текущем языке.)
func displaySummary(_ s: String) -> String {
    guard Lang.code != "ru" else { return s }
    if let t = Lang.lookup(s) { return t }
    if let re = try? NSRegularExpression(pattern: "^(\\d+) новых, (\\d+) обновлено$"),
       let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
       let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s) {
        return trf("%d новых, %d обновлено", Int(s[a]) ?? 0, Int(s[b]) ?? 0)
    }
    if let r = s.range(of: ": ") {
        return String(s[..<r.lowerBound]) + ": " + tr(String(s[r.upperBound...]))
    }
    return s
}
