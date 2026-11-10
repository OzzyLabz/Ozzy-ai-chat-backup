import AppKit
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if Build.demo && (args.contains("--export") || args.contains("--import") || args.contains("--check") || args.contains("--test-notification")) {
            print(tr("Тестовая сборка: сохранение, импорт и проверка отключены."))
            return
        }
        if Build.demo { Demo.ensure() }
        Lang.captureLaunchMenuLanguage()
        Lang.apply(AppConfig.load().language)
        Lang.syncSystemMenus(AppConfig.load().language)
        if args.contains("--check") {
            print(Exporter.checkFormat(AppConfig.load()))
            return
        }
        if args.contains("--test-notification") {
            let ok = Notifier.post(tr("Бэкап ИИ — проверка уведомлений"), tr("Так будет выглядеть сообщение о проблеме. Нажмите, чтобы открыть программу."))
            print(ok ? tr("отправлено от имени программы") : tr("уведомления программе не разрешены — отправлено запасным способом"))
            return
        }
        if let i = args.firstIndex(of: "--import"), i + 1 < args.count {
            let r = WebImport.run(URL(fileURLWithPath: args[i + 1]))
            print(r.message)
            if !r.ok { return }
        }
        if args.contains("--kit") || args.contains("--kit-preview") {
            Headless.kit(args)
            return
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
    // Служебные слова в уже сохранённых файлах — на языке программы (если язык меняли).
    static func syncArchiveLang(_ config: inout AppConfig) {
        guard !Build.demo, let lang = ArchiveLang.ensure(config) else { return }
        config.archiveLang = lang
        var saved = AppConfig.load(); saved.archiveLang = lang; saved.save()
    }

    static func run(_ args: [String]) {
        var config = AppConfig.load()
        syncArchiveLang(&config)
        if !Build.demo, config.pinKitFolder() { var saved = AppConfig.load(); saved.kitFolder = config.kitFolder; saved.save() }
        if let i = args.firstIndex(of: "--archive"), i + 1 < args.count {
            config.archivePath = args[i + 1]
            config.setupDone = true
        }
        if let i = args.firstIndex(of: "--name"), i + 1 < args.count { config.userName = args[i + 1] }
        guard config.setupDone else {
            print(tr("Программа ещё не настроена: откройте её и выберите папку архива."))
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
        print("\(Fmt.full.string(from: Date())) \(trigger.title): \(result.status.level.mark) \(result.status.history.first?.shown ?? result.message)")
        // Навыки и MCP — вместе с переписками, если так выбрано.
        if config.kitEnabled && config.kitWithChats && !Build.demo {
            let st = Kit.run(config, trigger: trigger)
            print(tr("Навыки и MCP") + ": " + (st.history.first.map { $0.shown } ?? ""))
        }
        if auto { ExportReminder.checkAndNotify() }
        if auto, config.notify, result.status.level == .warn || result.status.level == .err {
            let what = advice(for: result.status)?.what ?? result.message
            Notifier.post(tr("Бэкап ИИ") + " — \(result.status.headline.lowercased())", what + tr(" Нажмите, чтобы узнать, что делать."))
        }
    }
}

extension Headless {
    // --kit — сохранить навыки и MCP; --kit-preview — показать, что войдёт, без записи;
    // --kit-folder <папка> — куда сохранять (для проверки); --auto — запуск по своему расписанию навыков.
    static func kit(_ args: [String]) {
        var config = AppConfig.load()
        syncArchiveLang(&config)
        if !Build.demo, config.pinKitFolder() { var saved = AppConfig.load(); saved.kitFolder = config.kitFolder; saved.save() }
        var folder: URL?
        if let i = args.firstIndex(of: "--kit-folder"), i + 1 < args.count { folder = URL(fileURLWithPath: args[i + 1], isDirectory: true) }
        if let i = args.firstIndex(of: "--keys"), i + 1 < args.count { config.kitKeys = args[i + 1] }
        if args.contains("--kit-preview") {
            for (group, lines) in Kit.preview(config) {
                print("\n" + group)
                for l in lines { print("  \(l.icon) \(l.what)" + (l.path.isEmpty ? "" : "   \(l.path)")) }
            }
            return
        }
        if args.contains("--auto") { guard config.kitEnabled, !config.kitWithChats else { return } }
        let st = Kit.run(config, trigger: args.contains("--auto") ? .schedule : .manual, folder: folder)
        for r in st.history.prefix(while: { $0.date == st.lastRun }) { print("\(r.level.mark) \(r.who): \(r.shown)") }
        for a in st.agents { print("  \(a.name): \(a.skills) / MCP \(a.mcp) / \(a.plugins) · \(a.path)") }
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
    // Название прежнее, но шрифт — по языку окна (Bellota, Baloo 2, M PLUS Rounded, ZCOOL KuaiLe).
    static func bellota(_ size: CGFloat, bold: Bool = true) -> Font {
        Font(Lang.nsFont(size, bold: bold))
    }
}

func registerFonts() {
    let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
    for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
}

func resourceImage(_ name: String) -> NSImage {
    if let url = Bundle.main.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) { return img }
    return NSImage(size: NSSize(width: 1, height: 1))
}

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    // Другие языки: в переводе «одна|много» (английский, хинди) или одна форма (китайский, японский).
    if let t = Lang.lookup("\(one)|\(few)|\(many)") {
        let parts = t.components(separatedBy: "|")
        return parts.count > 1 && n != 1 ? parts[1] : parts[0]
    }
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}

// «2 новых сегодня» — целой фразой: в китайском, японском и хинди порядок слов другой.
func newTodayText(_ n: Int) -> String {
    Lang.code == "ru" ? "\(n) \(plural(n, "новая", "новых", "новых")) сегодня" : trf("%d новых сегодня", n)
}

func whenText(_ date: Date) -> String {
    let cal = Calendar.current
    let t = TimeFormat.time(date)
    if cal.isDateInToday(date) { return trf("сегодня в %@", t) }
    if cal.isDateInYesterday(date) { return trf("вчера в %@", t) }
    return TimeFormat.day(date) + tr(" в ") + t
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
                .onHover { inside in
                    hover = inside
                    if inside { NSCursor.arrow.set() }
                }
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
            .help(tr("Об авторе"))
    }
}

struct TrafficLights: View {
    var close: () -> Void
    var green: () -> Void
    var body: some View {
        HStack(spacing: 9) {
            Button(action: close) { Dot(color: Color(red: 1, green: 0.28, blue: 0.27), size: 13) }.buttonStyle(.plain).help(tr("Свернуть в строку меню"))
            Button(action: green) { Dot(color: Color(red: 0.14, green: 0.80, blue: 0.27), size: 13) }.buttonStyle(.plain).help(tr("Подробности"))
        }
    }
}

// Прокрутка с полосой в цветах программы. Полоса видна, только когда содержимое не помещается.
// Ползунок можно тащить мышью, щелчок по дорожке перематывает туда.
final class ScrollHandle { weak var view: NSScrollView? }

