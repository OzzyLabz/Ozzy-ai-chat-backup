import AppKit
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--check") {
            print(Exporter.checkFormat(AppConfig.load()))
            return
        }
        if args.contains("--test-notification") {
            let ok = Notifier.post("Бэкап ИИ — проверка уведомлений", "Так будет выглядеть сообщение о проблеме. Нажмите, чтобы открыть программу.")
            print(ok ? "отправлено от имени программы" : "уведомления программе не разрешены — отправлено запасным способом")
            return
        }
        if let i = args.firstIndex(of: "--import"), i + 1 < args.count {
            let r = WebImport.run(URL(fileURLWithPath: args[i + 1]))
            print(r.message)
            if !r.ok { return }
        }
        if args.contains("--export") || args.contains("--import") {
            Headless.run(args)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

// Запуск без окна: от расписания (--auto) или из терминала.
enum Headless {
    static func run(_ args: [String]) {
        var config = AppConfig.load()
        if let i = args.firstIndex(of: "--archive"), i + 1 < args.count {
            config.archivePath = args[i + 1]
            config.setupDone = true
        }
        if let i = args.firstIndex(of: "--name"), i + 1 < args.count { config.userName = args[i + 1] }
        guard config.setupDone else {
            print("Программа ещё не настроена: откройте её и выберите папку архива.")
            return
        }
        let auto = args.contains("--auto")
        var trigger = Trigger.manual
        if auto {
            guard config.autoEnabled else { return }
            trigger = Scheduler.autoTrigger(config)
            // launchd запускает задачу и при её перезагрузке — не дублируем недавнее сохранение.
            if trigger == .login, let last = AppStatus.load().lastRun, Date().timeIntervalSince(last) < 3600 { return }
        }
        let exporter = Exporter(config: config, trigger: trigger)
        if let i = args.firstIndex(of: "--rebuild"), i + 1 < args.count {
            exporter.rebuild = Set(args[i + 1].split(separator: ",").map(String.init))
        }
        let result = exporter.run()
        print("\(Fmt.full.string(from: Date())) \(trigger.title): \(result.status.level.mark) \(result.message)")
        if auto { ExportReminder.checkAndNotify() }
        if auto, config.notify, result.status.level == .warn || result.status.level == .err {
            let what = advice(for: result.status)?.what ?? result.message
            Notifier.post("Бэкап ИИ — \(result.status.headline.lowercased())", what + " Нажмите, чтобы узнать, что делать.")
        }
    }
}

// MARK: - Оформление

enum Palette {
    static let window = Color(red: 6 / 255, green: 6 / 255, blue: 6 / 255)
    static let button = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let buttonBorder = Color(red: 0.35, green: 0.35, blue: 0.37)
    static let blue = Color(red: 0.11, green: 0.09, blue: 0.25)
    static let blueBorder = Color(red: 0.36, green: 0.27, blue: 0.94)
    static let purple = Color(red: 0.36, green: 0.27, blue: 0.94)
    static let card = Color(red: 0.055, green: 0.055, blue: 0.067)
    static let cardBorder = Color(red: 0.15, green: 0.15, blue: 0.17)
    static let line = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let dim = Color(red: 0.6, green: 0.6, blue: 0.62)
    static let ok = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let warn = Color(red: 1.0, green: 0.69, blue: 0.13)
    static let err = Color(red: 1.0, green: 0.28, blue: 0.27)
    static let off = Color(red: 0.23, green: 0.23, blue: 0.24)
    static let border = AngularGradient(
        gradient: Gradient(stops: [
            .init(color: Color(red: 75 / 255, green: 39 / 255, blue: 246 / 255), location: 0),
            .init(color: Color(red: 39 / 255, green: 83 / 255, blue: 246 / 255), location: 0.25),
            .init(color: Color(red: 75 / 255, green: 39 / 255, blue: 246 / 255), location: 0.5),
            .init(color: Color(red: 118 / 255, green: 48 / 255, blue: 246 / 255), location: 0.67),
            .init(color: Color(red: 252 / 255, green: 107 / 255, blue: 230 / 255), location: 0.77),
            .init(color: Color(red: 252 / 255, green: 107 / 255, blue: 230 / 255), location: 0.88),
            .init(color: Color(red: 75 / 255, green: 39 / 255, blue: 246 / 255), location: 1)
        ]),
        center: .center)

    static func level(_ l: Level) -> Color {
        switch l {
        case .ok: return ok
        case .warn: return warn
        case .err: return err
        case .none: return off
        }
    }
}

extension Font {
    static func bellota(_ size: CGFloat, bold: Bool = true) -> Font {
        .custom(bold ? "Bellota-Bold" : "Bellota-Regular", size: size)
    }
}

func registerFonts() {
    for name in ["Bellota-Bold", "Bellota-Regular"] {
        if let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.main.url(forResource: name, withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

func resourceImage(_ name: String) -> NSImage {
    if let url = Bundle.main.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) { return img }
    return NSImage(size: NSSize(width: 1, height: 1))
}

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}

func whenText(_ date: Date) -> String {
    let cal = Calendar.current
    let t = Fmt.time.string(from: date)
    if cal.isDateInToday(date) { return "сегодня в \(t)" }
    if cal.isDateInYesterday(date) { return "вчера в \(t)" }
    return Fmt.dayTime.string(from: date).replacingOccurrences(of: " ", with: " в ")
}

struct GlassButtonStyle: ButtonStyle {
    var accent = false
    var dashed = false
    var height: CGFloat = 42

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, accent: accent, dashed: dashed, height: height)
    }

    struct StyledBody: View {
        let configuration: Configuration
        let accent: Bool
        let dashed: Bool
        let height: CGFloat
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.bellota(height < 36 ? 14 : 17))
                .lineLimit(1)
                .foregroundColor(dashed ? Color(red: 0.81, green: 0.78, blue: 1) : .white)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 9).fill(dashed ? Color.clear : (accent ? Palette.blue : Palette.button)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(accent ? Palette.blueBorder : Palette.buttonBorder,
                                      style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : []))
                )
                .brightness(configuration.isPressed ? -0.06 : (hover ? 0.06 : 0))
                .shadow(color: Palette.purple.opacity(hover && enabled ? 0.35 : 0), radius: 8)
                .opacity(enabled ? 1 : 0.55)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.15), value: hover)
        }
    }
}

struct Dot: View {
    var color: Color
    var size: CGFloat = 15
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct CheckBox: View {
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(on ? Palette.purple : Palette.off).frame(width: 20, height: 20)
                if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(.white) }
            }
        }
        .buttonStyle(.plain)
    }
}

