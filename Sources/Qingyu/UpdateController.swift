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

    /// Version string of an update Sparkle has found and the user hasn't installed, or
    /// nil when up to date. The menu and Settings read this to say so plainly.
    private(set) var availableVersion: String?

    /// Fired when `availableVersion` changes, so whatever is on screen can catch up.
    var onAvailabilityChange: (() -> Void)?

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
                                                      userDriverDelegate: self)
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
    ///
    /// 轻语 has no Dock icon, so without activating first Sparkle's window opens behind
    /// whatever the user is looking at and the check appears to have done nothing.
    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.updater.checkForUpdates()
    }

    private func setAvailable(_ version: String?) {
        guard availableVersion != version else { return }
        availableVersion = version
        onAvailabilityChange?()
    }

    /// Version string of the running bundle, for the menu and the bug report.
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
}

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor [weak self] in self?.setAvailable(version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak self] in self?.setAvailable(nil) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle reports "no update found" through this path too; it is not a fault.
        let code = (error as NSError).code
        guard code != Int(Sparkle.SUError.noUpdateError.rawValue) else { return }
        NSLog("Qingyu: update check failed: %@", error.localizedDescription as NSString)
    }
}

/// Gentle reminders: a scheduled check that finds something records it and lets the
/// menu bar and Settings say so, instead of throwing a window in front of whatever the
/// user is doing. A check the user asked for still shows the window — they are waiting
/// for an answer. See https://sparkle-project.org/documentation/gentle-reminders
extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false   // we show it in the menu instead
    }
}
