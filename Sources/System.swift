import Foundation
import ServiceManagement
import UserNotifications

// Расписание через launchd: каждый день в выбранное время и при входе в систему.
enum Scheduler {
    static let label = "com.ozzy.backup-ai"
    static var plistURL: URL { Paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var domain: String { "gui/\(getuid())" }

    static func desiredPlist(_ config: AppConfig) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? "", "--export", "--auto"],
            "StartCalendarInterval": ["Hour": config.hour, "Minute": config.minute],
            "RunAtLoad": true,
            "ProcessType": "Background",
            "StandardOutPath": Paths.launchLog.path,
            "StandardErrorPath": Paths.launchLog.path
        ]
    }

    static func currentPlist() -> NSDictionary? { NSDictionary(contentsOf: plistURL) }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    // Приводит расписание в соответствие с настройками. Вызывается при запуске программы,
    // поэтому после переноса программы в другую папку путь в расписании исправится сам.
    static func apply(_ config: AppConfig) {
        guard !Paths.isTest else { return }
        KitScheduler.apply(config)
        guard config.autoEnabled, config.setupDone else { remove(); return }
        let wanted = desiredPlist(config) as NSDictionary
        if let current = currentPlist(), current == wanted { return }
        Paths.ensureSupport()
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        launchctl(["bootout", "\(domain)/\(label)"])
        wanted.write(to: plistURL, atomically: true)
        launchctl(["bootstrap", domain, plistURL.path])
    }

    static func remove() {
        guard !Paths.isTest else { return }
        guard isInstalled else { return }
        launchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return -1 }
        return p.terminationStatus
    }

    // Запуск от launchd: по расписанию, если время совпало, иначе — при входе или после сна.
    static func autoTrigger(_ config: AppConfig, now: Date = Date()) -> Trigger {
        let cal = Calendar.current
        guard let planned = cal.date(bySettingHour: config.hour, minute: config.minute, second: 0, of: now) else { return .login }
        let late = now.timeIntervalSince(planned)
        return late >= -5 && late <= 120 ? .schedule : .login
    }
}

// Своё время для навыков и MCP (когда выключено «Вместе с переписками»): вторая задача launchd.
enum KitScheduler {
    static let label = "com.ozzy.backup-ai.kit"
    static var plistURL: URL { Paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }

    static func apply(_ config: AppConfig) {
        guard !Paths.isTest else { return }
        guard config.setupDone, config.kitEnabled, !config.kitWithChats else { remove(); return }
        let wanted: NSDictionary = [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? "", "--kit", "--auto"],
            "StartCalendarInterval": ["Hour": config.kitHour, "Minute": config.kitMinute],
            "ProcessType": "Background",
            "StandardOutPath": Paths.launchLog.path,
            "StandardErrorPath": Paths.launchLog.path
        ]
        if let current = NSDictionary(contentsOf: plistURL), current == wanted { return }
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        Scheduler.launchctl(["bootout", "\(Scheduler.domain)/\(label)"])
        wanted.write(to: plistURL, atomically: true)
        Scheduler.launchctl(["bootstrap", Scheduler.domain, plistURL.path])
    }

    static func remove() {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        Scheduler.launchctl(["bootout", "\(Scheduler.domain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }
}

// «Запускать приложение при входе в macOS».
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) -> String? {
        guard !Paths.isTest else { return nil }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// Сколько дней Claude Code хранит переписки (настройка cleanupPeriodDays, по умолчанию 30).
enum ClaudeRetention {
    static let wanted = 3650

    static var installed: Bool { FileManager.default.fileExists(atPath: Paths.home.appendingPathComponent(".claude").path) }

    static var days: Int {
        guard let data = try? Data(contentsOf: Paths.claudeSettings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 30 }
        return json["cleanupPeriodDays"] as? Int ?? 30
    }

    // Добавляет или меняет одну строку, остальные настройки не трогает. Перед правкой делает копию.
    static func extend() -> String? { set(wanted) }

    // Сколько дней Claude Code хранит переписки: 30 (как у него по умолчанию), 365 или 3650.
    static func set(_ days: Int) -> String? {
        let url = Paths.claudeSettings
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "{\n}\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.backup-ai-bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        if text.contains("\"cleanupPeriodDays\"") {
            text = Fmt.replace(text, "\"cleanupPeriodDays\"\\s*:\\s*\\d+", "\"cleanupPeriodDays\": \(days)")
        } else if let brace = text.firstIndex(of: "{") {
            let rest = text[text.index(after: brace)...].trimmingCharacters(in: .whitespacesAndNewlines)
            let comma = rest.hasPrefix("}") ? "" : ","
            text.insert(contentsOf: "\n  \"cleanupPeriodDays\": \(days)\(comma)", at: text.index(after: brace))
        } else {
            return "Не удалось разобрать файл настроек Claude Code"
        }
        guard let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return "Файл настроек Claude Code получился бы повреждённым — изменение отменено"
        }
        do { try data.write(to: url, options: .atomic) } catch { return error.localizedDescription }
        return nil
    }
}

// Уведомление macOS о проблеме при автоматическом сохранении — от имени самой программы,
// с её значком. По клику открывается окно с объяснением. Если уведомления программе
// запрещены, запасной путь — системное уведомление через osascript.
enum Notifier {
    static let problemID = "backup-ai-problem"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @discardableResult
    static func post(_ title: String, _ body: String) -> Bool {
        let center = UNUserNotificationCenter.current()
        let sem = DispatchSemaphore(value: 0)
        var allowed = false
        center.getNotificationSettings { settings in
            allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        if allowed {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            var delivered = false
            center.add(UNNotificationRequest(identifier: problemID, content: content, trigger: nil)) { error in
                delivered = error == nil
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 5)
            if delivered { return true }
        }
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return false
    }
}

// Раз в месяц напоминает скачать экспорт с сайтов claude.ai и ChatGPT.
// Дата последнего напоминания — в отдельном файле, чтобы её не затирали сохранения настроек из окна.
enum ExportReminder {
    static let file = Paths.support.appendingPathComponent("reminder.txt")

    static func checkAndNotify() {
        let config = AppConfig.load()
        guard config.setupDone, config.exportReminder else { return }
        let now = Date()
        guard let text = try? String(contentsOf: file, encoding: .utf8), let last = Double(text) else {
            Paths.ensureSupport()
            try? String(now.timeIntervalSince1970).write(to: file, atomically: true, encoding: .utf8)
            return
        }
        guard now.timeIntervalSince1970 - last > 30 * 24 * 3600 else { return }
        try? String(now.timeIntervalSince1970).write(to: file, atomically: true, encoding: .utf8)
        Notifier.post(tr("Бэкап ИИ — пора скачать экспорт"),
                      tr("claude.ai и ChatGPT: скачайте экспорт в настройках сайта и перетащите ZIP в окно программы. Подробно — «Как скачать?» в разделе «Источники»."))
    }
}
