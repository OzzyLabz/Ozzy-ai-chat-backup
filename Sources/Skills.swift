import Foundation
import CryptoKit

// MARK: - Навыки, MCP, плагины и инструкции ИИ-агентов
//
// Что делает: находит на Mac агентов (Claude Code, приложение Claude, Codex, DSH, Hermes, Gemini, Antigravity, Cursor,
// Windsurf, VS Code, общие навыки ~/.agents), копирует их навыки, инструкции и настройки в отдельную папку
// «Навыки и MCP» и пишет понятные списки MCP и плагинов — чтобы любой агент мог поставить их заново.
//
// Правила (согласованы):
// • навык копируется один раз, с пометкой, в каких агентах стоит; одно имя с разным содержимым — с подписью агента;
// • копии точные: в сами файлы ничего не дописывается;
// • ключи в конфигах — по выбору: скрывать / как есть / не сохранять такие файлы;
// • файлы входа (auth.json, .credentials…, .env) и кэши не копируются никогда;
// • главное — то, что стоит у агента: правка копии затирается точной копией без сохранения в «_прежние»;
// • если агент обновил или удалил навык, правило, плагин или настройки — одна прошлая версия ложится в «_прежние»
//   (если включено «Хранить прошлую версию»);
// • программа источники только читает.

// Названия файлов и папок внутри «Навыки и MCP». Собраны в одном месте — их язык меняется вместе с языком архива.
enum KitNames {
    static var overview: String { AW.w("Обзор") + ".md" }
    static var skills: String { AW.w("Навыки") }
    static var mcp: String { "MCP.md" }
    static var plugins: String { AW.w("Плагины") + ".md" }
    static var pluginFiles: String { AW.w("Плагины") }
    static var instructions: String { AW.w("Инструкции агентов") }
    static var own: String { AW.w("Свои папки") }
    static var previous: String { AW.w("_прежние") }
    static var journal: String { AW.w("Журнал изменений") + ".md" }
    static var hidden: String { AW.w("‹скрыто›") }
}

// Описание агента: где лежит и что у него брать.
struct KitAgentSpec {
    var id: String
    var name: String
    var root: String            // путь от домашней папки
}

enum KitCatalog {
    static let all: [KitAgentSpec] = [
        KitAgentSpec(id: "claude", name: "Claude Code", root: ".claude"),
        KitAgentSpec(id: "claude-app", name: "Приложение Claude", root: "Library/Application Support/Claude"),
        KitAgentSpec(id: "codex", name: "Codex", root: ".codex"),
        KitAgentSpec(id: "dsh", name: "DSH Desktop", root: ".dsh"),
        KitAgentSpec(id: "agents", name: "Общие навыки", root: ".agents"),
        KitAgentSpec(id: "hermes", name: "Hermes", root: ".hermes"),
        KitAgentSpec(id: "gemini", name: "Gemini CLI", root: ".gemini"),
        KitAgentSpec(id: "antigravity", name: "Antigravity", root: ".gemini/config"),
        KitAgentSpec(id: "cursor", name: "Cursor", root: ".cursor"),
        KitAgentSpec(id: "windsurf", name: "Windsurf", root: ".codeium/windsurf"),
        KitAgentSpec(id: "vscode", name: "VS Code", root: "Library/Application Support/Code/User")
    ]
    static func spec(_ id: String) -> KitAgentSpec? { all.first { $0.id == id } }
}

// MARK: - Найденное у агента

struct KitSkill {
    var name: String
    var dir: URL
    var hash: String
    var version: String?
    var source: String?
}

struct KitMCP {
    var name: String
    var format: String      // json / toml / yaml
    var text: String        // настройки сервера в формате агента (ключи — по выбранному режиму)
    var hash: String
}

struct KitPlugin {
    var name: String
    var version: String?
    var source: String?
    var enabled: Bool?
    var copyDir: URL?       // источник неизвестен или локальный — копируем файлы плагина
}

struct KitFile {
    var src: URL            // файл или папка у агента
    var dest: String        // путь внутри «Инструкции агентов/<агент>/»
    var config: String?     // json / toml / yaml — конфиг, где могут быть ключи
}

struct KitScan {
    var spec: KitAgentSpec
    var root: URL
    var found = false
    var skills: [KitSkill] = []
    var mcp: [KitMCP] = []
    var plugins: [KitPlugin] = []
    var files: [KitFile] = []
    var keysFound = 0
    var skippedFiles: [String] = []   // файлы с ключами, не сохранённые в режиме «Не сохранять»
    var problems: [String] = []
    var notes: [String] = []          // что сознательно не копируется (кэш, файлы входа)
}

// Запись истории вкладки — по смыслу (код + подставляемые значения), текст собирается на языке окна.
enum KitEvent {
    static let phrases: [String: String] = [
        "skill.new": "новый навык: %@",
        "skill.update": "обновлён навык: %@",
        "skill.update.prev": "обновлён навык: %@, прежний сохранён",
        "skill.remove": "удалён навык: %@",
        "skill.remove.prev": "удалён навык: %@, прежний сохранён",
        "file.new": "добавлен файл: %@",
        "file.update": "изменён %@",
        "file.update.prev": "изменён %@, прежний сохранён",
        "file.remove": "удалён файл: %@",
        "file.remove.prev": "удалён файл: %@, прежний сохранён",
        "mcp.add": "добавлен MCP: %@",
        "mcp.remove": "удалён MCP: %@",
        "plugin.add": "добавлен плагин: %@",
        "plugin.remove": "удалён плагин: %@",
        "copy.restored": "правка в копии заменена точной копией: %@",
        "nochange": "без изменений",
        "gone": "не найдено — программа удалена или папка перенесена",
        "unreadable": "не удалось прочитать настройки",
        "folder.error": "нет доступа к папке навыков: %@",
        "first": "первое сохранение: %@"
    ]
    static func text(_ code: String, _ args: [String]) -> String {
        guard let f = phrases[code] else { return code }
        let t = tr(f)
        return args.isEmpty ? t : String(format: t, arguments: args.map { $0 as CVarArg })
    }
}

