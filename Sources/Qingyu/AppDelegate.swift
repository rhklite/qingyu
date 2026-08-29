import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()

    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let engine = WhisperEngine()
    private let speechBar = SpeechBar()
    private let jargonToast = JargonToast()
    private let ducker = AudioDucker()
    private var hotkey: HotKeyMonitor?
    private var hotkeyRetry: Timer?
    private var hotkeyWatchdog: Timer?
    private var napAssertion: NSObjectProtocol?
    private var remapper: KeyRemapper?
    private let updater = UpdateController()
    /// True while the "press your new key" window is up. Rebinding deliberately stops the
    /// live tap first, so without this the watchdog would restart it on the OLD key
    /// mid-capture and start dictating at the very keypress being captured.
    private var isCapturingHotkey = false

    private enum State { case loading, idle, listening, thinking, error, noModel }
    private var state: State = .loading { didSet { updateStatusIcon(); updateSpeechBar() } }

    private var recordingStart = Date.distantPast
    private var lastTranscript = ""
    private var statusMessage: String?
    private var ollamaReachable = false

    // Hybrid push-to-talk state (hold to talk; double-tap to lock hands-free).
    private var pttLocked = false
    private var pttDownTime = Date.distantPast
    private var lastTapTime = Date.distantPast
    private var ignoreNextUp = false
    private let hotkeyCapture = HotkeyCapture()

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        recorder.preferredDeviceUID = config.inputDeviceUID
        recorder.warmUp()                      // pay the graph build now, not on first press
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.speechBar.update(level: level) }
        }
        recorder.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.speechBar.hide()
                ActivityLog.shared.record("microphone error: \(error.localizedDescription)")
                self.statusMessage = error.localizedDescription
                self.state = .error
                if self.config.playSounds { Cue.error() }
                self.scheduleErrorRecovery()
            }
        }

        SpeechBar.bottomMargin = config.overlayBottomMargin
        ducker.configure(setting: config.ducking, level: config.duckLevel)
        preventAppNap()
        startHotkey()
        startRemapper()
        startHotkeyWatchdog()
        observeWake()
        updater.start(automatic: config.autoCheckUpdates)
        // A scheduled check no longer opens a window (see UpdateController), so the
        // menu-bar mark is how the user learns an update is waiting.
        updater.onAvailabilityChange = { [weak self] in self?.updateStatusIcon() }
        // No model on disk yet (fresh install — the DMG doesn't ship one) means setup:
        // pick a model, download it, then walk through permissions and cleanup. The
        // wizard fires the permission prompts itself, after explaining them — firing
        // them here first would stack system dialogs on top of the setup window.
        if resolvedModelPath() == nil {
            state = .noModel
            DispatchQueue.main.async { [weak self] in self?.runModelSetup(firstRun: true) }
        } else {
            // Returning user with no wizard to run: ask for anything still missing.
            if !Permissions.allGranted { Permissions.requestAll() }
            // A model is already here (source install, or scripts/download_model.sh) —
            // never interrupt those users with a picker they don't need.
            if !config.modelChosen { config.modelChosen = true; config.save() }
            loadModel()
        }
        refreshOllamaStatus()
    }

    /// Runs the setup window. It only returns a model once that model is on disk, so
    /// there's nothing to check here before loading it. The optional cleanup step is
    /// offered on first run only — afterwards it lives behind its own menu item.
    private func runModelSetup(firstRun: Bool, preselect: SpeechModel? = nil) {
        let current = preselect ?? SpeechModel.named((config.modelPath as NSString).lastPathComponent)
        let result = ModelChooser.present(current: firstRun ? preselect : current,
                                          fullSetup: firstRun,
                                          ollamaURL: config.ollamaURL,
                                          ollamaModel: config.ollamaModel)
        guard let result else {
            if firstRun { loadModel() }   // dismissed — reflects reality in the menu
            return
        }
        // The chooser already pointed Config.modelsDir at the new folder; persist it.
        config.modelsDir = result.modelsDir
        if let enabled = result.cleanupEnabled { applyCleanup(enabled) }
        if let model = result.model {
            applyModel(model)
        } else if firstRun {
            loadModel()
        }
    }

    private func applyCleanup(_ enabled: Bool) {
        config.level = enabled ? .light : .raw
        config.save()
        refreshOllamaStatus()
    }

    /// Add a newly heard term to the dictionary, then offer 10 seconds to take it back.
    /// Adding first keeps dictation a flow activity — a question mid-flow is a tax, and
    /// the common case is that the term is genuinely wanted.
    private func offerJargon(in text: String) {
        guard config.autoJargon else { return }
        let known = config.customVocabulary + config.declinedJargon
        guard let term = JargonDetector.candidate(in: text, known: known,
                                                  replacements: config.replacements)
        else { return }

        config.customVocabulary.append(term)
        config.save()
        jargonToast.show(term: term) { [weak self] in
            guard let self else { return }
            self.config.customVocabulary.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
            // Remember the refusal, or the same mis-hearing nags after every dictation.
            self.config.declinedJargon.append(term)
            self.config.save()
        }
    }

    /// Point config at `model` and reload.
    private func applyModel(_ model: SpeechModel) {
        config.modelPath = model.localURL.path
        config.modelChosen = true
        config.save()
        loadModel()
    }

    // MARK: Model

    private func loadModel() {
        state = .loading
        guard let path = resolvedModelPath() else {
            state = .noModel
            return
        }
        Task {
            do {
                try await engine.load(modelPath: path)
                state = .idle
            } catch {
                statusMessage = error.localizedDescription
                state = .error
            }
        }
    }

    /// config.json's modelPath, or a model shipped inside the bundle
    /// (Contents/Resources/models — the DMG build) so a fresh install works with
    /// no download step. Returns nil when neither exists.
    private func resolvedModelPath() -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: config.modelPath) { return config.modelPath }
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("models"),
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        let wanted = (config.modelPath as NSString).lastPathComponent
        if let exact = files.first(where: { $0.lastPathComponent == wanted }) { return exact.path }
        return files.first(where: { $0.pathExtension == "bin" })?.path
    }

    private func refreshOllamaStatus() {
        guard config.cleanup else { ollamaReachable = false; return }
        let url = config.ollamaURL
        Task {
            ollamaReachable = await LLMCleaner.isReachable(baseURL: url)
        }
    }

    // MARK: Hotkey

    private func startHotkey() {
        hotkey?.stop()
        let monitor = HotKeyMonitor(keyCode: config.pttKeyCode) { [weak self] key in
            // The tap fires on the main run loop; hop onto the main actor to touch state.
            Task { @MainActor in self?.handleHotkey(key) }
        }
        // Always ATTEMPT the tap. When Input Monitoring isn't granted the attempt
        // fails, but the attempt itself is what registers Qingyu in the Input Monitoring
        // list and fires the system prompt — so we must try even while unauthorized.
        if monitor.start() {
            hotkey = monitor
            hotkeyRetry?.invalidate()
            hotkeyRetry = nil
        } else {
            // Tap failed → neither Accessibility nor Input Monitoring is granted yet.
            // (Accessibility alone satisfies a listen tap; Input Monitoring is an
            // alternative.) The attempt registers Qingyu and fires the prompt.
            if hotkeyRetry == nil { Permissions.ensureInputMonitoring(prompt: true) }
            scheduleHotkeyRetry()
        }
    }

    private func scheduleHotkeyRetry() {
        guard hotkeyRetry == nil else { return }
        // Keep re-attempting the tap; it succeeds the moment the user flips the toggle.
        hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startHotkey() }
        }
    }

    /// A menu-bar app with no windows is precisely what App Nap goes after: leave 轻语
    /// alone for a few minutes and macOS throttles its run loop, the push-to-talk tap
    /// stops answering within the deadline, and the system switches the tap off. Holding
    /// a user-initiated activity for the process lifetime keeps the app answering while
    /// still letting the Mac go to sleep on its own schedule.
    private func preventAppNap() {
        napAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Listening for the push-to-talk key")
    }

    /// macOS tells a tap it has been disabled by sending the news *to that tap* — so a
    /// tap switched off while the app is throttled or the Mac is asleep never hears it
    /// and stays dead until relaunch. That is the "leave it a while and it stops
    /// working" failure, and the only reliable answer is to check rather than trust.
    private func startHotkeyWatchdog() {
        hotkeyWatchdog?.invalidate()
        // Common modes so an open menu or a drag doesn't pause the check.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reviveHotkey() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hotkeyWatchdog = timer
    }

    /// Re-arm the tap, building a new one if macOS won't switch the old one back on.
    private func reviveHotkey() {
        guard !isCapturingHotkey else { return }   // rebinding stopped the tap on purpose
        if let remapper, !remapper.isActive, !remapper.reviveIfNeeded() { startRemapper() }
        guard hotkeyRetry == nil else { return }   // no tap yet — the retry timer owns this
        guard let hotkey else { startHotkey(); return }
        guard !hotkey.isActive else { return }
        if !hotkey.reviveIfNeeded() { startHotkey() }
    }

    // MARK: Mouse → Return

    /// Bring the remap tap up, down, or over to a different button, to match config.
    /// Unlike push-to-talk this one needs Accessibility specifically: swallowing the
    /// original click requires an active tap, which Input Monitoring alone won't grant.
    private func startRemapper() {
        remapper?.stop()
        remapper = nil
        guard config.remapEnabled else { return }
        guard config.remapButtonCode != config.pttKeyCode else {
            NSLog("Qingyu: remap button is also the push-to-talk key — remap left off")
            return
        }
        let monitor = KeyRemapper(mouseButtonCode: config.remapButtonCode)
        if monitor.start() {
            remapper = monitor
            ActivityLog.shared.record("mouse → Return active on "
                                      + HotkeyCapture.name(for: config.remapButtonCode))
        } else {
            statusMessage = "Mouse → Return needs Accessibility"
            updateStatusIcon()
            ActivityLog.shared.record("mouse → Return failed: no Accessibility")
        }
    }

    /// Sleep, screen lock and fast user switching all pull the rug out: the event tap
    /// comes back disabled, and the audio graph is left describing a microphone that may
    /// no longer be there. Rebuild both on the way back rather than on first failure.
    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recoverAfterWake() }
            }
        }
    }

    private func recoverAfterWake() {
        recorder.invalidate()   // the mic may be a different device than it was
        reviveHotkey()
    }

    private func handleHotkey(_ key: HotKeyMonitor.Key) {
        switch config.hotkeyMode {
        case "toggle":
            guard key == .down else { return }
            if state == .listening { stopDictation() } else { startDictation() }
        case "hybrid":
            handleHotkeyHybrid(key)
        default:   // "hold"
            if key == .down { startDictation() } else { stopDictation() }
        }
    }

    /// Hold to talk; double-tap to lock into hands-free (toggle), then a single press stops.
    /// A plain hold records while held; two quick taps latch recording on until you tap again.
    private func handleHotkeyHybrid(_ key: HotKeyMonitor.Key) {
        let now = Date()
        let tapThreshold = 0.28     // held shorter than this counts as a "tap", not a hold
        let doubleTapWindow = 0.42  // max gap between taps to register a double-tap

        switch key {
        case .down:
            if pttLocked {                       // locked hands-free → a press ends it
                pttLocked = false
                ignoreNextUp = true
                stopDictation()
                return
            }
            pttDownTime = now
            if state == .idle { startDictation() }

        case .up:
            if ignoreNextUp { ignoreNextUp = false; return }
            if pttLocked { return }
            let held = now.timeIntervalSince(pttDownTime)
            if held < tapThreshold {
                // Quick tap — a second one within the window locks recording on.
                if now.timeIntervalSince(lastTapTime) < doubleTapWindow {
                    pttLocked = true             // stay recording, hands-free
                    lastTapTime = .distantPast
                    return
                }
                lastTapTime = now
                stopDictation()                  // lone quick tap → usually too short → back to idle
            } else {
                lastTapTime = .distantPast
                stopDictation()                  // real hold → normal push-to-talk stop
            }
        }
    }

    // MARK: Dictation pipeline

    private func startDictation() {
        guard state == .idle else {
            if state == .noModel { notify("No model — download one from the menu") }
            return
        }
        guard Permissions.microphoneGranted else {
            Permissions.requestMicrophone { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.startDictation() }
                    else { self?.notify("Microphone access denied") }
                }
            }
            return
        }
        // Ask for the microphone before anything else. The chime, the toast and the
        // ducking all run on this actor and together cost ~300 ms — 300 ms of speech
        // thrown away, because the user starts talking on the button press, not on the
        // chime. Capture first; feedback is still instant to a human either way.
        recordingStart = Date()
        recorder.start()

        if config.playSounds { Cue.start() }   // instant audio + visual feedback
        jargonToast.hide()                     // the speech bar wants that spot back
        ducker.dictating = true                // quieten other audio, if enabled
        statusMessage = nil
        state = .listening                     // bar shows now; the mic opens in the background
        ActivityLog.shared.record("started listening")
    }

    /// Transient failures (a flaky device, a whisper hiccup) must not brick the app.
    /// Return to Ready shortly after showing the error so the next hotkey press works
    /// and the floating bar can appear again.
    private func scheduleErrorRecovery() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.state == .error else { return }
            self.statusMessage = nil
            self.state = .idle
        }
    }

    private func stopDictation() {
        guard state == .listening else { return }
        ducker.dictating = false               // media comes back after resumeDelay
        let samples = recorder.stop()
        if config.playSounds { Cue.stop() }

        let duration = Date().timeIntervalSince(recordingStart)
        // A hold long enough to speak into that captured nothing at all means the audio
        // graph went stale underneath us. Rebuild it so the next press works, and say so:
        // dropping the take in silence is what made this read as a dead app.
        if duration > 0.3, samples.isEmpty {
            ActivityLog.shared.record(String(format: "captured NO audio after %.1fs — rebuilding mic", duration))
            recorder.invalidate()
            notify("No audio from the microphone — try again")
            state = .idle
            return
        }
        guard duration > 0.3, samples.count > 3_200 else {
            state = .idle   // too short — likely an accidental tap
            return
        }

        state = .thinking
        let cfg = config
        let audio = cfg.boostAudio ? AudioRecorder.normalizedForRecognition(samples) : samples
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.engine.transcribe(
                    samples: audio, language: cfg.language,
                    detectLanguages: cfg.detectLanguages, vocabulary: cfg.customVocabulary)

                var result = raw
                // Spoken punctuation first: it's deterministic, and doing it before the
                // LLM means the model sees real sentences instead of the words "question
                // mark" sitting mid-clause.
                if cfg.spokenPunctuation { result = SpokenPunctuation.apply(to: result) }

                if cfg.level != .raw, !result.isEmpty {
                    let cleaner = LLMCleaner(baseURL: cfg.ollamaURL, model: cfg.ollamaModel,
                                             level: cfg.level)
                    if let cleaned = await cleaner.cleanup(
                        result, vocabulary: cfg.customVocabulary,
                        spokenPunctuation: cfg.spokenPunctuation) {
                        result = cleaned
                    }
                }
                // Replacements last, so the LLM can't undo a substitution the user
                // explicitly asked for.
                result = PersonalDictionary.applyReplacements(result, cfg.replacements)

                self.state = .idle
                ActivityLog.shared.record("transcribed \(result.count) chars")
                guard !result.isEmpty else { return }
                self.lastTranscript = result
                if TextInjector.inject(result, mode: cfg.injectionMode) == .clipboardOnly {
                    // No Accessibility (often: not an admin on this Mac). Say so once
                    // rather than looking broken — the text is on the clipboard.
                    self.statusMessage = "Copied — press ⌘V to paste"
                    self.updateStatusIcon()
                }
                self.offerJargon(in: result)
            } catch {
                NSLog("Qingyu: transcription failed: %@", error.localizedDescription as NSString)
                ActivityLog.shared.record("transcription failed: \(error.localizedDescription)")
                self.statusMessage = error.localizedDescription
                self.state = .error
                if cfg.playSounds { Cue.error() }
                self.scheduleErrorRecovery()
            }
        }
    }

    // MARK: Status item & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    /// The designed 轻语 mark, loaded once. Idle is a template image so macOS tints it
    /// for light/dark menu bars; the listening cut keeps its amber dot, so it must NOT
    /// be a template — the whole point of the two-tone mark is that the state change is
    /// one colour swap on one stroke rather than a different glyph.
    private static func menuBarImage(named name: String, template: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = template
        return image
    }

    private lazy var idleIcon = Self.menuBarImage(named: "menubar-16", template: true)
    private lazy var listeningIcon = Self.menuBarImage(named: "menubar-listening-16",
                                                       template: false)

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        // States with their own meaning keep a system symbol; the designed mark covers
        // the two states you actually look at.
        switch state {
        case .idle, .thinking:
            if let idleIcon {
                button.image = idleIcon
                button.contentTintColor = state == .thinking ? .systemBlue : nil
                button.toolTip = statusText
                return
            }
        case .listening:
            if let listeningIcon {
                button.image = listeningIcon
                button.contentTintColor = nil
                button.toolTip = statusText
                return
            }
        default:
            break
        }

        let symbol: String
        let tint: NSColor?
        switch state {
        case .loading:   symbol = "hourglass";                 tint = .secondaryLabelColor
        case .idle:      symbol = "mic";                       tint = nil
        case .listening: symbol = "mic.fill";                  tint = .systemRed
        case .thinking:  symbol = "waveform";                  tint = .systemBlue
        case .error:     symbol = "exclamationmark.triangle";  tint = .systemOrange
        case .noModel:   symbol = "arrow.down.circle";         tint = .systemOrange
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusText)
        button.contentTintColor = tint
        button.toolTip = statusText
    }

    /// The floating speech bar follows recording state: waveform while listening,
    /// shimmer while transcribing, hidden otherwise (or when disabled in config).
    private func updateSpeechBar() {
        guard config.showOverlay else { speechBar.hide(); return }
        switch state {
        case .listening: speechBar.show(mode: .listening)
        case .thinking:  speechBar.show(mode: .thinking)
        default:         speechBar.hide()
        }
    }

    private var statusText: String {
        if let statusMessage { return statusMessage }
        switch state {
        case .loading:   return "Loading model…"
        case .idle:      return "Ready"
        case .listening: return "Listening…"
        case .thinking:  return "Transcribing…"
        case .error:     return "Error"
        case .noModel:   return "No model installed"
        }
    }

    private var hotkeyLabel: String {
        // Don't advertise a key that physically cannot fire: the event tap needs
        // Accessibility or Input Monitoring, neither of which a non-admin can grant.
        guard Permissions.accessibilityGranted || Permissions.inputMonitoringGranted else {
            return "Push-to-talk needs permissions"
        }
        let name = keyName(config.pttKeyCode)
        switch config.hotkeyMode {
        case "toggle": return "Tap \(name) to start/stop"
        case "hybrid": return "Hold \(name) to talk · double-tap to lock"
        default:       return "Hold \(name) to talk"
        }
    }

    // Rebuild the menu each time it opens so dynamic state stays current.
    //
    // Five things live here and nothing else: the two settings worth switching without
    // breaking stride, the door into everything else, and the two you reach for when
    // something is wrong. Every other setting is in the Settings window — a dropdown is
    // for acting, not for configuring, and this one had grown into a second settings
    // panel that happened to be shaped like a menu.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled("轻语 — \(statusText)"))
        menu.addItem(disabled(hotkeyLabel))
        if config.remapEnabled {
            menu.addItem(disabled(HotkeyCapture.name(for: config.remapButtonCode) + " sends Return"))
        }

        // Without Accessibility or Input Monitoring the hotkey tap can't run at all —
        // the normal situation for someone who isn't an admin on this Mac. Dictating from
        // the menu needs no permission beyond the microphone, so for those users this row
        // is the only way in and has to stay.
        if !Permissions.accessibilityGranted && !Permissions.inputMonitoringGranted {
            menu.addItem(.separator())
            addAction(state == .listening ? "■ Stop Dictation" : "● Start Dictation",
                      to: menu, #selector(toggleDictationFromMenu))
            menu.addItem(disabled("   no push-to-talk key without permissions"))
        }
        if state == .noModel {
            menu.addItem(.separator())
            addAction("⤓ Download a Model…", to: menu, #selector(downloadModel))
        }
        // Transient rather than configuration: there is nowhere in Settings this belongs.
        if !lastTranscript.isEmpty {
            menu.addItem(.separator())
            addAction("Copy Last Transcript", to: menu, #selector(copyLast))
        }

        menu.addItem(.separator())
        menu.addItem(microphoneMenuItem())
        menu.addItem(languageMenuItem())

        menu.addItem(.separator())
        addAction("Open Settings…", to: menu, #selector(openSettings))

        menu.addItem(.separator())
        addAction("Report a Bug…", to: menu, #selector(reportBug))
        if let version = updater.availableVersion {
            addAction("Update to \(version)…", to: menu, #selector(checkForUpdates))
            // Bold, the way macOS marks the one item in a menu that wants acting on.
            let bold = NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0),
                                                    toHaveTrait: .boldFontMask)
            menu.items.last?.attributedTitle = NSAttributedString(
                string: "Update to \(version)…", attributes: [.font: bold])
        } else {
            addAction(updater.isConfigured ? "Check for Updates…" : "Updates unavailable in this build",
                      to: menu, #selector(checkForUpdates))
            menu.items.last?.isEnabled = updater.isConfigured
        }

        menu.addItem(.separator())
        addAction("Quit 轻语", to: menu, #selector(quit))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func addAction(_ title: String, to menu: NSMenu, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    /// A "Language" submenu. Toggle languages to build a detection set: 0 = detect among
    /// all, 1 = pin, 2+ = detect only among those (kills mis-detection on short/mixed clips).
    ///
    /// Only the common languages get a row — all 99 belong in Settings, where they can be
    /// searched — plus whatever is currently picked, so a choice made there is never
    /// invisible here.
    private func languageMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        let set = config.detectLanguages

        let auto = NSMenuItem(title: "Auto-detect (all)", action: #selector(setAutoLanguage), keyEquivalent: "")
        auto.target = self
        auto.state = set.isEmpty ? .on : .off
        sub.addItem(auto)
        sub.addItem(.separator())

        for code in Language.common + set.filter({ !Language.common.contains($0) }) {
            let item = NSMenuItem(title: Language.shortLabel(code),
                                  action: #selector(toggleLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = set.contains(code) ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        let hint: String
        switch set.count {
        case 0:  hint = "Detecting: all languages"
        case 1:  hint = "Pinned to \(Language.label(set[0]))"
        default: hint = "Detecting only: " + set.map(Language.shortLabel).joined(separator: ", ")
        }
        sub.addItem(disabled(hint))
        sub.addItem(disabled("More languages in Settings"))

        let parent = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    /// A "Microphone" submenu: System Default plus every connected input device,
    /// with a checkmark on the pinned one. Pinning persists by UID (config.inputDeviceUID).
    private func microphoneMenuItem() -> NSMenuItem {
        let sub = NSMenu()

        let pinned = config.inputDeviceUID
        let def = NSMenuItem(title: "System Default", action: #selector(selectMic(_:)), keyEquivalent: "")
        def.target = self
        def.representedObject = ""
        def.state = (pinned?.isEmpty ?? true) ? .on : .off
        sub.addItem(def)

        let devices = AudioDevices.inputs()
        if !devices.isEmpty { sub.addItem(.separator()) }
        var pinnedConnected = false
        for d in devices {
            let item = NSMenuItem(title: d.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.uid
            let on = (pinned == d.uid)
            if on { pinnedConnected = true }
            item.state = on ? .on : .off
            sub.addItem(item)
        }
        // Pinned to a device that isn't plugged in right now: tell the user (we'll
        // fall back to the system default until it returns).
        if let uid = pinned, !uid.isEmpty, !pinnedConnected {
            sub.addItem(.separator())
            let warn = NSMenuItem(title: "⚠︎ Pinned mic not connected — using default", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            sub.addItem(warn)
        }

        let parent = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    // MARK: Menu actions

    @objc private func openSettings() {
        let actions = SettingsPanel.Actions(
            chooseModel: { [weak self] in self?.runModelSetup(firstRun: false) },
            setUpCleanup: { [weak self] in self?.setUpCleanupFlow() },
            openConfigFolder: { NSWorkspace.shared.open(Config.configDir) },
            checkForUpdates: { [weak self] in self?.updater.checkNow() },
            openPermission: { [weak self] pane in self?.openPermissionPane(pane) },
            captureMouseButton: { [weak self] done in
                self?.beginHotkeyCapture(mouseOnly: true) { code in done(code) }
            },
            requestAllPermissions: { Permissions.requestAll() },
            updatesConfigured: updater.isConfigured,
            appVersion: UpdateController.currentVersion,
            updateAvailable: updater.availableVersion)

        SettingsPanel.present(config: config, currentConfig: { [weak self] in
            self?.config ?? Config.load()
        }, actions: actions, onCaptureKey: { [weak self] done in
            guard let self else { return }
            self.beginHotkeyCapture { keyCode in done(keyCode) }
        }, onSave: { [weak self] updated in
            guard let self else { return }
            self.config = updated
            self.config.save()
            self.refreshOllamaStatus()
            SpeechBar.bottomMargin = updated.overlayBottomMargin
            self.ducker.configure(setting: updated.ducking, level: updated.duckLevel)
            self.recorder.preferredDeviceUID = updated.inputDeviceUID  // applies next recording
            self.pttLocked = false; self.ignoreNextUp = false          // mode may have changed
            self.updater.setAutomatic(updated.autoCheckUpdates)
            self.updateSpeechBar()                                     // overlay may have changed
            self.startHotkey()                                         // key may have changed
            self.startRemapper()                                       // button may have changed
        })
    }

    /// Stop the live taps, capture one keypress, then bring them back. Shared by the menu
    /// bar and the settings panel so the "stop first" rule — without which the tap
    /// swallows the very press being captured — can't be forgotten in one of them.
    private func beginHotkeyCapture(mouseOnly: Bool = false,
                                    _ done: @escaping (Int?) -> Void) {
        isCapturingHotkey = true
        hotkey?.stop()
        remapper?.stop()
        hotkeyCapture.begin(mouseOnly: mouseOnly) { [weak self] keyCode in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturingHotkey = false
                self.startHotkey()      // re-arm on the old key; callers rebind if it changed
                self.startRemapper()
                done(keyCode)
            }
        }
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        let uid = (sender.representedObject as? String) ?? ""
        config.inputDeviceUID = uid.isEmpty ? nil : uid
        config.save()
        recorder.preferredDeviceUID = config.inputDeviceUID   // applies on next recording
        recorder.warmUp()                                     // build for the new device now
    }

    @objc private func setAutoLanguage() {
        config.detectLanguages = []
        config.language = "auto"
        config.save()
    }

    @objc private func toggleLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        var set = config.detectLanguages
        if let i = set.firstIndex(of: code) { set.remove(at: i) } else { set.append(code) }
        config.detectLanguages = set
        config.language = (set.count == 1) ? set[0] : "auto"   // keep `language` coherent
        config.save()   // applies on the next dictation
    }

    @objc private func toggleDictationFromMenu() {
        if state == .listening { stopDictation() } else { startDictation() }
    }

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    @objc private func openConfigFolder() {
        NSWorkspace.shared.open(Config.configDir)
    }

    @objc private func downloadModel() {
        runModelSetup(firstRun: false)
    }

    /// Prompt for a permission and open its System Settings pane. `pane` is the name
    /// Apple's URL scheme uses, which for Input Monitoring is "ListenEvent".
    private func openPermissionPane(_ pane: String) {
        switch pane {
        case "Microphone":
            Permissions.requestMicrophone { _ in }
        case "Accessibility":
            Permissions.ensureAccessibility(prompt: true)
        case "ListenEvent":
            Permissions.ensureInputMonitoring(prompt: true)
        default:
            break
        }
        Permissions.openPrivacySettings(pane: pane)
        // The taps can come up the moment the switch is flipped; re-attempt on return.
        startHotkey()
        startRemapper()
    }

    /// Reopens just the cleanup step: probes Ollama, offers to pull the model, or
    /// explains what's missing when Ollama isn't installed.
    private func setUpCleanupFlow() {
        if let enabled = ModelChooser.presentCleanup(ollamaURL: config.ollamaURL,
                                                     ollamaModel: config.ollamaModel) {
            applyCleanup(enabled)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func checkForUpdates() {
        guard updater.isConfigured else { return }
        updater.checkNow()
    }

    /// Writes the report to the Desktop and puts it on the clipboard, then offers to
    /// open a prefilled GitHub issue. The file is the point — the people using this text
    /// it over rather than filing anything.
    @objc private func reportBug() {
        let report = BugReport.text(config: config, state: statusText,
                                    lastError: statusMessage,
                                    recentLog: ActivityLog.shared.recent)
        let url = BugReport.save(report)

        let alert = NSAlert()
        alert.messageText = "Bug report ready"
        alert.informativeText = url.map {
            "Saved to your Desktop as \($0.lastPathComponent), and copied to the clipboard.\n\n"
            + "Open it, describe what went wrong at the top, then send it over."
        } ?? "Copied to the clipboard — paste it into a message and describe what went wrong."
        alert.addButton(withTitle: url == nil ? "OK" : "Show in Finder")
        alert.addButton(withTitle: "Open a GitHub Issue")
        alert.addButton(withTitle: "Done")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .alertSecondButtonReturn:
            if let issue = BugReport.githubURL(title: "轻语 \(UpdateController.currentVersion): ",
                                               body: report) {
                NSWorkspace.shared.open(issue)
            }
        default:
            break
        }
    }

    // MARK: Helpers

    private func notify(_ message: String) {
        statusMessage = message
        updateStatusIcon()
        if config.playSounds { Cue.error() }
    }

    private func keyName(_ code: Int) -> String { HotkeyCapture.name(for: code) }
}