// Логотип OlegX: при наведении чуть увеличивается и светится пурпурно-синим, по клику — окно автора.
struct OlegLogo: View {
    var width: CGFloat
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Image(nsImage: resourceImage("oleg"))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: width)
            .shadow(color: Palette.purple.opacity(hover ? 0.95 : 0), radius: 10)
            .shadow(color: Color(red: 39 / 255, green: 83 / 255, blue: 246 / 255).opacity(hover ? 0.8 : 0), radius: 18)
            .scaleEffect(hover ? 1.08 : 1)
            .animation(.easeOut(duration: 0.18), value: hover)
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture(perform: action)
            .help("Об авторе")
    }
}

struct TrafficLights: View {
    var close: () -> Void
    var green: () -> Void
    var body: some View {
        HStack(spacing: 9) {
            Button(action: close) { Dot(color: Color(red: 1, green: 0.28, blue: 0.27), size: 13) }.buttonStyle(.plain).help("Свернуть в строку меню")
            Button(action: green) { Dot(color: Color(red: 0.14, green: 0.80, blue: 0.27), size: 13) }.buttonStyle(.plain).help("Подробности")
        }
    }
}

// Прокрутка с полосой в цветах программы. Полоса видна, только когда содержимое не помещается.
struct ThemedScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { outer in
            ScrollView(.vertical, showsIndicators: false) {
                content()
                    .background(GeometryReader { g in
                        let frame = g.frame(in: .named("themedScroll"))
                        Color.clear
                            .onAppear { offset = -frame.minY; contentHeight = frame.height }
                            .onChange(of: frame) { f in offset = -f.minY; contentHeight = f.height }
                    })
            }
            .coordinateSpace(name: "themedScroll")
            .overlay(alignment: .topTrailing) {
                let visible = outer.size.height
                if contentHeight > visible + 1 {
                    let thumb = max(36, visible * visible / contentHeight)
                    let progress = min(max(offset / (contentHeight - visible), 0), 1)
                    ZStack(alignment: .top) {
                        Capsule().fill(Color.white.opacity(0.06)).frame(width: 6, height: visible)
                        Capsule()
                            .fill(LinearGradient(colors: [Color(red: 252 / 255, green: 107 / 255, blue: 230 / 255),
                                                          Palette.purple,
                                                          Color(red: 39 / 255, green: 83 / 255, blue: 246 / 255)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 6, height: thumb)
                            .shadow(color: Palette.purple.opacity(0.6), radius: 4)
                            .offset(y: (visible - thumb) * progress)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Данные окна

final class ViewModel: ObservableObject {
    @Published var config = AppConfig.load()
    @Published var status = AppStatus.load() {
        didSet { if (advice(for: oldValue) == nil) != (advice(for: status) == nil) { onResize?() } }
    }
    @Published var expanded = false
    @Published var busy = false
    @Published var loginEnabled = LoginItem.isEnabled
    @Published var retentionDays = ClaudeRetention.days
    @Published var setupPath = AppConfig.load().archivePath ?? AppConfig.defaultArchivePath()

    var onResize: (() -> Void)?
    var onAbout: (() -> Void)?
    var onHide: (() -> Void)?
    private var timer: Timer?
    private var statusStamp: Date?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.reloadIfChanged() }
    }

    func reloadIfChanged() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Paths.status.path))?[.modificationDate] as? Date
        if stamp != statusStamp {
            statusStamp = stamp
            status = AppStatus.load()
        }
    }

    func refreshSystem() {
        loginEnabled = LoginItem.isEnabled
        retentionDays = ClaudeRetention.days
        reloadIfChanged()
    }

    func update(_ change: (inout AppConfig) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        config = c
        c.save()
        DispatchQueue.global().async { Scheduler.apply(c) }
    }

    var scheduleDate: Date {
        get { Calendar.current.date(bySettingHour: config.hour, minute: config.minute, second: 0, of: Date()) ?? Date() }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            update { $0.hour = parts.hour ?? 4; $0.minute = parts.minute ?? 0 }
        }
    }

    var nextRunText: String {
        guard config.autoEnabled else { return "автосохранение выключено" }
        let cal = Calendar.current
        let now = Date()
        var next = cal.date(bySettingHour: config.hour, minute: config.minute, second: 0, of: now) ?? now
        if next <= now { next = cal.date(byAdding: .day, value: 1, to: next) ?? next }
        let t = Fmt.time.string(from: next)
        return cal.isDateInToday(next) ? "следующее сегодня в \(t)" : "следующее завтра в \(t)"
    }

    var lastRunText: String {
        guard let r = status.history.first else { return "ещё не сохранялось" }
        return "\(whenText(r.date).capitalizedFirst) · \(r.trigger.title)"
    }

