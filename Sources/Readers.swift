import Foundation
import SQLite3

// Источники, кроме файлов Claude Code и Codex: база Codex, DSH Desktop, Hermes, VS Code,
// экспорты claude.ai и ChatGPT. Базы открываются только для чтения.

struct SessionRef {
    var key: String
    var size: Int64
    var mod: Double
    var label: String
    var rewrite = false              // экспорты с сайтов: файл пересобирается целиком
    var load: () -> ParsedSession?
}

struct SourceScan {
    var found = false
    var refs: [SessionRef] = []
    var problems: [Msg] = []
}

func fileStamp(_ url: URL) -> (Int64, Double) {
    let a = try? FileManager.default.attributesOfItem(atPath: url.path)
    return ((a?[.size] as? NSNumber)?.int64Value ?? 0, (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
}

func dirExists(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

// MARK: - SQLite только для чтения

final class SQLiteDB {
    private var db: OpaquePointer?

    init?(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let base = URL(fileURLWithPath: path).absoluteString
        for suffix in ["?mode=ro", "?mode=ro&immutable=1"] {
            var h: OpaquePointer?
            if sqlite3_open_v2(base + suffix, &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
               sqlite3_exec(h, "select count(*) from sqlite_master", nil, nil, nil) == SQLITE_OK {
                db = h
                sqlite3_busy_timeout(h, 5000)
                return
            }
            sqlite3_close(h)
        }
        return nil
    }

    deinit { sqlite3_close(db) }

    func rows(_ sql: String, _ args: [String] = []) -> [[String: Any]]? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() { sqlite3_bind_text(st, Int32(i + 1), a, -1, transient) }
        var out: [[String: Any]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var r: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(st) {
                let name = String(cString: sqlite3_column_name(st, c))
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: r[name] = NSNumber(value: sqlite3_column_int64(st, c))
                case SQLITE_FLOAT: r[name] = NSNumber(value: sqlite3_column_double(st, c))
                case SQLITE_TEXT: r[name] = String(cString: sqlite3_column_text(st, c))
                default: break
                }
            }
            out.append(r)
        }
        return out
    }

    func columns(_ table: String) -> Set<String> {
        Set((rows("PRAGMA table_info(\(table))") ?? []).compactMap { $0["name"] as? String })
    }
}

func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) ?? 0 }

// MARK: - Claude Code

enum ClaudeScan {
    static func scan(_ config: AppConfig) -> SourceScan {
        let root = URL(fileURLWithPath: config.path(.claude))
        guard dirExists(root.path) else { return SourceScan() }
        var scan = SourceScan(found: true)
        for url in ClaudeReader.sessionFiles(root) {
            let (size, mod) = fileStamp(url)
            scan.refs.append(SessionRef(key: "claude:" + url.deletingPathExtension().lastPathComponent, size: size, mod: mod,
                                        label: url.lastPathComponent) { ClaudeReader.parse(url) })
        }
        return scan
    }
}

// MARK: - Codex: файлы + база

