import Foundation

// Общие модели и разбор файлов Claude Code и Codex.
// Принцип для всех источников: сообщение узнаём по смыслу (кто говорит + есть ли текст),
// а не по номеру версии формата. Если основной разбор ничего не нашёл — запасной (Generic).

enum Role { case user, assistant }

struct Turn {
    var role: Role
    var date: Date?
    var text: String
    var alts: [String] = []   // другие варианты (ветки) этого сообщения
}

struct ParsedSession {
    var id: String
    var title: String?
    var cwd: String?
    var start: Date?
    var turns: [Turn] = []
    var messageLines = 0     // записей, похожих на сообщения
    var badLines = 0         // строк, которые не удалось разобрать как JSON
    var fallback = false     // сохранено запасным способом
    var version: String?     // версия формата, если источник её пишет

    mutating func add(_ role: Role, _ text: String, _ date: Date?, alts: [String] = []) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty || !alts.isEmpty else { return }
        if start == nil { start = date }
        if var last = turns.last, last.role == role {
            if !clean.isEmpty { last.text += (last.text.isEmpty ? "" : "\n\n") + clean }
            last.alts += alts
            turns[turns.count - 1] = last
        } else {
            turns.append(Turn(role: role, date: date, text: clean, alts: alts))
        }
    }
}

// MARK: - Вспомогательное

enum Fmt {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    // Дата из строки ISO или из числа (секунды или миллисекунды).
    static func date(_ value: Any?) -> Date? {
        if let s = value as? String { return isoFrac.date(from: s) ?? iso.date(from: s) ?? Double(s).flatMap { date($0) } }
        if let n = value as? NSNumber {
            let v = n.doubleValue
            guard v > 0 else { return nil }
            return Date(timeIntervalSince1970: v > 1e11 ? v / 1000 : v)
        }
        if let d = value as? Double { return date(NSNumber(value: d)) }
        return nil
    }

    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    static func tidy(_ s: String) -> String {
        replace(s, "\\n{3,}", "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fileName(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "\n", with: " ")
        for ch in ["/", ":", "\\", "*", "?", "\"", "<", ">", "|", "#", "^", "[", "]"] {
            t = t.replacingOccurrences(of: ch, with: " ")
        }
        t = replace(t, " {2,}", " ").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if t.count > 80 { t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces) + "…" }
        return t.isEmpty ? AW.w("Без названия") : t
    }