    func saveNow() {
        guard !busy else { return }
        busy = true
        let c = config
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Exporter(config: c, trigger: .manual).run()
            DispatchQueue.main.async {
                self.busy = false
                self.status = r.status
                if r.message == "Сохранение уже идёт" { self.alert("Сохранение уже идёт", "Подождите, пока закончится текущее сохранение.") }
            }
        }
    }

    func checkFormat() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Exporter.checkFormat(self.config)
            DispatchQueue.main.async {
                self.busy = false
                self.alert("Проверка формата", text)
            }
        }
    }

    // Программа, в которой открывать архив. id: "finder", "obsidian", bundle id или путь к .app (добавлена вручную).
    struct OpenTarget: Identifiable, Hashable {
        let id: String
        let name: String
        let app: URL?

        // Для кнопки: длинные названия — короче (рядом значок, программа и так узнаётся).
        var short: String {
            switch id {
            case "com.microsoft.VSCode": return "VS Code"
            case "info.filesmanager.Files": return "Commander"
            case "com.apple.Terminal": return "Терминале"
            default: return name
            }
        }

        // Значок — как его показывает система, с заменами пользователя; берётся заново при каждом показе.
        var icon: NSImage {
            let image = (app.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(size: NSSize(width: 16, height: 16))).copy() as! NSImage
            image.size = NSSize(width: 16, height: 16)
            return image
        }
    }

    // Известные программы, которые открывают папку целиком; в списке — только установленные.
    static let folderApps = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
        "com.sublimetext.4", "com.coteditor.CotEditor", "com.barebones.bbedit", "abnerworks.Typora",
        "info.filesmanager.Files", "com.binarynights.ForkLift", "com.binarynights.ForkLift-3", "org.yanex.marta",
        "com.eltima.cmd1", "com.apple.Terminal", "com.googlecode.iterm2"
    ]

    var openTargets: [OpenTarget] {
        let ws = NSWorkspace.shared
        var list = [OpenTarget(id: "finder", name: "Finder", app: ws.urlForApplication(withBundleIdentifier: "com.apple.finder"))]
        if case .vault = obsidianState {
            list.append(OpenTarget(id: "obsidian", name: "Obsidian", app: ws.urlForApplication(withBundleIdentifier: "md.obsidian")))
        }
        for id in Self.folderApps {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                list.append(OpenTarget(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), app: url))
            }
        }
        for path in config.customApps where FileManager.default.fileExists(atPath: path) && !list.contains(where: { $0.app?.path == path }) {
            list.append(OpenTarget(id: path, name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""), app: URL(fileURLWithPath: path)))
        }
        return list
    }

    // Выбранная программа; если её удалили или архив ушёл из хранилища — Obsidian/Finder по умолчанию.
    var openTarget: OpenTarget {
        let list = openTargets
        if let id = config.openWith, let t = list.first(where: { $0.id == id }) { return t }
        return list.first(where: { $0.id == "obsidian" }) ?? list[0]
    }

    func openArchive() {
        let url = config.archiveURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let target = openTarget
        switch target.id {
        case "obsidian":
            openInObsidian()
        case "finder":
            NSWorkspace.shared.open(url)
        default:
            guard let app = target.app else { NSWorkspace.shared.open(url); return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    self.alert("Не открылось в \(target.name)", "Похоже, эта программа не умеет открывать папки. Выберите другую в «Подробностях» → «Папка архива».")
                }
            }
        }
    }

    func chooseOpenApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Выбрать"
        panel.message = "Программа, в которой открывать архив"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = Bundle(url: url)?.bundleIdentifier
        update {
            if let id, Self.folderApps.contains(id) || id == "com.apple.finder" || id == "md.obsidian" {
                $0.openWith = id == "com.apple.finder" ? "finder" : (id == "md.obsidian" ? "obsidian" : id)
            } else {
                if !$0.customApps.contains(url.path) { $0.customApps.append(url.path) }
                $0.openWith = url.path
            }
        }
    }

    func openJournal() {
        let url = config.archiveURL.appendingPathComponent("Журнал сохранений.md")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            alert("Журнал пока пуст", "Он появится после первого сохранения.")
        }
    }

    // Obsidian: архив в хранилище → открыть журнал в нём; иначе — подсказка.
    enum ObsidianState { case vault(String), notVault, notInstalled }

    var obsidianState: ObsidianState {
        if let vault = Obsidian.vault(containing: config.archiveURL) { return .vault(vault) }
        let installed = URL(string: "obsidian://").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
        return installed ? .notVault : .notInstalled
    }

    func openInObsidian() {
        // Значение экранируем полностью: в путях бывают пробелы, «&», «+», «#».
        func encode(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")) ?? s
        }
        let journal = config.archiveURL.appendingPathComponent("Журнал сохранений.md")
        var link = "obsidian://open"
        if FileManager.default.fileExists(atPath: journal.path) {
            link += "?path=" + encode(journal.path)
        } else if case .vault(let vault) = obsidianState {
            link += "?vault=" + encode((vault as NSString).lastPathComponent)
        }
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func chooseObsidianVault() {
        if let url = URL(string: "obsidian://choose-vault") { NSWorkspace.shared.open(url) }
    }

    func downloadObsidian() {
        if let url = URL(string: "https://obsidian.md/download") { NSWorkspace.shared.open(url) }
    }

    func chooseFolder(setup: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Папка, куда сохранять историю переписок"
        panel.directoryURL = URL(fileURLWithPath: setup ? setupPath : config.archiveURL.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if setup { setupPath = url.path } else { update { $0.archivePath = url.path } }
    }

    func finishSetup() {
        update {
            $0.archivePath = setupPath
            $0.setupDone = true
        }
        if !loginEnabled { setLogin(true) }
        saveNow()
    }

    func setLogin(_ on: Bool) {
        if let error = LoginItem.set(on) { alert("Не удалось изменить автозапуск", error) }
        loginEnabled = LoginItem.isEnabled
        update { $0.loginWanted = on }
    }

    // macOS сбрасывает автозапуск, если программу пересобрали или перенесли — включаем снова.
    func restoreLogin() {
        guard config.loginWanted == true, !LoginItem.isEnabled else { return }
        _ = LoginItem.set(true)
        loginEnabled = LoginItem.isEnabled
    }

    func extendRetention() {
        if let error = ClaudeRetention.extend() { alert("Не удалось изменить настройку Claude Code", error) }
        retentionDays = ClaudeRetention.days
    }

    func writeAuthor(about problem: String) {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = "samo.zlo.spb@gmail.com"
        c.queryItems = [URLQueryItem(name: "subject", value: "Бэкап ИИ: проблема"),
                        URLQueryItem(name: "body", value: "\(problem)\n\nЖурнал: \(status.history.first?.summary ?? "")\n")]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    // Программы, которые нашлись на этом Mac (или уже что-то сохранили) — для карточек.
    var visibleSources: [SourceStatus] {
        status.sources.filter { $0.kind != "mirror" && (($0.found == true && $0.level != .none) || $0.sessions > 0) }
    }

    func source(_ kind: SourceKind) -> SourceStatus? { status.sources.first { $0.kind == kind.rawValue } }

    func setSource(_ kind: SourceKind, on: Bool) {
        update { c in
            c.disabledSources.removeAll { $0 == kind.rawValue }
            if !on { c.disabledSources.append(kind.rawValue) }
        }
    }

    // Новый путь проверяем сразу: нашлись ли там переписки этой программы.
    func changePath(_ kind: SourceKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = "Выбрать"
        panel.message = "Папка, где \(kind.title) хранит переписки"
        panel.directoryURL = URL(fileURLWithPath: config.path(kind)).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var test = config
        test.sourcePaths[kind.rawValue] = url.path
        let scan = Exporter.scan(kind, test)
        if scan.found && !scan.refs.isEmpty {
            update { $0.sourcePaths[kind.rawValue] = url.path }
            alert("\(kind.title): ✅ найдено", "\(scan.refs.count) \(plural(scan.refs.count, "переписка", "переписки", "переписок")). Они сохранятся при следующем сохранении.")
        } else {
            let a = NSAlert()
            a.messageText = "\(kind.title): ❌ здесь нет переписок"
            a.informativeText = "В папке \(Fmt.shortPath(url.path)) не найдено переписок \(kind.title). Всё равно использовать её?"
            a.addButton(withTitle: "Отмена")
            a.addButton(withTitle: "Использовать")
            if a.runModal() == .alertSecondButtonReturn { update { $0.sourcePaths[kind.rawValue] = url.path } }
        }
    }

    func resetPath(_ kind: SourceKind) { update { $0.sourcePaths.removeValue(forKey: kind.rawValue) } }

    func importExport(_ url: URL? = nil) {
        var file = url
        if file == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
            panel.allowedContentTypes = [.zip, .json, .folder]
            panel.prompt = "Импортировать"
            panel.message = "Скачанный экспорт claude.ai или ChatGPT (ZIP-архив или распакованная папка)"
            panel.directoryURL = Paths.home.appendingPathComponent("Downloads")
            guard panel.runModal() == .OK else { return }
            file = panel.url
        }
        guard let file else { return }
        busy = true
        let c = config
        DispatchQueue.global(qos: .userInitiated).async {
            let r = WebImport.run(file)
            let saved = r.ok ? Exporter(config: c, trigger: .manual).run() : nil
            DispatchQueue.main.async {
                self.busy = false
                if let saved { self.status = saved.status }
                self.alert(r.ok ? "Экспорт импортирован" : "Не получилось импортировать", r.message + (saved.map { "\nСохранение: \($0.message)" } ?? ""))
            }
        }
    }

    func exportHelp() {
        alert("Как скачать экспорт",
              "claude.ai: сайт или Claude Desktop → Настройки → Конфиденциальность → Export data. Ссылка придёт на почту, действует 24 часа.\n\nChatGPT: Settings → Data controls → Export data. Письмо может прийти не сразу (до 7 дней), ссылка действует 24 часа.\n\nСкачанный ZIP перетащите в окно программы или нажмите «Импортировать экспорт…». Повторный импорт добавляет новое, старое не теряется.")
    }

    func addMDFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Добавить"
        panel.message = "Папка, куда вы сохраняете экспорты чатов в .md (Cursor, Windsurf и другие)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let a = NSAlert()
        a.messageText = "Как назвать эту папку в архиве?"
        a.informativeText = "Так будет называться раздел в «История ИИ»."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = url.lastPathComponent
        a.accessoryView = field
        a.addButton(withTitle: "Добавить")
        a.addButton(withTitle: "Отмена")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? url.lastPathComponent : field.stringValue
        update { c in
            c.mdFolders.removeAll { $0.path == url.path }
            c.mdFolders.append(MDFolder(name: name, path: url.path))
        }
    }

    func removeMDFolder(_ f: MDFolder) { update { $0.mdFolders.removeAll { $0.path == f.path } } }

    func chooseMirror() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Вторая папка для копии архива: внешний диск или папка облака"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.path.hasPrefix(config.archiveURL.path) {
            alert("Эта папка внутри архива", "Выберите папку вне «\(config.archiveURL.lastPathComponent)» — иначе копия будет копировать саму себя.")
            return
        }
        update { $0.mirrorPath = url.appendingPathComponent("История ИИ (копия)").path }
    }

    func clearMirror() { update { $0.mirrorPath = nil } }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "Понятно")
        a.runModal()
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Что случилось и что делать