// Состояние вкладки (для окна): агенты и история.
struct KitStatus: Codable {
    var lastRun: Date?
    var agents: [DemoAgent] = []
    var history: [DemoChange] = []

    static var url: URL { Paths.support.appendingPathComponent("kit-status.json") }
    static func load() -> KitStatus { JSONFile.load(KitStatus.self, from: url) ?? KitStatus() }
    func save() { JSONFile.save(self, to: Self.url) }
}

// Что программа записала в прошлый раз: путь внутри папки → отпечаток. По нему видно, кто поменял копию — агент или человек.
struct KitState: Codable {
    var units: [String: String] = [:]      // путь → отпечаток того, что записано
    var sources: [String: String] = [:]    // путь → отпечаток источника в прошлый раз
    var mcp: [String] = []
    var plugins: [String] = []
    static var url: URL { Paths.support.appendingPathComponent("kit-state.json") }
    static func load() -> KitState { JSONFile.load(KitState.self, from: url) ?? KitState() }
    func save() { JSONFile.save(self, to: Self.url) }
}

// MARK: - Отпечатки и ключи

enum KitHash {
    static let skipNames: Set<String> = [".DS_Store", "Icon\r", "auth.json", ".credentials.json", ".credentials.yaml",
                                         ".credentials", ".env", "credentials.json", "node_modules", ".git", "__pycache__", ".venv"]
    static func skipped(_ name: String) -> Bool {
        skipNames.contains(name) || name.hasSuffix(".env") || name.hasPrefix(".env.") || name.hasSuffix(".pem")
            || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519")
    }

    static func data(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // Файлы папки (относительные пути), без служебных и файлов входа.
    static func files(_ dir: URL) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: []) else { return [] }
        var out: [String] = []
        let base = dir.standardizedFileURL.path
        for case let u as URL in e {
            if skipped(u.lastPathComponent) {
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { e.skipDescendants() }
                continue
            }
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let p = u.standardizedFileURL.path
            out.append(String(p.dropFirst(base.count + 1)))
        }
        return out.sorted()
    }

    static func tree(_ dir: URL) -> String {
        var s = ""
        for rel in files(dir) {
            let d = (try? Data(contentsOf: dir.appendingPathComponent(rel))) ?? Data()
            s += rel + "\u{0}" + data(d) + "\n"
        }
        return data(Data(s.utf8))
    }

    static func item(_ url: URL) -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return "" }
        return isDir.boolValue ? tree(url) : data((try? Data(contentsOf: url)) ?? Data())
    }
}

