import AppKit
import SwiftUI

// MARK: - Время как в macOS (12 или 24 часа)

enum TimeFormat {
    // «j» — шаблон часа, который macOS подбирает по языку и по выбору пользователя «24-часовое время».
    static let is12: Bool = (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    // Вид времени (12/24) — из настроек macOS, слова (AM/PM, 午後, अपराह्न) и порядок даты — по языку окна.
    private static var timeF = makeTime()
    private static var dayF = makeDay()
    private static func makeTime() -> DateFormatter {
        let f = DateFormatter(); f.locale = Lang.locale; f.setLocalizedDateFormatFromTemplate(is12 ? "hmma" : "HHmm"); return f
    }
    private static func makeDay() -> DateFormatter {
        let f = DateFormatter()
        if Lang.code == "ru" { f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "dd.MM" }
        else { f.locale = Lang.locale; f.setLocalizedDateFormatFromTemplate("dMMM") }
        return f
    }
    static func reset() { timeF = makeTime(); dayF = makeDay() }
    static var am: String { timeF.amSymbol }
    static var pm: String { timeF.pmSymbol }
    static func time(_ d: Date) -> String { timeF.string(from: d) }
    static func day(_ d: Date) -> String { dayF.string(from: d) }
    static func dayTime(_ d: Date) -> String { day(d) + " " + time(d) }
    static func hm(_ h: Int, _ m: Int) -> String {
        time(Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date())
    }
    static var dateColumn: CGFloat { is12 ? 150 : 110 }
}

// Часы и минуты: можно вписать руками или выбрать кнопкой ⇅. Минуты в списке — через 10.
struct TimeField: View {
    @Binding var hour: Int
    @Binding var minute: Int
    @State private var hText = ""
    @State private var mText = ""
    @State private var badH = false
    @State private var badM = false
    @FocusState private var focus: Int?
    @State private var menuTarget = MenuActions()
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            box(text: $hText, bad: badH, tag: 0, commit: commitH) {
                if TimeFormat.is12 {
                    let pmHalf = hour >= 12
                    return (1...12).map { v in let h = (v % 12) + (pmHalf ? 12 : 0); return ("\(v)", h == hour, { hour = h }) }
                }
                return (0..<24).map { v in (String(format: "%02d", v), v == hour, { hour = v }) }
            }
            Text(":").font(.bellota(16))
            box(text: $mText, bad: badM, tag: 1, commit: commitM) {
                [0, 10, 20, 30, 40, 50].map { v in (String(format: "%02d", v), v == minute, { minute = v }) }
            }
            if TimeFormat.is12 {
                Button { hour = (hour + 12) % 24 } label: {
                    Text(hour < 12 ? TimeFormat.am : TimeFormat.pm)
                        .font(.bellota(13))
                        .lineLimit(1).fixedSize()
                        .foregroundColor(Color(red: 0.81, green: 0.78, blue: 1))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 30, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.11)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 3)
                .help(tr("До полудня / после полудня"))
            }
        }
        .opacity(enabled ? 1 : 0.5)
        .onAppear(perform: sync)
        .onChange(of: hour) { _ in sync() }
        .onChange(of: minute) { _ in sync() }
        .onChange(of: focus) { [focus] _ in
            // Ушли из поля — принимаем то, что вписано.
            if focus == 0 { commitH() }
            if focus == 1 { commitM() }
        }
    }

    private func box(text: Binding<String>, bad: Bool, tag: Int, commit: @escaping () -> Void, items: @escaping () -> [(String, Bool, () -> Void)]) -> some View {
        HStack(spacing: 0) {
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.bellota(15))
                .foregroundColor(bad ? Palette.err : .white)
                .frame(width: 22)
                .focused($focus, equals: tag)
                .onSubmit(commit)
            Spacer(minLength: 0)
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Color(red: 0.69, green: 0.30, blue: 0.94), Color(red: 0.46, green: 0.19, blue: 0.96)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 18, height: 18)
                Button { popMenu(items(), target: menuTarget) } label: {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { NSCursor.arrow.set() } }
            }
            .help(tr("Выбрать из списка"))
        }
        .padding(.leading, 8).padding(.trailing, 3)
        .frame(width: 54, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.11)))
    }

    private func sync() {
        hText = TimeFormat.is12 ? "\(hour % 12 == 0 ? 12 : hour % 12)" : String(format: "%02d", hour)
        mText = String(format: "%02d", minute)
    }

    private func commitH() {
        let v = Int(hText.trimmingCharacters(in: .whitespaces))
        if TimeFormat.is12 {
            guard let v, (1...12).contains(v) else { return reject(h: true) }
            hour = (v % 12) + (hour >= 12 ? 12 : 0)
        } else {
            guard let v, (0...23).contains(v) else { return reject(h: true) }
            hour = v
        }
        sync()
    }

    private func commitM() {
        guard let v = Int(mText.trimmingCharacters(in: .whitespaces)), (0...59).contains(v) else { return reject(h: false) }
        minute = v
        sync()
    }

    // Неверное число: подсвечиваем красным и возвращаем прежнее значение.
    private func reject(h: Bool) {
        if h { badH = true } else { badM = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { badH = false; badM = false; sync() }
    }
}

// MARK: - Мелкие элементы

struct NewBadge: View {
    var body: some View {
        Text("NEW")
            .font(.bellota(11))
            .foregroundColor(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(LinearGradient(
                colors: [Color(red: 75 / 255, green: 39 / 255, blue: 246 / 255), Color(red: 118 / 255, green: 48 / 255, blue: 246 / 255)],
                startPoint: .leading, endPoint: .trailing)))
    }
}

struct TestBadge: View {
    var body: some View {
        Text(tr("ТЕСТОВАЯ СБОРКА"))
            .font(.bellota(11))
            .foregroundColor(Palette.warn)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.warn.opacity(0.7)))
            .help(tr("Данные вымышленные, настоящие файлы не трогаются"))
    }
}

struct TabSwitch: View {
    @Binding var tab: Int