enum FixAction { case save, folder, journal, author, check }

struct Advice {
    var what: String
    var todo: String
    var actions: [FixAction]
}

// Переводит запись о проблеме в понятное объяснение. Набор известных случаев — по тексту, который пишет Exporter.
func advice(for status: AppStatus) -> Advice? {
    guard status.level == .warn || status.level == .err else { return nil }
    let summary = status.history.first?.summary ?? ""
    let source = status.sources.first { $0.level == .err || $0.level == .warn }?.name ?? "Claude Code или Codex"
    if summary.contains("Нет доступа к папке архива") {
        return Advice(what: "Программа не смогла записать файлы в папку архива.",
                      todo: "Проверьте, что папка существует и диск подключён. Если macOS спрашивала доступ к «Документам» — разрешите: Системные настройки → Конфиденциальность и безопасность → Файлы и папки → «Бэкап ИИ». Или выберите другую папку.",
                      actions: [.folder, .save])
    }
    if summary.contains("формат не понятен") {
        return Advice(what: "\(source) изменил формат файлов переписок — скорее всего, после обновления. Уже сохранённый архив цел, но новые переписки не сохраняются.",
                      todo: "Программу нужно поправить под новый формат. Напишите автору или попросите ИИ-помощника в папке проекта: «Бэкап ИИ: формат не понятен, поправь Sources/Exporter.swift».",
                      actions: [.check, .journal, .author])
    }
    if summary.contains("не извлечён текст") {
        return Advice(what: "Часть переписок \(source) не удалось прочитать — их формат отличается от привычного. Остальные сохраняются.",
                      todo: "Если повторяется несколько дней — программу нужно поправить под новый формат. Напишите автору или попросите ИИ-помощника поправить Sources/Exporter.swift.",
                      actions: [.check, .journal, .author])
    }
    if summary.contains("zstd") {
        return Advice(what: "Старые сжатые сессии Codex пропущены: на Mac нет утилиты zstd.",
                      todo: "Установите её в Терминале командой «brew install zstd» и нажмите «Сохранить снова». Новые сессии сохраняются и без неё.",
                      actions: [.save, .journal])
    }
    if summary.contains("нечитаемых строк") {
        return Advice(what: "В файле переписки есть недописанные строки — обычно это сессия, которая шла в момент сохранения.",
                      todo: "Обычно ничего делать не нужно: при следующем сохранении всё прочитается. Если повторяется несколько дней — нажмите «Проверить формат».",
                      actions: [.save, .check])
    }
    if summary.contains("упрощённым способом") {
        return Advice(what: "\(source) обновился и изменил формат. Переписки всё равно сохранены — запасным способом, текст на месте.",
                      todo: "Ничего срочного. Чтобы вернуть точный разбор, напишите автору или попросите ИИ-помощника поправить Sources/Readers.swift под новую версию.",
                      actions: [.check, .journal, .author])
    }
    if summary.contains("не прочитано") || summary.contains("базы Codex") || summary.contains("база Codex") || summary.contains("базы Hermes") || summary.contains("база Hermes") {
        return Advice(what: "Часть переписок \(source) не удалось прочитать. Они не потеряны — программа пробует снова при каждом сохранении.",
                      todo: "Нажмите «Проверить формат». Если повторяется несколько дней — напишите автору или попросите ИИ-помощника поправить разбор этого источника.",
                      actions: [.check, .journal, .author])
    }
    if summary.contains("папка для копии недоступна") || summary.contains("копию архива") || summary.contains("папки копии") {
        return Advice(what: "Копия архива не обновилась: папка для копии недоступна.",
                      todo: "Подключите диск с копией или выберите другую папку в «Копия архива». Основной архив в порядке.",
                      actions: [.save])
    }
    if summary.contains("папка не найдена") {
        return Advice(what: "Одна из папок с экспортами .md недоступна.",
                      todo: "Подключите диск или уберите эту папку в разделе «Папки с экспортами .md». Остальное сохраняется.",
                      actions: [.save])
    }
    if summary.contains("переписки не найдены") {
        return Advice(what: "\(source) установлен, но переписок в нём нет.",
                      todo: "Если вы им не пользуетесь — всё в порядке, ничего делать не нужно.",
                      actions: [.save])
    }
    return Advice(what: summary.isEmpty ? "Последнее сохранение прошло с ошибкой." : summary,
                  todo: "Нажмите «Проверить формат» и посмотрите журнал. Если непонятно — напишите автору.",
                  actions: [.check, .journal, .author])
}

