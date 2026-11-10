import Foundation

// Сохранение: обходит все источники, пишет Markdown, ведёт журнал и делает копию архива.

struct RunResult {
    var status: AppStatus
    var message: String
}

final class Exporter {
    let config: AppConfig
    let trigger: Trigger
    private var state = ArchiveState.load()
    private let fm = FileManager.default
    private var created = 0
    private var updated = 0

    // Источники, файлы которых нужно пересобрать целиком (например, после улучшения фильтра служебных вставок).
    var rebuild: Set<String> = []

    init(config: AppConfig, trigger: Trigger) {
        self.config = config
        self.trigger = trigger
    }

    private var archive: URL { config.archiveURL }

    // Блокировка, чтобы ручное и автоматическое сохранение не шли одновременно.
    private static func lock() -> Int32? {
        Paths.ensureSupport()
        let fd = open(Paths.lock.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }
        return fd
    }

    static func scan(_ kind: SourceKind, _ config: AppConfig) -> SourceScan {
        switch kind {
        case .claude: return ClaudeScan.scan(config)
        case .codex: return CodexScan.scan(config)
        case .dsh: return DSHScan.scan(config)
        case .hermes: return HermesScan.scan(config)
        case .vscode: return VSCodeScan.scan(config)
        case .claudeai, .chatgpt: return WebScan.scan(kind, config)
        }
    }

    func run() -> RunResult {
        guard let fd = Exporter.lock() else {
            return RunResult(status: AppStatus.load(), message: "Сохранение уже идёт")
        }
        defer { flock(fd, LOCK_UN); close(fd) }

        var status = AppStatus.load()
        do {
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
            let probe = archive.appendingPathComponent(".backup-ai-probe")
            try Data().write(to: probe)
            try? fm.removeItem(at: probe)
        } catch {
            return finish(status: &status, sources: [], level: .err,
                          parts: [RunPart(label: nil, msgs: [Msg("Нет доступа к папке архива: %@", [Fmt.shortPath(archive.path)])])])
        }
        if state.archivePath != archive.path {
            state = ArchiveState(sessions: [:], archivePath: archive.path)
        }

        var sources: [SourceStatus] = []
        for kind in SourceKind.allCases where config.enabled(kind) {
            sources.append(export(kind))
            state.save()   // сохраняем по ходу: если что-то упадёт, сделанное не придётся повторять
        }
        for folder in config.mdFolders { sources.append(exportMD(folder)) }
        state.save()
        if let problem = mirror() {
            var st = SourceStatus(name: "Копия архива", kind: "mirror", path: config.mirrorPath, found: true, level: .warn, formatOK: true)
            st.set([problem])
            sources.append(st)
        }

        let levels = sources.map(\.level)
        let level: Level = levels.contains(.err) ? .err : (levels.contains(.warn) ? .warn : (levels.contains(.ok) ? .ok : .none))
        var parts = [RunPart(label: nil, msgs: [created == 0 && updated == 0 ? Msg("без изменений") : Msg("%@ новых, %@ обновлено", ["\(created)", "\(updated)"])])]
        for s in sources where s.level == .warn || s.level == .err {
            parts.append(RunPart(label: s.name, msgs: s.msgs ?? [Msg(s.note)]))
        }
        return finish(status: &status, sources: sources, level: level, parts: parts)
    }

    private func finish(status: inout AppStatus, sources: [SourceStatus], level: Level, parts: [RunPart]) -> RunResult {
        let now = Date()
        let summary = parts.map(\.ru).joined(separator: " · ")
        status.lastRun = now
        status.lastTrigger = trigger
        status.level = level
        if !sources.isEmpty { status.sources = sources }
        status.history.insert(RunRecord(date: now, trigger: trigger, level: level, summary: summary, parts: parts), at: 0)
        if status.history.count > 60 { status.history = Array(status.history.prefix(60)) }
        status.save()
        appendJournal("\(Fmt.full.string(from: now)) · \(tr(trigger.title)) · \(level.mark) " + parts.map(\.text).joined(separator: " · "))
        return RunResult(status: status, message: summary)
    }

