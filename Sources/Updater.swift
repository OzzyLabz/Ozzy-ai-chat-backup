import AppKit
import Sparkle

// Обновления через Sparkle, но окна — свои, в стиле программы (Sparkle только проверяет, качает, проверяет подпись и ставит).
final class Updater: NSObject, SPUUserDriver {
    static let shared = Updater()
    private weak var vm: ViewModel?
    private var updater: SPUUpdater?
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var expected: UInt64 = 0
    private var received: UInt64 = 0

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    func start(_ vm: ViewModel) {
        self.vm = vm
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do { try u.start() } catch { NSLog("Sparkle: %@", error.localizedDescription) }
        updater = u
        apply(vm.config.updateMode)
    }

    // auto — проверять и ставить сами; notify — проверять и сообщать; off — не проверять.
    func apply(_ mode: String) {
        updater?.automaticallyChecksForUpdates = mode != "off"
        updater?.automaticallyDownloadsUpdates = mode == "auto"
    }

    func check() { updater?.checkForUpdates() }
    func install() { let r = foundReply; foundReply = nil; r?(.install) }
    func skip() { let r = foundReply; foundReply = nil; r?(.dismiss) }
    func restartNow() { let r = readyReply; readyReply = nil; r?(.install) }
    func restartLater() { let r = readyReply; readyReply = nil; r?(.dismiss); main { $0.installing = 0 } }

    private func main(_ f: @escaping (ViewModel) -> Void) {
        DispatchQueue.main.async { if let vm = self.vm { f(vm) } }
    }

    // Список «Что нового» из описания выпуска: <li lang="ru">…</li> — на языке окна, иначе английский.
    static func notes(_ html: String?) -> [String] {
        guard let html, let re = try? NSRegularExpression(pattern: "<li(?:\\s+lang=\"([a-z]+)\")?>(.*?)</li>", options: [.dotMatchesLineSeparators]) else { return [] }
        var byLang: [String: [String]] = [:]
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let lang = Range(m.range(at: 1), in: html).map { String(html[$0]) } ?? "en"
            if let t = Range(m.range(at: 2), in: html) { byLang[lang, default: []].append(String(html[t])) }
        }
        return byLang[Lang.code] ?? byLang["en"] ?? byLang.values.first ?? []
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: vm?.config.updateMode != "off", sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { main { $0.updateChecking = true } }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        foundReply = reply
        let v = appcastItem.displayVersionString
        let notes = Updater.notes(appcastItem.itemDescription)
        main {
            $0.updateChecking = false
            $0.lastUpdateCheck = Date()
            $0.updateVersion = v
            $0.updateNotes = notes
            $0.updateAvailable = true
            if state.userInitiated == false, state.stage == .downloaded { $0.installing = 1 }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        main {
            $0.updateChecking = false
            $0.lastUpdateCheck = Date()
            $0.updateAvailable = false
            $0.alert(tr("Обновлений нет"), trf("У вас последняя версия — %@.", Updater.currentVersion))
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        main {
            $0.updateChecking = false
            $0.installing = 0
            $0.alert(tr("Не удалось проверить обновления"), error.localizedDescription)
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0; received = 0
        main { $0.installing = 0.01 }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        let p = expected > 0 ? min(0.9, Double(received) / Double(expected) * 0.9) : 0.5
        main { $0.installing = max(0.01, p) }
    }

    func showDownloadDidStartExtractingUpdate() { main { $0.installing = 0.9 } }
    func showExtractionReceivedProgress(_ progress: Double) { main { $0.installing = 0.9 + 0.09 * progress } }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyReply = reply
        main { $0.installing = 1 }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }

    func showUpdateInFocus() { main { $0.onShow?() } }

    func dismissUpdateInstallation() {
        main {
            $0.updateChecking = false
            if $0.installing < 1 { $0.installing = 0 }
        }
    }
}