struct ProblemCard: View {
    @ObservedObject var vm: ViewModel
    var advice: Advice

    var color: Color { Palette.level(vm.status.level) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(vm.status.level.mark) Что случилось").font(.bellota(17)).foregroundColor(color)
            Text(advice.what).font(.bellota(15, bold: false)).fixedSize(horizontal: false, vertical: true)
            Text("Что делать").font(.bellota(17)).padding(.top, 4)
            Text(advice.todo).font(.bellota(15, bold: false)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(advice.actions, id: \.self) { a in
                    Button(title(a)) { run(a) }.buttonStyle(GlassButtonStyle(accent: a == .save, height: 34))
                }
            }
            .disabled(vm.busy)
            .padding(.top, 4)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.6)))
    }

    func title(_ a: FixAction) -> String {
        switch a {
        case .save: return vm.busy ? "Сохраняю…" : "Сохранить снова"
        case .folder: return "Изменить папку…"
        case .journal: return "Журнал"
        case .author: return "Написать автору"
        case .check: return "Проверить формат"
        }
    }

    func run(_ a: FixAction) {
        switch a {
        case .save: vm.saveNow()
        case .folder: vm.chooseFolder(setup: false)
        case .journal: vm.openJournal()
        case .author: vm.writeAuthor(about: advice.what)
        case .check: vm.checkFormat()
        }
    }
}

// MARK: - Окна

struct RootView: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 26).fill(Palette.window)
            RoundedRectangle(cornerRadius: 26).strokeBorder(Palette.border, lineWidth: 2)
            Group {
                if !vm.config.setupDone {
                    SetupView(vm: vm)
                } else if vm.expanded {
                    DetailView(vm: vm)
                } else {
                    CompactView(vm: vm)
                }
            }
            TrafficLights(close: { vm.onHide?() }, green: {
                guard vm.config.setupDone else { return }
                vm.expanded.toggle()
                vm.onResize?()
            })
            .padding(.leading, 30)
            .padding(.top, 24)
        }
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard vm.config.setupDone, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { vm.importExport(url) } }
            }
            return true
        }
    }
}

struct CompactView: View {
    @ObservedObject var vm: ViewModel

    var sourceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(vm.visibleSources, id: \.name) { s in
                HStack(spacing: 12) {
                    Dot(color: Palette.level(s.level))
                    Text("\(s.name) · \(s.sessions)").font(.bellota(17))
                }
            }
        }
    }

    var glow: Color {
        switch vm.status.level {
        case .warn: return Palette.warn
        case .err: return Palette.err
        default: return Palette.purple
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: resourceImage("mascot"))
                .resizable().frame(width: 120, height: 120).clipShape(Circle())
                .shadow(color: glow.opacity(0.6), radius: 18)
                .padding(.top, advice(for: vm.status) == nil ? 52 : 40)
            Text(vm.status.headline).font(.bellota(28)).padding(.top, 14)
            Text(vm.lastRunText).font(.bellota(15, bold: false)).foregroundColor(Palette.dim).padding(.top, 4)
            if let a = advice(for: vm.status) {
                Text(a.what + " Что делать — в подробностях.")
                    .font(.bellota(14, bold: false)).foregroundColor(Palette.level(vm.status.level))
                    .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 30).padding(.top, 8)
            }
            // До трёх программ — как было. Больше — тот же список той же высоты, с прокруткой и цветной полосой.
            Group {
                if vm.visibleSources.count > 3 {
                    ThemedScroll {
                        HStack { Spacer(minLength: 0); sourceList; Spacer(minLength: 0) }
                    }
                    .frame(height: 92)
                    .padding(.horizontal, 40)
                } else {
                    sourceList
                }
            }
            .padding(.top, 16)
            VStack(spacing: 12) {
                Button(vm.busy ? "Сохраняю…" : "Сохранить сейчас") { vm.saveNow() }
                    .buttonStyle(GlassButtonStyle(accent: true)).disabled(vm.busy)
                HStack(spacing: 12) {
                    Button("Открыть архив") { vm.openArchive() }.buttonStyle(GlassButtonStyle())
                    Button("Журнал") { vm.openJournal() }.buttonStyle(GlassButtonStyle())
                }
                Button("Подробности и настройки ▾") { vm.expanded = true; vm.onResize?() }
                    .buttonStyle(GlassButtonStyle(dashed: true))
            }
            .padding(.horizontal, 34)
            .padding(.top, 18)
            Spacer(minLength: 0)
            OlegLogo(width: 92) { vm.onAbout?() }.padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SetupView: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: resourceImage("mascot"))
                .resizable().frame(width: 110, height: 110).clipShape(Circle())
                .shadow(color: Palette.purple.opacity(0.6), radius: 18)
                .padding(.top, 48)
            Text("Бэкап ИИ").font(.bellota(28)).padding(.top, 12)
            Text("Сохраняет текст переписок Claude Code и Codex в Markdown по датам — на этом Mac.")
                .font(.bellota(15, bold: false)).foregroundColor(Palette.dim)
                .multilineTextAlignment(.center).padding(.horizontal, 34).padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                Text("Куда сохранять архив").font(.bellota(16))
                Text(Fmt.shortPath(vm.setupPath)).font(.bellota(14, bold: false)).foregroundColor(Palette.dim).lineLimit(2)
                Button("Изменить…") { vm.chooseFolder(setup: true) }.buttonStyle(GlassButtonStyle(height: 34)).padding(.top, 4)
            }
            .padding(.horizontal, 34).padding(.top, 18)
            if ClaudeRetention.installed && vm.retentionDays < ClaudeRetention.wanted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("⚠️ Claude Code удаляет переписки старше \(vm.retentionDays) дн.").font(.bellota(15))
                    Button("Хранить 10 лет") { vm.extendRetention() }.buttonStyle(GlassButtonStyle(height: 34))
                }
                .padding(.horizontal, 34).padding(.top, 14)
            }
            Spacer(minLength: 0)
            Button("Начать") { vm.finishSetup(); vm.onResize?() }
                .buttonStyle(GlassButtonStyle(accent: true)).padding(.horizontal, 34)
            OlegLogo(width: 92) { vm.onAbout?() }.padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity)
    }
}

// Плитка программы для 4 и больше: то же, что в карточке, мельче.
struct SourceTile: View {
    static let height: CGFloat = 80   // постоянная — по ней считается высота блока с прокруткой
    var s: SourceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Dot(color: Palette.level(s.level), size: 9)
                Text(s.name).font(.bellota(15)).lineLimit(1)
            }
            if s.level == .none {
                Text(s.note.capitalizedFirst).font(.bellota(12, bold: false)).foregroundColor(Palette.dim).lineLimit(2).padding(.top, 6)
            } else {
                Text("\(s.sessions)").font(.bellota(24)).padding(.top, 2)
                if s.level == .ok {
                    Text("\(s.newToday) \(plural(s.newToday, "новая", "новых", "новых")) сегодня")
                        .font(.bellota(12, bold: false)).foregroundColor(Palette.dim).lineLimit(1)
                } else {
                    Text("\(s.level.mark) \(s.note.capitalizedFirst)").font(.bellota(12)).foregroundColor(Palette.level(s.level)).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.cardBorder))
    }
}

