import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()

    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let engine = WhisperEngine()
    private let speechBar = SpeechBar()
    private var hotkey: HotKeyMonitor?
    private var hotkeyRetry: Timer?

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
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.speechBar.update(level: level) }
        }
        recorder.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.speechBar.hide()
                self.statusMessage = error.localizedDescription
                self.state = .error
                if self.config.playSounds { Cue.error() }
                self.scheduleErrorRecovery()
            }
        }

        // Request every permission the app needs in one pass on first launch, so the
        // user can grant them all at once instead of hitting them feature by feature.
        if !Permissions.allGranted {
            Permissions.requestAll()
        }

        startHotkey()
        loadModel()
        refreshOllamaStatus()
    }

    // MARK: Model

    private func loadModel() {
        state = .loading
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            state = .noModel
            return
        }
        let path = config.modelPath
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
        // fails, but the attempt itself is what registers Flow in the Input Monitoring
        // list and fires the system prompt — so we must try even while unauthorized.
        if monitor.start() {
            hotkey = monitor
            hotkeyRetry?.invalidate()
            hotkeyRetry = nil
        } else {
            // Tap failed → neither Accessibility nor Input Monitoring is granted yet.
            // (Accessibility alone satisfies a listen tap; Input Monitoring is an
            // alternative.) The attempt registers Flow and fires the prompt.
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
        if config.playSounds { Cue.start() }   // instant audio + visual feedback
        statusMessage = nil
        recordingStart = Date()
        state = .listening                     // bar shows now; the mic opens in the background
        recorder.start()
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
        let samples = recorder.stop()
        if config.playSounds { Cue.stop() }

        let duration = Date().timeIntervalSince(recordingStart)
        guard duration > 0.3, samples.count > 3_200 else {
            state = .idle   // too short — likely an accidental tap
            return
        }

        state = .thinking
        let cfg = config
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.engine.transcribe(
                    samples: samples, language: cfg.language, vocabulary: cfg.customVocabulary)

                var result = raw
                if cfg.cleanup, !raw.isEmpty {
                    let cleaner = LLMCleaner(baseURL: cfg.ollamaURL, model: cfg.ollamaModel)
                    if let cleaned = await cleaner.cleanup(raw, vocabulary: cfg.customVocabulary) {
                        result = cleaned
                    }
                }

                self.state = .idle
                guard !result.isEmpty else { return }
                self.lastTranscript = result
                TextInjector.inject(result, mode: cfg.injectionMode)
            } catch {
                NSLog("Flow: transcription failed: %@", error.localizedDescription as NSString)
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

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
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
        let name = keyName(config.pttKeyCode)
        switch config.hotkeyMode {
        case "toggle": return "Tap \(name) to start/stop"
        case "hybrid": return "Hold \(name) to talk · double-tap to lock"
        default:       return "Hold \(name) to talk"
        }
    }

    // Rebuild the menu each time it opens so dynamic state stays current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshOllamaStatus()
        menu.removeAllItems()

        menu.addItem(disabled("Flow — \(statusText)"))
        menu.addItem(disabled(hotkeyLabel))
        menu.addItem(.separator())

        let cleanupTitle = "LLM Cleanup: " + (config.cleanup
            ? (ollamaReachable ? "On" : "On (Ollama offline)")
            : "Off")
        addAction(cleanupTitle, to: menu, #selector(toggleCleanup))

        menu.addItem(modeMenuItem())
        addAction("Change Push-to-Talk Key…", to: menu, #selector(changeHotkey))

        let overlayTitle = "Floating Bar: " + (config.showOverlay ? "On" : "Off")
        addAction(overlayTitle, to: menu, #selector(toggleOverlay))
        menu.addItem(microphoneMenuItem())

        if !lastTranscript.isEmpty {
            addAction("Copy Last Transcript", to: menu, #selector(copyLast))
        }
        menu.addItem(.separator())

        if state == .noModel {
            addAction("⤓ Download a Model…", to: menu, #selector(showModelHelp))
        }
        addAction("Open Config Folder", to: menu, #selector(openConfigFolder))
        menu.addItem(permissionsMenuItem())
        menu.addItem(.separator())
        addAction("Quit Flow", to: menu, #selector(quit))
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

    /// A "Permissions" submenu showing ✓/✗ for each grant with a jump straight to its
    /// System Settings pane, plus a one-click "Request All Permissions".
    private func permissionsMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        permRow(sub, "Microphone", Permissions.microphoneGranted, #selector(openMicPane))
        permRow(sub, "Accessibility", Permissions.accessibilityGranted, #selector(openAccessibilityPane))
        permRow(sub, "Input Monitoring", Permissions.inputMonitoringGranted, #selector(openInputMonitoringPane))
        sub.addItem(.separator())
        addAction("Request All Permissions…", to: sub, #selector(grantPermissions))

        let parent = NSMenuItem(title: "Permissions " + (Permissions.allGranted ? "✓" : "⚠︎"),
                                action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    /// A "Mode" submenu: Hold, Toggle, or the hybrid Hold + double-tap lock.
    private func modeMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        modeRow(sub, "Hold to talk", "hold")
        modeRow(sub, "Toggle (tap on / off)", "toggle")
        modeRow(sub, "Hold + double-tap to lock", "hybrid")
        let parent = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    private func modeRow(_ menu: NSMenu, _ title: String, _ value: String) {
        let item = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = (config.hotkeyMode == value) ? .on : .off
        menu.addItem(item)
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

    private func permRow(_ menu: NSMenu, _ name: String, _ granted: Bool, _ selector: Selector) {
        let item = NSMenuItem(title: "\(granted ? "✓" : "✗")  \(name)", action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: Menu actions

    @objc private func toggleCleanup() {
        config.cleanup.toggle()
        config.save()
        refreshOllamaStatus()
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        config.hotkeyMode = value
        config.save()
        pttLocked = false; ignoreNextUp = false   // reset hybrid state on mode change
    }

    @objc private func changeHotkey() {
        hotkey?.stop()   // avoid the live tap firing on the current key during capture
        hotkeyCapture.begin { [weak self] keyCode in
            guard let self else { return }
            if let keyCode {
                self.config.pttKeyCode = keyCode
                self.config.save()
            }
            self.startHotkey()   // rebind (new key if changed, else the old one)
        }
    }

    @objc private func toggleOverlay() {
        config.showOverlay.toggle()
        config.save()
        updateSpeechBar()
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        let uid = (sender.representedObject as? String) ?? ""
        config.inputDeviceUID = uid.isEmpty ? nil : uid
        config.save()
        recorder.preferredDeviceUID = config.inputDeviceUID   // applies on next recording
    }

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    @objc private func openConfigFolder() {
        NSWorkspace.shared.open(Config.configDir)
    }

    @objc private func showModelHelp() {
        let alert = NSAlert()
        alert.messageText = "Download a Whisper model"
        alert.informativeText = """
        Flow needs a whisper.cpp GGML model. Either run

            ./scripts/download_model.sh

        from the Flow repo, or download a model (e.g.
        ggml-large-v3-turbo-q5_0.bin from Hugging Face:
        ggerganov/whisper.cpp) into:

            \(Config.modelsDir.path)

        Then choose “Reload Model”. config.json → modelPath controls
        which file Flow loads.
        """
        alert.addButton(withTitle: "Open Models Folder")
        alert.addButton(withTitle: "Reload Model")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            try? FileManager.default.createDirectory(at: Config.modelsDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Config.modelsDir)
        case .alertSecondButtonReturn:
            config = Config.load()
            loadModel()
        default:
            break
        }
    }

    @objc private func grantPermissions() {
        Permissions.requestAll()
        Permissions.openPrivacySettings(pane: "Accessibility")
        startHotkey()
    }

    @objc private func openMicPane() {
        Permissions.requestMicrophone { _ in }
        Permissions.openPrivacySettings(pane: "Microphone")
    }

    @objc private func openAccessibilityPane() {
        Permissions.ensureAccessibility(prompt: true)
        Permissions.openPrivacySettings(pane: "Accessibility")
    }

    @objc private func openInputMonitoringPane() {
        Permissions.ensureInputMonitoring(prompt: true)
        Permissions.openPrivacySettings(pane: "ListenEvent")
        startHotkey()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private func notify(_ message: String) {
        statusMessage = message
        updateStatusIcon()
        if config.playSounds { Cue.error() }
    }

    private func keyName(_ code: Int) -> String {
        switch code {
        case 61: return "Right ⌥"
        case 58: return "Left ⌥"
        case 62: return "Right ⌃"
        case 59: return "Left ⌃"
        case 54: return "Right ⌘"
        case 55: return "Left ⌘"
        case 60: return "Right ⇧"
        case 56: return "Left ⇧"
        default: return "key \(code)"
        }
    }
}