    var body: some View {
        HStack(spacing: 0) {
            item(tr("Переписки"), 0)
            item(tr("Навыки и настройки"), 1)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.08, green: 0.08, blue: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.cardBorder))
    }

    private func item(_ title: String, _ i: Int) -> some View {
        Button { tab = i } label: {
            Text(title)
                .font(.bellota(15))
                .foregroundColor(tab == i ? .white : Palette.dim)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(tab == i ? Palette.blue : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(tab == i ? Palette.blueBorder : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

let historyRowHeight: CGFloat = 34

// История: видно 4 строки, остальное — прокруткой.
// Раскрытая строка сообщает списку: список на это время выше (7 строк) и прокручивает её наверх.
struct HistoryOpenKey: EnvironmentKey { static let defaultValue: (Int, Bool) -> Void = { _, _ in } }
extension EnvironmentValues {
    var historyOpen: (Int, Bool) -> Void {
        get { self[HistoryOpenKey.self] }
        set { self[HistoryOpenKey.self] = newValue }
    }
}

struct HistoryList<Content: View>: View {
    var count: Int
    @ViewBuilder var content: () -> Content
    @State private var opened: Set<Int> = []

    var body: some View {
        if count > 4 {
            ThemedScroll {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) { content() }
                        .padding(.trailing, 16)
                        .environment(\.historyOpen) { id, open in
                            if open { opened.insert(id) } else { opened.remove(id) }
                            if open {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
                                }
                            }
                        }
                }
            }
            .frame(height: historyRowHeight * (opened.isEmpty ? 4 : 7))
            .animation(.easeOut(duration: 0.15), value: opened.isEmpty)
        } else {
            VStack(spacing: 0) { content() }
        }
    }
}

struct HistoryRow: View {
    var date: Date
    var who: String
    var text: String
    var level: Level = .ok
    var advice: Advice? = nil                  // для ошибок и предупреждений: что случилось и что делать
    var onFix: ((FixAction) -> Void)? = nil
    var rowID = 0
    var openTitleTrailing: CGFloat = 0         // отступ справа у заголовка раскрытой строки (на «Переписках» — под машинку)
    @State private var open = false
    @State private var hover = false
    @Environment(\.historyOpen) private var reportOpen

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: open ? .top : .center, spacing: 0) {
                Text(TimeFormat.dayTime(date)).foregroundColor(Palette.dim).frame(width: TimeFormat.dateColumn, alignment: .leading)
                Group {
                    if open { Text(who).fixedSize(horizontal: false, vertical: true) } else { MarqueeText(text: who) }
                }
                .foregroundColor(Palette.dim).frame(width: 182, alignment: .leading).padding(.trailing, 8)
                if open {
                    Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .padding(.trailing, openTitleTrailing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarqueeText(text: text)
                }
                Spacer(minLength: 0)
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold)).foregroundColor(Palette.dim)
                    .opacity(hover || open ? 1 : 0)
                    .frame(width: 16)
            }
            if open, let a = advice {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("Что случилось")).font(.bellota(14)).foregroundColor(Palette.level(level))
                    Text(a.what).font(.bellota(14, bold: false)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text(tr("Что делать")).font(.bellota(14)).padding(.top, 3)
                    Text(a.todo).font(.bellota(14, bold: false)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(spacing: 8) {
                        ForEach(a.actions, id: \.self) { f in
                            Button(fixTitle(f)) { onFix?(f) }
                                .buttonStyle(GlassButtonStyle(accent: f == .save, height: 30))
                                .frame(minWidth: 0, maxWidth: 170)   // сжимаются, чтобы ряд не вылезал за окно
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .padding(.leading, TimeFormat.dateColumn + 190)
                .padding(.trailing, 16)
                .padding(.top, 8)
            }
        }
        .font(.bellota(15, bold: false))
        .padding(.vertical, open ? 8 : 0)
        .frame(minHeight: historyRowHeight)
        .background(open ? Color.white.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            reportOpen(rowID, open)
        }
        .id(rowID)
        .help(open ? tr("Щёлкните, чтобы свернуть") : (advice != nil ? tr("Щёлкните: что случилось и что делать") : tr("Щёлкните, чтобы раскрыть целиком")))
        .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
    }
}

func fixTitle(_ a: FixAction) -> String {
    switch a {
    case .save: return tr("Сохранить снова")
    case .folder: return tr("Изменить папку…")
    case .journal: return tr("Журнал")
    case .author: return tr("Написать автору")
    case .check: return tr("Проверить формат")
    case .path: return tr("Изменить путь…")
    }
}

extension ViewModel {
    func runFix(_ a: FixAction, about: String, kit: Bool = false) {
        switch a {
        case .save: kit ? kitSaveNow() : saveNow()
        case .folder: kit ? chooseKitFolder() : chooseFolder(setup: false)
        case .journal: kit ? openKitJournal() : openJournal()
        case .author: writeAuthor(about: about)
        case .check: checkFormat()
        case .path: if let a = agents.first(where: { tr($0.name) == about || about.contains(tr($0.name)) }) { kitChangePath(a) } else { kitAddProgram() }
        }
    }
}

// «Что случилось / что делать» для записей вкладки навыков.
func kitAdvice(_ c: DemoChange) -> Advice? {
    switch c.level {
    case .err:
        return Advice(what: trf("%@: настройки прочитать не удалось — формат мог измениться после обновления программы.", tr(c.who)),
                      todo: tr("Ничего не потеряно: прежняя копия в папке на месте. Если повторяется несколько дней — напишите автору."),
                      actions: [.journal, .author])
    case .warn where c.text.contains("не найдено"):
        return Advice(what: trf("Программа больше не находит %@ на этом Mac.", tr(c.who)),
                      todo: tr("Если вы его удалили — ничего делать не нужно, сохранённое остаётся в папке. Если перенесли — укажите новое место."),
                      actions: [.path])
    case .warn:
        return Advice(what: trf("%@ обновился и изменил формат настроек. Всё сохранено запасным способом, ничего не потеряно.", tr(c.who)),
                      todo: tr("Ничего срочного. Чтобы вернуть точный разбор, напишите автору."),
                      actions: [.journal, .author])
    default:
        return nil
    }
}

// Кнопка со списком в стиле программы: шрифт Bellota, как остальные кнопки; сам список — меню macOS.
final class MenuActions: NSObject {
    var actions: [() -> Void] = []
    @objc func run(_ sender: NSMenuItem) { actions[sender.tag]() }
}