enum CodexScan {
    static func newest(_ root: URL, prefix: String) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return files.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".sqlite") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.last
            .map { root.appendingPathComponent($0).path }
    }

    static func scan(_ config: AppConfig) -> SourceScan {
        let root = URL(fileURLWithPath: config.path(.codex))
        guard dirExists(root.path) else { return SourceScan() }
        var scan = SourceScan(found: true)
        let titles = CodexReader.titles(root)
        let hasZstd = Zstd.path() != nil

        // 1. Файлы сессий. Одна сессия может лежать и в sessions, и в архиве — берём несжатый или самый большой файл.
        var byID: [String: (CodexReader.Candidate, Int64, Double)] = [:]
        for c in CodexReader.sessionFiles(root) {
            let id = CodexReader.idFromName(c.url)
            let (size, mod) = fileStamp(c.url)
            if let prev = byID[id] {
                if prev.0.compressed != c.compressed {
                    if !prev.0.compressed { continue }
                } else if prev.1 >= size {
                    continue
                }
            }
            byID[id] = (c, size, mod)
        }
        var skippedZst = 0
        for (id, entry) in byID {
            let (c, size, mod) = entry
            if c.compressed && !hasZstd { skippedZst += 1; continue }
            scan.refs.append(SessionRef(key: "codex:" + id, size: size, mod: mod, label: c.url.lastPathComponent) {
                var url = c.url
                if c.compressed {
                    guard let out = Zstd.decompress(c.url) else { return nil }
                    url = out
                }
                defer { if c.compressed { try? FileManager.default.removeItem(at: url) } }
                var s = CodexReader.parse(url, fallbackID: id)
                if s.title == nil { s.title = titles[s.id] ?? titles[id] }
                return s
            })
        }
        if skippedZst > 0 { scan.problems.append(Msg("%@ сжатых сессий пропущено: нет утилиты zstd", ["\(skippedZst)"])) }

        // 2. База истории: разговоры, у которых нет файла.
        guard let histPath = newest(root, prefix: "thread_history") else { return scan }
        guard let hist = SQLiteDB(histPath) else {
            scan.problems.append(Msg("база Codex не открывается"))
            return scan
        }
        let cols = hist.columns("thread_items")
        guard cols.isSuperset(of: ["thread_id", "item_type", "item_json"]) else {
            scan.problems.append(Msg("формат базы Codex изменился"))
            return scan
        }
        let order = cols.contains("rollout_ordinal") ? "rollout_ordinal" : "rowid"
        let timeCol = cols.contains("created_at_ms") ? "created_at_ms" : "0"
        var meta: [String: [String: Any]] = [:]
        if let statePath = newest(root, prefix: "state_"), let st = SQLiteDB(statePath) {
            for r in st.rows("select * from threads") ?? [] { if let id = r["id"] as? String { meta[id] = r } }
        }
        let stamps = hist.rows("select thread_id, count(*) as c, max(\(timeCol)) as m from thread_items where item_type = 'userMessage' group by thread_id") ?? []
        for r in stamps {
            guard let id = r["thread_id"] as? String, byID[id] == nil else { continue }
            let m = meta[id] ?? [:]
            let updated = max(num(r["m"]), num(m["updated_at_ms"]), num(m["updated_at"]) * 1000) / 1000
            scan.refs.append(SessionRef(key: "codex:" + id, size: Int64(num(r["c"])), mod: updated, label: "база: \(id)") {
                var s = ParsedSession(id: id)
                let items = hist.rows("select item_type, item_json, \(timeCol) as t from thread_items where thread_id = ? and item_type in ('userMessage', 'agentMessage') order by \(order)", [id]) ?? []
                for it in items {
                    guard let json = (it["item_json"] as? String)?.data(using: .utf8), let d = jsonObject(json) else { s.badLines += 1; continue }
                    s.messageLines += 1
                    let date = Fmt.date(it["t"])
                    if (it["item_type"] as? String) == "userMessage" {
                        s.add(.user, Fmt.blocks(d["content"], user: true), date)
                    } else {
                        s.add(.assistant, (d["text"] as? String) ?? Fmt.blocks(d["content"], user: false), date)
                    }
                }
                if s.turns.isEmpty {
                    // Запасной путь: формат элементов поменялся — ищем текст по смыслу во всех элементах разговора.
                    var g = ParsedSession(id: id)
                    g.fallback = true
                    for it in hist.rows("select item_json from thread_items where thread_id = ? order by \(order)", [id]) ?? [] {
                        if let json = (it["item_json"] as? String)?.data(using: .utf8), let d = jsonObject(json) { Generic.collect(d, date: nil, into: &g) }
                    }
                    s = g
                }
                let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (m["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                s.title = name ?? titles[id]
                s.cwd = m["cwd"] as? String
                if let c = m["created_at_ms"] ?? m["created_at"] { s.start = Fmt.date(c) ?? s.start }
                s.version = "база"
                return s
            })
        }
        return scan
    }
}

// MARK: - DSH Desktop (DeepSeek Harness)

enum DSHScan {
    static func scan(_ config: AppConfig) -> SourceScan {
        let root = URL(fileURLWithPath: config.path(.dsh))
        let sessions = root.appendingPathComponent("sessions")
        guard dirExists(sessions.path) else { return SourceScan() }
        var scan = SourceScan(found: true)
        let fm = FileManager.default
        let hasZstd = Zstd.path() != nil
        var skipped = 0
        for project in (try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [] {
            for dir in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? [] where dir.lastPathComponent.hasPrefix("session") {
                let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("session") && ($0.lastPathComponent.hasSuffix(".jsonl") || $0.lastPathComponent.hasSuffix(".jsonl.zstd") || $0.lastPathComponent.hasSuffix(".jsonl.zst")) }
                guard let file = files.max(by: { fileStamp($0).1 < fileStamp($1).1 }) else { continue }
                let compressed = !file.lastPathComponent.hasSuffix(".jsonl")
                if compressed && !hasZstd { skipped += 1; continue }
                let id = dir.lastPathComponent
                let (size, mod) = fileStamp(file)
                scan.refs.append(SessionRef(key: "dsh:" + id, size: size, mod: mod, label: "\(id)/\(file.lastPathComponent)") {
                    var url = file
                    if compressed { guard let out = Zstd.decompress(file) else { return nil }; url = out }
                    defer { if compressed { try? FileManager.default.removeItem(at: url) } }
                    var s = parse(url, id: id)
                    s.title = title(root: root, id: id) ?? s.title
                    return s
                })
            }
        }
        if skipped > 0 { scan.problems.append(Msg("%@ сжатых сессий пропущено: нет утилиты zstd", ["\(skipped)"])) }
        return scan
    }

    static func title(root: URL, id: String) -> String? {
        let url = root.appendingPathComponent("storages/session_projcache/sessions/\(id).json")
        guard let data = try? Data(contentsOf: url), let d = jsonObject(data) else { return nil }
        var record = d["record"]
        if let s = record as? String, let r = s.data(using: .utf8) { record = jsonObject(r) }
        let rows = (record as? [String: Any])?["rows"] as? [String: Any]
        let t = (rows?["title"] as? [String: Any])?["val"] as? String
        return t?.isEmpty == false ? t : nil
    }

    // Записи узнаём по окончанию типа (…user/message, …assistant/message) — так новые версии формата продолжают читаться.
    static func parse(_ url: URL, id: String) -> ParsedSession {
        var s = ParsedSession(id: id)
        forEachLine(url, markers: []) { line, last in
            guard let d = jsonObject(line) else { if !last { s.badLines += 1 }; return }
            let type = (d["type"] as? String ?? "").lowercased()
            let data = d["data"] as? [String: Any] ?? [:]
            let date = Fmt.date(d["time"] ?? d["timestamp"])
            if type.hasSuffix("session/title"), let t = data["title"] as? String, !t.isEmpty {
                if s.title == nil { s.title = t }
            } else if type == "session" {
                s.cwd = d["cwd"] as? String
                s.start = Fmt.date(d["createdAt"])
                if let v = d["version"] { s.version = "v\(v)" }
            } else if type.hasSuffix("user/message") {
                let msg = data["message"] as? [String: Any]
                let text = Fmt.blocks(data["content"] ?? msg?["content"], user: true)
                // Сообщение пользователя без своего текста (только вложение или служебная вставка) — не признак поломки формата.
                if !text.isEmpty { s.messageLines += 1 }
                s.add(.user, text, date)
            } else if type.hasSuffix("assistant/message") {
                s.messageLines += 1
                let msg = data["message"] as? [String: Any]
                s.add(.assistant, Fmt.blocks(msg?["content"] ?? data["content"], user: false), date)
            }
        }
        if s.turns.isEmpty {
            var g = Generic.parseLines(url, id: id)
            g.cwd = s.cwd; g.start = s.start ?? g.start; g.version = s.version
            if !g.turns.isEmpty || s.messageLines == 0 { g.title = g.title ?? s.title; return g }
        }
        return s
    }
}

// MARK: - Hermes (Nous Research): ~/.hermes/state.db и ~/.hermes/profiles/<имя>/state.db

enum HermesScan {
    static func scan(_ config: AppConfig) -> SourceScan {
        let root = URL(fileURLWithPath: config.path(.hermes))
        var dbs: [(String, String)] = []
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("state.db").path) {
            dbs.append(("default", root.appendingPathComponent("state.db").path))
        }
        for p in (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("profiles").path)) ?? [] {
            let path = root.appendingPathComponent("profiles/\(p)/state.db").path
            if FileManager.default.fileExists(atPath: path) { dbs.append((p, path)) }
        }
        guard !dbs.isEmpty else { return SourceScan() }
        var scan = SourceScan(found: true)
        for (profile, path) in dbs {
            guard let db = SQLiteDB(path) else { scan.problems.append(Msg("база Hermes «%@» не открывается", [profile])); continue }
            let mcols = db.columns("messages")
            guard mcols.isSuperset(of: ["session_id", "role", "content"]) else { scan.problems.append(Msg("формат базы Hermes изменился")); continue }
            let tcol = mcols.contains("timestamp") ? "timestamp" : "0"
            var sessions: [String: [String: Any]] = [:]
            for r in db.rows("select * from sessions") ?? [] { if let id = r["id"] as? String { sessions[id] = r } }
            for r in db.rows("select session_id, count(*) as c, max(\(tcol)) as m from messages group by session_id") ?? [] {
                guard let id = r["session_id"] as? String else { continue }
                let meta = sessions[id] ?? [:]
                scan.refs.append(SessionRef(key: "hermes:\(profile):\(id)", size: Int64(num(r["c"])), mod: num(r["m"]), label: "\(profile)/\(id)") {
                    var s = ParsedSession(id: id)
                    for m in db.rows("select role, content, \(tcol) as t from messages where session_id = ? order by rowid", [id]) ?? [] {
                        let role = (m["role"] as? String ?? "").lowercased()
                        guard role == "user" || role == "assistant" else { continue }
                        s.messageLines += 1
                        var content: Any? = m["content"]
                        if let str = content as? String, str.hasPrefix("["), let data = str.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: data) { content = parsed }
                        s.add(role == "user" ? .user : .assistant, Fmt.blocks(content, user: role == "user"), Fmt.date(m["t"]))
                    }
                    s.title = (meta["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    s.start = Fmt.date(meta["started_at"]) ?? s.start
                    if profile != "default" { s.cwd = "профиль \(profile)" }
                    return s
                })
            }
        }
        return scan
    }
}