enum KitKeys {
    // Имя поля похоже на ключ или пароль.
    static let keyName = try! NSRegularExpression(pattern: "(token|secret|password|passwd|api[_-]?key|apikey|access[_-]?key|private[_-]?key|bearer|cookie|credential|authorization)", options: [.caseInsensitive])
    // Значение похоже на ключ, где бы оно ни стояло.
    static let keyValue = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_-])(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|figd_[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{5,})")

    static func isKeyName(_ s: String) -> Bool { keyName.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    static func looksSecret(_ v: String) -> Bool {
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix("$") || t.hasPrefix("${") { return false }
        return t.count >= 8
    }

    // JSON: значения полей-ключей и всё, что похоже на ключ, заменяются; возвращает число замен.
    static func mask(json: Any) -> (Any, Int) {
        var n = 0
        func walk(_ v: Any, key: String?) -> Any {
            if let d = v as? [String: Any] {
                var out: [String: Any] = [:]
                for (k, x) in d { out[k] = walk(x, key: k) }
                return out
            }
            if let a = v as? [Any] { return a.map { walk($0, key: key) } }
            if let s = v as? String {
                if let key, isKeyName(key), looksSecret(s) { n += 1; return KitNames.hidden }
                let r = NSRange(s.startIndex..., in: s)
                if keyValue.firstMatch(in: s, range: r) != nil {
                    n += 1
                    return keyValue.stringByReplacingMatches(in: s, range: r, withTemplate: KitNames.hidden)
                }
                // «Bearer …» в заголовках
                if s.lowercased().hasPrefix("bearer "), s.count > 15 { n += 1; return "Bearer " + KitNames.hidden }
            }
            return v
        }
        return (walk(json, key: nil), n)
    }

    // TOML и YAML: построчно. Поля-ключи (в том числе внутри { … }) и похожие на ключ значения заменяются.
    static let line = try! NSRegularExpression(pattern: "([\"']?)([A-Za-z0-9_.\\-]+)\\1(\\s*[=:]\\s*)([\"'])([^\"'\\n]*)\\4")
    static func mask(text: String) -> (String, Int) {
        var n = 0
        var out: [String] = []
        for l in text.components(separatedBy: "\n") {
            var s = l
            let r = NSRange(s.startIndex..., in: s)
            // поля «имя = "значение"»
            for m in line.matches(in: s, range: r).reversed() {
                guard let kr = Range(m.range(at: 2), in: s), let vr = Range(m.range(at: 5), in: s) else { continue }
                if isKeyName(String(s[kr])) && looksSecret(String(s[vr])) {
                    s.replaceSubrange(vr, with: KitNames.hidden); n += 1
                }
            }
            // YAML без кавычек: «api_key: значение»
            if let c = s.firstIndex(of: ":"), !s.contains("\""), !s.contains("'") {
                let k = s[..<c].trimmingCharacters(in: .whitespaces)
                let v = s[s.index(after: c)...].trimmingCharacters(in: .whitespaces)
                if isKeyName(k) && looksSecret(v) && !v.hasPrefix("{") { s = String(s[...c]) + " " + KitNames.hidden; n += 1 }
            }
            let r2 = NSRange(s.startIndex..., in: s)
            let hits = keyValue.numberOfMatches(in: s, range: r2)
            if hits > 0 { s = keyValue.stringByReplacingMatches(in: s, range: r2, withTemplate: KitNames.hidden); n += hits }
            out.append(s)
        }
        return (out.joined(separator: "\n"), n)
    }

    // Текст конфига для копии по режиму: hide — скрыть, keep — как есть, skip — nil (не сохранять, если есть ключи).
    static func apply(_ data: Data, format: String, mode: String) -> (Data?, Int) {
        let (masked, n): (Data, Int) = {
            if format == "json", let obj = try? JSONSerialization.jsonObject(with: data) {
                let (m, n) = mask(json: obj)
                if n == 0 { return (data, 0) }
                let out = (try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? data
                return (out, n)
            }
            let (t, n) = mask(text: String(decoding: data, as: UTF8.self))
            return (n == 0 ? data : Data(t.utf8), n)
        }()
        switch mode {
        case "keep": return (data, n)
        case "skip": return (n > 0 ? nil : data, n)
        default: return (masked, n)
        }
    }
}

// MARK: - Чтение агентов

enum KitReader {
    static let fm = FileManager.default
    static func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
    static func isDir(_ u: URL) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue }

    static func root(_ spec: KitAgentSpec, _ config: AppConfig) -> URL {
        if let p = config.kitPaths[spec.id] { return URL(fileURLWithPath: p, isDirectory: true) }
        return Paths.home.appendingPathComponent(spec.root, isDirectory: true)
    }

    // Навыки: каждая папка с SKILL.md; системные (с точкой в начале) не берём.
    static func skills(_ dir: URL) -> [KitSkill] {
        guard let list = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return list.filter { !$0.lastPathComponent.hasPrefix(".") && isDir($0) && exists($0.appendingPathComponent("SKILL.md")) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { d in
                let head = (try? String(contentsOf: d.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
                return KitSkill(name: d.lastPathComponent, dir: d, hash: KitHash.tree(d), version: frontField(head, "version"), source: frontField(head, "source") ?? frontField(head, "homepage"))
            }
    }

    // Поле из шапки SKILL.md (--- … ---), в том числе вложенное в metadata.
    static func frontField(_ text: String, _ name: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        let body = text.dropFirst(3)
        guard let end = body.range(of: "\n---") else { return nil }
        for l in body[..<end.lowerBound].components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(name + ":") {
                let v = t.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    static func file(_ scan: inout KitScan, _ rel: String, config: String? = nil, as dest: String? = nil) {
        let u = scan.root.appendingPathComponent(rel)
        guard exists(u) else { return }
        scan.files.append(KitFile(src: u, dest: dest ?? rel, config: config))
    }

    // MCP из JSON: { "mcpServers": { имя: {…} } } (или «servers» у VS Code).
    static func mcpJSON(_ url: URL, key: String = "mcpServers", mode: String, scan: inout KitScan) {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            scan.problems.append(url.lastPathComponent); return
        }
        let servers = (obj[key] as? [String: Any]) ?? [:]
        for (name, cfg) in servers.sorted(by: { $0.key < $1.key }) {
            let (masked, n) = KitKeys.mask(json: cfg)
            let show: Any = mode == "keep" ? cfg : masked
            if mode == "skip" && n > 0 {
                scan.mcp.append(KitMCP(name: name, format: "json", text: "", hash: KitHash.data(Data(name.utf8))))
            } else {
                let block = (try? JSONSerialization.data(withJSONObject: [name: show], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
                scan.mcp.append(KitMCP(name: name, format: "json", text: String(decoding: block, as: UTF8.self), hash: KitHash.data(block)))
            }
        }
    }

    // TOML-разделы с общим началом: [mcp_servers.имя], [mcp_servers.имя.env] …
    static func tomlSections(_ text: String, prefix: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var cur: String?
        var buf: [String] = []
        func flush() { if let c = cur { out.append((c, buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) } }
        for l in text.components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") && !t.hasPrefix("[[") {
                let head = t.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if head.hasPrefix(prefix + ".") {
                    let rest = String(head.dropFirst(prefix.count + 1))
                    let name: String = {
                        if rest.hasPrefix("\""), let e = rest.dropFirst().firstIndex(of: "\"") { return String(rest[rest.index(after: rest.startIndex)..<e]) }
                        return rest.components(separatedBy: ".").first ?? rest
                    }()
                    if name != cur { flush(); cur = name; buf = [] }
                    buf.append(l)
                    continue
                }
                flush(); cur = nil; buf = []
                continue
            }
            if cur != nil { buf.append(l) }
        }
        flush()
        return out
    }

    static func value(_ block: String, _ key: String) -> String? {
        for l in block.components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(key) else { continue }
            let rest = t.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            return rest.dropFirst().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    static func scan(_ spec: KitAgentSpec, _ config: AppConfig) -> KitScan {
        let r = root(spec, config)
        var s = KitScan(spec: spec, root: r)
        guard isDir(r) else { return s }
        let mode = config.kitKeys
        switch spec.id {
        case "claude":
            s.skills = skills(r.appendingPathComponent("skills"))
            file(&s, "CLAUDE.md")
            file(&s, "settings.json", config: "json")
            file(&s, "keybindings.json")
            for d in ["agents", "commands", "output-styles", "rules"] where isDir(r.appendingPathComponent(d)) { file(&s, d) }
            mcpJSON(Paths.home.appendingPathComponent(".claude.json"), mode: mode, scan: &s)
            claudePlugins(&s)
        case "claude-app":
            file(&s, "claude_desktop_config.json", config: "json")
            mcpJSON(r.appendingPathComponent("claude_desktop_config.json"), mode: mode, scan: &s)
            claudeAppPlugins(&s)
        case "codex":
            s.skills = skills(r.appendingPathComponent("skills"))
            file(&s, "AGENTS.md")
            file(&s, "rules")
            file(&s, "keybindings.json")
            file(&s, "config.toml", config: "toml")
            codexConfig(&s, mode: mode)
            if isDir(r.appendingPathComponent("plugins")) { s.notes.append("plugins") }
        case "dsh":
            s.skills = skills(r.appendingPathComponent("skills"))
            file(&s, "AGENTS.md")
        case "agents":
            s.skills = skills(r.appendingPathComponent("skills"))
        case "hermes":
            s.skills = skills(r.appendingPathComponent("skills"))
            file(&s, "SOUL.md")
            file(&s, "config.yaml", config: "yaml")
            if let t = try? String(contentsOf: r.appendingPathComponent("config.yaml"), encoding: .utf8) { hermesMCP(t, mode: mode, scan: &s) }
            if let profiles = try? fm.contentsOfDirectory(at: r.appendingPathComponent("profiles"), includingPropertiesForKeys: nil) {
                for p in profiles where isDir(p) {
                    for k in skills(p.appendingPathComponent("skills")) { s.skills.append(k) }
                    file(&s, "profiles/\(p.lastPathComponent)/config.yaml", config: "yaml")
                    file(&s, "profiles/\(p.lastPathComponent)/SOUL.md")
                }
            }
        case "gemini":
            s.skills = skills(r.appendingPathComponent("skills"))
            file(&s, "GEMINI.md")
            file(&s, "AGENTS.md")
            file(&s, "settings.json", config: "json")
            mcpJSON(r.appendingPathComponent("settings.json"), mode: mode, scan: &s)
            if let ext = try? fm.contentsOfDirectory(at: r.appendingPathComponent("extensions"), includingPropertiesForKeys: nil) {
                for e in ext where isDir(e) {
                    var p = KitPlugin(name: e.lastPathComponent, copyDir: e)
                    if let d = try? Data(contentsOf: e.appendingPathComponent("gemini-extension.json")),
                       let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                        p.name = j["name"] as? String ?? p.name
                        p.version = j["version"] as? String
                    }
                    s.plugins.append(p)
                }
            }
        case "antigravity":
            s.skills = skills(r.appendingPathComponent("skills"))
            for k in skills(Paths.home.appendingPathComponent(".gemini/antigravity-cli/skills")) { s.skills.append(k) }
            file(&s, "AGENTS.md")
            file(&s, "GEMINI.md")
            file(&s, "rules")
            file(&s, "mcp_config.json", config: "json")
            mcpJSON(r.appendingPathComponent("mcp_config.json"), mode: mode, scan: &s)
            if let pl = try? fm.contentsOfDirectory(at: r.appendingPathComponent("plugins"), includingPropertiesForKeys: nil) {
                for p in pl where isDir(p) { s.plugins.append(KitPlugin(name: p.lastPathComponent, copyDir: p)) }
            }
        case "cursor":
            s.skills = skills(r.appendingPathComponent("skills"))
            file(&s, "mcp.json", config: "json")
            mcpJSON(r.appendingPathComponent("mcp.json"), mode: mode, scan: &s)
            file(&s, "rules")
        case "windsurf":
            file(&s, "mcp_config.json", config: "json")
            mcpJSON(r.appendingPathComponent("mcp_config.json"), mode: mode, scan: &s)
            file(&s, "memories/global_rules.md")
        case "vscode":
            file(&s, "mcp.json", config: "json")
            mcpJSON(r.appendingPathComponent("mcp.json"), key: "servers", mode: mode, scan: &s)
        default:
            break
        }
        s.found = !s.skills.isEmpty || !s.files.isEmpty || !s.mcp.isEmpty || !s.plugins.isEmpty
        return s
    }

    // Claude Code: установленные плагины, маркеты и включённые (документация Claude Code, «Plugin loading reference»).
    static func claudePlugins(_ s: inout KitScan) {
        let p = s.root.appendingPathComponent("plugins")
        var markets: [String: String] = [:]
        if let d = try? Data(contentsOf: p.appendingPathComponent("known_marketplaces.json")),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            for (name, v) in j {
                let src = (v as? [String: Any])?["source"] as? [String: Any]
                markets[name] = (src?["repo"] as? String) ?? (src?["url"] as? String) ?? (src?["path"] as? String) ?? (src?["source"] as? String)
            }
        }
        var enabled: [String: Bool] = [:]
        if let d = try? Data(contentsOf: s.root.appendingPathComponent("settings.json")),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            enabled = j["enabledPlugins"] as? [String: Bool] ?? [:]
        }
        if let d = try? Data(contentsOf: p.appendingPathComponent("installed_plugins.json")),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            let list = (j["plugins"] as? [String: Any]) ?? j
            for (id, v) in list.sorted(by: { $0.key < $1.key }) {
                let entry = (v as? [[String: Any]])?.first ?? (v as? [String: Any]) ?? [:]
                let market = id.components(separatedBy: "@").dropFirst().first
                var plugin = KitPlugin(name: id, version: entry["version"] as? String,
                                       source: market.map { m in markets[m].map { "\(m) — \($0)" } ?? m },
                                       enabled: enabled[id])
                // Плагин из своей папки (не с маркета) — копируем файлы, иначе его не вернуть.
                if market == nil || markets[market!] == nil, let path = entry["installPath"] as? String { plugin.copyDir = URL(fileURLWithPath: path) }
                s.plugins.append(plugin)
            }
        }
        for (id, on) in enabled where !s.plugins.contains(where: { $0.name == id }) {
            s.plugins.append(KitPlugin(name: id, source: id.components(separatedBy: "@").dropFirst().first, enabled: on))
        }
    }

    // Приложение Claude: плагины из каталога Anthropic и встроенные навыки — список с источником.
    static func claudeAppPlugins(_ s: inout KitScan) {
        let base = s.root.appendingPathComponent("local-agent-mode-sessions")
        guard let e = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { return }
        var seen = Set<String>()
        for case let u as URL in e where u.lastPathComponent == "manifest.json" {
            guard let d = try? Data(contentsOf: u), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            if let list = j["plugins"] as? [[String: Any]] {
                for p in list {
                    let name = p["displayName"] as? String ?? p["name"] as? String ?? "?"
                    guard seen.insert(name).inserted else { continue }
                    let src = [p["marketplaceName"] as? String, p["upstreamRepoUrl"] as? String].compactMap { $0 }.joined(separator: " — ")
                    var plugin = KitPlugin(name: name, source: src.isEmpty ? nil : src)
                    if let id = p["id"] as? String {
                        let pj = u.deletingLastPathComponent().appendingPathComponent(id).appendingPathComponent(".claude-plugin/plugin.json")
                        if let pd = try? Data(contentsOf: pj), let pjj = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any] {
                            plugin.version = pjj["version"] as? String
                        }
                    }
                    s.plugins.append(plugin)
                }
            }
            if let list = j["skills"] as? [[String: Any]], !list.isEmpty, seen.insert("anthropic-skills").inserted {
                let names = list.compactMap { $0["name"] as? String }.sorted().joined(separator: ", ")
                s.plugins.append(KitPlugin(name: "anthropic-skills", source: tr("встроено в приложение Claude") + ": " + names))
            }
        }
    }

    static func codexConfig(_ s: inout KitScan, mode: String) {
        guard let text = try? String(contentsOf: s.root.appendingPathComponent("config.toml"), encoding: .utf8) else { return }
        for (name, block) in tomlSections(text, prefix: "mcp_servers") {
            let (masked, n) = KitKeys.mask(text: block)
            let show = mode == "keep" ? block : masked
            s.mcp.append(KitMCP(name: name, format: "toml", text: mode == "skip" && n > 0 ? "" : show, hash: KitHash.data(Data(show.utf8))))
        }
        var markets: [String: (String, String)] = [:]   // имя → (тип, адрес)
        for (name, block) in tomlSections(text, prefix: "marketplaces") {
            markets[name] = (value(block, "source_type") ?? "", value(block, "source") ?? "")
        }
        for (id, block) in tomlSections(text, prefix: "plugins") {
            let market = id.components(separatedBy: "@").dropFirst().first ?? ""
            var p = KitPlugin(name: id, source: market, enabled: value(block, "enabled").map { $0 == "true" })
            if let m = markets[market] {
                p.source = m.1.isEmpty ? market : "\(market) — \(m.1)"
                // Встроенные маркеты OpenAI Codex ставит сам; свой локальный маркет копируем, иначе плагин не вернуть.
                if !market.hasPrefix("openai-"), m.0 == "local", isDir(URL(fileURLWithPath: m.1)) { p.copyDir = URL(fileURLWithPath: m.1) }
            }
            s.plugins.append(p)
        }
    }

    // Hermes: блок mcp_servers: в config.yaml — каждый сервер с отступом под ним.
    static func hermesMCP(_ text: String, mode: String, scan: inout KitScan) {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("mcp_servers:") }) else { return }
        var cur: String?
        var buf: [String] = []
        func flush() {
            guard let c = cur else { return }
            let block = buf.joined(separator: "\n")
            let (masked, n) = KitKeys.mask(text: block)
            let show = mode == "keep" ? block : masked
            scan.mcp.append(KitMCP(name: c, format: "yaml", text: mode == "skip" && n > 0 ? "" : show, hash: KitHash.data(Data(show.utf8))))
        }
        for l in lines[(start + 1)...] {
            if !l.hasPrefix(" ") && !l.trimmingCharacters(in: .whitespaces).isEmpty { break }
            let indent = l.prefix { $0 == " " }.count
            if indent == 2, l.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                flush(); cur = l.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":")); buf = [l]
            } else if cur != nil { buf.append(l) }
        }
        flush()
    }
}

