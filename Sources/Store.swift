import Foundation

// Вариант сборки (build.sh): DEMO=1 — вымышленные данные; идентификатор «.test» — проверка на настоящих данных;
// обычная — настоящая программа.
enum Build {
    #if DEMO
    static let demo = true
    #else
    static let demo = false
    #endif
    // Проверочная сборка: свои настройки в отдельной папке, расписание, автозапуск и уведомления не трогаются,
    // настоящие переписки и навыки только читаются.
    static let check = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".test")
}

// Где программа хранит свои настройки, состояние и статус.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let env = ProcessInfo.processInfo.environment
    // BACKUP_AI_SUPPORT — только для проверки, чтобы не трогать настоящие настройки.
    static let support: URL = {
        if Build.demo { return home.appendingPathComponent("Documents/Мои программы/Бэкап ИИ тест/demo-data", isDirectory: true) }
        if let s = env["BACKUP_AI_SUPPORT"] { return URL(fileURLWithPath: s, isDirectory: true) }
        return home.appendingPathComponent(Build.check ? "Library/Application Support/Бэкап ИИ (тест)" : "Library/Application Support/Бэкап ИИ",
                                           isDirectory: true)
    }()
    static let config = support.appendingPathComponent("config.json")
    static let state = support.appendingPathComponent("state.json")
    static let status = support.appendingPathComponent("status.json")
    static let lock = support.appendingPathComponent("run.lock")
    static let launchLog = support.appendingPathComponent("launchd.log")
    static let imports = support.appendingPathComponent("imports", isDirectory: true)

    // Проверка и демо: расписание, автозапуск и уведомления не трогаются.
    static let isTest = Build.demo || Build.check || env["BACKUP_AI_SUPPORT"] != nil

    // BACKUP_AI_CLAUDE_DIR / BACKUP_AI_CODEX_DIR — подмена источников для проверки поломки формата.
    // В демо источники — пустые папки внутри demo-data. В проверке настоящие папки только читаются,
    // а настройку Claude Code «хранить переписки» программа меняет в своей копии, не в ~/.claude.
    static let claudeProjects = Build.demo ? support.appendingPathComponent("sources/claude-projects", isDirectory: true)
        : env["BACKUP_AI_CLAUDE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
    static let claudeSettings = isTest ? support.appendingPathComponent("sources/claude-settings.json")
        : home.appendingPathComponent(".claude/settings.json")
    static let codexRoot = Build.demo ? support.appendingPathComponent("sources/codex", isDirectory: true)
        : env["BACKUP_AI_CODEX_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".codex", isDirectory: true)

    static func ensureSupport() {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
}

enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        Paths.ensureSupport()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Источники

// Программы, из которых берём переписки. Порядок — как в окне.
enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case claude, codex, dsh, hermes, vscode, claudeai, chatgpt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .dsh: return "DSH Desktop"
        case .hermes: return "Hermes"
        case .vscode: return "VS Code"
        case .claudeai: return "claude.ai"
        case .chatgpt: return "ChatGPT"
        }
    }

    // Как подписаны ответы модели в архиве.
    var speaker: String {
        switch self {
        case .claude, .claudeai: return "Claude"
        case .codex: return "Codex"
        case .dsh: return "DSH"
        case .hermes: return "Hermes"
        case .vscode: return "Copilot"
        case .chatgpt: return "ChatGPT"
        }
    }

    // Экспорты с сайтов не ищутся на диске — их импортируют вручную.
    var isWebExport: Bool { self == .claudeai || self == .chatgpt }

    var defaultPath: String {
        let h = Paths.home.path
        switch self {
        case .claude: return h + "/.claude/projects"
        case .codex: return h + "/.codex"
        case .dsh: return h + "/.dsh"
        case .hermes: return h + "/.hermes"
        case .vscode: return h + "/Library/Application Support/Code/User"
        case .claudeai, .chatgpt: return Paths.imports.appendingPathComponent(rawValue + ".json").path
        }
    }

    // BACKUP_AI_<ИСТОЧНИК>_DIR — подмена пути для проверок.
    var envOverride: String? { ProcessInfo.processInfo.environment["BACKUP_AI_\(rawValue.uppercased())_DIR"] }

    var note: String {
        switch self {
        case .vscode: return tr("Copilot Chat · экспериментально")
        case .claudeai: return tr("экспорт с сайта")
        case .chatgpt: return tr("экспорт с сайта")
        default: return ""
        }
    }
}

