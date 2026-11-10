import Foundation

// ТЕСТОВАЯ СБОРКА: вымышленные данные, чтобы посмотреть все варианты окна.
// Всё лежит в Paths.support (папка demo-data рядом с проектом). Настоящие переписки, навыки и настройки не читаются.

// Модель окна вкладки «Навыки и настройки»: её заполняет движок (Skills.swift), а в демо — вымышленные данные.
enum AgentState: String, Codable { case ok, warn, err, off, gone }

struct DemoAgent: Identifiable, Codable {
    var name: String
    var path: String
    var skills = 0
    var mcp = 0
    var plugins = 0
    var keys = 0
    var extra = ""
    var state: AgentState = .ok
    var note = ""
    var on = true
    var key = ""                     // id агента в каталоге (или «own:путь» у своей папки)
    var id: String { key.isEmpty ? name : key }

    // Крупное число на плитке: навыки, а если их нет — MCP.
    var big: Int { skills > 0 ? skills : mcp }
}

// Запись истории вкладки навыков. Настоящие записи хранятся по смыслу (code + args), текст собирается на языке окна.
struct DemoChange: Codable {
    var date: Date
    var who: String
    var text: String
    var level: Level
    var code: String? = nil
    var args: [String] = []

    var shown: String { code.map { KitEvent.text($0, args) } ?? tr(text) }
}

enum Demo {
    static var scenario = 0          // 0 — всё в порядке, 1 — предупреждение, 2 — ошибка
    static var sourceCount = 3
    static var agentCount = 5
    static var historyCount = 60

    static let archive = Paths.support.appendingPathComponent("История ИИ", isDirectory: true)
    static let kitFolder = Paths.support.appendingPathComponent("Навыки и MCP", isDirectory: true)