struct PopMenuButton: View {
    var label: String
    var width: CGFloat
    var items: [(String, Bool, () -> Void)]    // название («-» — разделитель), отмечен ли, действие
    @State private var target = MenuActions()

    var body: some View {
        Button { pop() } label: {
            HStack(spacing: 6) {
                MarqueeText(text: label)   // не влезло — бегущая строка при наведении
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 12)
        }
        .buttonStyle(GlassButtonStyle(height: 32))
        .frame(width: width)
    }

    private func pop() { popMenu(items, target: target) }
}

// Список под кнопкой: меню macOS, пункты — шрифтом Bellota, у выбранного — галочка.
func popMenu(_ items: [(String, Bool, () -> Void)], target: MenuActions) {
    let menu = NSMenu()
    menu.font = Lang.nsFont(15, bold: false)
    target.actions = items.map { $0.2 }
    for (i, it) in items.enumerated() {
        if it.0 == "-" { menu.addItem(.separator()); continue }
        let mi = NSMenuItem(title: it.0, action: #selector(MenuActions.run(_:)), keyEquivalent: "")
        mi.tag = i
        mi.target = target
        mi.state = it.1 ? .on : .off
        if let f = Optional(Lang.nsFont(15, bold: false)) { mi.attributedTitle = NSAttributedString(string: it.0, attributes: [.font: f]) }
        menu.addItem(mi)
    }
    menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSEvent.mouseLocation, in: nil)
}

func retentionLabel(_ d: Int) -> String {
    switch d {
    case 3650: return tr("10 лет")
    case 365: return tr("1 год")
    default: return "\(d) \(plural(d, "день", "дня", "дней"))"
    }
}

struct LanguagePicker: View {
    @ObservedObject var vm: ViewModel
    static var langs: [(String, String)] { [("sys", tr("Как в системе")), ("-", "-"), ("ru", "Русский"), ("en", "English"), ("zh", "中文（简体）"), ("ja", "日本語"), ("hi", "हिन्दी")] }

    var body: some View {
        let cur = vm.config.language
        PopMenuButton(label: Self.langs.first { $0.0 == cur }?.1 ?? tr("Как в системе"), width: 170,
                      items: Self.langs.map { l in (l.1, l.0 == cur, { set(l.0) }) })
    }

    private func set(_ v: String) { vm.setLanguage(v) }
}

// Значок состояния агента: один на состояние.
struct StatusIcon: View {
    var state: AgentState
    var body: some View {
        Image(systemName: name).font(.system(size: 17)).foregroundColor(color).frame(width: 22, height: 22)
    }
    var name: String {
        switch state {
        case .ok: return "checkmark.circle"
        case .warn, .gone: return "exclamationmark.triangle"
        case .err: return "xmark.circle"
        case .off: return "pause.circle"
        }
    }
    var color: Color {
        switch state {
        case .ok: return Palette.ok
        case .warn, .gone: return Palette.warn
        case .err: return Palette.err
        case .off: return Color(white: 0.47)
        }
    }
}

// MARK: - Данные вкладки навыков

extension ViewModel {
    var kitURL: URL { Build.demo ? URL(fileURLWithPath: config.kitFolder ?? Demo.kitFolder.path, isDirectory: true) : config.kitURL }

    var kitTargets: [OpenTarget] {
        var list = openTargets.filter { $0.id != "obsidian" }
        if Obsidian.vault(containing: kitURL) != nil {
            list.insert(OpenTarget(id: "obsidian", name: "Obsidian", app: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian")), at: 1)
        }
        return list
    }

    var kitTarget: OpenTarget {
        let list = kitTargets
        if let id = config.kitOpenWith, let t = list.first(where: { $0.id == id }) { return t }
        return list.first(where: { $0.id == "obsidian" }) ?? list[0]
    }

    func openKitFolder() {
        let url = kitURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            alert(tr("Папки пока нет"), trf("Она появится после первого сохранения навыков: %@.", Fmt.shortPath(url.path)))
            return
        }
        let target = kitTarget
        switch target.id {
        case "obsidian":
            let overview = url.appendingPathComponent(KitNames.overview).path
            let enc = overview.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")) ?? overview
            if let link = URL(string: "obsidian://open?path=" + enc) { NSWorkspace.shared.open(link) }
        case "finder":
            NSWorkspace.shared.open(url)
        default:
            guard let app = target.app else { NSWorkspace.shared.open(url); return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    func openKitJournal() {
        let url = kitURL.appendingPathComponent(KitNames.journal)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) } else { alert(tr("Журнал пока пуст"), tr("Он появится после первого сохранения навыков.")) }
    }

    func chooseKitFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("Выбрать")
        panel.message = tr("Папка для навыков, MCP и плагинов (отдельно от «Истории ИИ»)")
        panel.directoryURL = kitURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update { $0.kitFolder = url.path }
    }

    func chooseKitMirror() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("Выбрать")
        panel.message = tr("Вторая папка для копии навыков и MCP: внешний диск или папка облака")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update { $0.kitMirror = url.appendingPathComponent("Навыки и MCP (копия)").path }
    }

    func setAgent(_ id: String, on: Bool) {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[i].on = on
        guard !Build.demo else { return }
        update { c in c.kitOff.removeAll { $0 == id }; if !on { c.kitOff.append(id) } }
        loadKit()
    }

    // Агенты и история вкладки: история — из прошлого сохранения, агенты — по проверке без записи.
    func loadKit() {
        guard !Build.demo else { return }
        kitHistory = KitStatus.load().history
        let c = config
        DispatchQueue.global(qos: .userInitiated).async {
            let (scans, _) = KitBackup(config: c, trigger: .manual).run(dryRun: true)
            let list = Kit.agents(scans, c)
            DispatchQueue.main.async { self.agents = list }
        }
    }

    func kitSaveNow() {
        if Build.demo { demoOnly(tr("Сохранить сейчас")); return }
        guard !kitBusy else { return }
        kitBusy = true
        let c = config
        DispatchQueue.global(qos: .userInitiated).async {
            let st = Kit.run(c, trigger: .manual)
            DispatchQueue.main.async {
                self.kitBusy = false
                self.agents = st.agents
                self.kitHistory = st.history
            }
        }
    }