struct ScrollFinder: NSViewRepresentable {
    let handle: ScrollHandle
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { handle.view = v.enclosingScrollView }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if handle.view == nil { DispatchQueue.main.async { handle.view = v.enclosingScrollView } }
    }
}

// Область полосы прокрутки: сама принимает нажатие и перетаскивание, поэтому окно (оно двигается за фон) не уезжает.
struct BarDragArea: NSViewRepresentable {
    var onDrag: (_ startY: CGFloat, _ y: CGFloat) -> Void
    var onEnd: () -> Void
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> DragView { let v = DragView(); v.owner = self; return v }
    func updateNSView(_ v: DragView, context: Context) { v.owner = self }

    final class DragView: NSView {
        var owner: BarDragArea?
        private var startY: CGFloat?
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { owner?.onHover(true); NSCursor.arrow.set() }
        override func mouseExited(with event: NSEvent) { owner?.onHover(false) }
        private func y(_ e: NSEvent) -> CGFloat { convert(e.locationInWindow, from: nil).y }
        override func mouseDown(with event: NSEvent) { let p = y(event); startY = p; owner?.onDrag(p, p) }
        override func mouseDragged(with event: NSEvent) { if let s = startY { owner?.onDrag(s, y(event)) } }
        override func mouseUp(with event: NSEvent) { startY = nil; owner?.onEnd() }
    }
}