// MARK: - Сохранение

struct KitRunResult {
    var changes: [DemoChange] = []
    var problems: [String] = []
}

final class KitBackup {
    let config: AppConfig
    let trigger: Trigger
    let fm = FileManager.default
    var dest: URL
    var state = KitState.load()
    var newState = KitState()
    var changes: [DemoChange] = []
    var now = Date()

    init(config: AppConfig, trigger: Trigger, folder: URL? = nil) {
        self.config = config
        self.trigger = trigger
        self.dest = folder ?? config.kitURL
    }

    var agentIDs: [String] { KitCatalog.all.map(\.id) + config.kitPaths.keys.filter { KitCatalog.spec($0) == nil }.sorted() }

    // Все найденные агенты (и добавленные вручную), включённые — со сканом.
    func scans() -> [KitScan] {
        KitCatalog.all.compactMap { spec in
            let s = KitReader.scan(spec, config)
            return (s.found || config.kitPaths[spec.id] != nil) ? s : nil
        }
    }

    func log(_ who: String, _ code: String, _ args: [String] = [], _ level: Level = .ok) {
        changes.append(DemoChange(date: now, who: who, text: KitEvent.text(code, args), level: level, code: code, args: args))
    }

    // Записать файл или папку как точную копию, с учётом «_прежних».
    // key — путь внутри «Навыки и MCP»; srcHash — отпечаток источника.
    @discardableResult
    func put(_ key: String, write: (URL) throws -> Void, srcHash: String, who: String, kind: String, label: String) -> Bool {
        let target = dest.appendingPathComponent(key)
        let had = fm.fileExists(atPath: target.path)
        let prevSrc = state.sources[key]
        let prevWritten = state.units[key]
        newState.sources[key] = srcHash
        if had, prevSrc == srcHash, let w = prevWritten, KitHash.item(target) == w {
            newState.units[key] = w
            return false                                        // ничего не поменялось
        }
        if had {
            let current = KitHash.item(target)
            let userEdited = prevWritten != nil && current != prevWritten && prevSrc == srcHash
            if userEdited {
                log(who, "copy.restored", [label])
            } else if prevSrc != nil && prevSrc != srcHash {
                if config.kitKeepPrev { movePrev(key) }
                log(who, "\(kind).update" + (config.kitKeepPrev ? ".prev" : ""), [label])
            } else if prevSrc == nil {
                log(who, "\(kind).new", [label])
            }
            try? fm.removeItem(at: target)
        } else {
            log(who, "\(kind).new", [label])
        }
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try write(target) } catch { changes.append(DemoChange(date: now, who: who, text: error.localizedDescription, level: .err)) }
        newState.units[key] = KitHash.item(target)
        return true
    }

    func movePrev(_ key: String) {
        let from = dest.appendingPathComponent(key)
        let to = dest.appendingPathComponent(KitNames.previous).appendingPathComponent(key)
        try? fm.removeItem(at: to)
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: from, to: to)
    }

    // Копия папки без служебных файлов и файлов входа.
    func copyTree(_ src: URL, to target: URL) throws {
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for rel in KitHash.files(src) {
            let t = target.appendingPathComponent(rel)
            try fm.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src.appendingPathComponent(rel), to: t)
        }
    }

    // MARK: Запуск

    func run(dryRun: Bool = false) -> (scans: [KitScan], result: KitRunResult) {
        let all = scans()
        let on = all.filter { !config.kitOff.contains($0.spec.id) }
        if dryRun { return (all, KitRunResult()) }

        do { try fm.createDirectory(at: dest, withIntermediateDirectories: true) } catch {
            log(tr("Навыки и MCP"), "folder.error", [Fmt.shortPath(dest.path)], .err)
            return (all, KitRunResult(changes: changes))
        }
        let first = state.units.isEmpty

        // 1. Навыки: каждый один раз. Одно имя с разным содержимым — с подписью агента.
        var byName: [String: [(KitSkill, String)]] = [:]
        for s in on { for k in s.skills { byName[k.name, default: []].append((k, s.spec.name)) } }
        var skillRows: [(name: String, folder: String, version: String?, source: String?, agents: [(String, String)], files: [String])] = []
        for name in byName.keys.sorted() {
            let list = byName[name]!
            let variants = Dictionary(grouping: list, by: { $0.0.hash })
            for (_, group) in variants.sorted(by: { $0.key < $1.key }) {
                let k = group[0].0
                let folder = variants.count == 1 ? name : "\(name) (\(group.map(\.1).joined(separator: ", ")))"
                let key = "\(KitNames.skills)/\(folder)"
                let who = group.map(\.1).joined(separator: ", ")
                put(key, write: { try self.copyTree(k.dir, to: $0) }, srcHash: k.hash, who: who, kind: "skill", label: folder)
                skillRows.append((folder, folder, k.version, k.source, group.map { ($0.1, Fmt.shortPath($0.0.dir.path)) }, KitHash.files(k.dir)))
            }
        }

        // 2. Инструкции и настройки агентов — по агентам, конфиги с ключами — по выбранному режиму.
        for s in on {
            for f in s.files {
                let key = "\(KitNames.instructions)/\(s.spec.name)/\(f.dest)"
                if KitReader.isDir(f.src) {
                    put(key, write: { try self.copyTree(f.src, to: $0) }, srcHash: KitHash.tree(f.src), who: s.spec.name, kind: "file", label: f.dest)
                    continue
                }
                guard let data = try? Data(contentsOf: f.src) else { continue }
                var out: Data? = data
                if let fmt = f.config {
                    let (d, n) = KitKeys.apply(data, format: fmt, mode: config.kitKeys)
                    out = d
                    _ = n
                }
                guard let payload = out else { continue }   // «Не сохранять»: файл с ключами пропускаем
                put(key, write: { try payload.write(to: $0) }, srcHash: KitHash.data(payload), who: s.spec.name, kind: "file", label: f.dest)
            }
        }

        // 3. Файлы плагинов, у которых источник неизвестен или локальный.
        for s in on {
            for p in s.plugins {
                guard let dir = p.copyDir, KitReader.isDir(dir) else { continue }
                let key = "\(KitNames.pluginFiles)/\(s.spec.name)/\(safe(p.name))"
                put(key, write: { try self.copyTree(dir, to: $0) }, srcHash: KitHash.tree(dir), who: s.spec.name, kind: "file", label: p.name)
            }
        }

        // 4. Свои папки (например, AI-Memory) — целиком.
        for o in config.kitOwn where !config.kitOff.contains("own:" + o.path) {
            let src = URL(fileURLWithPath: o.path, isDirectory: true)
            guard KitReader.isDir(src) else { log(o.name, "gone", [], .warn); continue }
            let key = "\(KitNames.own)/\(safe(o.name))"
            put(key, write: { try self.copyTree(src, to: $0) }, srcHash: KitHash.tree(src), who: o.name, kind: "file", label: o.name)
        }

        // 5. Исчезнувшее у агентов: одна прошлая версия — в «_прежние».
        for key in state.units.keys where newState.units[key] == nil {
            let target = dest.appendingPathComponent(key)
            guard fm.fileExists(atPath: target.path) else { continue }
            let isSkill = key.hasPrefix(KitNames.skills + "/")
            if config.kitKeepPrev { movePrev(key) } else { try? fm.removeItem(at: target) }
            log(isSkill ? tr("Навыки") : String(key.split(separator: "/").dropFirst().first ?? ""),
                (isSkill ? "skill.remove" : "file.remove") + (config.kitKeepPrev ? ".prev" : ""), [(key as NSString).lastPathComponent])
        }

        // 6. Списки MCP и плагинов, обзор.
        writeMCP(on)
        writePlugins(on)
        writeOverview(on, skills: skillRows)

        if first && !changes.isEmpty {
            let n = skillRows.count
            changes = [DemoChange(date: now, who: tr("все программы"), text: KitEvent.text("first", ["\(n) \(plural(n, "навык", "навыка", "навыков"))"]), level: .ok, code: "first", args: ["\(n) \(plural(n, "навык", "навыка", "навыков"))"])]
        }
        newState.save()
        writeJournal()
        mirror()
        return (all, KitRunResult(changes: changes))
    }

    func safe(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "∕").replacingOccurrences(of: ":", with: "：") }

    // MARK: Списки

    func writeMCP(_ on: [KitScan]) {
        var byName: [String: [(KitMCP, String)]] = [:]
        for s in on { for m in s.mcp { byName[m.name, default: []].append((m, s.spec.name)) } }
        let names = Set(byName.keys)
        for n in names.subtracting(state.mcp).sorted() where !state.mcp.isEmpty { log(byName[n]!.map(\.1).joined(separator: ", "), "mcp.add", [n]) }
        for n in Set(state.mcp).subtracting(names).sorted() { log("MCP", "mcp.remove", [n]) }
        newState.mcp = names.sorted()

        var md = "# MCP\n\n" + tr("Каждый сервер — один раз. Ниже — где он стоит и готовый блок настроек для вставки в агент.") + "\n"
        if config.kitKeys == "hide" { md += "\n" + trf("Ключи и пароли заменены на %@ — впишите свои при установке.", KitNames.hidden) + "\n" }
        for name in byName.keys.sorted() {
            let list = byName[name]!
            md += "\n## \(name)\n\n" + tr("Где стоит") + ": " + list.map(\.1).joined(separator: ", ") + "\n"
            for (variant, group) in Dictionary(grouping: list, by: { $0.0.hash }).sorted(by: { $0.key < $1.key }) {
                _ = variant
                let m = group[0].0
                if Dictionary(grouping: list, by: { $0.0.hash }).count > 1 { md += "\n**" + group.map(\.1).joined(separator: ", ") + "**\n" }
                if m.text.isEmpty { md += "\n" + tr("Настройки не сохранены: в них есть ключи (режим «Не сохранять»).") + "\n" }
                else { md += "\n```\(m.format)\n\(m.text)\n```\n" }
            }
        }
        writeDoc(KitNames.mcp, md)
    }

    func writePlugins(_ on: [KitScan]) {
        let ids = Set(on.flatMap { s in s.plugins.map { "\(s.spec.name)/\($0.name)" } })
        if !state.plugins.isEmpty {
            for id in ids.subtracting(state.plugins).sorted() { log(String(id.split(separator: "/")[0]), "plugin.add", [String(id.split(separator: "/").dropFirst().joined(separator: "/"))]) }
            for id in Set(state.plugins).subtracting(ids).sorted() { log(String(id.split(separator: "/")[0]), "plugin.remove", [String(id.split(separator: "/").dropFirst().joined(separator: "/"))]) }
        }
        newState.plugins = ids.sorted()
        var md = "# " + tr("Плагины") + "\n\n" + tr("По агентам: у каждого свои форматы и свои маркеты. Источник — откуда ставить заново.") + "\n"
        for s in on where !s.plugins.isEmpty {
            md += "\n## \(s.spec.name)\n\n| " + tr("Плагин") + " | " + tr("Версия") + " | " + tr("Включён") + " | " + tr("Источник") + " |\n|---|---|---|---|\n"
            for p in s.plugins.sorted(by: { $0.name < $1.name }) {
                let on = p.enabled.map { $0 ? "✅" : "—" } ?? ""
                var src = p.source ?? tr("неизвестно")
                if p.copyDir != nil { src += " · " + tr("файлы сохранены") + ": `\(KitNames.pluginFiles)/\(s.spec.name)/\(safe(p.name))`" }
                md += "| \(p.name) | \(p.version ?? "") | \(on) | \(src.replacingOccurrences(of: "|", with: "/")) |\n"
            }
        }
        writeDoc(KitNames.plugins, md)
    }

    func writeOverview(_ on: [KitScan], skills: [(name: String, folder: String, version: String?, source: String?, agents: [(String, String)], files: [String])]) {
        var md = "# " + tr("Навыки и MCP") + "\n\n"
        md += trf("Сохранено программой «Бэкап ИИ» %@.", Fmt.full.string(from: now)) + " "
        md += tr("Главное — то, что стоит у агента: правки в этой папке при следующем сохранении заменяются точной копией.") + "\n\n"
        md += "## " + tr("Агенты") + "\n\n| " + tr("Агент") + " | " + tr("Папка") + " | " + tr("Навыки") + " | MCP | " + tr("Плагины") + " |\n|---|---|---|---|---|\n"
        for s in on { md += "| \(s.spec.name) | `\(Fmt.shortPath(s.root.path))` | \(s.skills.count) | \(s.mcp.count) | \(s.plugins.count) |\n" }
        md += "\n## " + tr("Навыки") + "\n\n| " + tr("Навык") + " | " + tr("Версия") + " | " + tr("Где стоит") + " | " + tr("Откуда") + " | " + tr("Файлы") + " |\n|---|---|---|---|---|\n"
        for r in skills {
            let link = "[[\(KitNames.skills)/\(r.folder)/SKILL|\(r.name)]]"
            let where_ = r.agents.map { "\($0.0) (`\($0.1)`)" }.joined(separator: ", ")
            let files = r.files.count <= 6 ? r.files.joined(separator: ", ") : r.files.prefix(5).joined(separator: ", ") + " … +\(r.files.count - 5)"
            md += "| \(link) | \(r.version ?? "") | \(where_) | \(r.source ?? tr("неизвестно")) | \(files) |\n"
        }
        if !config.kitOwn.isEmpty {
            md += "\n## " + tr("Свои папки") + "\n\n"
            for o in config.kitOwn { md += "- \(o.name) — `\(Fmt.shortPath(o.path))`\n" }
        }
        md += "\n## " + tr("Как вернуть") + "\n\n"
        md += "- " + tr("Навык: скопируйте его папку из «Навыки» в папку навыков агента (например, ~/.claude/skills или ~/.codex/skills).") + "\n"
        md += "- " + tr("MCP: вставьте блок из MCP.md в настройки агента и впишите свои ключи.") + "\n"
        md += "- " + tr("Плагины: поставьте заново из указанного источника; если сохранены файлы — из папки «Плагины».") + "\n"
        md += "- " + tr("Прошлые версии — в «_прежние».") + "\n"
        writeDoc(KitNames.overview, md)
    }

    func writeDoc(_ name: String, _ text: String) {
        let u = dest.appendingPathComponent(name)
        if let old = try? String(contentsOf: u, encoding: .utf8), stripDate(old) == stripDate(text) { return }
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }

    // Строка с датой в обзоре меняется каждый раз — при сравнении её не учитываем.
    func stripDate(_ s: String) -> String { s.components(separatedBy: "\n").filter { !$0.contains("«Бэкап ИИ»") }.joined(separator: "\n") }

    func writeJournal() {
        let u = dest.appendingPathComponent(KitNames.journal)
        if !fm.fileExists(atPath: u.path) {
            try? ("# " + AW.w("Журнал изменений") + "\n\n" + AW.w("Записи программы «Бэкап ИИ» о навыках, MCP и плагинах. Новые — внизу.") + "\n\n").write(to: u, atomically: true, encoding: .utf8)
        }
        let lines = changes.isEmpty ? ["- \(Fmt.full.string(from: now)) \(trigger.title): " + KitEvent.text("nochange", [])]
            : changes.map { "- \(Fmt.full.string(from: now)) \($0.who): \($0.text)" }
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            try? h.close()
        }
    }

    // Копия во вторую папку — все файлы, точное повторение.
    func mirror() {
        guard let m = config.kitMirror, !m.isEmpty else { return }
        let target = URL(fileURLWithPath: m, isDirectory: true)
        guard !target.path.hasPrefix(dest.path + "/") else { return }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = ["-a", "--delete", dest.path + "/", target.path + "/"]
        try? p.run(); p.waitUntilExit()
    }
}