struct MDFolder: Codable, Equatable, Identifiable {
    var name: String
    var path: String
    var id: String { path }
}

// MARK: - Настройки

struct AppConfig: Codable, Equatable {
    var archivePath: String?
    var setupDone = false
    var autoEnabled = true
    var hour = 4
    var minute = 0
    var notify = true
    var userName = tr("Я")
    var loginWanted: Bool?
    var sourcePaths: [String: String] = [:]
    var disabledSources: [String] = []
    var mdFolders: [MDFolder] = []
    var mirrorPath: String?
    var exportReminder = true
    var openWith: String?            // в чём открывать архив: bundle id программы; nil — Obsidian, если архив в хранилище, иначе Finder
    var customApps: [String] = []    // программы, добавленные вручную («Другая программа…»), — пути к .app
    // v2: язык и «Навыки и настройки»
    var language = "sys"
    var kitEnabled = true
    var kitWithChats = true
    var kitHour = 3
    var kitMinute = 0
    var kitFolder: String?
    var kitMirror: String?
    var kitKeys = "hide"             // hide — скрывать, keep — как есть, skip — не сохранять такие файлы
    var kitKeepPrev = true
    var kitOpenWith: String?
    var kitPaths: [String: String] = [:]   // агент → своя папка (если стоит в необычном месте)
    var kitOff: [String] = []              // выключенные агенты
    var kitOwn: [MDFolder] = []            // свои папки (например, AI-Memory) — копируются целиком
    var archiveLang: String?               // язык служебных слов в уже сохранённых файлах (нет — русский, как в 1.0)
    var updateMode = "notify"        // auto — проверять и ставить сами, notify — проверять и сообщать, off — не проверять