struct ThemedScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var handle = ScrollHandle()
    @State private var dragStart: CGFloat?
    @State private var hover = false
    static var barWidth: CGFloat { 4 }
    static var thumbGradient: LinearGradient {
        LinearGradient(gradient: Gradient(stops: [
            .init(color: Color(red: 39 / 255, green: 83 / 255, blue: 246 / 255), location: 0),
            .init(color: Color(red: 75 / 255, green: 39 / 255, blue: 246 / 255), location: 0.45),
            .init(color: Color(red: 118 / 255, green: 48 / 255, blue: 246 / 255), location: 0.8),
            .init(color: Color(red: 252 / 255, green: 107 / 255, blue: 230 / 255), location: 1)
        ]), startPoint: .top, endPoint: .bottom)
    }

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
                    .background(ScrollFinder(handle: handle))
            }
            .coordinateSpace(name: "themedScroll")
            .overlay(alignment: .topTrailing) {
                let visible = outer.size.height
                if contentHeight > visible + 1 {
                    let thumb = max(30, visible * visible / contentHeight)
                    let range = contentHeight - visible
                    let progress = min(max(offset / range, 0), 1)
                    ZStack(alignment: .top) {
                        Capsule().fill(Color.white.opacity(hover ? 0.09 : 0.05)).frame(width: Self.barWidth, height: visible)
                        Capsule().fill(Self.thumbGradient)
                            .frame(width: Self.barWidth, height: thumb)
                            .shadow(color: Palette.purple.opacity(0.45), radius: 3)
                            .offset(y: (visible - thumb) * progress)
                    }
                    .frame(width: 14, height: visible, alignment: .top)
                    // Нажатие и перетаскивание ловит своя область: двигается только прокрутка, окно стоит на месте.
                    .overlay(BarDragArea(onDrag: { startY, y in
                        let thumbTop = (visible - thumb) * progress
                        if dragStart == nil {
                            // Нажали на ползунок — тащим за то место, где взяли; на дорожку — перематываем туда.
                            let onThumb = startY >= thumbTop && startY <= thumbTop + thumb
                            dragStart = onThumb ? startY - thumbTop : thumb / 2
                        }
                        let top = min(max(y - (dragStart ?? 0), 0), visible - thumb)
                        scroll(to: (visible - thumb) > 0 ? top / (visible - thumb) * range : 0)
                    }, onEnd: { dragStart = nil }, onHover: { hover = $0 }))
                    .offset(x: 5)
                }
            }
        }
    }

    private func scroll(to y: CGFloat) {
        guard let sv = handle.view, let doc = sv.documentView else { return }
        let maxY = max(doc.frame.height - sv.contentView.bounds.height, 0)
        let target = doc.isFlipped ? min(max(y, 0), maxY) : maxY - min(max(y, 0), maxY)
        sv.contentView.scroll(to: NSPoint(x: sv.contentView.bounds.origin.x, y: target))
        sv.reflectScrolledClipView(sv.contentView)
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
    @Published var tab = 0                      // 0 — «Переписки», 1 — «Навыки и настройки»
    @Published var agents: [DemoAgent] = Build.demo ? Demo.agents(Demo.agentCount) : []
    @Published var kitHistory: [DemoChange] = Build.demo ? Demo.kitHistory(Demo.historyCount) : []
    @Published var showWhat = false
    @Published var message: Message?
    @Published var showAuthor = false
    @Published var kitBusy = false
    let addSourceMenu = MenuActions()
    var onShow: (() -> Void)?
    var onLanguage: (() -> Void)?
    var onBeforeRelaunch: (() -> Void)?
    @Published var updateAvailable = false
    @Published var updateChecking = false
    @Published var lastUpdateCheck: Date?
    @Published var installing: Double = 0
    @Published var updateVersion = ""
    @Published var updateNotes: [String] = []

    func setLanguage(_ v: String) {
        Lang.apply(v)                 // сначала язык, чтобы окно сразу строилось на нём
        Lang.syncSystemMenus(v)       // системные пункты меню macOS — тоже на языке программы (после перезапуска)
        update { $0.language = v }
        onLanguage?()
        objectWillChange.send()
        // Название программы в строке меню, системные пункты меню и системные части окон macOS берёт
        // только при запуске. Поэтому после смены языка программа перезапускается и открывается на том же месте.
        if Lang.menuNeedsRestart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.relaunch() }
        }
    }

    // Перезапуск программы: системные пункты меню macOS переводятся только при запуске.
    func relaunch() {
        onBeforeRelaunch?()   // запомнить, где стоит окно
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let reopen = expanded ? " --args --reopen-details --tab \(tab)" : " --args --reopen"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open '\(path)'" + reopen]
        try? p.run()
        NSApp.terminate(nil)
    }

    // Тестовая сборка: действия, которые в настоящей программе читают или пишут данные, только показывают окошко.
    func demoOnly(_ what: String) {
        alert(tr("Тестовая сборка"), trf("«%@» — в тестовой сборке действие не выполняется. Данные вымышленные, настоящие файлы не трогаются.", tr(what)))
    }

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
        guard config.autoEnabled else { return tr("автосохранение выключено") }
        let cal = Calendar.current
        let now = Date()
        var next = cal.date(bySettingHour: config.hour, minute: config.minute, second: 0, of: now) ?? now
        if next <= now { next = cal.date(byAdding: .day, value: 1, to: next) ?? next }
        let t = TimeFormat.time(next)
        return cal.isDateInToday(next) ? trf("следующее сегодня в %@", t) : trf("следующее завтра в %@", t)
    }

    var lastRunText: String {
        guard let r = status.history.first else { return tr("ещё не сохранялось") }
        return "\(whenText(r.date).capitalizedFirst) · \(r.trigger.title)"
    }

    func saveNow() {
        if Build.demo { demoOnly(tr("Сохранить сейчас")); return }
        guard !busy else { return }
        busy = true
        let c = config
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Exporter(config: c, trigger: .manual).run()
            DispatchQueue.main.async {
                self.busy = false
                self.status = r.status
                if r.message == "Сохранение уже идёт" { self.alert(tr("Сохранение уже идёт"), tr("Подождите, пока закончится текущее сохранение.")) }
            }
        }
    }

    func checkFormat() {
        if Build.demo { demoOnly(tr("Проверить формат")); return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Exporter.checkFormat(self.config)
            DispatchQueue.main.async {
                self.busy = false
                self.alert(tr("Проверка формата"), text)
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
            case "com.apple.Terminal": return tr("Терминале")
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
                    self.alert(trf("Не открылось в %@", target.name), tr("Похоже, эта программа не умеет открывать папки. Выберите другую в «Подробностях» → «Папка архива»."))
                }
            }
        }
    }

    func chooseOpenApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = tr("Выбрать")
        panel.message = tr("Программа, в которой открывать архив")
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

    // «Другая программа…» для папки навыков — как у «Папки архива».
    func chooseKitOpenApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = tr("Выбрать")
        panel.message = tr("Выбрать программу для папки навыков")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = Bundle(url: url)?.bundleIdentifier
        update {
            if let id, Self.folderApps.contains(id) || id == "com.apple.finder" || id == "md.obsidian" {
                $0.kitOpenWith = id == "com.apple.finder" ? "finder" : (id == "md.obsidian" ? "obsidian" : id)
            } else {
                if !$0.customApps.contains(url.path) { $0.customApps.append(url.path) }
                $0.kitOpenWith = url.path
            }
        }
    }

    func openJournal() {
        let url = config.archiveURL.appendingPathComponent(AW.journalFile)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            alert(tr("Журнал пока пуст"), tr("Он появится после первого сохранения."))
        }
    }

    // Obsidian: архив в хранилище → открыть журнал в нём; иначе — подсказка.
    enum ObsidianState { case vault(String), notVault, notInstalled }

    var obsidianState: ObsidianState { obsidianState(for: config.archiveURL) }

    // То же для любой папки (папка навыков показывает подпись так же, как «Папка архива»).
    func obsidianState(for url: URL) -> ObsidianState {
        if let vault = Obsidian.vault(containing: url) { return .vault(vault) }
        let installed = URL(string: "obsidian://").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
        return installed ? .notVault : .notInstalled
    }

    func openInObsidian() {
        // Значение экранируем полностью: в путях бывают пробелы, «&», «+», «#».
        func encode(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")) ?? s
        }
        let journal = config.archiveURL.appendingPathComponent(AW.journalFile)
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
        panel.prompt = tr("Выбрать")
        panel.message = tr("Папка, куда сохранять историю переписок")
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
        if let error = LoginItem.set(on) { alert(tr("Не удалось изменить автозапуск"), error) }
        loginEnabled = LoginItem.isEnabled
        update { $0.loginWanted = on }
    }

    // macOS сбрасывает автозапуск, если программу пересобрали или перенесли — включаем снова.
    func restoreLogin() {
        guard config.loginWanted == true, !LoginItem.isEnabled else { return }
        _ = LoginItem.set(true)
        loginEnabled = LoginItem.isEnabled
    }

    func extendRetention() { setRetention(ClaudeRetention.wanted) }

    func setRetention(_ days: Int) {
        if let error = ClaudeRetention.set(days) { alert(tr("Не удалось изменить настройку Claude Code"), error) }
        retentionDays = ClaudeRetention.days
    }

    func writeAuthor(about problem: String) {
        if Build.demo { demoOnly(tr("Написать автору")); return }
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = "samo.zlo.spb@gmail.com"
        c.queryItems = [URLQueryItem(name: "subject", value: tr("Бэкап ИИ: проблема")),
                        URLQueryItem(name: "body", value: "\(problem)\n\n" + tr("Журнал") + ": \(status.history.first?.summary ?? "")\n")]
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
        if Build.demo { demoOnly(tr("Изменить путь…")); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = tr("Выбрать")
        panel.message = trf("Папка, где %@ хранит переписки", kind.title)
        panel.directoryURL = URL(fileURLWithPath: config.path(kind)).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var test = config
        test.sourcePaths[kind.rawValue] = url.path
        let scan = Exporter.scan(kind, test)
        if scan.found && !scan.refs.isEmpty {
            update { $0.sourcePaths[kind.rawValue] = url.path }
            alert(trf("%@: ✅ найдено", kind.title), "\(scan.refs.count) \(plural(scan.refs.count, "переписка", "переписки", "переписок")). " + tr("Они сохранятся при следующем сохранении."))
        } else {
            let path = url.path
            askNoChats(kind, path) { [weak self] in self?.update { $0.sourcePaths[kind.rawValue] = path } }
        }
    }

    // Окно в стиле программы: в выбранной папке нет переписок — всё равно использовать?
    func askNoChats(_ kind: SourceKind, _ path: String, use: @escaping () -> Void) {
        onShow?()
        message = Message(title: trf("%@: ❌ здесь нет переписок", kind.title),
                          text: trf("В папке %@ не найдено переписок %@. Всё равно использовать её?", Fmt.shortPath(path), kind.title),
                          buttons: [MsgButton(title: tr("Отмена")),
                                    MsgButton(title: tr("Использовать"), accent: true) { _ in use() }])
    }

    // Окно в стиле программы: как назвать папку с экспортами .md в архиве. В поле — имя папки, его можно поменять.
    func askFolderName(_ folderName: String, text: String? = nil, add: @escaping (String) -> Void) {
        onShow?()
        message = Message(title: tr("Как назвать эту папку в архиве?"),
                          text: text ?? tr("Так будет называться раздел в «Истории ИИ»."),
                          buttons: [MsgButton(title: tr("Отмена")),
                                    MsgButton(title: tr("Добавить"), accent: true) { v in
                                        let name = v.trimmingCharacters(in: .whitespaces)
                                        add(name.isEmpty ? folderName : name)
                                    }],
                          field: folderName)
    }

    // «Добавить программу…» в «Источниках»: поддерживаемые программы, которых нет в списке, — выбрать и указать папку.
    func addSourceProgram() {
        if Build.demo { demoOnly(tr("Добавить программу…")); return }
        let shown = Set(visibleSources.compactMap { $0.kind })
        let rest = SourceKind.allCases.filter { !$0.isWebExport && !shown.contains($0.rawValue) }
        guard !rest.isEmpty else {
            alert(tr("Добавить программу"), tr("Все поддерживаемые программы уже в списке. Если программа стоит в необычном месте, нажмите у неё «Изменить путь…»."))
            return
        }
        popMenu(rest.map { k in (k.title, false, { [weak self] in self?.changePath(k) }) }, target: addSourceMenu)
    }

    func resetPath(_ kind: SourceKind) { update { $0.sourcePaths.removeValue(forKey: kind.rawValue) } }

    func importExport(_ url: URL? = nil) {
        if Build.demo { demoOnly(tr("Импортировать экспорт")); return }
        var file = url
        if file == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
            panel.allowedContentTypes = [.zip, .json, .folder]
            panel.prompt = tr("Импортировать")
            panel.message = tr("Скачанный экспорт claude.ai или ChatGPT (ZIP-архив или распакованная папка)")
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
                self.alert(r.ok ? tr("Экспорт импортирован") : tr("Не получилось импортировать"), r.message + (saved.map { "\n" + tr("Сохранение") + ": \($0.message)" } ?? ""))
            }
        }
    }

    func exportHelp() {
        alert(tr("Как скачать экспорт"),
              tr("claude.ai: сайт или Claude Desktop → Настройки → Конфиденциальность → Export data. Ссылка придёт на почту, действует 24 часа.\n\nChatGPT: Settings → Data controls → Export data. Письмо может прийти не сразу (до 7 дней), ссылка действует 24 часа.\n\nСкачанный ZIP перетащите в окно программы или нажмите «Импортировать экспорт…». Повторный импорт добавляет новое, старое не теряется."))
    }

    func addMDFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = tr("Добавить")
        panel.message = tr("Папка, куда вы сохраняете экспорты чатов в .md (Cursor, Windsurf и другие)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        askFolderName(url.lastPathComponent) { [weak self] name in
            self?.update { c in
                c.mdFolders.removeAll { $0.path == path }
                c.mdFolders.append(MDFolder(name: name, path: path))
            }
        }
    }

    func removeMDFolder(_ f: MDFolder) { update { $0.mdFolders.removeAll { $0.path == f.path } } }

    func chooseMirror() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("Выбрать")
        panel.message = tr("Вторая папка для копии архива: внешний диск или папка облака")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.path.hasPrefix(config.archiveURL.path) {
            alert(tr("Эта папка внутри архива"), trf("Выберите папку вне «%@» — иначе копия будет копировать саму себя.", config.archiveURL.lastPathComponent))
            return
        }
        update { $0.mirrorPath = url.appendingPathComponent("История ИИ (копия)").path }
    }

    func clearMirror() { update { $0.mirrorPath = nil } }

    // Сообщение — в окне программы, её шрифтом и цветами (не системное окно macOS).
    func alert(_ title: String, _ text: String) {
        onShow?()
        message = Message(title: title, text: text)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Что случилось и что делать

enum FixAction { case save, folder, journal, author, check, path }

struct Advice {
    var what: String
    var todo: String
    var actions: [FixAction]
}

// Переводит запись о проблеме в понятное объяснение. Набор известных случаев — по тексту, который пишет Exporter.
func advice(for status: AppStatus) -> Advice? {
    guard status.level == .warn || status.level == .err else { return nil }
    let summary = status.history.first?.summary ?? ""
    let source = status.sources.first { $0.level == .err || $0.level == .warn }?.name ?? tr("Claude Code или Codex")
    if summary.contains("Нет доступа к папке архива") {
        return Advice(what: tr("Программа не смогла записать файлы в папку архива."),
                      todo: tr("Проверьте, что папка существует и диск подключён. Если macOS спрашивала доступ к «Документам» — разрешите: Системные настройки → Конфиденциальность и безопасность → Файлы и папки → «Бэкап ИИ». Или выберите другую папку."),
                      actions: [.folder, .save])
    }
    if summary.contains("формат не понятен") {
        return Advice(what: trf("%@ изменил формат файлов переписок — скорее всего, после обновления. Уже сохранённый архив цел, но новые переписки не сохраняются.", source),
                      todo: tr("Программу нужно поправить под новый формат. Напишите автору или попросите ИИ-помощника в папке проекта: «Бэкап ИИ: формат не понятен, поправь Sources/Exporter.swift»."),
                      actions: [.check, .journal, .author])
    }
    if summary.contains("не извлечён текст") {
        return Advice(what: trf("Часть переписок %@ не удалось прочитать — их формат отличается от привычного. Остальные сохраняются.", source),
                      todo: tr("Если повторяется несколько дней — программу нужно поправить под новый формат. Напишите автору или попросите ИИ-помощника поправить Sources/Exporter.swift."),
                      actions: [.check, .journal, .author])
    }
    if summary.contains("zstd") {
        return Advice(what: tr("Старые сжатые сессии Codex пропущены: на Mac нет утилиты zstd."),
                      todo: tr("Установите её в Терминале командой «brew install zstd» и нажмите «Сохранить снова». Новые сессии сохраняются и без неё."),
                      actions: [.save, .journal])
    }
    if summary.contains("нечитаемых строк") {
        return Advice(what: tr("В файле переписки есть недописанные строки — обычно это сессия, которая шла в момент сохранения."),
                      todo: tr("Обычно ничего делать не нужно: при следующем сохранении всё прочитается. Если повторяется несколько дней — нажмите «Проверить формат»."),
                      actions: [.save, .check])
    }
    if summary.contains("упрощённым способом") {
        return Advice(what: trf("%@ обновился и изменил формат. Переписки всё равно сохранены — запасным способом, текст на месте.", source),
                      todo: tr("Ничего срочного. Чтобы вернуть точный разбор, напишите автору или попросите ИИ-помощника поправить Sources/Readers.swift под новую версию."),
                      actions: [.check, .journal, .author])
    }
    if summary.contains("не прочитано") || summary.contains("базы Codex") || summary.contains("база Codex") || summary.contains("базы Hermes") || summary.contains("база Hermes") {
        return Advice(what: trf("Часть переписок %@ не удалось прочитать. Они не потеряны — программа пробует снова при каждом сохранении.", source),
                      todo: tr("Нажмите «Проверить формат». Если повторяется несколько дней — напишите автору или попросите ИИ-помощника поправить разбор этого источника."),
                      actions: [.check, .journal, .author])
    }
    if summary.contains("папка для копии недоступна") || summary.contains("копию архива") || summary.contains("папки копии") {
        return Advice(what: tr("Копия архива не обновилась: папка для копии недоступна."),
                      todo: tr("Подключите диск с копией или выберите другую папку в разделе «Копия архива». Основной архив в порядке."),
                      actions: [.save])
    }
    if summary.contains("папка не найдена") {
        return Advice(what: tr("Одна из папок с экспортами .md недоступна."),
                      todo: tr("Подключите диск или уберите эту папку в разделе «Папки с экспортами .md». Остальное сохраняется."),
                      actions: [.save])
    }
    if summary.contains("переписки не найдены") {
        return Advice(what: trf("%@ установлен, но переписок в нём нет.", source),
                      todo: tr("Если вы им не пользуетесь — всё в порядке, ничего делать не нужно."),
                      actions: [.save])
    }
    return Advice(what: summary.isEmpty ? tr("Последнее сохранение прошло с ошибкой.") : summary,
                  todo: tr("Нажмите «Проверить формат» и посмотрите журнал. Если непонятно — напишите автору."),
                  actions: [.check, .journal, .author])
}

struct ProblemCard: View {
    @ObservedObject var vm: ViewModel
    var advice: Advice

    var color: Color { Palette.level(vm.status.level) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(vm.status.level.mark) " + tr("Что случилось")).font(.bellota(17)).foregroundColor(color)
            Text(advice.what).font(.bellota(15, bold: false)).fixedSize(horizontal: false, vertical: true)
            Text(tr("Что делать")).font(.bellota(17)).padding(.top, 4)
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
        case .save: return vm.busy ? tr("Сохраняю…") : tr("Сохранить снова")
        case .folder: return tr("Изменить папку…")
        case .journal: return tr("Журнал")
        case .author: return tr("Написать автору")
        case .check: return tr("Проверить формат")
        case .path: return tr("Изменить путь…")
        }
    }

    func run(_ a: FixAction) {
        switch a {
        case .save: vm.saveNow()
        case .folder: vm.chooseFolder(setup: false)
        case .journal: vm.openJournal()
        case .author: vm.writeAuthor(about: advice.what)
        case .check: vm.checkFormat()
        case .path: vm.demoOnly(tr("Изменить путь…"))
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
            .id(vm.config.language)   // сменили язык — окно строится заново целиком, все надписи на новом языке
            // Пока открыто окно поверх (сообщение, автор, установка), то, что под ним, недоступно и для VoiceOver.
            .accessibilityHidden(vm.message != nil || vm.showAuthor || vm.showWhat || vm.installing > 0)
            TrafficLights(close: { vm.onHide?() }, green: {
                guard vm.config.setupDone else { return }
                vm.expanded.toggle()
                vm.onResize?()
            })
            .padding(.leading, 30)
            .padding(.top, 24)
        }
        .overlay { if vm.installing > 0 { InstallView(vm: vm) } }
        .overlay { if vm.showAuthor { AuthorView(vm: vm) } }
        .overlay { if let m = vm.message { MessageView(vm: vm, msg: m) } }   // сообщение — поверх всего
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
            if vm.updateAvailable {
                LinkButton(title: trf("Доступна версия %@ ›", vm.updateVersion)) { vm.expanded = true; vm.onResize?() }
                    .font(.bellota(14, bold: false)).padding(.top, 6)
            }
            if let a = advice(for: vm.status) {
                Text(a.what + tr(" Что делать — в подробностях."))
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
                Button(vm.busy ? tr("Сохраняю…") : tr("Сохранить сейчас")) { vm.saveNow() }
                    .buttonStyle(GlassButtonStyle(accent: true)).disabled(vm.busy)
                HStack(spacing: 12) {
                    Button(tr("Открыть архив")) { vm.openArchive() }.buttonStyle(GlassButtonStyle())
                    Button(tr("Журнал")) { vm.openJournal() }.buttonStyle(GlassButtonStyle())
                }
                Button(tr("Подробности и настройки ▾")) { vm.expanded = true; vm.onResize?() }
                    .buttonStyle(GlassButtonStyle(dashed: true))
            }
            .padding(.horizontal, 34)
            .padding(.top, 18)
            // Логотип — посередине между кнопками и низом окна.
            OlegLogo(width: 92) { vm.onAbout?() }.frame(maxHeight: .infinity)
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
            Text(tr("Бэкап ИИ")).font(.bellota(28)).padding(.top, 12)
            Text(tr("Сохраняет текст переписок Claude Code и Codex в Markdown по датам — на этом Mac."))
                .font(.bellota(15, bold: false)).foregroundColor(Palette.dim)
                .multilineTextAlignment(.center).padding(.horizontal, 34).padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Куда сохранять архив")).font(.bellota(16))
                Text(Fmt.shortPath(vm.setupPath)).font(.bellota(14, bold: false)).foregroundColor(Palette.dim).lineLimit(2)
                Button(tr("Изменить…")) { vm.chooseFolder(setup: true) }.buttonStyle(GlassButtonStyle(height: 34)).padding(.top, 4)
            }
            .padding(.horizontal, 34).padding(.top, 18)
            if ClaudeRetention.installed && vm.retentionDays < ClaudeRetention.wanted {
                VStack(alignment: .leading, spacing: 6) {
                    Text(trf("⚠️ Claude Code удаляет переписки старше %d дн.", vm.retentionDays)).font(.bellota(15))
                    Button(tr("Хранить 10 лет")) { vm.extendRetention() }.buttonStyle(GlassButtonStyle(height: 34))
                }
                .padding(.horizontal, 34).padding(.top, 14)
            }
            Spacer(minLength: 0)
            Button(tr("Начать")) { vm.finishSetup(); vm.onResize?() }
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
                Text(s.shownNote.capitalizedFirst).font(.bellota(12, bold: false)).foregroundColor(Palette.dim).lineLimit(2).padding(.top, 6)
            } else {
                Text("\(s.sessions)").font(.bellota(24)).padding(.top, 2)
                if s.level == .ok {
                    Text(newTodayText(s.newToday))
                        .font(.bellota(12, bold: false)).foregroundColor(Palette.dim).lineLimit(1)
                } else {
                    MarqueeText(text: "\(s.level.mark) \(s.shownNote.capitalizedFirst)").font(.bellota(12)).foregroundColor(Palette.level(s.level))
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
                Text(s.shownNote.capitalizedFirst).font(.bellota(15, bold: false)).foregroundColor(Palette.dim).padding(.top, 12)
            } else {
                Text("\(s.sessions)").font(.bellota(compact ? 30 : 36)).padding(.top, compact ? 4 : 8)
                Text("\(plural(s.sessions, "сессия", "сессии", "сессий")) · " + newTodayText(s.newToday))
                    .font(.bellota(15, bold: false)).foregroundColor(Palette.dim).padding(.top, 4)
                Group {
                    if s.level == .ok {
                        Text(tr("Формат понятен ✅"))
                    } else {
                        MarqueeText(text: "\(s.level.mark) \(s.shownNote.capitalizedFirst)").foregroundColor(Palette.level(s.level))
                    }
                }
                .font(.bellota(15)).padding(.top, 8)
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
            Text(tr("ИСТОЧНИКИ")).font(.bellota(14, bold: false)).tracking(1.2).foregroundColor(Palette.dim).padding(.top, 20).padding(.bottom, 4)
            ForEach(SourceKind.allCases.filter { k in
                !k.isWebExport && (vm.source(k)?.found == true || vm.config.sourcePaths[k.rawValue] != nil || (vm.source(k)?.sessions ?? 0) > 0)
            }) { kind in
                let st = vm.source(kind)
                let on = vm.config.enabled(kind)
                let found = st?.found == true
                HStack(spacing: 10) {
                    Dot(color: !on ? Palette.off : (found ? Palette.level(st?.level == .none ? .ok : (st?.level ?? .ok)) : Palette.off), size: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title + (kind.note.isEmpty ? "" : " · " + kind.note)).font(.bellota(16))
                        MarqueeText(text: (found ? "✅ " : tr("❌ не найдено · ")) + Fmt.shortPath(vm.config.path(kind)) + (found && (st?.sessions ?? 0) > 0 ? " · \(st!.sessions)" : ""))
                            .font(.bellota(13, bold: false)).foregroundColor(Palette.dim)
                    }
                    Spacer()
                    if vm.config.sourcePaths[kind.rawValue] != nil {
                        Button(tr("Сбросить")) { vm.resetPath(kind) }.buttonStyle(GlassButtonStyle(height: 30)).frame(width: 96)
                    }
                    Button(tr("Изменить путь…")) { vm.changePath(kind) }.buttonStyle(GlassButtonStyle(height: 30)).frame(width: 176)
                    Toggle("", isOn: Binding(get: { on }, set: { vm.setSource(kind, on: $0) }))
                        .toggleStyle(.switch).labelsHidden().tint(Palette.purple)
                }
                .padding(.vertical, 7)
                .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
            }

            HStack {
                Text(tr("Если программа стоит в необычном месте")).font(.bellota(14, bold: false)).foregroundColor(Palette.dim)
                Spacer()
                Button(tr("Добавить программу…")) { vm.addSourceProgram() }.buttonStyle(GlassButtonStyle(accent: true, height: 30)).frame(width: 224) // ширина = «Изменить путь…» (176) + отступ (10) + переключатель (38)
            }
            .padding(.vertical, 9)
            .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)

            SettingRow(title: tr("Экспорты claude.ai и ChatGPT"),
                       subtitle: webSubtitle) {
                HStack(spacing: 8) {
                    Button(tr("Как скачать?")) { vm.exportHelp() }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 130)
                    Button(tr("Импортировать экспорт…")) { vm.importExport() }.buttonStyle(GlassButtonStyle(accent: true, height: 32)).frame(width: 236)
                        .help(tr("Можно просто перетащить скачанный ZIP в окно программы"))
                }
            }
            HStack(spacing: 10) {
                CheckBox(on: Binding(get: { vm.config.exportReminder }, set: { v in vm.update { $0.exportReminder = v } }))
                Text(tr("Раз в месяц напоминать скачать экспорт с сайтов")).font(.bellota(16))
                Spacer()
            }
            .padding(.vertical, 11)
            .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Папки с экспортами .md")).font(.bellota(16))
                        Text(tr("Cursor, Windsurf и другие программы: укажите, куда сохраняете их чаты в .md или .txt")).font(.bellota(13, bold: false)).foregroundColor(Palette.dim)
                    }
                    Spacer()
                    Button(tr("+ Добавить папку…")) { vm.addMDFolder() }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 190)
                }
                ForEach(vm.config.mdFolders) { f in
                    HStack(spacing: 10) {
                        Dot(color: dirExists(f.path) ? Palette.ok : Palette.warn, size: 10)
                        Text("\(f.name) · \(Fmt.shortPath(f.path))").font(.bellota(14, bold: false)).foregroundColor(Palette.dim).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(tr("Убрать")) { vm.removeMDFolder(f) }.buttonStyle(GlassButtonStyle(height: 28)).frame(width: 90)
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
            return n > 0 ? "\(k.title): \(n)" : "\(k.title): " + tr("не импортирован")
        }
        return parts.joined(separator: " · ")
    }
}