// MARK: - Для окна: агенты и «Что войдёт»

enum Kit {
    static var lock: URL { Paths.support.appendingPathComponent("kit.lock") }

    // Сохранить навыки и обновить состояние вкладки.
    @discardableResult
    static func run(_ config: AppConfig, trigger: Trigger, folder: URL? = nil) -> KitStatus {
        let b = KitBackup(config: config, trigger: trigger, folder: folder)
        let (scans, r) = b.run()
        var st = KitStatus.load()
        st.lastRun = b.now
        st.agents = agents(scans, config)
        let entries = r.changes.isEmpty
            ? [DemoChange(date: b.now, who: tr("все программы"), text: KitEvent.text("nochange", []), level: .ok, code: "nochange")]
            : r.changes
        st.history = Array((entries.reversed() + st.history).prefix(60))
        st.save()
        return st
    }

    static func agents(_ scans: [KitScan], _ config: AppConfig) -> [DemoAgent] {
        var list: [DemoAgent] = scans.map { s in
            var a = DemoAgent(name: s.spec.name, path: Fmt.shortPath(s.root.path), skills: s.skills.count, mcp: s.mcp.count, plugins: s.plugins.count)
            a.key = s.spec.id
            let extra = s.files.filter { !$0.dest.contains("/") && $0.config == nil }.map(\.dest)
            a.extra = extra.prefix(2).joined(separator: ", ")
            a.keys = s.files.filter { $0.config != nil }.reduce(0) { n, f in
                guard let d = try? Data(contentsOf: f.src) else { return n }
                return n + KitKeys.apply(d, format: f.config!, mode: "hide").1
            }
            a.on = !config.kitOff.contains(s.spec.id)
            if !a.on { a.state = .off; a.note = "выключено" }
            else if !s.found { a.state = .gone; a.note = "не найдено — программа удалена или папка перенесена" }
            else if !s.problems.isEmpty { a.state = .warn; a.note = "не удалось прочитать настройки" }
            return a
        }
        for o in config.kitOwn {
            var a = DemoAgent(name: o.name, path: Fmt.shortPath(o.path))
            a.key = "own:" + o.path
            a.extra = tr("своя папка")
            a.on = !config.kitOff.contains(a.key)
            if !a.on { a.state = .off; a.note = "выключено" }
            if !KitReader.isDir(URL(fileURLWithPath: o.path)) { a.state = .gone; a.note = "не найдено — программа удалена или папка перенесена" }
            list.append(a)
        }
        return list
    }

