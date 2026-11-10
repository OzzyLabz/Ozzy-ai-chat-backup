import Foundation

// MARK: - Служебные слова в файлах архива и «Навыки и MCP»
//
// Язык файлов — тот же, что у программы. Переводы лежат в Resources/Lang/<язык>.json с приставкой «archive:»,
// чтобы не путаться с надписями окна. Нет перевода — английский, нет и его — русский.
enum AW {
    // Все служебные слова (русский образец). Порядок не важен.
    static let words = [
        "источник", "дата", "время", "проект", "сессия",
        "Без названия", "[изображение]", "〔вставленный текст〕", "〔конец вставки〕",
        "[файл: %@]", "[вложение: %@]", "Вопрос:", "Ответ:", "↳ другой вариант",
        "Журнал сохранений", "Записи программы «Бэкап ИИ». Новые — внизу.",
        "Обзор", "Навыки", "Плагины", "Инструкции агентов", "Свои папки", "_прежние", "Журнал изменений", "‹скрыто›",
        "Записи программы «Бэкап ИИ» о навыках, MCP и плагинах. Новые — внизу."
    ]

    static func w(_ ru: String, lang: String = Lang.code) -> String {
        if lang == "ru" { return ru }
        return Lang.words(lang)["archive:" + ru] ?? Lang.words("en")["archive:" + ru] ?? ru
    }
    static func f(_ ru: String, _ arg: String) -> String { String(format: w(ru), arg) }
    static var journalFile: String { w("Журнал сохранений") + ".md" }
}

// MARK: - Смена языка служебных слов в уже сохранённом
//
// Что делает (согласовано): переименовывает свои служебные файлы, переписывает служебные строки в переписках,
// чинит ссылки на них в хранилище Obsidian и поля в запросах Dataview / .base, делает то же в копии архива.
// Папки, которые выбрал или назвал человек, не трогает. Каждый шаг можно повторить: если сохранение
// прервали, при следующем запуске программа доделает — уже переписанное просто не меняется.
enum ArchiveLang {
    static let fm = FileManager.default

    // Язык, на котором написаны служебные слова (у версии 1.0 — русский). Вернёт новый язык, если что-то переписывалось.
    @discardableResult
    static func ensure(_ config: AppConfig) -> String? {
        let from = config.archiveLang ?? "ru"
        let to = Lang.code
        guard from != to else { return nil }
        migrate(config, from: from, to: to)
        return to
    }

    static func migrate(_ config: AppConfig, from: String, to: String) {
        let pair = { (ru: String) in (AW.w(ru, lang: from), AW.w(ru, lang: to)) }
        var chatRoots = [config.archiveURL]
        if let m = config.mirrorPath, !m.isEmpty { chatRoots.append(URL(fileURLWithPath: m, isDirectory: true)) }
        for root in chatRoots where isDir(root) {
            rewriteChats(root, pair)
            renameJournal(root, pair)
        }
        var kitRoots = [config.kitURL]
        if let m = config.kitMirror, !m.isEmpty { kitRoots.append(URL(fileURLWithPath: m, isDirectory: true)) }
        for (i, root) in kitRoots.enumerated() where isDir(root) {
            renameKit(root, pair, updateState: i == 0)
        }
        // BACKUP_AI_VAULT — только для проверки: подставное хранилище вместо настоящего.
        let testVault = ProcessInfo.processInfo.environment["BACKUP_AI_VAULT"]
        if let vault = testVault ?? Obsidian.vault(containing: config.archiveURL) ?? Obsidian.vault(containing: config.kitURL) {
            fixVault(URL(fileURLWithPath: vault, isDirectory: true), config: config, pair)
        }
    }