    // «Изменить путь…» у агента: своя папка агента (если он стоит в необычном месте) или новое место своей папки.
    func kitChangePath(_ a: DemoAgent) {
        if Build.demo { demoOnly(tr("Изменить путь…")); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = tr("Выбрать")
        panel.message = trf("Папка, где %@ хранит навыки и настройки", tr(a.name))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if a.id.hasPrefix("own:") {
            let old = String(a.id.dropFirst(4))
            update { c in if let i = c.kitOwn.firstIndex(where: { $0.path == old }) { c.kitOwn[i].path = url.path } }
        } else {
            update { $0.kitPaths[a.id] = url.path }
        }
        loadKit()
    }

    // «Добавить программу…»: поддерживаемые агенты, которых нет в списке, и своя папка (например, AI-Memory).
    func kitAddProgram() {
        if Build.demo { demoOnly(tr("Добавить программу…")); return }
        let shown = Set(agents.map(\.id))
        var items: [(String, Bool, () -> Void)] = KitCatalog.all.filter { !shown.contains($0.id) }.map { spec in
            (tr(spec.name), false, { [weak self] in
                guard let self else { return }
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.showsHiddenFiles = true
                panel.prompt = tr("Выбрать")
                panel.message = trf("Папка, где %@ хранит навыки и настройки", tr(spec.name))
                guard panel.runModal() == .OK, let url = panel.url else { return }
                self.update { $0.kitPaths[spec.id] = url.path }
                self.loadKit()
            })
        }
        if !items.isEmpty { items.append(("-", false, {})) }
        items.append((tr("Своя папка…"), false, { [weak self] in
            guard let self else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = tr("Добавить")
            panel.message = tr("Своя папка, которую сохранять вместе с навыками (например, память агентов)")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let path = url.path
            self.askFolderName(url.lastPathComponent, text: tr("Так будет называться папка в «Свои папки».")) { name in
                self.update { c in c.kitOwn.removeAll { $0.path == path }; c.kitOwn.append(MDFolder(name: name, path: path)) }
                self.loadKit()
            }
        }))
        popMenu(items, target: addSourceMenu)
    }
}

// MARK: - Вкладка «Навыки и настройки»

struct KitView: View {
    @ObservedObject var vm: ViewModel

    var agents: [DemoAgent] { vm.agents }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tiles.padding(.top, 16)

            Text(tr("ПОСЛЕДНИЕ ИЗМЕНЕНИЯ")).font(.bellota(14, bold: false)).tracking(1.2).foregroundColor(Palette.dim).padding(.top, 20)
            Group {
                if vm.kitHistory.isEmpty {
                    Text(tr("Изменений ещё не было")).font(.bellota(15, bold: false)).foregroundColor(Palette.dim)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                } else {
                    HistoryList(count: vm.kitHistory.count) {
                        ForEach(Array(vm.kitHistory.enumerated()), id: \.offset) { i, r in
                            HistoryRow(date: r.date, who: tr(r.who), text: "\(r.level.mark) \(r.shown)", level: r.level,
                                       advice: kitAdvice(r), onFix: { vm.runFix($0, about: tr(r.who), kit: true) }, rowID: i)
                        }
                    }
                }
            }
            .padding(.top, 8)