struct SettingRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var note: AnyView? = nil     // третья строка под подписью (подсказка или ссылка)
    var badge = false            // метка NEW у новой строки
    var subtitleColor: Color = Palette.dim
    var oneLine = false          // путь: одна строка, не влезло — бегущая строка при наведении
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) { Text(title).font(.bellota(16)); if badge { NewBadge() } }
                if let subtitle {
                    if oneLine { MarqueeText(text: subtitle).font(.bellota(13, bold: false)).foregroundColor(subtitleColor) }
                    else { Text(subtitle).font(.bellota(13, bold: false)).foregroundColor(subtitleColor) }
                }
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
                    Text(trf("Открыть в %@", current.short)).truncationMode(.tail)
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
                Button(tr("Другая программа…")) { vm.chooseOpenApp() }
            } label: {
                Text("▾").font(.bellota(14)).foregroundColor(.white)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 26, height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.button))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.buttonBorder, lineWidth: 1))
            .help(tr("Выбрать программу для архива"))
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
                    HStack(spacing: 10) { Text(tr("Бэкап ИИ")).font(.bellota(30)); if Build.demo || Build.check { TestBadge() } }
                    MarqueeText(text: "\(vm.status.level.mark) \(vm.status.headline) · \(vm.lastRunText.lowercasedFirst) · \(vm.nextRunText)")
                        .font(.bellota(15, bold: false)).foregroundColor(Palette.dim)
                }
                Spacer()
                Button(tr("Свернуть ▴")) { vm.expanded = false; vm.onResize?() }
                    .buttonStyle(GlassButtonStyle()).frame(width: 130)
            }
            .padding(.top, 50)

            TabSwitch(tab: $vm.tab).padding(.top, 14)

            if vm.tab == 0 { chatsTab } else { KitView(vm: vm) }

            HStack { Spacer(); OlegLogo(width: 100) { vm.onAbout?() }; Spacer() }.padding(.top, 12).padding(.bottom, 8)
        }
        .padding(.horizontal, 34)
        .overlay { if vm.showWhat { WhatSheet(vm: vm) } }
    }

    private var chatsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            Text(tr("ПОСЛЕДНИЕ СОХРАНЕНИЯ")).font(.bellota(14, bold: false)).tracking(1.2).foregroundColor(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    Image(nsImage: resourceImage("car")).resizable().aspectRatio(contentMode: .fit).frame(width: 170, height: 74)
                        .offset(x: 640, y: -12)
                        .allowsHitTesting(false)
                }
                .padding(.top, 20).zIndex(1)

            Group {
                if vm.status.history.isEmpty {
                    Text(tr("Сохранений ещё не было")).font(.bellota(15, bold: false)).foregroundColor(Palette.dim)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                } else {
                    HistoryList(count: vm.status.history.count) {
                        ForEach(Array(vm.status.history.enumerated()), id: \.offset) { i, r in
                            HistoryRow(date: r.date, who: r.trigger.title, text: "\(r.level.mark) \(r.shown)", level: r.level,
                                       advice: r.level == .ok ? nil : advice(for: AppStatus(level: r.level, history: [r])),
                                       onFix: { vm.runFix($0, about: r.summary) }, rowID: i, openTitleTrailing: 170)
                        }
                    }
                }
            }
            .padding(.top, 8)
            }

            Text(tr("НАСТРОЙКИ")).font(.bellota(14, bold: false)).tracking(1.2).foregroundColor(Palette.dim).padding(.top, 20)

            // Настройки прокручиваются, если окно не вмещает всё (например, когда показана проблема).
            ThemedScroll {
            VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: tr("Автосохранение каждый день"),
                       subtitle: tr("Если Mac спал или был выключен — сохранит после пробуждения или входа")) {
                HStack(spacing: 10) {
                    Image(nsImage: resourceImage("sloth")).resizable().aspectRatio(contentMode: .fit).frame(height: 54)
                    TimeField(hour: Binding(get: { vm.config.hour }, set: { v in vm.update { $0.hour = v } }),
                              minute: Binding(get: { vm.config.minute }, set: { v in vm.update { $0.minute = v } }))
                        .disabled(!vm.config.autoEnabled)
                    Toggle("", isOn: Binding(get: { vm.config.autoEnabled }, set: { v in vm.update { $0.autoEnabled = v } }))
                        .toggleStyle(.switch).labelsHidden().tint(Palette.purple)
                }
            }
            HStack(spacing: 10) {
                CheckBox(on: Binding(get: { vm.loginEnabled }, set: { vm.setLogin($0) }))
                Text(tr("Запускать приложение при входе в macOS")).font(.bellota(16))
                Image(nsImage: resourceImage("apple")).resizable().frame(width: 26, height: 26)
                Spacer()
            }
            .padding(.vertical, 9)
            .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
            HStack(spacing: 10) {
                CheckBox(on: Binding(get: { vm.config.notify }, set: { v in vm.update { $0.notify = v } }))
                Text(tr("Уведомлять, если что-то не так")).font(.bellota(16))
                Spacer()
            }
            .padding(.vertical, 11)
            .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
            SettingRow(title: tr("Язык интерфейса"), subtitle: tr("Окно, строка меню и уведомления"),
                       note: Lang.menuNeedsRestart ? AnyView(HStack(spacing: 6) {
                           Text(tr("Пункты меню macOS сменят язык после перезапуска")).foregroundColor(Palette.dim)
                           LinkButton(title: tr("Перезапустить")) { vm.relaunch() }
                       }.font(.bellota(13, bold: false))) : nil,
                       badge: true) {
                LanguagePicker(vm: vm)
            }
            UpdatesRow(vm: vm)
            if ClaudeRetention.installed {
                SettingRow(title: tr("Claude Code хранит переписки"),
                           subtitle: tr("По умолчанию 30 дней, потом удаляет их сам. Выбор можно поменять в любой момент")) {
                    PopMenuButton(label: retentionLabel(vm.retentionDays), width: 150, items: [
                        (tr("30 дней"), vm.retentionDays == 30, { vm.setRetention(30) }),
                        (tr("1 год"), vm.retentionDays == 365, { vm.setRetention(365) }),
                        (tr("10 лет"), vm.retentionDays == 3650, { vm.setRetention(3650) })
                    ])
                }
            }
            SettingRow(title: tr("Ваше имя в архиве"), subtitle: tr("Так подписаны ваши сообщения в файлах")) {
                TextField("", text: Binding(get: { vm.config.userName }, set: { v in vm.update { $0.userName = v } }))
                    .textFieldStyle(.roundedBorder).font(.bellota(15)).frame(width: 200)
            }
            let obsidian = vm.obsidianState
            SettingRow(title: tr("Папка архива"), subtitle: Fmt.shortPath(vm.config.archiveURL.path).replacingOccurrences(of: "/", with: " › "),
                       note: AnyView(obsidianNote(obsidian)), oneLine: true) {
                HStack(spacing: 8) {
                    OpenWithButton(vm: vm)
                    Button(tr("Изменить…")) { vm.chooseFolder(setup: false) }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 130)
                }
            }
            SettingRow(title: tr("Копия архива"),
                       subtitle: vm.config.mirrorPath.map { Fmt.shortPath($0).replacingOccurrences(of: "/", with: " › ") } ?? tr("Не задана — например, внешний диск или папка облака"),
                       oneLine: vm.config.mirrorPath != nil) {
                HStack(spacing: 8) {
                    if vm.config.mirrorPath != nil {
                        Button(tr("Убрать")) { vm.clearMirror() }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 90)
                    }
                    Button(tr("Выбрать…")) { vm.chooseMirror() }.buttonStyle(GlassButtonStyle(height: 32)).frame(width: 130)
                }
            }

            SourcesSection(vm: vm)
            }
            .padding(.trailing, 14)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                Button(vm.busy ? tr("Подождите…") : tr("Сохранить сейчас")) { vm.saveNow() }.buttonStyle(GlassButtonStyle(accent: true))
                Button(tr("Проверить формат")) { vm.checkFormat() }.buttonStyle(GlassButtonStyle())
                Button(tr("Открыть архив")) { vm.openArchive() }.buttonStyle(GlassButtonStyle())
                Button(tr("Журнал")) { vm.openJournal() }.buttonStyle(GlassButtonStyle())
            }
            .disabled(vm.busy)
            .padding(.top, 14)
        }
    }

    @ViewBuilder private func obsidianNote(_ state: ViewModel.ObsidianState) -> some View {
        let link = Color(red: 0.81, green: 0.78, blue: 1)
        switch state {
        case .vault(let vault):
            Text(trf("Хранилище Obsidian «%@»", (vault as NSString).lastPathComponent))
                .font(.bellota(13, bold: false)).foregroundColor(link)
        case .notVault:
            HStack(spacing: 6) {
                Text(tr("Не в хранилище Obsidian")).foregroundColor(Palette.dim)
                Text("·").foregroundColor(Palette.dim)
                LinkButton(title: tr("открыть в Obsidian как хранилище")) { vm.chooseObsidianVault() }
            }
            .font(.bellota(13, bold: false)).lineLimit(1)
        case .notInstalled:
            HStack(spacing: 6) {
                Text(tr("Удобно читать в Obsidian, он бесплатный")).foregroundColor(Palette.dim)
                Text("·").foregroundColor(Palette.dim)
                LinkButton(title: tr("скачать")) { vm.downloadObsidian() }
            }
            .font(.bellota(13, bold: false)).lineLimit(1)
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
        // Как в 1.0: разрешение на уведомления и напоминание об экспорте. Тестовая сборка — без них.
        if !Paths.isTest {
            Notifier.requestPermission()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { ExportReminder.checkAndNotify() }
        }
        registerFonts()
        buildMainMenu()
        buildStatusItem()
        vm.onResize = { [weak self] in self?.resize(animated: true) }
        vm.onAbout = { [weak self] in self?.showAuthor() }
        vm.onHide = { [weak self] in self?.hideToMenuBar() }
        vm.onShow = { [weak self] in self?.showWindow() }
        vm.onLanguage = { [weak self] in self?.buildMainMenu(); self?.window?.title = tr("Бэкап ИИ") }
        Updater.shared.start(vm)

        window = MainWindow(contentRect: NSRect(origin: .zero, size: Self.compact),
                            styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        window.title = tr("Бэкап ИИ")
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
        vm.onBeforeRelaunch = { [weak self] in
            guard let w = self?.window else { return }
            UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: "relaunchFrame")
        }
        // Перезапуск после смены языка: открыться там же, где было окно, — те же «Подробности» и вкладка.
        let args = CommandLine.arguments
        if args.contains("--reopen") || args.contains("--reopen-details") {
            if args.contains("--reopen-details") {
                vm.expanded = true
                if let i = args.firstIndex(of: "--tab"), i + 1 < args.count { vm.tab = Int(args[i + 1]) ?? 0 }
                resize(animated: false)
            }
            if let saved = UserDefaults.standard.string(forKey: "relaunchFrame") {
                let f = NSRectFromString(saved)
                window.setFrameTopLeftPoint(NSPoint(x: f.minX, y: f.maxY))
                UserDefaults.standard.removeObject(forKey: "relaunchFrame")
            }
        }
        showWindow()

        // Расписание приводим в порядок при каждом запуске — так переносы программы не ломают его.
        vm.restoreLogin()
        if !Build.demo { vm.update { _ = $0.pinKitFolder() } }
        vm.loadKit()
        // Сменили язык — служебные слова в уже сохранённом переписываются на новый (в фоне; прерванное доделается).
        if !Build.demo {
            let c = vm.config
            DispatchQueue.global(qos: .utility).async {
                guard let lang = ArchiveLang.ensure(c) else { return }
                DispatchQueue.main.async { self.vm.update { $0.archiveLang = lang } }
            }
        }
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
        appMenu.addItem(withTitle: tr("Об авторе"), action: #selector(showAuthor), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Скрыть окно"), action: #selector(hideFromMenu), keyEquivalent: "w").target = self
        appMenu.addItem(withTitle: tr("Выйти из «Бэкап ИИ»"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        if Build.demo {
            // Меню «Тест»: переключение вымышленных данных, чтобы посмотреть все варианты окна.
            let testItem = NSMenuItem()
            let test = NSMenu(title: tr("Тест"))
            func sub(_ title: String, _ items: [(String, Int)], _ action: Selector) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let m = NSMenu(title: title)
                for (t, tag) in items {
                    let i = NSMenuItem(title: t, action: action, keyEquivalent: "")
                    i.tag = tag; i.target = self
                    m.addItem(i)
                }
                item.submenu = m
                test.addItem(item)
            }
            sub(tr("Состояние «Переписок»"), [(tr("Всё в порядке"), 0), (tr("Есть предупреждение"), 1), (tr("Ошибка"), 2)], #selector(demoScenario(_:)))
            sub(tr("Программ в «Переписках»"), [(tr("3 — большие карточки"), 3), (tr("6 — плитки"), 6), (tr("12 — плитки с прокруткой"), 12)], #selector(demoSources(_:)))
            sub(tr("Агентов в «Навыках»"), [(tr("3 — большие карточки"), 3), (tr("5 — как на этом Mac"), 5), (tr("12 — все состояния, с прокруткой"), 12)], #selector(demoAgents(_:)))
            sub(tr("Записей в истории"), [(tr("Пусто"), 0), ("4", 4), ("60", 60)], #selector(demoHistory(_:)))
            test.addItem(.separator())
            test.addItem(withTitle: tr("Окно: «здесь нет переписок»"), action: #selector(demoNoChats), keyEquivalent: "").target = self
            test.addItem(withTitle: tr("Окно: «Как назвать папку»"), action: #selector(demoFolderName), keyEquivalent: "").target = self
            test.addItem(.separator())
            test.addItem(withTitle: tr("Сбросить тестовые данные"), action: #selector(demoReset), keyEquivalent: "").target = self
            testItem.submenu = test
            main.addItem(testItem)
        }

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("Правка"))
        edit.addItem(withTitle: tr("Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: tr("Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Скопировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Выделить всё"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = resourceImage("menubar")
        image.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = image
        statusItem.button?.toolTip = tr("Бэкап ИИ")
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
        add(menu, vm.busy ? tr("Сохраняю…") : tr("Сохранить сейчас"), #selector(saveFromMenu))
        if vm.updateAvailable { add(menu, trf("Доступна версия %@ — установить…", vm.updateVersion), #selector(installFromMenu)) }
        add(menu, tr("Открыть окно"), #selector(openCompact))
        add(menu, tr("Подробности и настройки…"), #selector(openDetail))
        add(menu, tr("Открыть архив"), #selector(openArchive))
        add(menu, tr("Журнал"), #selector(openJournal))
        menu.addItem(.separator())
        let auto = add(menu, trf("Автосохранение: %@", vm.config.autoEnabled ? tr("вкл") : tr("выкл")), #selector(toggleAuto))
        auto.state = vm.config.autoEnabled ? .on : .off
        add(menu, tr("Выйти"), #selector(NSApplication.terminate(_:)), target: NSApp)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    @objc private func demoScenario(_ sender: NSMenuItem) { Demo.scenario = sender.tag; demoApply() }
    @objc private func demoSources(_ sender: NSMenuItem) { Demo.sourceCount = sender.tag; demoApply() }
    @objc private func demoAgents(_ sender: NSMenuItem) { Demo.agentCount = sender.tag; vm.agents = Demo.agents(sender.tag) }
    @objc private func demoHistory(_ sender: NSMenuItem) {
        Demo.historyCount = sender.tag
        vm.kitHistory = Demo.kitHistory(sender.tag)
        demoApply()
    }
    @objc private func demoNoChats() {
        showWindow()
        vm.askNoChats(.codex, NSHomeDirectory() + "/Documents/Пример") {}
    }

    @objc private func demoFolderName() {
        showWindow()
        vm.askFolderName("Cursor exports") { _ in }
    }

    @objc private func demoReset() {
        Demo.reset()
        vm.config = AppConfig.load()
        vm.agents = Demo.agents(Demo.agentCount)
        vm.kitHistory = Demo.kitHistory(Demo.historyCount)
        demoApply()
    }
    private func demoApply() {
        Demo.writeStatus()
        vm.status = AppStatus.load()
        resize(animated: false)
    }

    @objc private func saveFromMenu() { vm.saveNow() }
    @objc private func installFromMenu() { showWindow(); vm.installUpdate() }
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

    // Окно автора — в стиле программы (AuthorView в Kit.swift).
    @objc private func showAuthor() {
        showWindow()
        vm.showAuthor = true
    }
}