    static func isDir(_ u: URL) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue }

    static func mdFiles(_ root: URL, skip: Set<String> = []) -> [URL] {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            if skip.contains(u.lastPathComponent) { e.skipDescendants(); continue }
            if u.pathExtension.lowercased() == "md" { out.append(u) }
        }
        return out
    }

    // Переписать файл, только если текст изменился. Запись атомарная: файл или прежний, или новый целиком.
    static func rewrite(_ u: URL, _ change: (String) -> String) {
        guard let t = try? String(contentsOf: u, encoding: .utf8) else { return }
        let n = change(t)
        if n != t { try? n.write(to: u, atomically: true, encoding: .utf8) }
    }

    // MARK: Переписки

    static func rewriteChats(_ root: URL, _ pair: (String) -> (String, String)) {
        let keys = ["источник", "дата", "время", "проект", "сессия"].map(pair).filter { $0.0 != $0.1 }
        // Пометки программы. Меняются только там, где их ставит программа, — чтобы не задеть текст самих переписок:
        // «[изображение]» — если за ним не идёт ссылка «(…)»; остальное — только в начале строки.
        func rule(_ pattern: String, _ o: String, _ n: String) -> (NSRegularExpression, String)? {
            guard o != n, let r = try? NSRegularExpression(pattern: pattern.replacingOccurrences(of: "OLD", with: NSRegularExpression.escapedPattern(for: o)), options: [.anchorsMatchLines]) else { return nil }
            return (r, NSRegularExpression.escapedTemplate(for: n))
        }
        let img = pair("[изображение]"), pasted = pair("〔вставленный текст〕"), pastedEnd = pair("〔конец вставки〕")
        let q = pair("Вопрос:"), ans = pair("Ответ:"), alt = pair("↳ другой вариант")
        let file = pair("[файл: %@]"), att = pair("[вложение: %@]")
        let head = { (x: String) in String(x.components(separatedBy: "%@")[0]) }
        let rules: [(NSRegularExpression, String)] = [
            rule("OLD(?!\\()", img.0, img.1),
            rule("^OLD$", pasted.0, pasted.1),
            rule("^OLD$", pastedEnd.0, pastedEnd.1),
            rule("^\\*\\*OLD\\*\\*", q.0, "**" + q.1 + "**").map { ($0.0, NSRegularExpression.escapedTemplate(for: "**" + q.1 + "**")) },
            rule("^\\*\\*OLD\\*\\*", ans.0, ans.1).map { ($0.0, NSRegularExpression.escapedTemplate(for: "**" + ans.1 + "**")) },
            rule("^> \\*\\*OLD\\*\\*$", alt.0, alt.1).map { ($0.0, NSRegularExpression.escapedTemplate(for: "> **" + alt.1 + "**")) },
            rule("^OLD(?=[^\\]\\n]+\\]$)", head(file.0), head(file.1)),
            rule("OLD(?=[^\\]\\n]+\\])", head(att.0), head(att.1))
        ].compactMap { $0 }
        let untitled = pair("Без названия")
        for u in mdFiles(root) {
            rewrite(u) { text in
                var t = text
                // Поля в начале файла: «источник: …» → «source: …» — только внутри блока --- … ---.
                if t.hasPrefix("---\n"), let end = t.range(of: "\n---\n", range: t.index(t.startIndex, offsetBy: 4)..<t.endIndex) {
                    var head = String(t[t.startIndex..<end.lowerBound])
                    for (o, n) in keys { head = head.replacingOccurrences(of: "\n" + o + ":", with: "\n" + n + ":") }
                    t = head + t[end.lowerBound...]
                }
                for (r, tmpl) in rules { t = r.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: tmpl) }
                if untitled.0 != untitled.1 { t = t.replacingOccurrences(of: "\n# " + untitled.0 + "\n", with: "\n# " + untitled.1 + "\n") }
                return t
            }
        }
    }

    static func renameJournal(_ root: URL, _ pair: (String) -> (String, String)) {
        let (o, n) = pair("Журнал сохранений")
        let intro = pair("Записи программы «Бэкап ИИ». Новые — внизу.")
        let old = root.appendingPathComponent(o + ".md"), new = root.appendingPathComponent(n + ".md")
        if o != n, fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
        rewrite(new) { $0.replacingOccurrences(of: "# " + o + "\n", with: "# " + n + "\n").replacingOccurrences(of: intro.0, with: intro.1) }
    }

    // MARK: «Навыки и MCP»

    static func renameKit(_ root: URL, _ pair: (String) -> (String, String), updateState: Bool) {
        let dirs = ["Навыки", "Плагины", "Инструкции агентов", "Свои папки"].map(pair)
        let prev = pair("_прежние")
        let files = [("Обзор", ".md"), ("Плагины", ".md"), ("Журнал изменений", ".md")].map { (pair($0.0).0 + $0.1, pair($0.0).1 + $0.1) }
        func move(_ base: URL, _ o: String, _ n: String) {
            let a = base.appendingPathComponent(o), b = base.appendingPathComponent(n)
            if o != n, fm.fileExists(atPath: a.path), !fm.fileExists(atPath: b.path) { try? fm.moveItem(at: a, to: b) }
        }
        move(root, prev.0, prev.1)
        for base in [root, root.appendingPathComponent(prev.1)] { for (o, n) in dirs { move(base, o, n) } }
        for (o, n) in files { move(root, o, n) }
        // «‹скрыто›» в копиях конфигов и в списке MCP.
        let hidden = pair("‹скрыто›")
        let intro = pair("Записи программы «Бэкап ИИ» о навыках, MCP и плагинах. Новые — внизу.")
        let journal = pair("Журнал изменений")
        if hidden.0 != hidden.1 {
            for sub in [dirs[2].1, prev.1 + "/" + dirs[2].1] {
                let d = root.appendingPathComponent(sub)
                if let e = fm.enumerator(at: d, includingPropertiesForKeys: nil) {
                    for case let u as URL in e where !isDir(u) { rewrite(u) { $0.replacingOccurrences(of: hidden.0, with: hidden.1) } }
                }
            }
            rewrite(root.appendingPathComponent("MCP.md")) { $0.replacingOccurrences(of: hidden.0, with: hidden.1) }
        }
        rewrite(root.appendingPathComponent(journal.1 + ".md")) {
            $0.replacingOccurrences(of: "# " + journal.0 + "\n", with: "# " + journal.1 + "\n").replacingOccurrences(of: intro.0, with: intro.1)
        }
        guard updateState else { return }
        // Пути в «что записано в прошлый раз» — под новые названия; отпечатки переписанных копий — заново.
        var st = KitState.load()
        func renamed(_ key: String) -> String {
            var k = key
            if k.hasPrefix(prev.0 + "/") { k = prev.1 + k.dropFirst(prev.0.count) }
            for (o, n) in dirs where k.hasPrefix(o + "/") { k = n + k.dropFirst(o.count) }
            return k
        }
        var units: [String: String] = [:], sources: [String: String] = [:]
        for (k, v) in st.units {
            let nk = renamed(k)
            let fresh = KitHash.item(root.appendingPathComponent(nk))
            units[nk] = fresh.isEmpty ? v : fresh
            // У копий конфигов источник — сама копия (ключи скрыты), поэтому отпечаток источника тоже новый.
            sources[nk] = (st.sources[k] == v && !fresh.isEmpty) ? fresh : (st.sources[k] ?? v)
        }
        st.units = units
        st.sources = sources
        st.save()
    }

    // MARK: Хранилище Obsidian: ссылки и запросы

    static func fixVault(_ vault: URL, config: AppConfig, _ pair: (String) -> (String, String)) {
        let journal = pair("Журнал сохранений")
        let kitFolder = config.kitURL.lastPathComponent
        var names = [journal]
        for n in ["Обзор", "Плагины", "Журнал изменений"] { let p = pair(n); names.append((kitFolder + "/" + p.0, kitFolder + "/" + p.1)) }
        let fields = ["источник", "дата", "время", "проект", "сессия"].map(pair).filter { $0.0 != $0.1 }
        let archiveRel = relative(config.archiveURL, to: vault)
        for u in mdFiles(vault, skip: [".obsidian", ".trash"]) {
            rewrite(u) { text in
                var t = text
                for (o, n) in names where o != n {
                    t = relink(t, o, n)
                }
                if !fields.isEmpty, t.contains("```dataview"), let rel = archiveRel {
                    t = fixQueries(t, fields: fields, folder: rel)
                }
                return t
            }
        }
        // .base — запросы Obsidian Bases: поля меняем, только если запрос про папку архива.
        if let rel = archiveRel, let e = fm.enumerator(at: vault, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where u.pathExtension == "base" {
                rewrite(u) { t in t.contains(rel) ? replaceFields(t, fields) : t }
            }
        }
    }

    static func relative(_ u: URL, to base: URL) -> String? {
        let p = u.standardizedFileURL.path, b = base.standardizedFileURL.path
        return p.hasPrefix(b + "/") ? String(p.dropFirst(b.count + 1)) : nil
    }

    // Ссылки [[…старое…]] и [текст](…старое….md), обычный текст не трогается.
    static func relink(_ t: String, _ o: String, _ n: String) -> String {
        var out = t
        let esc = NSRegularExpression.escapedPattern(for: o)
        let tmpl = NSRegularExpression.escapedTemplate(for: n)
        if let r = try? NSRegularExpression(pattern: "(\\[\\[[^\\]\\n]*?)" + esc + "(?=\\]\\]|\\||#|\\.md)") {
            out = r.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1" + tmpl)
        }
        // Путь в ссылке бывает как есть, с пробелами «%20» (так пишет Obsidian) или закодирован целиком.
        let enc = { (x: String) in x.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? x }
        let sp = { (x: String) in x.replacingOccurrences(of: " ", with: "%20") }
        // Новое название в такой ссылке — всегда с «%20» вместо пробелов, как пишет Obsidian.
        for (oo, nn) in [(o, sp(n)), (sp(o), sp(n)), (enc(o), enc(n))] {
            if let r = try? NSRegularExpression(pattern: "(\\]\\([^)\\n]*?)" + NSRegularExpression.escapedPattern(for: oo) + "(?=\\.md\\))") {
                out = r.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: nn))
            }
        }
        return out
    }

    // Блоки ```dataview …``` про папку архива: названия полей — на новом языке.
    static func fixQueries(_ t: String, fields: [(String, String)], folder: String) -> String {
        guard let r = try? NSRegularExpression(pattern: "```dataview(js)?\\n[\\s\\S]*?```") else { return t }
        var out = t
        for m in r.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
            guard let range = Range(m.range, in: out) else { continue }
            let block = String(out[range])
            guard block.contains(folder) else { continue }
            out.replaceSubrange(range, with: replaceFields(block, fields))
        }
        return out
    }

    static func replaceFields(_ t: String, _ fields: [(String, String)]) -> String {
        var out = t
        for (o, n) in fields {
            if let r = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: o) + "(?![\\p{L}\\p{N}_])") {
                out = r.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: NSRegularExpression.escapedTemplate(for: n))
            }
        }
        return out
    }
}