            Text(tr("НАСТРОЙКИ")).font(.bellota(14, bold: false)).tracking(1.2).foregroundColor(Palette.dim).padding(.top, 20)
            ThemedScroll { settings.padding(.trailing, 14) }
                .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                Button(vm.kitBusy ? tr("Сохраняю…") : tr("Сохранить сейчас")) { vm.kitSaveNow() }.buttonStyle(GlassButtonStyle(accent: true)).disabled(vm.kitBusy)
                Button(tr("Что войдёт")) { vm.showWhat = true }.buttonStyle(GlassButtonStyle())
                Button(tr("Открыть папку")) { vm.openKitFolder() }.buttonStyle(GlassButtonStyle())
                Button(tr("Журнал")) { vm.openKitJournal() }.buttonStyle(GlassButtonStyle())
            }
            .padding(.top, 14)
        }
    }

    // То же правило, что у переписок: до 3 — большие карточки, 4–8 — плитки по 4, с 9-й — прокрутка.
    @ViewBuilder private var tiles: some View {
        if agents.count > 3 {
            let grid = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(agents) { KitTile(a: $0, keys: vm.config.kitKeys) }
            }
            if agents.count > 8 {
                ThemedScroll { grid.padding(.trailing, 16) }.frame(height: SourceTile.height * 2 + 10)
            } else {
                grid
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: max(1, agents.count)), spacing: 14) {
                ForEach(agents) { KitCard(a: $0, keys: vm.config.kitKeys) }
            }
        }
    }

    private var settings: some View {
        let c = vm.config
        return VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: tr("Сохранять навыки и настройки"), subtitle: tr("Навыки, MCP, плагины и инструкции агентов")) {
                Toggle("", isOn: Binding(get: { c.kitEnabled }, set: { v in vm.update { $0.kitEnabled = v } }))
                    .toggleStyle(.switch).labelsHidden().tint(Palette.purple)
            }
            VStack(alignment: .leading, spacing: 0) {
                SettingRow(title: tr("Вместе с переписками"),
                           subtitle: c.kitWithChats
                               ? trf("В то же время, что и автосохранение (%@). Выключите, чтобы задать своё", TimeFormat.hm(c.hour, c.minute))
                               : tr("Своё время, каждый день. Если Mac спал — после пробуждения или входа")) {
                    HStack(spacing: 10) {
                        if !c.kitWithChats {
                            TimeField(hour: Binding(get: { vm.config.kitHour }, set: { v in vm.update { $0.kitHour = v } }),
                                      minute: Binding(get: { vm.config.kitMinute }, set: { v in vm.update { $0.kitMinute = v } }))
                        }
                        Toggle("", isOn: Binding(get: { c.kitWithChats }, set: { v in vm.update { $0.kitWithChats = v } }))
                            .toggleStyle(.switch).labelsHidden().tint(Palette.purple)
                    }
                }
                SettingRow(title: tr("Папка навыков и MCP"), subtitle: Fmt.shortPath(vm.kitURL.path).replacingOccurrences(of: "/", with: " › "),
                           note: AnyView(kitNote), oneLine: true) {
                    HStack(spacing: 8) {
                        KitOpenWithButton(vm: vm)
                        Button(tr("Изменить…")) { vm.chooseKitFolder() }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 130)
                    }
                }
                SettingRow(title: tr("Копия навыков и MCP"),
                           subtitle: c.kitMirror.map { Fmt.shortPath($0).replacingOccurrences(of: "/", with: " › ") }
                               ?? tr("Не задана — например, внешний диск или папка облака. Копируются все файлы, не только .md"),
                           oneLine: c.kitMirror != nil) {
                    HStack(spacing: 8) {
                        if c.kitMirror != nil {
                            Button(tr("Убрать")) { vm.update { $0.kitMirror = nil } }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 90)
                        }
                        Button(tr("Выбрать…")) { vm.chooseKitMirror() }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 130)
                    }
                }
                SettingRow(title: tr("Ключи и пароли в конфигах"), subtitle: keysSubtitle(c.kitKeys),
                           subtitleColor: c.kitKeys == "keep" ? Palette.warn : Palette.dim) {
                    let modes = [("hide", tr("Скрывать")), ("keep", tr("Сохранять как есть")), ("skip", tr("Не сохранять такие файлы"))]
                    PopMenuButton(label: modes.first { $0.0 == c.kitKeys }?.1 ?? tr("Скрывать"), width: 240,
                                  items: modes.map { m in (m.1, m.0 == c.kitKeys, { vm.update { $0.kitKeys = m.0 } }) })
                }
                HStack(spacing: 10) {
                    CheckBox(on: Binding(get: { c.kitKeepPrev }, set: { v in vm.update { $0.kitKeepPrev = v } }))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) { Text(tr("Хранить прошлую версию")).font(.bellota(16)); NewBadge() }
                        Text(tr("Если агент обновил или удалил навык, правило, плагин или MCP — одна прошлая версия ложится в «_прежние»"))
                            .font(.bellota(13, bold: false)).foregroundColor(Palette.dim)
                    }
                    Spacer()
                }
                .padding(.vertical, 9)
                .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)

                agentsSection
            }
            .opacity(c.kitEnabled ? 1 : 0.4)
            .disabled(!c.kitEnabled)
        }
    }

    private func keysSubtitle(_ mode: String) -> String {
        switch mode {
        case "keep": return tr("⚠️ Ключи лежат в папке открытым текстом. Не выкладывайте её в облако и на GitHub")
        case "skip": return tr("Файлы с ключами не копируются — только списки плагинов и MCP")
        default: return tr("Значения заменяются на «скрыто», остальное копируется")
        }
    }

    @ViewBuilder private var kitNote: some View {
        let link = Color(red: 0.81, green: 0.78, blue: 1)
        if let vault = Obsidian.vault(containing: vm.kitURL) {
            Text(trf("Хранилище Obsidian «%@»", (vault as NSString).lastPathComponent)).font(.bellota(13, bold: false)).foregroundColor(link)
        } else {
            Text(tr("Отдельно от «Истории ИИ»")).font(.bellota(13, bold: false)).foregroundColor(Palette.dim)
        }
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("АГЕНТЫ")).font(.bellota(14, bold: false)).tracking(1.2).foregroundColor(Palette.dim).padding(.top, 20).padding(.bottom, 4)
            ForEach(agents) { a in
                let state: AgentState = a.on ? (a.state == .off ? .ok : a.state) : .off
                HStack(spacing: 10) {
                    StatusIcon(state: state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr(a.name)).font(.bellota(16)).foregroundColor(a.on ? .white : Palette.dim)
                        MarqueeText(text: line(a, state)).font(.bellota(13, bold: false)).foregroundColor(lineColor(state))
                    }
                    Spacer()
                    Button(tr("Изменить путь…")) { vm.kitChangePath(a) }.buttonStyle(GlassButtonStyle(height: 30)).frame(width: 176)
                    Toggle("", isOn: Binding(get: { a.on }, set: { vm.setAgent(a.id, on: $0) }))
                        .toggleStyle(.switch).labelsHidden().tint(Palette.purple)
                }
                .padding(.vertical, 7)
                .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
            }
            HStack {
                Text(tr("Если программа стоит в необычном месте")).font(.bellota(14, bold: false)).foregroundColor(Palette.dim)
                Spacer()
                Button(tr("Добавить программу…")) { vm.kitAddProgram() }.buttonStyle(GlassButtonStyle(accent: true, height: 30)).frame(width: 224) // ширина = «Изменить путь…» (176) + отступ (10) + переключатель (38)
            }
            .padding(.vertical, 9)
        }
    }

    private func line(_ a: DemoAgent, _ state: AgentState) -> String {
        switch state {
        case .ok: return "\(a.path) · \(kitSummary(a))"
        case .off: return "\(a.path) · " + tr("выключено")
        default: return "\(a.path) · \(tr(a.note))"
        }
    }

    private func lineColor(_ state: AgentState) -> Color {
        switch state {
        case .warn, .gone: return Palette.warn
        case .err: return Color(red: 1, green: 0.54, blue: 0.53)
        default: return Palette.dim
        }
    }
}

// Подпись под числом на плитке и карточке агента: что в нём есть.
// tile: true — под крупным числом, поэтому само число не повторяем («навыка · …», как «сессия · …» у переписок).
func kitSummary(_ a: DemoAgent, tile: Bool = false) -> String {
    var parts: [String] = []
    if a.skills > 0 { parts.append((tile ? "" : "\(a.skills) ") + plural(a.skills, "навык", "навыка", "навыков")) }
    if a.mcp > 0 { parts.append(tile && a.skills == 0 ? "MCP" : "\(a.mcp) MCP") }
    if a.plugins > 0 { parts.append("\(a.plugins) \(plural(a.plugins, "плагин", "плагина", "плагинов"))") }
    if !a.extra.isEmpty { parts.append(a.extra) }
    return parts.joined(separator: " · ")
}

func kitKeysText(_ a: DemoAgent, _ mode: String) -> String? {
    guard a.keys > 0 else { return nil }
    switch mode {
    case "keep": return trf("🔑 %d с ключами", a.keys)
    case "skip": return tr("⛔ конфиг не сохранён")
    default: return trf("🔒 %d скрыто", a.keys)
    }
}