// MARK: - VS Code (Copilot Chat). Формат не описан официально и меняется — экспериментально.

enum VSCodeScan {
    static func roots(_ config: AppConfig) -> [URL] {
        var list = [URL(fileURLWithPath: config.path(.vscode))]
        if config.sourcePaths[SourceKind.vscode.rawValue] == nil && SourceKind.vscode.envOverride == nil {
            list.append(Paths.home.appendingPathComponent("Library/Application Support/Code - Insiders/User"))
        }
        return list.filter { dirExists($0.path) }
    }

    static func scan(_ config: AppConfig) -> SourceScan {
        let roots = roots(config)
        guard !roots.isEmpty else { return SourceScan() }
        var scan = SourceScan(found: true)
        let fm = FileManager.default
        for root in roots {
            var files: [(URL, String?)] = []
            let ws = root.appendingPathComponent("workspaceStorage")
            for dir in (try? fm.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil)) ?? [] {
                let folder = workspaceFolder(dir)
                for f in (try? fm.contentsOfDirectory(at: dir.appendingPathComponent("chatSessions"), includingPropertiesForKeys: nil)) ?? []
                where ["json", "jsonl"].contains(f.pathExtension) { files.append((f, folder)) }
            }
            for f in (try? fm.contentsOfDirectory(at: root.appendingPathComponent("globalStorage/emptyWindowChatSessions"), includingPropertiesForKeys: nil)) ?? []
            where ["json", "jsonl"].contains(f.pathExtension) { files.append((f, nil)) }
            for (f, folder) in files {
                let (size, mod) = fileStamp(f)
                let id = f.deletingPathExtension().lastPathComponent
                scan.refs.append(SessionRef(key: "vscode:" + id, size: size, mod: mod, label: f.lastPathComponent) {
                    var s = parse(f, id: id)
                    s.cwd = folder
                    return s
                })
            }
        }
        return scan
    }

    static func workspaceFolder(_ dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("workspace.json")), let d = jsonObject(data),
              let folder = (d["folder"] ?? d["workspace"]) as? String else { return nil }
        return URL(string: folder)?.path ?? folder
    }

    // .jsonl — журнал изменений: kind 0 — снимок, 1 — заменить значение по пути, 2 — добавить в список по пути.
    static func load(_ url: URL) -> [String: Any]? {
        if url.pathExtension == "json" {
            return (try? Data(contentsOf: url)).flatMap { jsonObject($0) }
        }
        var root: Any = [String: Any]()
        forEachLine(url, markers: []) { line, _ in
            guard let d = jsonObject(line) else { return }
            let kind = num(d["kind"])
            let path = (d["k"] as? [Any]) ?? []
            if kind == 0 { root = d["v"] ?? root }
            else if kind == 1 { root = setValue(root, path[...], d["v"] as Any, append: false) }
            else if kind == 2 { root = setValue(root, path[...], d["v"] as Any, append: true) }
        }
        return root as? [String: Any]
    }

    static func setValue(_ node: Any, _ path: ArraySlice<Any>, _ value: Any, append: Bool) -> Any {
        guard let key = path.first else {
            if append {
                var list = node as? [Any] ?? []
                if let more = value as? [Any] { list += more } else { list.append(value) }
                return list
            }
            return value
        }
        if let k = key as? String {
            var d = node as? [String: Any] ?? [:]
            d[k] = setValue(d[k] as Any, path.dropFirst(), value, append: append)
            return d
        }
        if let i = (key as? NSNumber)?.intValue {
            var list = node as? [Any] ?? []
            while list.count <= i { list.append([String: Any]()) }
            list[i] = setValue(list[i], path.dropFirst(), value, append: append)
            return list
        }
        return node
    }

    static func parse(_ url: URL, id: String) -> ParsedSession {
        var s = ParsedSession(id: id)
        guard let d = load(url) else { s.badLines = 1; return s }
        s.title = (d["customTitle"] as? String) ?? (d["title"] as? String)
        s.start = Fmt.date(d["creationDate"])
        for r in d["requests"] as? [[String: Any]] ?? [] {
            s.messageLines += 1
            let date = Fmt.date(r["timestamp"])
            let message = r["message"] as? [String: Any]
            let userText = (message?["text"] as? String) ?? Fmt.blocks(message?["parts"], user: true)
            s.add(.user, Fmt.cleanUser(userText), date)
            var answer: [String] = []
            for part in r["response"] as? [Any] ?? [] {
                if let p = part as? [String: Any] {
                    if let v = p["value"] as? String { answer.append(v) }
                    else if let c = p["content"] as? [String: Any], let v = c["value"] as? String { answer.append(v) }
                } else if let v = part as? String { answer.append(v) }
            }
            s.add(.assistant, answer.joined(), date)
        }
        if s.turns.isEmpty {
            var g = ParsedSession(id: id)
            g.fallback = true
            Generic.collect(d, date: nil, into: &g)
            g.title = s.title
            if !g.turns.isEmpty { return g }
        }
        return s
    }
}