    private func appendJournal(_ line: String) {
        let url = archive.appendingPathComponent(AW.journalFile)
        if !fm.fileExists(atPath: url.path) {
            try? "# \(AW.w("Журнал сохранений"))\n\n\(AW.w("Записи программы «Бэкап ИИ». Новые — внизу."))\n\n".write(to: url, atomically: true, encoding: .utf8)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write(Data("- \(line)\n".utf8))
        try? h.close()
    }

    private func unchanged(_ key: String, size: Int64, mod: Double) -> Bool {
        guard let r = state.sessions[key], r.sourceSize == size, r.sourceModified == mod else { return false }
        return fm.fileExists(atPath: archive.appendingPathComponent(r.file).path)
    }

    // MARK: Один источник

    private func export(_ kind: SourceKind) -> SourceStatus {
        let scan = Exporter.scan(kind, config)
        var st = SourceStatus(name: kind.title, kind: kind.rawValue, path: config.path(kind), found: scan.found)
        guard scan.found else {
            st.set([Msg(kind.isWebExport ? "экспорт ещё не импортирован" : "не найден на этом Mac")])
            return st
        }
        var problems = scan.problems
        var readable = 0
        var empty = 0
        var fallback = 0
        var versions = Set<String>()
        let rebuilding = rebuild.contains(kind.rawValue)
        for var ref in scan.refs {
            if rebuilding { ref.rewrite = true }
            else if unchanged(ref.key, size: ref.size, mod: ref.mod) { readable += 1; continue }
            // Непрочитанное не записывается в состояние — при следующем сохранении программа попробует снова.
            guard let s = ref.load() else { problems.append(Msg("не прочитано: %@", [ref.label])); continue }
            if s.turns.isEmpty {
                // Пустая сессия (открыли и ничего не написали) — не ошибка.
                if s.messageLines > 0 { problems.append(Msg("не извлечён текст: %@", [ref.label])) } else { empty += 1 }
                continue
            }
            readable += 1
            if s.fallback { fallback += 1; if let v = s.version { versions.insert(v) } }
            if s.badLines > 0 && !s.fallback { problems.append(Msg("%@ нечитаемых строк: %@", ["\(s.badLines)", ref.label])) }
            write(s, kind: kind, ref: ref)
        }
        if fallback > 0 {
            problems.append(versions.isEmpty ? Msg("%@ сохранено упрощённым способом — формат изменился", ["\(fallback)"])
                : Msg("%@ сохранено упрощённым способом — формат изменился (версия %@)", ["\(fallback)", versions.sorted().joined(separator: ", ")]))
        }
        return summarize(&st, prefix: kind.rawValue + ":", files: scan.refs.count - empty, readable: readable, problems: problems)
    }

    private func summarize(_ st: inout SourceStatus, prefix: String, files: Int, readable: Int, problems: [Msg]) -> SourceStatus {
        let today = "/" + Fmt.day.string(from: Date()) + "/"
        let mine = state.sessions.filter { $0.key.hasPrefix(prefix) }
        st.sessions = mine.count
        st.newToday = mine.values.filter { $0.file.contains(today) }.count
        if files == 0 && problems.isEmpty {
            st.level = .none
            st.set([Msg("переписок пока нет")])
        } else if files > 0 && readable == 0 {
            st.level = .err
            st.formatOK = false
            st.set([Msg("формат не понятен — текст не найден ни в одной сессии")])
        } else if !problems.isEmpty {
            st.level = .warn
            st.formatOK = !problems.contains { $0.k.hasPrefix("не извлечён") || $0.k.contains("упрощённым") || $0.k.contains("формат") }
            st.set(problems)
        } else {
            st.level = .ok
            st.set([Msg("формат понятен")])
        }
        return st
    }

    // MARK: Запись Markdown

    private func write(_ s: ParsedSession, kind: SourceKind, ref: SessionRef) {
        // Сессия ещё идёт (менялась последние 2 минуты) — последнюю реплику допишем в следующий раз.
        let active = !ref.rewrite && Date().timeIntervalSince1970 - ref.mod < 120
        let complete = active ? max(0, s.turns.count - 1) : s.turns.count
        let start = s.start ?? s.turns.first?.date ?? Date(timeIntervalSince1970: ref.mod)
        let day = Fmt.day.string(from: start)
        let stamp = SessionRecord(file: "", written: complete, sourceSize: active ? -1 : ref.size, sourceModified: ref.mod)

        if let r = state.sessions[ref.key], fm.fileExists(atPath: archive.appendingPathComponent(r.file).path) {
            let url = archive.appendingPathComponent(r.file)
            if ref.rewrite {
                // Экспорт с сайта содержит весь разговор целиком — пересобираем файл, ничего не теряя.
                try? document(s, kind: kind, title: title(s), start: start, day: day, count: complete)
                    .write(to: url, atomically: true, encoding: .utf8)
                updated += 1
            } else if complete > r.written {
                let chunk = s.turns[r.written..<complete].map { render($0, kind: kind, day: day) }.joined()
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile()
                    h.write(Data(chunk.utf8))
                    try? h.close()
                    updated += 1
                }
            }
            var rec = stamp
            rec.file = r.file
            rec.written = ref.rewrite ? complete : max(r.written, complete)
            state.sessions[ref.key] = rec
            return
        }

        let name = title(s)
        let folder = "\(kind.title)/\(day)"
        try? fm.createDirectory(at: archive.appendingPathComponent(folder), withIntermediateDirectories: true)
        let used = Set(state.sessions.values.map(\.file))
        var rel = "\(folder)/\(Fmt.fileName(name)).md"
        var n = 2
        while used.contains(rel) || fm.fileExists(atPath: archive.appendingPathComponent(rel).path) {
            rel = "\(folder)/\(Fmt.fileName(name)) (\(n)).md"
            n += 1
        }
        do {
            try document(s, kind: kind, title: name, start: start, day: day, count: complete)
                .write(to: archive.appendingPathComponent(rel), atomically: true, encoding: .utf8)
            created += 1
            var rec = stamp
            rec.file = rel
            state.sessions[ref.key] = rec
        } catch {}
    }