struct SourceCard: View {
    var s: SourceStatus
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Dot(color: Palette.level(s.level))
                Text(s.name).font(.bellota(19))
            }
            if s.level == .none {
                Text(s.note.capitalizedFirst).font(.bellota(15, bold: false)).foregroundColor(Palette.dim).padding(.top, 12)
            } else {
                Text("\(s.sessions)").font(.bellota(compact ? 30 : 36)).padding(.top, compact ? 4 : 8)
                Text("\(plural(s.sessions, "сессия", "сессии", "сессий")) · \(s.newToday) \(plural(s.newToday, "новая", "новых", "новых")) сегодня")
                    .font(.bellota(15, bold: false)).foregroundColor(Palette.dim).padding(.top, 4)
                Group {
                    if s.level == .ok {
                        Text("Формат понятен ✅")
                    } else {
                        Text("\(s.level.mark) \(s.note.capitalizedFirst)").foregroundColor(Palette.level(s.level))
                    }
                }
                .font(.bellota(15)).lineLimit(2).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 112 : 128, alignment: .topLeading)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.cardBorder))
    }
}

// Откуда программа берёт переписки: найденные пути, смена пути, импорт экспортов, папки .md.
struct SourcesSection: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ИСТОЧНИКИ").font(.bellota(14, bold: false)).tracking(1.2).foregroundColor(Palette.dim).padding(.top, 20).padding(.bottom, 4)
            ForEach(SourceKind.allCases.filter { !$0.isWebExport }) { kind in
                let st = vm.source(kind)
                let on = vm.config.enabled(kind)
                let found = st?.found == true
                HStack(spacing: 10) {
                    Dot(color: !on ? Palette.off : (found ? Palette.level(st?.level == .none ? .ok : (st?.level ?? .ok)) : Palette.off), size: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title + (kind.note.isEmpty ? "" : " · " + kind.note)).font(.bellota(16))
                        Text((found ? "✅ " : "❌ не найдено · ") + Fmt.shortPath(vm.config.path(kind)) + (found && (st?.sessions ?? 0) > 0 ? " · \(st!.sessions)" : ""))
                            .font(.bellota(13, bold: false)).foregroundColor(Palette.dim).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if vm.config.sourcePaths[kind.rawValue] != nil {
                        Button("Сбросить") { vm.resetPath(kind) }.buttonStyle(GlassButtonStyle(height: 30)).frame(width: 96)
                    }
                    Button("Изменить путь…") { vm.changePath(kind) }.buttonStyle(GlassButtonStyle(height: 30)).frame(width: 176)
                    Toggle("", isOn: Binding(get: { on }, set: { vm.setSource(kind, on: $0) }))
                        .toggleStyle(.switch).labelsHidden().tint(Palette.purple)
                }
                .padding(.vertical, 7)
                .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
            }

            SettingRow(title: "Экспорты claude.ai и ChatGPT",
                       subtitle: webSubtitle) {
                HStack(spacing: 8) {
                    Button("Как скачать?") { vm.exportHelp() }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 130)
                    Button("Импортировать экспорт…") { vm.importExport() }.buttonStyle(GlassButtonStyle(accent: true, height: 32)).frame(width: 236)
                        .help("Можно просто перетащить скачанный ZIP в окно программы")
                }
            }
            HStack(spacing: 10) {
                CheckBox(on: Binding(get: { vm.config.exportReminder }, set: { v in vm.update { $0.exportReminder = v } }))
                Text("Раз в месяц напоминать скачать экспорт с сайтов").font(.bellota(16))
                Spacer()
            }
            .padding(.vertical, 11)
            .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Папки с экспортами .md").font(.bellota(16))
                        Text("Cursor, Windsurf и другие программы: укажите, куда сохраняете их чаты в .md или .txt").font(.bellota(13, bold: false)).foregroundColor(Palette.dim)
                    }
                    Spacer()
                    Button("+ Добавить папку…") { vm.addMDFolder() }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 190)
                }
                ForEach(vm.config.mdFolders) { f in
                    HStack(spacing: 10) {
                        Dot(color: dirExists(f.path) ? Palette.ok : Palette.warn, size: 10)
                        Text("\(f.name) · \(Fmt.shortPath(f.path))").font(.bellota(14, bold: false)).foregroundColor(Palette.dim).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Убрать") { vm.removeMDFolder(f) }.buttonStyle(GlassButtonStyle(height: 28)).frame(width: 90)
                    }
                }
            }
            .padding(.vertical, 8)
            .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
        }
    }

    var webSubtitle: String {
        let parts = [SourceKind.claudeai, .chatgpt].map { k -> String in
            let n = vm.source(k)?.sessions ?? 0
            return n > 0 ? "\(k.title): \(n)" : "\(k.title): не импортирован"
        }
        return parts.joined(separator: " · ")
    }
}

struct SettingRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var note: AnyView? = nil     // третья строка под подписью (подсказка или ссылка)
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.bellota(16))
                if let subtitle { Text(subtitle).font(.bellota(13, bold: false)).foregroundColor(Palette.dim) }
                if let note { note }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 8)
        .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
    }
}

// «Открыть в …» + ▾ со списком программ (галочка — у выбранной).
struct OpenWithButton: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        let targets = vm.openTargets
        let current = vm.openTarget
        HStack(spacing: 4) {
            // Ширина — по тексту, от 196 до 300; длиннее — многоточие в конце.
            Button { vm.openArchive() } label: {
                HStack(spacing: 8) {
                    Image(nsImage: current.icon).resizable().frame(width: 16, height: 16)
                    Text("Открыть в \(current.short)").truncationMode(.tail)
                }
                .padding(.horizontal, 16)
            }
            .buttonStyle(GlassButtonStyle(height: 32))
            .frame(minWidth: 196, maxWidth: 300)
            .fixedSize()
            Menu {
                Picker("", selection: Binding(get: { current.id }, set: { id in vm.update { $0.openWith = id } })) {
                    ForEach(targets) { t in
                        Label { Text(t.name) } icon: { Image(nsImage: t.icon) }.tag(t.id)
                    }
                }
                .pickerStyle(.inline).labelsHidden()
                Divider()
                Button("Другая программа…") { vm.chooseOpenApp() }
            } label: {
                Text("▾").font(.bellota(14)).foregroundColor(.white)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 26, height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.button))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.buttonBorder, lineWidth: 1))
            .help("Выбрать программу для архива")
        }
    }
}