    static func load() -> AppConfig { JSONFile.load(AppConfig.self, from: Paths.config) ?? AppConfig() }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        archivePath = try c.decodeIfPresent(String.self, forKey: .archivePath)
        setupDone = try c.decodeIfPresent(Bool.self, forKey: .setupDone) ?? d.setupDone
        autoEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoEnabled) ?? d.autoEnabled
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? d.hour
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? d.minute
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
        loginWanted = try c.decodeIfPresent(Bool.self, forKey: .loginWanted)
        sourcePaths = try c.decodeIfPresent([String: String].self, forKey: .sourcePaths) ?? [:]
        disabledSources = try c.decodeIfPresent([String].self, forKey: .disabledSources) ?? []
        mdFolders = try c.decodeIfPresent([MDFolder].self, forKey: .mdFolders) ?? []
        mirrorPath = try c.decodeIfPresent(String.self, forKey: .mirrorPath)
        exportReminder = try c.decodeIfPresent(Bool.self, forKey: .exportReminder) ?? true
        openWith = try c.decodeIfPresent(String.self, forKey: .openWith)
        customApps = try c.decodeIfPresent([String].self, forKey: .customApps) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        kitEnabled = try c.decodeIfPresent(Bool.self, forKey: .kitEnabled) ?? d.kitEnabled
        kitWithChats = try c.decodeIfPresent(Bool.self, forKey: .kitWithChats) ?? d.kitWithChats
        kitHour = try c.decodeIfPresent(Int.self, forKey: .kitHour) ?? d.kitHour
        kitMinute = try c.decodeIfPresent(Int.self, forKey: .kitMinute) ?? d.kitMinute
        kitFolder = try c.decodeIfPresent(String.self, forKey: .kitFolder)
        kitMirror = try c.decodeIfPresent(String.self, forKey: .kitMirror)
        kitKeys = try c.decodeIfPresent(String.self, forKey: .kitKeys) ?? d.kitKeys
        kitKeepPrev = try c.decodeIfPresent(Bool.self, forKey: .kitKeepPrev) ?? d.kitKeepPrev
        kitOpenWith = try c.decodeIfPresent(String.self, forKey: .kitOpenWith)
        kitPaths = try c.decodeIfPresent([String: String].self, forKey: .kitPaths) ?? [:]
        kitOff = try c.decodeIfPresent([String].self, forKey: .kitOff) ?? []
        kitOwn = try c.decodeIfPresent([MDFolder].self, forKey: .kitOwn) ?? []
        archiveLang = try c.decodeIfPresent(String.self, forKey: .archiveLang)
        updateMode = try c.decodeIfPresent(String.self, forKey: .updateMode) ?? d.updateMode
    }

    func path(_ kind: SourceKind) -> String { kind.envOverride ?? sourcePaths[kind.rawValue] ?? kind.defaultPath }
    func enabled(_ kind: SourceKind) -> Bool { !disabledSources.contains(kind.rawValue) }
    func save() { JSONFile.save(self, to: Paths.config) }

    var archiveURL: URL { URL(fileURLWithPath: archivePath ?? AppConfig.defaultArchivePath(), isDirectory: true) }

    // «Навыки и MCP»: по умолчанию рядом с архивом, если он в хранилище Obsidian, иначе в «Документах».
    // Название — на языке программы при первой настройке; дальше папка запоминается (kitFolder) и сама не переезжает.
    var kitURL: URL { URL(fileURLWithPath: kitFolder ?? defaultKitPath(), isDirectory: true) }
    func defaultKitPath() -> String {
        let name = tr("Навыки и MCP")
        if Obsidian.vault(containing: archiveURL) != nil { return archiveURL.deletingLastPathComponent().appendingPathComponent(name).path }
        if let vault = Obsidian.vaults().first { return (vault as NSString).appendingPathComponent(name) }
        return Paths.home.appendingPathComponent("Documents").appendingPathComponent(name).path
    }

    // Если на Mac есть хранилище Obsidian — архив кладём в него, иначе в «Документы». Название — на языке программы.
    static func defaultArchivePath() -> String {
        let name = tr("История ИИ")
        if let vault = Obsidian.vaults().first {
            return (vault as NSString).appendingPathComponent(name)
        }
        return Paths.home.appendingPathComponent("Documents").appendingPathComponent(name).path
    }

    // Папку навыков, выбранную по умолчанию, запоминаем, чтобы смена языка её не переименовала.
    mutating func pinKitFolder() -> Bool {
        guard kitFolder == nil, setupDone else { return false }
        kitFolder = defaultKitPath()
        return true
    }
}

// MARK: - Obsidian

// Список хранилищ Obsidian ведёт сам в obsidian.json (формат не документирован — только читаем).
enum Obsidian {
    // Существующие хранилища, последнее открытое — первым.
    static func vaults() -> [String] {
        let file = Paths.home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.values
            .sorted { ($0["ts"] as? Double ?? 0) > ($1["ts"] as? Double ?? 0) }
            .compactMap { $0["path"] as? String }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    // Хранилище, внутри которого лежит папка (самое вложенное, как ищет сам Obsidian).
    static func vault(containing url: URL) -> String? {
        let path = url.standardizedFileURL.path
        return vaults()
            .filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }
}

// MARK: - Состояние уже сохранённых сессий

struct SessionRecord: Codable {
    var file: String          // путь относительно папки архива
    var written: Int          // сколько реплик уже записано
    var sourceSize: Int64
    var sourceModified: Double
}

struct ArchiveState: Codable {
    var sessions: [String: SessionRecord] = [:]
    var archivePath: String?