    static func shortPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "—" }
        let home = Paths.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // Убирает служебные вставки, которые программы добавляют в сообщение пользователя.
    static func cleanUser(_ raw: String) -> String {
        var t = raw
        if t.hasPrefix("[Request interrupted") || t.hasPrefix("<task-notification>") { return "" }
        t = replace(t, "<system-reminder>.*?</system-reminder>", "")
        t = replace(t, "<local-command-std(out|err)>.*?</local-command-std(out|err)>", "")
        t = replace(t, "<command-message>.*?</command-message>", "")
        t = replace(t, "<command-name>(.*?)</command-name>", "$1")
        t = replace(t, "<command-args>(.*?)</command-args>", " $1")
        t = replace(t, "<in-app-browser-context[^>]*>.*?</in-app-browser-context>", "")
        t = replace(t, "\\[Image: source: [^\\]]*\\]", NSRegularExpression.escapedTemplate(for: AW.w("[изображение]")))
        t = replace(t, "<pasted_content[^>]*>", "\n" + NSRegularExpression.escapedTemplate(for: AW.w("〔вставленный текст〕")) + "\n")
        t = replace(t, "</pasted_content[^>]*>", "\n" + NSRegularExpression.escapedTemplate(for: AW.w("〔конец вставки〕")) + "\n")
        t = replace(t, "<side-sessions-event>.*?(</side-sessions-event>|$)", "")
        t = questionReplies(t)
        if let r = t.range(of: "## My request[^\\n]*:", options: .regularExpression) {
            var files: [String] = []
            for line in t[..<r.lowerBound].split(separator: "\n") where line.hasPrefix("## ") {
                let name = line.dropFirst(3).components(separatedBy: ": ").first ?? ""
                if !name.isEmpty { files.append(AW.f("[файл: %@]", name)) }
            }
            t = files.joined(separator: "\n") + "\n\n" + t[r.upperBound...]
        }
        return tidy(t)
    }

    // Ответы на вопросы модели (Codex) лежат как JSON — показываем их по-человечески.
    static func questionReplies(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<send_user_message_question_reply>(.*?)</send_user_message_question_reply>",
                                                options: [.dotMatchesLineSeparators]) else { return text }
        var out = text
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(m.range, in: text), let inner = Range(m.range(at: 1), in: text) else { continue }
            var lines: [String] = []
            if let data = text[inner].trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
               let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                for item in items {
                    let q = (item["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let a = (item["answer"] as? String) ?? ((item["answers"] as? [Any])?.compactMap { $0 as? String }.joined(separator: ", ")) ?? ""
                    lines.append((q.isEmpty ? "" : "**\(AW.w("Вопрос:"))** \(q)\n") + "**\(AW.w("Ответ:"))** \(a)")
                }
            }
            out.replaceSubrange(whole, with: lines.isEmpty ? String(text[inner]) : lines.joined(separator: "\n\n"))
        }
        return out
    }

    // Служебные сообщения, которые программы подкладывают от имени пользователя.
    static let injected = ["# AGENTS.md instructions", "<environment_context>", "<user_instructions>",
                           "<permissions instructions>", "<INSTRUCTIONS>", "<skill>", "<external_codex_apps_open_page>",
                           "<turn_aborted>", "<user_shell_command>", "<system-reminder>", "<side-sessions-event>",
                           // DSH Desktop: снимок настроек, смена модели, автоматические раунды цели, пересказы при сжатии контекста
                           "Current runtime context.", "[model changed:", "<goal_round>", "This is an automatically generated checkpoint",
                           "<compacted-summary>", "</compacted-summary>", "## Primary Request and Intent", "You are repeating the exact same tool call"]

    static func isInjected(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<system-reminder>") { return cleanUser(s).isEmpty }
        return injected.contains { s.hasPrefix($0) }
    }

    // Текст из списка блоков: [{type: text, text: …}, {type: image…}]. Картинки — пометкой, остальное (инструменты, рассуждения) пропускаем.
    static func blocks(_ content: Any?, user: Bool) -> String {
        if let s = content as? String { return user ? cleanUser(s) : s }
        guard let list = content as? [Any] else { return "" }
        var parts: [String] = []
        for item in list {
            if let s = item as? String { parts.append(user ? cleanUser(s) : s); continue }
            guard let b = item as? [String: Any] else { continue }
            let type = (b["type"] as? String ?? "").lowercased()
            if ["text", "input_text", "output_text"].contains(type) || (type.isEmpty && b["text"] is String) {
                guard let t = b["text"] as? String else { continue }
                if user, isInjected(t) { continue }
                parts.append(user ? cleanUser(t) : t)
            } else if type.contains("image") {
                parts.append(AW.w("[изображение]"))
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let time: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f }()
    static let dayTime: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "dd.MM HH:mm"; return f }()
    static let full: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "dd.MM.yyyy HH:mm"; return f }()
}

// Построчное чтение больших файлов без загрузки целиком в память.
func forEachLine(_ url: URL, markers: [Data], _ body: (Data, Bool) -> Void) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    var buffer = Data()
    func emit(_ line: Data, last: Bool) {
        guard !line.isEmpty else { return }
        if markers.isEmpty || markers.contains(where: { line.range(of: $0) != nil }) { body(line, last) }
    }
    while true {
        let chunk = handle.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        buffer.append(chunk)
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            emit(buffer.subdata(in: start..<nl), last: false)
            start = buffer.index(after: nl)
        }
        buffer = buffer.subdata(in: start..<buffer.endIndex)
    }
    emit(buffer, last: true)
}

func jsonObject(_ line: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
}

// MARK: - Распаковка zstd (встроенная утилита, запасной вариант — установленная в системе)

enum Zstd {
    static func path() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forResource: "zstd", withExtension: nil, subdirectory: "Helpers")?.path { candidates.append(bundled) }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/zstd").path)
        }
        candidates += ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Распаковывает во временный файл. Вызывающий удаляет его после чтения.
    static func decompress(_ url: URL) -> URL? {
        guard let zstd = path() else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-ai-zst", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(UUID().uuidString + ".jsonl")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: zstd)
        p.arguments = ["-d", "-q", "-f", url.path, "-o", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        return p.terminationStatus == 0 ? out : nil
    }
}

// MARK: - Запасной разбор для изменившихся форматов

// Обходит любые JSON-записи и собирает объекты, в которых есть «кто говорит» и текст.
enum Generic {
    static func role(of d: [String: Any]) -> Role? {
        var r = (d["role"] as? String) ?? (d["sender"] as? String) ?? ((d["author"] as? [String: Any])?["role"] as? String)
        if r == nil, let p = d["payload"] as? [String: Any] { r = p["role"] as? String }
        if r == nil, let t = d["type"] as? String {
            let low = t.lowercased()
            if low.contains("user") && low.contains("message") { r = "user" }
            if (low.contains("assistant") || low.contains("agent")) && low.contains("message") { r = "assistant" }
        }
        switch r?.lowercased() {
        case "user", "human": return .user
        case "assistant", "model", "ai", "bot": return .assistant
        default: return nil
        }
    }

