import Cocoa
import Sparkle

/// Over-the-air updates via Sparkle.
///
/// Sparkle does the part that is genuinely hard to get right: downloading over TLS,
/// checking an EdDSA signature made with a key that never leaves the maintainer's
/// Keychain, swapping the bundle out from under the running app, and relaunching it. A
/// hand-rolled updater that skips the signature check would be a remote-code-execution
/// hole wearing a "Check for Updates…" label, which is the reason not to hand-roll one.
///
/// The feed and the public key live in Info.plist (SUFeedURL / SUPublicEDKey) — see
/// scripts/release.sh, which builds the DMG and regenerates the appcast together so the
/// two can't drift.
@MainActor
final class UpdateController: NSObject {
    private var controller: SPUStandardUpdaterController?

    /// Whether the app is wired for updates at all. False when Info.plist has no feed —
    /// a source build, say — and the menu then says so instead of offering a check that
    /// can only fail.
    private(set) var isConfigured = false

    /// - Parameter automatic: check quietly on launch and daily thereafter.
    func start(automatic: Bool) {
        let info = Bundle.main.infoDictionary
        let feed = (info?["SUFeedURL"] as? String) ?? ""
        let key = (info?["SUPublicEDKey"] as? String) ?? ""
        guard !feed.isEmpty, !key.isEmpty, !key.hasPrefix("REPLACE_ME") else {
            isConfigured = false
            return
        }
        isConfigured = true

        // startingUpdater: true wires the scheduled check straight away. The delegate is
        // ours so the two Config switches stay the source of truth rather than Sparkle's
        // own defaults, which live in NSUserDefaults and would drift from config.json.
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: self,
                                                      userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = automatic
        controller.updater.updateCheckInterval = 60 * 60 * 24   // daily is plenty
        self.controller = controller
    }

    /// Reflect a Settings change without a relaunch.
    func setAutomatic(_ automatic: Bool) {
        controller?.updater.automaticallyChecksForUpdates = automatic
    }

    /// The menu item. Always reports something — "you're up to date" included — because a
    /// check that silently does nothing reads as broken.
    func checkNow() {
        controller?.updater.checkForUpdates()
    }

    /// Version string of the running bundle, for the menu and the bug report.
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
}

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle reports "no update found" through this path too; it is not a fault.
        let code = (error as NSError).code
        guard code != Int(Sparkle.SUError.noUpdateError.rawValue) else { return }
        NSLog("Qingyu: update check failed: %@", error.localizedDescription as NSString)
    }
}