    static func load() -> ArchiveState { JSONFile.load(ArchiveState.self, from: Paths.state) ?? ArchiveState() }
    func save() { JSONFile.save(self, to: Paths.state) }
}

// MARK: - Статус для окна

enum Level: String, Codable {
    case ok, warn, err, none

    var mark: String {
        switch self {
        case .ok: return "✅"
        case .warn: return "⚠️"
        case .err: return "❌"
        case .none: return "◽️"
        }
    }
}

enum Trigger: String, Codable {
    case manual, schedule, login

    var title: String {
        switch self {
        case .manual: return tr("вручную")
        case .schedule: return tr("по расписанию")
        case .login: return tr("при входе / после сна")
        }
    }
}

// Сообщение по смыслу: русская фраза-образец (она же ключ перевода) и подставляемые значения.
// Хранится так, а текст собирается при показе на языке окна — поэтому история переключается вместе с языком.
struct Msg: Codable, Equatable {
    var k: String
    var a: [String] = []
    init(_ k: String, _ a: [String] = []) { self.k = k; self.a = a }
    private func fill(_ f: String) -> String { a.isEmpty ? f : String(format: f, arguments: a.map { $0 as CVarArg }) }
    var ru: String { fill(k) }          // русский текст: по нему подсказки «Что делать» узнают проблему
    var text: String { fill(tr(k)) }    // на языке окна
}

extension Array where Element == Msg {
    // Первые три через «; », остальное — «и ещё N».
    func joined(ru: Bool) -> String {
        let head = prefix(3).map { ru ? $0.ru : $0.text }.joined(separator: "; ")
        guard count > 3 else { return head }
        let more = Msg(" и ещё %@", ["\(count - 3)"])
        return head + (ru ? more.ru : more.text)
    }
}

struct SourceStatus: Codable {
    var name: String
    var kind: String?
    var path: String?
    var found: Bool?
    var level: Level = .none
    var sessions = 0
    var newToday = 0
    var formatOK = true
    var note = ""
    var msgs: [Msg]?                 // то же, что note, по смыслу

    // Пометка на языке окна. Записи прежних версий (без msgs) переводятся как есть.
    var shownNote: String { msgs.map { $0.joined(ru: false) } ?? tr(note) }

    mutating func set(_ m: [Msg]) { msgs = m; note = m.joined(ru: true) }
}

// Часть записи истории: «Codex: …» — подпись (программа) и сообщения.
struct RunPart: Codable {
    var label: String?
    var msgs: [Msg]
    var ru: String { (label.map { $0 + ": " } ?? "") + msgs.joined(ru: true) }
    var text: String { (label.map { tr($0) + ": " } ?? "") + msgs.joined(ru: false) }
}

struct RunRecord: Codable {
    var date: Date
    var trigger: Trigger
    var level: Level
    var summary: String              // по-русски: по нему подсказки узнают проблему
    var parts: [RunPart]?            // то же по смыслу — для показа на языке окна

    // Текст записи на языке окна. Записи прежних версий (без parts) переводятся как раньше.
    var shown: String { parts.map { $0.map(\.text).joined(separator: " · ") } ?? displaySummary(summary) }
}

struct AppStatus: Codable {
    var lastRun: Date?
    var lastTrigger: Trigger?
    var level: Level = .none
    var sources: [SourceStatus] = []
    var history: [RunRecord] = []

    static func load() -> AppStatus { JSONFile.load(AppStatus.self, from: Paths.status) ?? AppStatus() }
    func save() { JSONFile.save(self, to: Paths.status) }

    var headline: String {
        switch level {
        case .ok: return tr("Всё в порядке")
        case .warn: return tr("Есть предупреждения")
        case .err: return tr("Ошибка")
        case .none: return lastRun == nil ? tr("Ещё не сохранялось") : tr("Нет данных")
        }
    }
}