// Ключи — жёлтым и целиком, остальное — серым; не влезло — бегущая строка при наведении.
struct KitSubline: View {
    var a: DemoAgent
    var keys: String
    var body: some View {
        if let k = kitKeysText(a, keys) {
            MarqueeText(label: Text(k).foregroundColor(Palette.warn) + Text(" · " + kitSummary(a, tile: true)).foregroundColor(Palette.dim))
        } else {
            MarqueeText(text: kitSummary(a, tile: true)).foregroundColor(Palette.dim)
        }
    }
}

private func kitLevel(_ a: DemoAgent) -> Level {
    guard a.on else { return .none }
    switch a.state {
    case .ok: return .ok
    case .warn, .gone: return .warn
    case .err: return .err
    case .off: return .none
    }
}

struct KitTile: View {
    var a: DemoAgent
    var keys: String

    var body: some View {
        let lv = kitLevel(a)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Dot(color: Palette.level(lv), size: 9)
                Text(tr(a.name)).font(.bellota(15)).lineLimit(1)
            }
            if lv == .none {
                Text(tr("Выключено")).font(.bellota(12, bold: false)).foregroundColor(Palette.dim).padding(.top, 6)
            } else {
                Text("\(a.big)").font(.bellota(24)).padding(.top, 2)
                if lv == .ok {
                    KitSubline(a: a, keys: keys).font(.bellota(12, bold: false))
                } else {
                    MarqueeText(text: "\(lv.mark) \(tr(a.note).capitalizedFirst)").font(.bellota(12)).foregroundColor(Palette.level(lv))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: SourceTile.height, maxHeight: SourceTile.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.cardBorder))
    }
}

struct KitCard: View {
    var a: DemoAgent
    var keys: String

    var body: some View {
        let lv = kitLevel(a)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Dot(color: Palette.level(lv))
                Text(tr(a.name)).font(.bellota(19)).lineLimit(1)
            }
            Text("\(a.big)").font(.bellota(30)).padding(.top, 4)
            KitSubline(a: a, keys: keys).font(.bellota(15, bold: false)).padding(.top, 4)
            Group {
                if lv == .ok { Text(tr("Всё сохранено ✅")) } else if lv == .none { Text(tr("Выключено")).foregroundColor(Palette.dim) }
                else { MarqueeText(text: "\(lv.mark) \(tr(a.note).capitalizedFirst)").foregroundColor(Palette.level(lv)) }
            }
            .font(.bellota(15)).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.cardBorder))
    }
}

// «Открыть в …» + ▾ для папки навыков — та же кнопка, что у папки архива, со своим выбором программы.
struct KitOpenWithButton: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        let targets = vm.kitTargets
        let current = vm.kitTarget
        HStack(spacing: 4) {
            Button { vm.openKitFolder() } label: {
                HStack(spacing: 8) {
                    Image(nsImage: current.icon).resizable().frame(width: 16, height: 16)
                    Text(trf("Открыть в %@", current.short)).truncationMode(.tail)
                }
                .padding(.horizontal, 16)
            }
            .buttonStyle(GlassButtonStyle(height: 32))
            .frame(minWidth: 196, maxWidth: 300)
            .fixedSize()
            Menu {
                Picker("", selection: Binding(get: { current.id }, set: { id in vm.update { $0.kitOpenWith = id } })) {
                    ForEach(targets) { t in
                        Label { Text(t.name) } icon: { Image(nsImage: t.icon) }.tag(t.id)
                    }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Text("▾").font(.bellota(14)).foregroundColor(.white)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 26, height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.button))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.buttonBorder, lineWidth: 1))
            .help(tr("Выбрать программу для папки навыков"))
        }
    }
}

// MARK: - «Что войдёт»

struct WhatSheet: View {
    @ObservedObject var vm: ViewModel

    struct Item: Identifiable {
        var icon: String
        var what: String
        var path: String
        var id: String { what + path }
    }

    var keyIcon: String { ["keep": "🔑", "skip": "⛔"][vm.config.kitKeys] ?? "🔒" }
    var keySuffix: String { ["keep": tr(" — с ключами"), "skip": tr(" — не копируется")][vm.config.kitKeys] ?? tr(" — ключи скрыты") }

    @State private var real: [(String, [Item])]?

    var groups: [(String, [Item])] {
        if !Build.demo { return real ?? [] }
        return [
            ("CLAUDE CODE", [Item(icon: "✅", what: tr("34 навыка — папки целиком"), path: "~/.claude/skills"),
                             Item(icon: "✅", what: "CLAUDE.md, settings.json", path: "~/.claude"),
                             Item(icon: "📋", what: tr("Плагины — список (сейчас не установлены)"), path: "~/.claude/plugins")]),
            (tr("ПРИЛОЖЕНИЕ CLAUDE"), [Item(icon: keyIcon, what: tr("11 MCP-серверов") + keySuffix, path: "claude_desktop_config.json"),
                                   Item(icon: "📋", what: tr("7 плагинов — список имён и версий"), path: "…/Claude/local-agent-mode-sessions")]),
            ("CODEX", [Item(icon: "✅", what: tr("7 навыков (системные .system — нет)"), path: "~/.codex/skills"),
                       Item(icon: "✅", what: "AGENTS.md, rules/default.rules, keybindings.json", path: "~/.codex"),
                       Item(icon: keyIcon, what: tr("Настройки, 12 MCP") + keySuffix, path: "~/.codex/config.toml"),
                       Item(icon: "📋", what: tr("12 плагинов и 3 маркета — список с источниками"), path: "config.toml"),
                       Item(icon: "⛔", what: tr("Кэш плагинов 520 МБ — не копируется"), path: "~/.codex/plugins")]),
            ("DSH DESKTOP", [Item(icon: "✅", what: "figma-mcp-routing, AGENTS.md", path: "~/.dsh")])
        ]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26).fill(Color.black.opacity(0.6))
                .onTapGesture { vm.showWhat = false }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Что войдёт")).font(.bellota(22))
                Text(Build.demo ? tr("Проверка без записи: что будет скопировано при следующем сохранении (в тесте — пример)")
                                : (real == nil ? tr("Проверяю…") : tr("Проверка без записи: что будет скопировано при следующем сохранении")))
                    .font(.bellota(13, bold: false)).foregroundColor(Palette.dim)
                ThemedScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups.indices, id: \.self) { gi in
                            let g = groups[gi]
                            Text(g.0).font(.bellota(12, bold: false)).tracking(2).foregroundColor(Palette.dim).padding(.top, 14).padding(.bottom, 2)
                            ForEach(g.1) { it in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(it.icon).frame(width: 24, alignment: .leading)
                                    Text(it.what).font(.bellota(14, bold: false))
                                    Spacer(minLength: 8)
                                    Text(it.path).font(.bellota(13, bold: false)).foregroundColor(Palette.dim).lineLimit(1)
                                }
                                .padding(.vertical, 6)
                                .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
                            }
                        }
                    }
                    .padding(.trailing, 14)
                }
                .frame(height: 400)
                Text(tr("✅ копия · 🔒 ключи скрыты · 🔑 с ключами · 📋 только список · ⛔ не копируется"))
                    .font(.bellota(13, bold: false)).foregroundColor(Palette.dim).padding(.top, 10)
                HStack {
                    Spacer()
                    Button("OK") { vm.showWhat = false }.buttonStyle(GlassButtonStyle(accent: true, height: 34)).frame(width: 100)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 26).padding(.vertical, 22)
            .frame(width: 720)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(red: 0.043, green: 0.043, blue: 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.blueBorder))
        }
        .onAppear {
            guard !Build.demo, real == nil else { return }
            let c = vm.config
            DispatchQueue.global(qos: .userInitiated).async {
                let g = Kit.preview(c).map { ($0.0, $0.1.map { Item(icon: $0.icon, what: $0.what, path: $0.path) }) }
                DispatchQueue.main.async { real = g }
            }
        }
    }
}