    static func text(of d: [String: Any], user: Bool) -> String {
        if let s = d["text"] as? String { return user ? Fmt.cleanUser(s) : s }
        if let c = d["content"] { let t = Fmt.blocks(c, user: user); if !t.isEmpty { return t } }
        if let parts = d["parts"] as? [Any] { return Fmt.blocks(parts, user: user) }
        if let m = d["message"] as? String { return user ? Fmt.cleanUser(m) : m }
        if let m = d["message"] as? [String: Any] { return text(of: m, user: user) }
        if let data = d["data"] as? [String: Any] { return text(of: data, user: user) }
        return deepText(d, user: user, depth: 0)
    }

    // Последняя попытка: текст во вложенных полях с типичными названиями (body, payload, value…).
    static func deepText(_ d: [String: Any], user: Bool, depth: Int) -> String {
        guard depth < 4 else { return "" }
        for key in ["text", "value", "body", "content", "payload", "message", "data"] {
            if let s = d[key] as? String, !s.isEmpty { return user ? Fmt.cleanUser(s) : s }
            if let n = d[key] as? [String: Any] { let t = deepText(n, user: user, depth: depth + 1); if !t.isEmpty { return t } }
            if let list = d[key] as? [Any] { let t = Fmt.blocks(list, user: user); if !t.isEmpty { return t } }
        }
        return ""
    }

    static func collect(_ any: Any, date: Date?, into s: inout ParsedSession) {
        if let d = any as? [String: Any] {
            let when = Fmt.date(d["timestamp"] ?? d["time"] ?? d["ts"] ?? d["created_at"] ?? d["createdAt"] ?? d["create_time"]) ?? date
            if let r = role(of: d) {
                let t = text(of: d, user: r == .user)
                if !t.isEmpty, !(r == .user && Fmt.isInjected(t)) { s.messageLines += 1; s.add(r, t, when); return }
            }
            for v in d.values { collect(v, date: when, into: &s) }
        } else if let list = any as? [Any] {
            for v in list { collect(v, date: date, into: &s) }
        }
    }

    static func parseLines(_ url: URL, id: String) -> ParsedSession {
        var s = ParsedSession(id: id)
        s.fallback = true
        forEachLine(url, markers: []) { line, _ in
            if let d = jsonObject(line) { collect(d, date: nil, into: &s) }
        }
        if s.turns.isEmpty { s.fallback = false }
        return s
    }
}

// MARK: - Claude Code

enum ClaudeReader {
    static let markers = ["\"type\":\"user\"", "\"type\":\"assistant\"", "custom-title", "\"type\":\"summary\""].map { Data($0.utf8) }

    static func sessionFiles(_ root: URL) -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var result: [URL] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            result += files.filter { $0.pathExtension == "jsonl" }
        }
        return result
    }

    static func parse(_ url: URL) -> ParsedSession {
        var s = ParsedSession(id: url.deletingPathExtension().lastPathComponent)
        var summary: String?
        forEachLine(url, markers: markers) { line, last in
            guard let d = jsonObject(line) else { if !last { s.badLines += 1 }; return }
            let type = d["type"] as? String
            if type == "custom-title", let t = d["customTitle"] as? String, !t.isEmpty { s.title = t; return }
            if type == "summary", let t = d["summary"] as? String { summary = t; return }
            guard type == "user" || type == "assistant", let message = d["message"] as? [String: Any] else { return }
            if s.version == nil { s.version = d["version"] as? String }
            if s.cwd == nil { s.cwd = d["cwd"] as? String }
            if d["isSidechain"] as? Bool == true || d["isMeta"] as? Bool == true
                || d["isCompactSummary"] as? Bool == true || d["isApiErrorMessage"] as? Bool == true
                || d["isVisibleInTranscriptOnly"] as? Bool == true { return }
            if let origin = d["origin"] as? [String: Any], origin["kind"] as? String == "task-notification" { return }
            s.messageLines += 1
            s.add(type == "user" ? .user : .assistant, Fmt.blocks(message["content"], user: type == "user"), Fmt.date(d["timestamp"]))
        }
        if s.title == nil {
            let side = url.deletingPathExtension().appendingPathComponent("custom-title.json")
            if let data = try? Data(contentsOf: side), let d = jsonObject(data) { s.title = d["customTitle"] as? String }
        }
        if s.title == nil { s.title = summary }
        if s.turns.isEmpty {
            var g = Generic.parseLines(url, id: s.id)
            g.title = s.title; g.cwd = s.cwd; g.version = s.version
            if !g.turns.isEmpty { return g }
        }
        return s
    }
}