    private func title(_ s: ParsedSession) -> String {
        s.title.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines)) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? s.turns.first(where: { $0.role == .user }).map { String($0.text.prefix(60)) } ?? AW.w("Без названия")
    }

    private func document(_ s: ParsedSession, kind: SourceKind, title: String, start: Date, day: String, count: Int) -> String {
        var md = """
        ---
        \(AW.w("источник")): \(kind.title)
        \(AW.w("дата")): \(day)
        \(AW.w("время")): \(Fmt.time.string(from: start))
        \(AW.w("проект")): "\(Fmt.shortPath(s.cwd))"
        \(AW.w("сессия")): \(s.id)
        ---

        # \(title.replacingOccurrences(of: "\n", with: " "))


        """
        md += s.turns.prefix(count).map { render($0, kind: kind, day: day) }.joined()
        return md
    }

    private func render(_ t: Turn, kind: SourceKind, day: String) -> String {
        let who = t.role == .user ? config.userName : kind.speaker
        var when = ""
        if let d = t.date {
            when = " · " + (Fmt.day.string(from: d) == day ? Fmt.time.string(from: d) : Fmt.dayTime.string(from: d))
        }
        var out = "### \(who)\(when)\n\n\(t.text)\n\n"
        for alt in t.alts {
            let quoted = alt.replacingOccurrences(of: WebScan.userMark, with: config.userName).split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            out += "> **\(AW.w("↳ другой вариант"))**\n>\n\(quoted)\n\n"
        }
        return out
    }

    // MARK: Папки с экспортами .md (Cursor, Windsurf и любые другие программы)

    private func exportMD(_ folder: MDFolder) -> SourceStatus {
        var st = SourceStatus(name: folder.name, kind: "md", path: folder.path, found: dirExists(folder.path))
        guard st.found == true else {
            st.level = .warn
            st.set([Msg("папка не найдена (диск не подключён?)")])
            return st
        }
        let root = URL(fileURLWithPath: folder.path).resolvingSymlinksInPath()
        let prefix = "md:\(folder.path):"
        var problems: [Msg] = []
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let f as URL in e where ["md", "markdown", "txt"].contains(f.pathExtension.lowercased()) {
                let rel = relative(f, to: root)
                let (size, mod) = fileStamp(f)
                guard size < 20_000_000 else { problems.append(Msg("слишком большой файл: %@", [rel])); continue }
                let key = prefix + rel
                if unchanged(key, size: size, mod: mod) { continue }
                let target = "\(Fmt.fileName(folder.name))/\(rel)"
                let dest = archive.appendingPathComponent(target)
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    let existed = fm.fileExists(atPath: dest.path)
                    if existed { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: f, to: dest)
                    if existed { updated += 1 } else { created += 1 }
                    state.sessions[key] = SessionRecord(file: target, written: 0, sourceSize: size, sourceModified: mod)
                } catch {
                    problems.append(Msg("не скопирован: %@", [rel]))
                }
            }
        }
        st.sessions = state.sessions.keys.filter { $0.hasPrefix(prefix) }.count
        st.level = problems.isEmpty ? (st.sessions > 0 ? .ok : .none) : .warn
        st.set(problems.isEmpty ? [Msg(st.sessions > 0 ? "файлы скопированы" : "в папке пока нет .md")] : problems)
        return st
    }

    // Путь файла относительно папки. Пути сравниваем после раскрытия ссылок (/tmp → /private/tmp).
    private func relative(_ f: URL, to root: URL) -> String {
        let full = f.resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        return String(full.hasPrefix(base) ? full.dropFirst(base.count) : Substring(f.lastPathComponent))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Копия архива во вторую папку (внешний диск, облако). Только добавляет и обновляет, ничего не удаляет.

    private func mirror() -> Msg? {
        guard let path = config.mirrorPath, !path.isEmpty else { return nil }
        let dest = URL(fileURLWithPath: path, isDirectory: true)
        guard dirExists(dest.path) || dirExists(dest.deletingLastPathComponent().path) else {
            return Msg("папка для копии недоступна: %@ — диск не подключён?", [Fmt.shortPath(path)])
        }
        do { try fm.createDirectory(at: dest, withIntermediateDirectories: true) } catch { return Msg("нет доступа к папке копии") }
        var failed = 0
        let source = archive.resolvingSymlinksInPath()
        if let e = fm.enumerator(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let f as URL in e where ["md", "markdown", "txt"].contains(f.pathExtension.lowercased()) {
                let rel = relative(f, to: source)
                let target = dest.appendingPathComponent(rel)
                let (size, mod) = fileStamp(f)
                let (tsize, tmod) = fileStamp(target)
                if fm.fileExists(atPath: target.path) && tsize == size && tmod >= mod { continue }
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: f, to: target)
                } catch { failed += 1 }
            }
        }
        return failed > 0 ? Msg("%@ файлов не скопировано в копию архива", ["\(failed)"]) : nil
    }

    // MARK: Проверка формата без записи

    static func checkFormat(_ config: AppConfig) -> String {
        var lines: [String] = []
        for kind in SourceKind.allCases where config.enabled(kind) {
            let scan = scan(kind, config)
            guard scan.found else {
                lines.append("\(kind.title): \(kind.isWebExport ? "экспорт не импортирован" : "не найден на этом Mac")")
                continue
            }
            var ok = 0, simple = 0, failed = 0, empty = 0
            for ref in scan.refs.prefix(400) {
                guard let s = ref.load() else { failed += 1; continue }
                if s.turns.isEmpty { if s.messageLines > 0 { failed += 1 } else { empty += 1 } } else if s.fallback { simple += 1 } else { ok += 1 }
            }
            let total = min(scan.refs.count, 400) - empty
            var line = "\(kind.title): прочитано \(ok + simple) из \(total)"
            if total == 0 { line = "\(kind.title): переписок пока нет" }
            else if ok + simple == 0 { line += " ❌ формат не понятен" }
            else if simple > 0 || failed > 0 { line += " ⚠️" + (simple > 0 ? " упрощённым способом: \(simple)" : "") + (failed > 0 ? " не прочитано: \(failed)" : "") }
            else { line += " ✅" }
            for p in scan.problems { line += "\n   ⚠️ \(p.text)" }
            lines.append(line)
        }
        lines.append("Распаковщик zstd: " + (Zstd.path() == nil ? "не найден ⚠️" : "есть ✅"))
        return lines.joined(separator: "\n")
    }
}
