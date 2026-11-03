import Foundation

// Где программа хранит свои настройки, состояние и статус.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    // BACKUP_AI_SUPPORT — только для проверки, чтобы не трогать настоящие настройки.
    static let support = ProcessInfo.processInfo.environment["BACKUP_AI_SUPPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? home.appendingPathComponent("Library/Application Support/Бэкап ИИ", isDirectory: true)
    static let config = support.appendingPathComponent("config.json")
    static let state = support.appendingPathComponent("state.json")
    static let status = support.appendingPathComponent("status.json")
    static let lock = support.appendingPathComponent("run.lock")
    static let launchLog = support.appendingPathComponent("launchd.log")
    static let imports = support.appendingPathComponent("imports", isDirectory: true)

    static let isTest = ProcessInfo.processInfo.environment["BACKUP_AI_SUPPORT"] != nil

    // BACKUP_AI_CLAUDE_DIR / BACKUP_AI_CODEX_DIR — подмена источников для проверки поломки формата.
    static let claudeProjects = ProcessInfo.processInfo.environment["BACKUP_AI_CLAUDE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
    static let claudeSettings = home.appendingPathComponent(".claude/settings.json")
    static let codexRoot = ProcessInfo.processInfo.environment["BACKUP_AI_CODEX_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? home.appendingPathComponent(".codex", isDirectory: true)

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
        case .vscode: return "Copilot Chat · экспериментально"
        case .claudeai: return "экспорт с сайта"
        case .chatgpt: return "экспорт с сайта"
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
    var userName = "Я"
    var loginWanted: Bool?
    var sourcePaths: [String: String] = [:]
    var disabledSources: [String] = []
    var mdFolders: [MDFolder] = []
    var mirrorPath: String?
    var exportReminder = true
    var openWith: String?            // в чём открывать архив: bundle id программы; nil — Obsidian, если архив в хранилище, иначе Finder
    var customApps: [String] = []    // программы, добавленные вручную («Другая программа…»), — пути к .app

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
    }

    func path(_ kind: SourceKind) -> String { kind.envOverride ?? sourcePaths[kind.rawValue] ?? kind.defaultPath }
    func enabled(_ kind: SourceKind) -> Bool { !disabledSources.contains(kind.rawValue) }
    func save() { JSONFile.save(self, to: Paths.config) }

    var archiveURL: URL { URL(fileURLWithPath: archivePath ?? AppConfig.defaultArchivePath(), isDirectory: true) }

    // Если на Mac есть хранилище Obsidian — архив кладём в него, иначе в «Документы».
    static func defaultArchivePath() -> String {
        if let vault = Obsidian.vaults().first {
            return (vault as NSString).appendingPathComponent("История ИИ")
        }
        return Paths.home.appendingPathComponent("Documents/История ИИ").path
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
        case .manual: return "вручную"
        case .schedule: return "по расписанию"
        case .login: return "при входе / после сна"
        }
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
}

struct RunRecord: Codable {
    var date: Date
    var trigger: Trigger
    var level: Level
    var summary: String
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
        case .ok: return "Всё в порядке"
        case .warn: return "Есть предупреждения"
        case .err: return "Ошибка"
        case .none: return lastRun == nil ? "Ещё не сохранялось" : "Нет данных"
        }
    }
}