struct DetailView: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: resourceImage("mascot")).resizable().frame(width: 58, height: 58).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Бэкап ИИ").font(.bellota(30))
                    Text("\(vm.status.level.mark) \(vm.status.headline) · \(vm.lastRunText.lowercased()) · \(vm.nextRunText)")
                        .font(.bellota(15, bold: false)).foregroundColor(Palette.dim).lineLimit(1)
                }
                Spacer()
                Button("Свернуть ▴") { vm.expanded = false; vm.onResize?() }
                    .buttonStyle(GlassButtonStyle()).frame(width: 130)
            }
            .padding(.top, 50)

            // До трёх программ — большие карточки, как было. Больше — плитки по 4: два ряда помещаются целиком,
            // с третьего — прокрутка в блоке той же высоты, чтобы сохранения и настройки не уезжали вниз.
            Group {
                if vm.visibleSources.count > 3 {
                    let tiles = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(vm.visibleSources, id: \.name) { SourceTile(s: $0) }
                    }
                    if vm.visibleSources.count > 8 {
                        ThemedScroll { tiles.padding(.trailing, 16) }
                            .frame(height: SourceTile.height * 2 + 10)
                    } else {
                        tiles
                    }
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: max(1, vm.visibleSources.count)), spacing: 14) {
                        ForEach(vm.visibleSources, id: \.name) { SourceCard(s: $0, compact: vm.visibleSources.count > 2) }
                    }
                }
            }
            .padding(.top, 16)

            if let a = advice(for: vm.status) {
                ProblemCard(vm: vm, advice: a).padding(.top, 16)
            } else {
            Text("ПОСЛЕДНИЕ СОХРАНЕНИЯ").font(.bellota(14, bold: false)).tracking(1.2).foregroundColor(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    Image(nsImage: resourceImage("car")).resizable().aspectRatio(contentMode: .fit).frame(width: 170, height: 74)
                        .offset(x: 640, y: -12)
                        .allowsHitTesting(false)
                }
                .padding(.top, 20).zIndex(1)

            VStack(spacing: 0) {
                if vm.status.history.isEmpty {
                    Text("Сохранений ещё не было").font(.bellota(15, bold: false)).foregroundColor(Palette.dim)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                ForEach(Array(vm.status.history.prefix(4).enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 0) {
                        Text(Fmt.dayTime.string(from: r.date)).foregroundColor(Palette.dim).frame(width: 110, alignment: .leading)
                        Text(r.trigger.title).foregroundColor(Palette.dim).frame(width: 190, alignment: .leading)
                        Text("\(r.level.mark) \(r.summary)").lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(.bellota(15, bold: false))
                    .padding(.vertical, 7)
                    .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
                }
            }
            .padding(.top, 8)
            }

            Text("НАСТРОЙКИ").font(.bellota(14, bold: false)).tracking(1.2).foregroundColor(Palette.dim).padding(.top, 20)

            // Настройки прокручиваются, если окно не вмещает всё (например, когда показана проблема).
            ThemedScroll {
            VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "Автосохранение каждый день",
                       subtitle: "Если Mac спал или был выключен — сохранит после пробуждения или входа") {
                HStack(spacing: 14) {
                    Image(nsImage: resourceImage("sloth")).resizable().aspectRatio(contentMode: .fit).frame(height: 54)
                    HStack(spacing: 2) {
                        Picker("", selection: Binding(get: { vm.config.hour }, set: { v in vm.update { $0.hour = v } })) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden().frame(width: 62)
                        Text(":").font(.bellota(16))
                        Picker("", selection: Binding(get: { vm.config.minute }, set: { v in vm.update { $0.minute = v } })) {
                            ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden().frame(width: 62)
                    }
                    .disabled(!vm.config.autoEnabled)
                    Toggle("", isOn: Binding(get: { vm.config.autoEnabled }, set: { v in vm.update { $0.autoEnabled = v } }))
                        .toggleStyle(.switch).labelsHidden().tint(Palette.purple)
                }
            }
            HStack(spacing: 10) {
                CheckBox(on: Binding(get: { vm.loginEnabled }, set: { vm.setLogin($0) }))
                Text("Запускать приложение при входе в macOS").font(.bellota(16))
                Image(nsImage: resourceImage("apple")).resizable().frame(width: 26, height: 26)
                Spacer()
            }
            .padding(.vertical, 9)
            .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
            HStack(spacing: 10) {
                CheckBox(on: Binding(get: { vm.config.notify }, set: { v in vm.update { $0.notify = v } }))
                Text("Уведомлять, если что-то не так").font(.bellota(16))
                Spacer()
            }
            .padding(.vertical, 11)
            .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
            if ClaudeRetention.installed {
                SettingRow(title: "Claude Code хранит переписки: \(vm.retentionDays) \(plural(vm.retentionDays, "день", "дня", "дней"))",
                           subtitle: "По умолчанию 30 дней, потом удаляет их сам") {
                    if vm.retentionDays >= ClaudeRetention.wanted {
                        Text("✅").font(.system(size: 18))
                    } else {
                        Button("Хранить 10 лет") { vm.extendRetention() }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 160)
                    }
                }
            }
            SettingRow(title: "Ваше имя в архиве", subtitle: "Так подписаны ваши сообщения в файлах") {
                TextField("", text: Binding(get: { vm.config.userName }, set: { v in vm.update { $0.userName = v } }))
                    .textFieldStyle(.roundedBorder).font(.bellota(15)).frame(width: 200)
            }
            let obsidian = vm.obsidianState
            SettingRow(title: "Папка архива", subtitle: Fmt.shortPath(vm.config.archiveURL.path).replacingOccurrences(of: "/", with: " › "),
                       note: AnyView(obsidianNote(obsidian))) {
                HStack(spacing: 8) {
                    OpenWithButton(vm: vm)
                    Button("Изменить…") { vm.chooseFolder(setup: false) }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 130)
                }
            }
            SettingRow(title: "Копия архива",
                       subtitle: vm.config.mirrorPath.map { Fmt.shortPath($0).replacingOccurrences(of: "/", with: " › ") } ?? "Не задана — например, внешний диск или папка облака") {
                HStack(spacing: 8) {
                    if vm.config.mirrorPath != nil {
                        Button("Убрать") { vm.clearMirror() }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 90)
                    }
                    Button("Выбрать…") { vm.chooseMirror() }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 130)
                }
            }

            SourcesSection(vm: vm)
            }
            .padding(.trailing, 14)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                Button(vm.busy ? "Подождите…" : "Сохранить сейчас") { vm.saveNow() }.buttonStyle(GlassButtonStyle(accent: true))
                Button("Проверить формат") { vm.checkFormat() }.buttonStyle(GlassButtonStyle())
                Button("Открыть архив") { vm.openArchive() }.buttonStyle(GlassButtonStyle())
                Button("Журнал") { vm.openJournal() }.buttonStyle(GlassButtonStyle())
            }
            .disabled(vm.busy)
            .padding(.top, 14)

            HStack { Spacer(); OlegLogo(width: 100) { vm.onAbout?() }; Spacer() }.padding(.top, 8).padding(.bottom, 12)
        }
        .padding(.horizontal, 34)
    }

    @ViewBuilder private func obsidianNote(_ state: ViewModel.ObsidianState) -> some View {
        let link = Color(red: 0.81, green: 0.78, blue: 1)
        switch state {
        case .vault(let vault):
            Text("Хранилище Obsidian «\((vault as NSString).lastPathComponent)»")
                .font(.bellota(13, bold: false)).foregroundColor(link)
        case .notVault:
            HStack(spacing: 4) {
                Text("Чтобы читать в Obsidian, откройте эту папку как хранилище.").foregroundColor(Palette.dim)
                Button("Открыть Obsidian ↗") { vm.chooseObsidianVault() }.buttonStyle(.plain).foregroundColor(link)
            }
            .font(.bellota(13, bold: false))
        case .notInstalled:
            HStack(spacing: 4) {
                Text("Удобно читать в Obsidian, он бесплатный.").foregroundColor(Palette.dim)
                Button("Скачать ↗") { vm.downloadObsidian() }.buttonStyle(.plain).foregroundColor(link)
            }
            .font(.bellota(13, bold: false))
        }
    }
}