// MARK: - Бегущая строка

// Текст в одну строку. Если не влез — при наведении мыши плавно едет влево по кругу, как на табло.
struct MarqueeText: View {
    let label: Text
    @State private var fullW: CGFloat = 0
    @State private var boxW: CGFloat = 0
    @State private var hover = false
    @State private var start = Date()

    init(text: String) { label = Text(text) }
    init(label: Text) { self.label = label }   // строка из нескольких цветных частей — едет целиком

    private var running: Bool { hover && fullW > boxW + 1 }

    var body: some View {
        label
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(running ? 0 : 1)
            .background(GeometryReader { g in
                Color.clear.onAppear { boxW = g.size.width }.onChange(of: g.size.width) { boxW = $0 }
            })
            .background(
                label.fixedSize().hidden()
                    .background(GeometryReader { g in
                        Color.clear.onAppear { fullW = g.size.width }.onChange(of: g.size.width) { fullW = $0 }
                    })
            )
            .overlay(alignment: .leading) {
                if running {
                    TimelineView(.animation) { ctx in
                        let gap: CGFloat = 48
                        let t = max(0, ctx.date.timeIntervalSince(start) - 0.4)
                        let x = -(CGFloat(t) * 45).truncatingRemainder(dividingBy: fullW + gap)
                        HStack(spacing: gap) { label; label }
                            .fixedSize()
                            .offset(x: x)
                    }
                    .frame(width: boxW, alignment: .leading)
                    .clipped()
                }
            }
            .contentShape(Rectangle())
            .onHover { h in
                hover = h
                if h { start = Date() }
            }
    }
}

// MARK: - Окно сообщений в стиле программы

// Кнопка в окне сообщения. action получает текст из поля ввода, если оно есть.
struct MsgButton {
    var title: String
    var accent = false
    var action: (String) -> Void = { _ in }
}

struct Message: Identifiable {
    let id = UUID()
    var title: String
    var text: String
    var buttons: [MsgButton] = []    // пусто — одна кнопка «Понятно»
    var field: String? = nil         // поле ввода с начальным текстом (например, имя папки)
}

struct MessageView: View {
    @ObservedObject var vm: ViewModel
    var msg: Message
    @State private var textH: CGFloat = 0
    @State private var value = ""

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26).fill(Color.black.opacity(0.6))
                .onTapGesture {}
            VStack(spacing: 14) {
                Image(nsImage: resourceImage("mascot")).resizable().frame(width: 64, height: 64).clipShape(Circle())
                    .shadow(color: Palette.purple.opacity(0.6), radius: 12)
                    .onHover { if $0 { NSCursor.arrow.set() } }
                Text(msg.title).font(.bellota(21)).multilineTextAlignment(.center)
                    .onHover { if $0 { NSCursor.arrow.set() } }
                ScrollView(.vertical) {
                    Text(msg.text)
                        .font(.bellota(16, bold: false))
                        .foregroundColor(Color(white: 0.85))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .background(GeometryReader { g in
                            Color.clear.onAppear { textH = g.size.height }.onChange(of: g.size.height) { textH = $0 }
                        })
                }
                .frame(height: min(max(textH, 20), 380))
                if msg.field != nil {
                    TextField("", text: $value)
                        .textFieldStyle(.plain)
                        .font(.bellota(16, bold: false))
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.button))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.blueBorder))
                        .onAppear { value = msg.field ?? "" }
                }
                if msg.buttons.isEmpty {
                    Button(tr("Понятно")) { vm.message = nil }
                        .buttonStyle(GlassButtonStyle(accent: true, height: 40))
                        .onHover { if $0 { NSCursor.arrow.set() } }
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 4)
                    Button("") { vm.message = nil }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
                } else {
                    // Слева — отмена (Esc), справа — главное действие (Enter), как кнопка «Сохранить сейчас».
                    HStack(spacing: 10) {
                        ForEach(msg.buttons.indices, id: \.self) { i in
                            let b = msg.buttons[i]
                            if b.accent {
                                Button(b.title) { let v = value; vm.message = nil; b.action(v) }
                                    .buttonStyle(GlassButtonStyle(accent: true, height: 40))
                                    .keyboardShortcut(.defaultAction)
                            } else {
                                Button(b.title) { let v = value; vm.message = nil; b.action(v) }
                                    .buttonStyle(GlassButtonStyle(height: 40))
                                    .keyboardShortcut(.cancelAction)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(width: 420)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(red: 0.043, green: 0.043, blue: 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.blueBorder))
            .shadow(color: Palette.purple.opacity(0.35), radius: 20)
        }
    }
}