// MARK: - Codex: файлы сессий

enum CodexReader {
    static let markers = ["session_meta", "UserMessage", "AgentMessage", "\"user_message\"", "\"agent_message\"", "\"type\":\"message\""].map { Data($0.utf8) }

    struct Candidate { var url: URL; var compressed: Bool }

    static func sessionFiles(_ root: URL) -> [Candidate] {
        let fm = FileManager.default
        var result: [Candidate] = []
        if let e = fm.enumerator(at: root.appendingPathComponent("sessions"), includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension == "jsonl" { result.append(Candidate(url: url, compressed: false)) }
        }
        for url in (try? fm.contentsOfDirectory(at: root.appendingPathComponent("archived_sessions"), includingPropertiesForKeys: nil)) ?? [] {
            if url.pathExtension == "jsonl" { result.append(Candidate(url: url, compressed: false)) }
            if url.lastPathComponent.hasSuffix(".jsonl.zst") { result.append(Candidate(url: url, compressed: true)) }
        }
        return result
    }

    // id сессии зашит в конец имени файла: rollout-<дата>-<uuid>.jsonl
    static func idFromName(_ url: URL) -> String {
        var name = url.lastPathComponent
        for ext in [".zst", ".jsonl"] where name.hasSuffix(ext) { name = String(name.dropLast(ext.count)) }
        let parts = name.split(separator: "-")
        return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : name
    }

    static func titles(_ root: URL) -> [String: String] {
        var map: [String: String] = [:]
        forEachLine(root.appendingPathComponent("session_index.jsonl"), markers: []) { line, _ in
            if let d = jsonObject(line), let id = d["id"] as? String, let name = d["thread_name"] as? String { map[id] = name }
        }
        return map
    }

    static func parse(_ url: URL, fallbackID: String) -> ParsedSession {
        var items = ParsedSession(id: fallbackID)      // из item_completed (новые версии)
        var events = ParsedSession(id: fallbackID)     // из event_msg user_message/agent_message
        var raw = ParsedSession(id: fallbackID)        // из response_item message (запасной путь)
        var id: String?
        var cwd: String?
        var metaDate: Date?
        var version: String?
        forEachLine(url, markers: markers) { line, last in
            guard let d = jsonObject(line) else { if !last { raw.badLines += 1 }; return }
            let type = d["type"] as? String
            let p = d["payload"] as? [String: Any] ?? [:]
            let date = Fmt.date(d["timestamp"])
            switch (type, p["type"] as? String) {
            case ("session_meta", _):
                if id == nil {
                    id = p["id"] as? String; cwd = p["cwd"] as? String
                    metaDate = Fmt.date(p["timestamp"]); version = p["cli_version"] as? String
                }
            case ("event_msg", "item_completed"):
                guard let item = p["item"] as? [String: Any] else { return }
                let kind = (item["type"] as? String ?? "").lowercased()
                if kind == "usermessage" {
                    items.messageLines += 1
                    items.add(.user, Fmt.blocks(item["content"], user: true), date)
                } else if kind == "agentmessage" {
                    items.messageLines += 1
                    items.add(.assistant, (item["text"] as? String) ?? Fmt.blocks(item["content"], user: false), date)
                }
            case ("event_msg", "user_message"):
                events.messageLines += 1
                events.add(.user, Fmt.cleanUser(p["message"] as? String ?? ""), date)
            case ("event_msg", "agent_message"):
                events.messageLines += 1
                events.add(.assistant, p["message"] as? String ?? "", date)
            case ("response_item", "message"):
                let role = p["role"] as? String
                guard role == "user" || role == "assistant" else { return }
                raw.messageLines += 1
                raw.add(role == "user" ? .user : .assistant, Fmt.blocks(p["content"], user: role == "user"), date)
            default: break
            }
        }
        var s = !items.turns.isEmpty ? items : (!events.turns.isEmpty ? events : raw)
        s.messageLines = max(items.messageLines, events.messageLines, raw.messageLines)
        s.badLines = raw.badLines
        s.id = id ?? fallbackID
        s.cwd = cwd
        s.version = version
        if s.start == nil { s.start = metaDate }
        if s.turns.isEmpty {
            var g = Generic.parseLines(url, id: s.id)
            g.cwd = cwd; g.version = version
            if !g.turns.isEmpty { return g }
        }
        return s
    }
}
