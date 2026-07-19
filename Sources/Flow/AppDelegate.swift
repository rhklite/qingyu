import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()

    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let engine = WhisperEngine()
    private var hotkey: HotKeyMonitor?
    private var hotkeyRetry: Timer?

    private enum State { case loading, idle, listening, thinking, error, noModel }
    private var state: State = .loading { didSet { updateStatusIcon() } }

    private var recordingStart = Date.distantPast
    private var lastTranscript = ""
    private var statusMessage: String?
    private var ollamaReachable = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        recorder.preferredDeviceUID = config.inputDeviceUID

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
        if config.hotkeyMode == "toggle" {
            guard key == .down else { return }
            if state == .listening { stopDictation() } else { startDictation() }
        } else {
            if key == .down { startDictation() } else { stopDictation() }
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
        do {
            try recorder.start()
            recordingStart = Date()
            statusMessage = nil
            state = .listening
            if config.playSounds { Cue.start() }
        } catch {
            statusMessage = error.localizedDescription
            state = .error
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
                self.statusMessage = error.localizedDescription
                self.state = .error
                if cfg.playSounds { Cue.error() }
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
        return config.hotkeyMode == "toggle" ? "Tap \(name) to start/stop" : "Hold \(name) to talk"
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

        let modeTitle = "Mode: " + (config.hotkeyMode == "toggle" ? "Toggle" : "Hold")
        addAction(modeTitle, to: menu, #selector(toggleMode))
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

    @objc private func toggleMode() {
        config.hotkeyMode = (config.hotkeyMode == "toggle") ? "hold" : "toggle"
        config.save()
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