    // «Что войдёт»: проверка без записи.
    struct Line: Identifiable { let id = UUID(); var icon: String; var what: String; var path: String }

    static func preview(_ config: AppConfig) -> [(String, [Line])] {
        let b = KitBackup(config: config, trigger: .manual)
        let (scans, _) = b.run(dryRun: true)
        let keyIcon = ["keep": "🔑", "skip": "⛔"][config.kitKeys] ?? "🔒"
        let keySuffix = ["keep": tr(" — с ключами"), "skip": tr(" — не копируется")][config.kitKeys] ?? tr(" — ключи скрыты")
        var out: [(String, [Line])] = []
        for s in scans where !config.kitOff.contains(s.spec.id) {
            var lines: [Line] = []
            if !s.skills.isEmpty {
                lines.append(Line(icon: "✅", what: "\(s.skills.count) \(plural(s.skills.count, "навык", "навыка", "навыков")) — " + tr("папки целиком"), path: Fmt.shortPath(s.root.path)))
            }
            for f in s.files {
                var keys = 0
                if let fmt = f.config, let d = try? Data(contentsOf: f.src) { keys = KitKeys.apply(d, format: fmt, mode: "hide").1 }
                lines.append(Line(icon: keys > 0 ? keyIcon : "✅", what: f.dest + (keys > 0 ? keySuffix : ""), path: Fmt.shortPath(f.src.path)))
            }
            if !s.mcp.isEmpty { lines.append(Line(icon: "📋", what: "\(s.mcp.count) MCP — " + tr("список с готовыми настройками"), path: "MCP.md")) }
            if !s.plugins.isEmpty {
                let copied = s.plugins.filter { $0.copyDir != nil }.count
                lines.append(Line(icon: "📋", what: "\(s.plugins.count) \(plural(s.plugins.count, "плагин", "плагина", "плагинов")) — " + tr("список с источниками") + (copied > 0 ? trf(", файлы %d — целиком", copied) : ""), path: "Плагины.md"))
            }
            if s.notes.contains("plugins") { lines.append(Line(icon: "⛔", what: tr("Кэш плагинов — не копируется"), path: Fmt.shortPath(s.root.appendingPathComponent("plugins").path))) }
            out.append((s.spec.name.uppercased(), lines))
        }
        if !config.kitOwn.isEmpty {
            out.append((tr("СВОИ ПАПКИ"), config.kitOwn.map { Line(icon: "✅", what: $0.name + " — " + tr("папка целиком"), path: Fmt.shortPath($0.path)) }))
        }
        out.append((tr("НИКОГДА НЕ КОПИРУЕТСЯ"), [Line(icon: "⛔", what: tr("Файлы входа и ключи доступа: auth.json, .credentials, .env"), path: "")]))
        return out
    }
}