// Окно автора — в стиле программы: как остальные сообщения, со своими кнопками и шрифтами.
struct AuthorView: View {
    @ObservedObject var vm: ViewModel
    static let email = "samo.zlo.spb@gmail.com"

    private func write() {
        vm.showAuthor = false
        if let url = URL(string: "mailto:\(Self.email)") { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26).fill(Color.black.opacity(0.6))
                .onTapGesture { vm.showAuthor = false }
            VStack(spacing: 0) {
                Image(nsImage: resourceImage("mascot")).resizable().frame(width: 64, height: 64).clipShape(Circle())
                    .shadow(color: Palette.purple.opacity(0.65), radius: 14)
                    .padding(.bottom, 14)
                Text(tr("✕ Разработчик, автор программы ✕")).font(.bellota(21))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("ツ  🎱").font(.bellota(16, bold: false)).foregroundColor(Color(white: 0.85)).padding(.top, 10)
                LinkButton(title: Self.email) { write() }
                    .font(.bellota(17, bold: false)).padding(.top, 14)
                HStack(spacing: 10) {
                    Button(tr("Закрыть")) { vm.showAuthor = false }
                        .buttonStyle(GlassButtonStyle(height: 40)).keyboardShortcut(.cancelAction)
                    Button(tr("Написать")) { write() }
                        .buttonStyle(GlassButtonStyle(accent: true, height: 40)).keyboardShortcut(.defaultAction)
                }
                .padding(.top, 20)
            }
            .onHover { if $0 { NSCursor.arrow.set() } }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: 460)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(red: 0.043, green: 0.043, blue: 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.blueBorder))
            .shadow(color: Palette.purple.opacity(0.35), radius: 20)
            .padding(.horizontal, 14)
        }
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// Ссылка в подписи: тем же шрифтом, цветом ссылки; при наведении — подчёркнута, курсор-рука.
struct LinkButton: View {
    var title: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).underline(hover).foregroundColor(Color(red: 0.81, green: 0.78, blue: 1))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover = inside
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Обновления (в тесте — вымышленная версия 2.1; механизм — Sparkle, подключается отдельно)

struct UpdateNote: Identifiable { let id = UUID(); var text: String }

extension ViewModel {
    var updateModes: [(String, String)] {
        [("auto", tr("Обновлять автоматически")), ("notify", tr("Проверять, не устанавливать")), ("off", tr("Отключить обновления"))]
    }

    func checkUpdates() { Updater.shared.check() }
    func installUpdate() { installing = 0.01; Updater.shared.install() }
}

struct UpdatesRow: View {
    @ObservedObject var vm: ViewModel
    @State private var notesOpen = false

    var subtitle: String {
        let mode: String
        switch vm.config.updateMode {
        case "auto": mode = tr("Проверяет, скачивает и устанавливает обновления автоматически")
        case "off": mode = tr("Программа не проверяет обновления")
        default: mode = tr("Проверяет и сообщает о новой версии. Без установки")
        }
        return mode
    }

    var body: some View {
        let cur = vm.config.updateMode
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: tr("Обновления"), subtitle: subtitle,
                       note: AnyView(Text(trf("Установлена версия %@", Updater.currentVersion) + (vm.lastUpdateCheck.map { " · " + trf("проверено %@", whenText($0)) } ?? ""))
                                        .font(.bellota(13, bold: false)).foregroundColor(Palette.dim)),
                       badge: true) {
                HStack(spacing: 8) {
                    Button(vm.updateChecking ? tr("Проверяю…") : tr("Проверить")) { vm.checkUpdates() }
                        .buttonStyle(GlassButtonStyle(accent: true, height: 32)).frame(width: 130).disabled(vm.updateChecking)
                    PopMenuButton(label: vm.updateModes.first { $0.0 == cur }?.1 ?? "", width: 280,
                                  items: vm.updateModes.map { m in (m.1, m.0 == cur, { vm.update { $0.updateMode = m.0 }; Updater.shared.apply(m.0) }) })
                }
            }
            if vm.updateAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 18)).foregroundColor(Palette.ok)
                        Text(trf("Доступна версия %@", vm.updateVersion)).font(.bellota(16))
                        Spacer()
                        Button(notesOpen ? tr("Что нового ▴") : tr("Что нового ▾")) { withAnimation(.easeOut(duration: 0.15)) { notesOpen.toggle() } }
                            .buttonStyle(GlassButtonStyle(height: 30)).frame(width: 160)
                        Button(tr("Установить")) { vm.installUpdate() }
                            .buttonStyle(GlassButtonStyle(accent: true, height: 30)).frame(width: 150)
                    }
                    if notesOpen {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(vm.updateNotes, id: \.self) { line in
                                Text("•  " + line).font(.bellota(14, bold: false)).foregroundColor(Color(white: 0.85))
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                        .padding(.leading, 28)
                    }
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.ok.opacity(0.35)))
                .padding(.vertical, 8)
            }
        }
    }
}

// Окно установки в стиле программы.
struct InstallView: View {
    @ObservedObject var vm: ViewModel
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26).fill(Color.black.opacity(0.6)).onTapGesture {}
            VStack(spacing: 14) {
                Image(nsImage: resourceImage("mascot")).resizable().frame(width: 64, height: 64).clipShape(Circle())
                    .shadow(color: Palette.purple.opacity(0.6), radius: 12)
                Text(vm.installing < 1 ? trf("Скачиваю версию %@…", vm.updateVersion) : tr("Готово к установке")).font(.bellota(21))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                    Capsule().fill(ThemedScroll<EmptyView>.thumbGradient).frame(width: 340 * vm.installing, height: 6)
                }
                .frame(width: 340)
                Text(vm.installing < 1 ? "\(Int(vm.installing * 100))%" : tr("Программа закроется, обновится и откроется снова. Архив и настройки не меняются."))
                    .font(.bellota(15, bold: false)).foregroundColor(Color(white: 0.85)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if vm.installing >= 1 {
                    HStack(spacing: 10) {
                        Button(tr("Позже")) { Updater.shared.restartLater() }.buttonStyle(GlassButtonStyle(height: 38))
                        Button(tr("Перезапустить")) { Updater.shared.restartNow() }
                            .buttonStyle(GlassButtonStyle(accent: true, height: 38)).keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(width: 420)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(red: 0.043, green: 0.043, blue: 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.blueBorder))
        }
    }
}