// MARK: - Приложение

final class MainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var window: MainWindow!
    private var statusItem: NSStatusItem!
    private let vm = ViewModel()

    static let compact = NSSize(width: 440, height: 600)
    static let detail = NSSize(width: 900, height: 940)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Делегат ставим до запуска — тогда клик по уведомлению откроет нужное окно, даже если программа была закрыта.
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { guard self.window != nil else { return }; self.vm.reloadIfChanged(); self.openDetail() }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestPermission()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { ExportReminder.checkAndNotify() }
        registerFonts()
        buildMainMenu()
        buildStatusItem()
        vm.onResize = { [weak self] in self?.resize(animated: true) }
        vm.onAbout = { [weak self] in self?.showAuthor() }
        vm.onHide = { [weak self] in self?.hideToMenuBar() }

        window = MainWindow(contentRect: NSRect(origin: .zero, size: Self.compact),
                            styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Бэкап ИИ"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        let host = NSHostingView(rootView: RootView(vm: vm))
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = []   // размер окна задаёт программа, а не содержимое
        window.contentView = host
        window.center()
        showWindow()

        // Расписание приводим в порядок при каждом запуске — так переносы программы не ломают его.
        vm.restoreLogin()
        let config = vm.config
        DispatchQueue.global().async { Scheduler.apply(config) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func resize(animated: Bool) {
        var size = vm.config.setupDone && vm.expanded ? Self.detail : Self.compact
        // При проблеме подробное окно выше: в нём объяснение и кнопки для исправления.
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame { size.height = min(size.height, screen.height - 10) }
        var frame = window.frame
        let top = frame.maxY
        let midX = frame.midX
        frame.size = size
        frame.origin = NSPoint(x: midX - size.width / 2, y: top - size.height)
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - size.width)
            frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - size.height)
        }
        window.setFrame(frame, display: true, animate: animated)
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        vm.refreshSystem()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hideToMenuBar() {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideToMenuBar()
        return false
    }

    // MARK: Меню

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Об авторе", action: #selector(showAuthor), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть окно", action: #selector(hideFromMenu), keyEquivalent: "w").target = self
        appMenu.addItem(withTitle: "Выйти из «Бэкап ИИ»", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = resourceImage("menubar")
        image.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Бэкап ИИ"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        vm.reloadIfChanged()
        menu.removeAllItems()
        let head = NSMenuItem(title: "\(vm.status.level.mark) \(vm.status.headline) · \(vm.lastRunText)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        add(menu, vm.busy ? "Сохраняю…" : "Сохранить сейчас", #selector(saveFromMenu))
        add(menu, "Открыть окно", #selector(openCompact))
        add(menu, "Подробности и настройки…", #selector(openDetail))
        add(menu, "Открыть архив", #selector(openArchive))
        add(menu, "Журнал", #selector(openJournal))
        menu.addItem(.separator())
        let auto = add(menu, "Автосохранение: \(vm.config.autoEnabled ? "вкл" : "выкл")", #selector(toggleAuto))
        auto.state = vm.config.autoEnabled ? .on : .off
        add(menu, "Выйти", #selector(NSApplication.terminate(_:)), target: NSApp)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    @objc private func saveFromMenu() { vm.saveNow() }
    @objc private func openArchive() { vm.openArchive() }
    @objc private func openJournal() { vm.openJournal() }
    @objc private func hideFromMenu() { hideToMenuBar() }
    @objc private func toggleAuto() { vm.update { $0.autoEnabled.toggle() } }

    @objc private func openCompact() {
        if vm.expanded { vm.expanded = false; resize(animated: false) }
        showWindow()
    }

    @objc private func openDetail() {
        if vm.config.setupDone && !vm.expanded { vm.expanded = true; resize(animated: false) }
        showWindow()
    }

    // Окно автора — как в «Программе скачивания» и «Windscribe через Tor 2».
    @objc private func showAuthor() {
        let alert = NSAlert()
        alert.icon = resourceImage("mascot")
        alert.messageText = "✕ Разработчик, автор программы ✕"
        alert.informativeText = "ツ  🎱"
        alert.addButton(withTitle: "Написать")

        let emailContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        let email = NSTextField(labelWithString: "")
        email.translatesAutoresizingMaskIntoConstraints = false
        email.alignment = .center
        email.isEditable = false
        email.allowsEditingTextAttributes = true
        email.isSelectable = true
        email.drawsBackground = false
        email.isBezeled = false
        email.focusRingType = .none
        email.attributedStringValue = NSAttributedString(
            string: "samo.zlo.spb@gmail.com",
            attributes: [.link: URL(string: "mailto:samo.zlo.spb@gmail.com")!,
                         .foregroundColor: NSColor.linkColor,
                         .underlineStyle: NSUnderlineStyle.single.rawValue,
                         .font: NSFont.systemFont(ofSize: 14)]
        )
        emailContainer.addSubview(email)
        NSLayoutConstraint.activate([
            email.centerXAnchor.constraint(equalTo: emailContainer.centerXAnchor, constant: 26),
            email.centerYAnchor.constraint(equalTo: emailContainer.centerYAnchor),
            email.widthAnchor.constraint(equalToConstant: 220),
            email.heightAnchor.constraint(equalToConstant: 28)
        ])
        alert.accessoryView = emailContainer
        alert.addButton(withTitle: "Закрыть")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "mailto:samo.zlo.spb@gmail.com") {
            NSWorkspace.shared.open(url)
        }
    }
}