    static func ensure() {
        let fm = FileManager.default
        Paths.ensureSupport()
        for dir in [Paths.claudeProjects, Paths.codexRoot, archive, kitFolder, kitFolder.appendingPathComponent("Навыки")] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: Paths.config.path) { defaultConfig().save() }
        if !fm.fileExists(atPath: Paths.claudeSettings.path) {
            try? "{\n  \"cleanupPeriodDays\": 30\n}\n".write(to: Paths.claudeSettings, atomically: true, encoding: .utf8)
        }
        let journal = archive.appendingPathComponent("Журнал сохранений.md")
        if !fm.fileExists(atPath: journal.path) {
            try? "# Журнал сохранений (тест)\n\nВымышленные записи тестовой сборки.\n".write(to: journal, atomically: true, encoding: .utf8)
        }
        let kitJournal = kitFolder.appendingPathComponent("Журнал изменений.md")
        if !fm.fileExists(atPath: kitJournal.path) {
            try? "# Журнал изменений (тест)\n\nВымышленные записи тестовой сборки.\n".write(to: kitJournal, atomically: true, encoding: .utf8)
        }
        let overview = kitFolder.appendingPathComponent("Обзор.md")
        if !fm.fileExists(atPath: overview.path) {
            try? "# Обзор (тест)\n\n| Что | Версия | В каких агентах | Откуда |\n|---|---|---|---|\n| impeccable | 4.8.1 | Claude Code, Codex | неизвестно |\n".write(to: overview, atomically: true, encoding: .utf8)
        }
        writeStatus()
    }

    static func defaultConfig() -> AppConfig {
        var c = AppConfig()
        c.setupDone = true
        c.archivePath = archive.path
        c.hour = 12
        c.minute = 0
        c.userName = "✕ Ozzy ✕"
        c.kitFolder = kitFolder.path
        return c
    }

    static func reset() {
        scenario = 0; sourceCount = 3; agentCount = 5; historyCount = 60
        defaultConfig().save()
        try? "{\n  \"cleanupPeriodDays\": 30\n}\n".write(to: Paths.claudeSettings, atomically: true, encoding: .utf8)
        writeStatus()
    }

    // MARK: «Переписки»

    static func writeStatus() {
        var st = AppStatus()
        let all: [(String, String?, Int)] = [
            ("Claude Code", "claude", 41), ("Codex", "codex", 362), ("DSH Desktop", "dsh", 48),
            ("Hermes", "hermes", 12), ("VS Code", "vscode", 9), ("claude.ai", "claudeai", 120),
            ("ChatGPT", "chatgpt", 85), ("Cursor", nil, 17), ("Windsurf", nil, 5),
            ("Gemini CLI", nil, 3), ("Zed", nil, 2), ("Obsidian Copilot", nil, 4)
        ]
        let problem = min(1, sourceCount - 1)   // проблема — у второй программы (Codex)
        for (i, src) in all.prefix(sourceCount).enumerated() {
            var s = SourceStatus(name: src.0, kind: src.1, path: nil, found: true)
            s.level = .ok
            s.sessions = src.2
            s.newToday = i == 0 ? 2 : 0
            if i == problem && scenario == 1 { s.level = .warn; s.note = "сохранено упрощённым способом" }
            if i == problem && scenario == 2 { s.level = .err; s.note = "формат не понятен"; s.formatOK = false }
            st.sources.append(s)
        }
        // При 6 и 12 программах — разные состояния на плитках, даже когда в целом всё в порядке.
        if sourceCount >= 6 {
            st.sources[4].level = .warn; st.sources[4].note = "сохранено упрощённым способом"
        }
        if sourceCount >= 12 {
            st.sources[9].level = .err; st.sources[9].note = "папка не найдена"
        }
        st.level = scenario == 0 ? .ok : (scenario == 1 ? .warn : .err)
        st.history = history(historyCount, problemName: all[problem].0)
        st.lastRun = st.history.first?.date
        st.lastTrigger = st.history.first?.trigger
        st.save()
    }

    static func history(_ n: Int, problemName: String) -> [RunRecord] {
        let cal = Calendar.current
        let now = Date()
        var out: [RunRecord] = []
        let okTexts = ["4 новых, 0 обновлено", "1 новых, 1 обновлено", "0 новых, 1 обновлено", "1 новых, 1 обновлено", "2 новых, 3 обновлено", "без изменений"]
        for i in 0..<n {
            let dayStart = cal.date(byAdding: .day, value: -i, to: now) ?? now
            let isSchedule = i % 3 == 1
            let date = cal.date(bySettingHour: isSchedule ? 12 : [9, 13, 23, 1][i % 4], minute: isSchedule ? 0 : [41, 9, 20, 5][i % 4], second: 0, of: dayStart) ?? dayStart
            var r = RunRecord(date: i == 0 ? now.addingTimeInterval(-300) : date, trigger: isSchedule ? .schedule : .login, level: .ok, summary: okTexts[i % okTexts.count])
            if i == 0 && scenario == 1 { r.level = .warn; r.summary = "\(problemName): сохранено упрощённым способом — формат изменился (версия 0.42)" }
            if i == 0 && scenario == 2 { r.level = .err; r.summary = "\(problemName): формат не понятен" }
            if i > 0 && i % 7 == 0 { r.level = .warn; r.summary = "Codex: сохранено упрощённым способом — формат изменился" }
            if i > 0 && i % 11 == 0 { r.level = .err; r.summary = "Нет доступа к папке архива" }
            out.append(r)
        }
        return out
    }

    // MARK: «Навыки и настройки»

    static func agents(_ n: Int) -> [DemoAgent] {
        let all: [DemoAgent] = [
            DemoAgent(name: "Claude Code", path: "~/.claude", skills: 34, extra: "CLAUDE.md, settings.json"),
            DemoAgent(name: "Приложение Claude", path: "~/Library/Application Support/Claude", mcp: 11, plugins: 7, keys: 1),
            DemoAgent(name: "Codex", path: "~/.codex", skills: 7, mcp: 12, plugins: 12, keys: 2),
            DemoAgent(name: "DSH Desktop", path: "~/.dsh", skills: 1, extra: "AGENTS.md"),
            DemoAgent(name: "Общие навыки", path: "~/.agents", skills: 1),
            DemoAgent(name: "Cursor", path: "~/.cursor", skills: 4, state: .gone, note: "не найдено — программа удалена или папка перенесена"),
            DemoAgent(name: "Windsurf", path: "~/.codeium/windsurf", skills: 2, state: .err, note: "не удалось прочитать"),
            DemoAgent(name: "Gemini CLI", path: "~/.gemini", skills: 3, mcp: 2, state: .off, note: "выключено", on: false),
            DemoAgent(name: "VS Code", path: "~/Library/Application Support/Code/User", mcp: 3, plugins: 5, state: .warn, note: "сохранено упрощённым способом"),
            DemoAgent(name: "Hermes", path: "~/.hermes", skills: 2),
            DemoAgent(name: "Zed", path: "~/.config/zed", mcp: 1, extra: "settings.json"),
            DemoAgent(name: "Cline", path: "~/Documents/Cline", skills: 5, mcp: 4)
        ]
        return Array(all.prefix(n))
    }

    static func kitHistory(_ n: Int) -> [DemoChange] {
        let cal = Calendar.current
        let now = Date()
        let items: [(String, String, Level)] = [
            ("Codex", "изменён config.toml, прежний сохранён", .ok),
            ("Claude Code", "новый навык: impeccable", .ok),
            ("Приложение Claude", "добавлен MCP: rea", .ok),
            ("все программы", "без изменений", .ok),
            ("Windsurf", "не удалось прочитать настройки", .err),
            ("Claude Code", "обновлён навык: obsidian-cli, прежний сохранён", .ok),
            ("Cursor", "не найдено — программа удалена или папка перенесена", .warn),
            ("Codex", "удалён плагин: chrome, прежний сохранён", .ok),
            ("все программы", "без изменений", .ok),
            ("VS Code", "сохранено упрощённым способом", .warn)
        ]
        return (0..<n).map { i in
            let day = cal.date(byAdding: .day, value: -i, to: now) ?? now
            let date = cal.date(bySettingHour: i % 2 == 0 ? 12 : 3, minute: i % 3 == 0 ? 8 : 0, second: 0, of: day) ?? day
            let it = items[i % items.count]
            return DemoChange(date: date, who: it.0, text: it.1, level: it.2)
        }
    }
}