// MARK: - Экспорты с сайтов: claude.ai и ChatGPT

enum WebScan {
    static func scan(_ kind: SourceKind, _ config: AppConfig) -> SourceScan {
        let url = URL(fileURLWithPath: config.path(kind))
        guard let data = try? Data(contentsOf: url) else { return SourceScan() }
        var scan = SourceScan(found: true)
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            scan.problems.append(Msg("импортированный файл не читается"))
            return scan
        }
        for c in list {
            let id = convID(c, kind)
            guard !id.isEmpty else { continue }
            let updated = Fmt.date(c["updated_at"] ?? c["update_time"])?.timeIntervalSince1970 ?? 0
            let count = (c["chat_messages"] as? [Any])?.count ?? (c["mapping"] as? [String: Any])?.count ?? 0
            scan.refs.append(SessionRef(key: "\(kind.rawValue):\(id)", size: Int64(count), mod: updated, label: id, rewrite: true) {
                kind == .chatgpt ? chatgpt(c) : claudeai(c)
            })
        }
        return scan
    }

    static func convID(_ c: [String: Any], _ kind: SourceKind) -> String {
        kind == .chatgpt ? ((c["conversation_id"] ?? c["id"]) as? String ?? "") : (c["uuid"] as? String ?? "")
    }

    // Ветки: основная — путь до последнего сообщения, остальные — «другие варианты» у места, где разговор разветвился.
    static let userMark = "{{ИМЯ}}"   // заменяется на имя из настроек при записи

    struct Node { var id: String; var parent: String?; var children: [String]; var role: Role?; var text: String; var date: Date? }

    static func render(_ nodes: [String: Node], main: [String], speaker: String) -> ParsedSession {
        var s = ParsedSession(id: "")
        let onPath = Set(main)
        for id in main {
            guard let n = nodes[id] else { continue }
            var alts: [String] = []
            if let p = n.parent, let parent = nodes[p] {
                for sib in parent.children where !onPath.contains(sib) && sib != id {
                    let branch = branchText(nodes, from: sib, speaker: speaker)
                    if !branch.isEmpty { alts.append(branch) }
                }
            }
            guard let role = n.role, !n.text.isEmpty else {
                if !alts.isEmpty, let last = s.turns.indices.last { s.turns[last].alts += alts }
                continue
            }
            s.messageLines += 1
            s.add(role, n.text, n.date, alts: alts)
        }
        return s
    }

    static func branchText(_ nodes: [String: Node], from start: String, speaker: String) -> String {
        var lines: [String] = []
        var cur: String? = start
        var guardCount = 0
        while let id = cur, let n = nodes[id], guardCount < 500 {
            if let r = n.role, !n.text.isEmpty { lines.append("**\(r == .user ? userMark : speaker):** \(n.text)") }
            cur = n.children.last
            guardCount += 1
        }
        return lines.joined(separator: "\n\n")
    }

    static func chatgpt(_ c: [String: Any]) -> ParsedSession {
        var nodes: [String: Node] = [:]
        for (key, value) in c["mapping"] as? [String: [String: Any]] ?? [:] {
            var role: Role?
            var text = ""
            var date: Date?
            if let m = value["message"] as? [String: Any] {
                let r = ((m["author"] as? [String: Any])?["role"] as? String) ?? ""
                let content = m["content"] as? [String: Any] ?? [:]
                let ctype = content["content_type"] as? String ?? ""
                let hidden = ((m["metadata"] as? [String: Any])?["is_visually_hidden_from_conversation"] as? Bool) ?? false
                let recipient = m["recipient"] as? String ?? "all"
                if (r == "user" || r == "assistant") && ["text", "multimodal_text"].contains(ctype) && !hidden && recipient == "all" {
                    role = r == "user" ? .user : .assistant
                    var parts: [String] = []
                    for p in content["parts"] as? [Any] ?? [] {
                        if let s = p as? String { parts.append(s) }
                        else if let d = p as? [String: Any], (d["content_type"] as? String ?? "").contains("image") { parts.append(AW.w("[изображение]")) }
                    }
                    text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                date = Fmt.date(m["create_time"])
            }
            nodes[key] = Node(id: key, parent: value["parent"] as? String, children: value["children"] as? [String] ?? [], role: role, text: text, date: date)
        }
        var main: [String] = []
        var cur = c["current_node"] as? String
        while let id = cur, let n = nodes[id], main.count < 100_000 { main.append(id); cur = n.parent }
        if main.isEmpty { main = nodes.values.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }.map(\.id) } else { main.reverse() }
        var s = render(nodes, main: main, speaker: "ChatGPT")
        s.id = convID(c, .chatgpt)
        s.title = c["title"] as? String
        s.start = Fmt.date(c["create_time"]) ?? s.start
        if s.turns.isEmpty { s.fallback = true; Generic.collect(c, date: nil, into: &s) }
        return s
    }

    static func claudeai(_ c: [String: Any]) -> ParsedSession {
        let msgs = c["chat_messages"] as? [[String: Any]] ?? []
        var nodes: [String: Node] = [:]
        var orderIDs: [String] = []
        for (i, m) in msgs.enumerated() {
            let id = m["uuid"] as? String ?? "m\(i)"
            let sender = (m["sender"] as? String ?? "").lowercased()
            let user = sender == "human" || sender == "user"
            var text = Fmt.blocks(m["content"], user: user)
            if text.isEmpty { text = (m["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let files = ((m["attachments"] as? [[String: Any]] ?? []) + (m["files"] as? [[String: Any]] ?? []))
                .compactMap { $0["file_name"] as? String }.map { AW.f("[вложение: %@]", $0) }
            if !files.isEmpty { text = (files + [text]).filter { !$0.isEmpty }.joined(separator: "\n") }
            nodes[id] = Node(id: id, parent: m["parent_message_uuid"] as? String, children: [],
                             role: user ? .user : (sender == "assistant" ? .assistant : nil), text: text,
                             date: Fmt.date(m["created_at"]))
            orderIDs.append(id)
        }
        let branched = nodes.values.contains { $0.parent != nil && nodes[$0.parent!] != nil }
        var main = orderIDs
        if branched {
            for id in orderIDs { if let p = nodes[id]?.parent, nodes[p] != nil { nodes[p]?.children.append(id) } }
            let leaves = nodes.values.filter { $0.children.isEmpty }
            if let leaf = leaves.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
                main = []
                var cur: String? = leaf.id
                while let id = cur, let n = nodes[id], main.count < 100_000 { main.append(id); cur = n.parent }
                main.reverse()
            }
        }
        var s = render(nodes, main: main, speaker: "Claude")
        s.id = convID(c, .claudeai)
        s.title = c["name"] as? String
        s.start = Fmt.date(c["created_at"]) ?? s.start
        if s.turns.isEmpty { s.fallback = true; Generic.collect(c, date: nil, into: &s) }
        return s
    }
}

// Импорт скачанного экспорта (ZIP, папка или JSON). Чей он — определяем по содержимому, а не по имени.
enum WebImport {
    static func run(_ url: URL) -> (ok: Bool, message: String) {
        let fm = FileManager.default
        var tmp: URL?
        var base = url
        if url.pathExtension.lowercased() == "zip" {
            let dir = fm.temporaryDirectory.appendingPathComponent("backup-ai-import-\(UUID().uuidString)", isDirectory: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, dir.path]
            do { try p.run(); p.waitUntilExit() } catch { return (false, tr("Не удалось распаковать архив")) }
            guard p.terminationStatus == 0 else { return (false, tr("Не удалось распаковать архив")) }
            tmp = dir
            base = dir
        }
        defer { if let tmp { try? fm.removeItem(at: tmp) } }

        var jsonFiles: [URL] = []
        if base.pathExtension.lowercased() == "json" {
            jsonFiles = [base]
        } else if let e = fm.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let f as URL in e where f.pathExtension.lowercased() == "json" && f.lastPathComponent.lowercased().hasPrefix("conversations") {
                jsonFiles.append(f)
            }
        }
        guard !jsonFiles.isEmpty else { return (false, tr("В этом файле нет переписок (conversations.json). Нужен экспорт из настроек claude.ai или ChatGPT.")) }

        var byKind: [SourceKind: [[String: Any]]] = [:]
        for f in jsonFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: f), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
                  let first = list.first else { continue }
            let kind: SourceKind? = first["mapping"] != nil ? .chatgpt : (first["chat_messages"] != nil ? .claudeai : nil)
            if let kind { byKind[kind, default: []] += list }
        }
        guard !byKind.isEmpty else { return (false, tr("Формат файла не похож ни на экспорт claude.ai, ни на экспорт ChatGPT.")) }

        try? fm.createDirectory(at: Paths.imports, withIntermediateDirectories: true)
        var report: [String] = []
        for (kind, list) in byKind {
            // Объединяем с прошлым импортом: разговоры, удалённые на сайте, не теряются.
            let target = Paths.imports.appendingPathComponent(kind.rawValue + ".json")
            var merged: [String: [String: Any]] = [:]
            var order: [String] = []
            if let data = try? Data(contentsOf: target), let old = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                for c in old { let id = WebScan.convID(c, kind); if merged[id] == nil { order.append(id) }; merged[id] = c }
            }
            for c in list { let id = WebScan.convID(c, kind); if merged[id] == nil { order.append(id) }; merged[id] = c }
            let all = order.compactMap { merged[$0] }
            if let data = try? JSONSerialization.data(withJSONObject: all) { try? data.write(to: target, options: .atomic) }
            report.append("\(kind.title): \(list.count) \(plural(list.count, "разговор", "разговора", "разговоров"))")
        }
        return (true, trf("Импортировано — %@.", report.joined(separator: ", ")))
    }
}
