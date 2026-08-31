import Cocoa

/// The settings window opened from the menu's "Open Settings…".
///
/// Deliberately light: forced Aqua appearance regardless of the system theme, plain
/// text controls, no icon set. Everything here is also reachable from the menu bar
/// except the things a menu can't hold — the dictionary table, and a 99-language
/// picker you can actually search.
///
/// Save applies and closes, and so does closing the window — only Cancel throws the
/// edits away. A panel whose red X silently discarded what you just set is a bug
/// people rediscover one setting at a time.
@MainActor
final class SettingsPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var config: Config
    private let onSave: (Config) -> Void
    private let onCaptureKey: (@escaping (Int?) -> Void) -> Void

    /// Which fields the user actually touched while the window was open.
    ///
    /// `config` is a snapshot taken when the panel opened, and Save used to write the
    /// whole of it back. Anything changed elsewhere in the meantime — the menu bar's own
    /// "Change Push-to-Talk Key…", a language toggle, a mic pick — was therefore silently
    /// reverted to whatever it had been when the window opened. Saving only what was
    /// edited here lets the two paths coexist.
    private var edited: Set<String> = []
    private func markEdited(_ field: String) { edited.insert(field) }

    private var hotkeyLabel: NSTextField!
    private var modeButtons: [String: NSButton] = [:]
    private var remapLabel: NSTextField!
    private var remapNote: NSTextField!
    private var remapOffButton: NSButton!
    private var micPopup: NSPopUpButton!
    private var micNote: NSTextField!

    private var languageSearch: NSSearchField!
    private var languageTable: NSTableView!
    private var languageHint: NSTextField!
    private var visibleLanguages: [Language] = []
    private var selectedLanguages: Set<String> = []

    private var levelButtons: [CleanupLevel: NSButton] = [:]
    private var levelBlurb: NSTextField!
    private var duckButtons: [DuckSetting: NSButton] = [:]
    private var duckBlurb: NSTextField!
    private var punctuationCheck: NSButton!
    private var jargonCheck: NSButton!
    private var overlayCheck: NSButton!
    private var boostCheck: NSButton!
    private var soundsCheck: NSButton!
    private var autoUpdateCheck: NSButton!
    private var modelLabel: NSTextField!
    private var permissionRows: NSStackView!

    private var table: NSTableView!
    private var termField: NSTextField!
    private var replaceField: NSTextField!

    /// Flattened view of vocabulary + replacements, so one table shows both.
    /// `replacement == nil` means a plain bias term.
    private struct Entry {
        var term: String
        var replacement: String?
    }
    private var entries: [Entry] = []

    /// Reads the app's live config at Save time, so edits land on top of it rather than
    /// on top of the copy this window opened with.
    private let currentConfig: () -> Config
    private let actions: Actions

    /// The things this window can only ask the app to do — open another window, prod a
    /// permission, run an update check. Everything else here is a plain config edit.
    struct Actions {
        var chooseModel: () -> Void
        var setUpCleanup: () -> Void
        var openConfigFolder: () -> Void
        var checkForUpdates: () -> Void
        var openPermission: (String) -> Void
        var captureMouseButton: (@escaping (Int?) -> Void) -> Void
        var requestAllPermissions: () -> Void
        var updatesConfigured: Bool
        var appVersion: String
        /// Version Sparkle has found and the user hasn't installed, or nil when current.
        var updateAvailable: String?
    }

    private init(config: Config,
                 currentConfig: @escaping () -> Config,
                 actions: Actions,
                 onCaptureKey: @escaping (@escaping (Int?) -> Void) -> Void,
                 onSave: @escaping (Config) -> Void) {
        self.config = config
        self.currentConfig = currentConfig
        self.actions = actions
        self.onSave = onSave
        self.onCaptureKey = onCaptureKey
        self.selectedLanguages = Set(config.detectLanguages)
        super.init()
        loadEntries()
        build()
    }

    private static var open: SettingsPanel?

    /// Show the panel, reusing the existing window if it's already up.
    ///
    /// `onCaptureKey` is the caller's job because rebinding needs the live event tap
    /// stopped first, or it swallows the very keypress being captured.
    static func present(config: Config,
                        currentConfig: @escaping () -> Config,
                        actions: Actions,
                        onCaptureKey: @escaping (@escaping (Int?) -> Void) -> Void,
                        onSave: @escaping (Config) -> Void) {
        if let existing = open {
            NSApp.activate(ignoringOtherApps: true)
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let panel = SettingsPanel(config: config, currentConfig: currentConfig,
                                  actions: actions, onCaptureKey: onCaptureKey, onSave: onSave)
        open = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.window.center()
        panel.window.makeKeyAndOrderFront(nil)
    }

    private func loadEntries() {
        entries = config.customVocabulary.map { Entry(term: $0, replacement: nil) }
        entries += config.replacements
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { Entry(term: $0.key, replacement: $0.value) }
    }

    // MARK: Layout

    private func build() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)

        content.addArrangedSubview(header("Key bindings"))
        hotkeyLabel = NSTextField(labelWithString: "")
        hotkeyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let changeKey = NSButton(title: "Change…", target: self, action: #selector(changeHotkey))
        changeKey.bezelStyle = .rounded
        changeKey.controlSize = .small
        let keyRow = NSStackView(views: [hotkeyLabel, changeKey])
        keyRow.orientation = .horizontal
        keyRow.spacing = 10
        content.addArrangedSubview(keyRow)
        refreshHotkeyLabel()

        let modeRow = NSStackView()
        modeRow.orientation = .horizontal
        modeRow.spacing = 18
        for (value, title) in [("hold", "Hold"), ("toggle", "Toggle"),
                               ("hybrid", "Hold + double-tap to lock")] {
            let b = NSButton(radioButtonWithTitle: title, target: self,
                             action: #selector(modeChanged(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(value)
            b.state = (config.hotkeyMode == value) ? .on : .off
            modeButtons[value] = b
            modeRow.addArrangedSubview(b)
        }
        content.addArrangedSubview(modeRow)

        // Mouse → Return lives here rather than only in the menu bar: both bindings are
        // the same kind of setting, and looking for one in the place that holds the other
        // is the obvious thing to do.
        remapLabel = NSTextField(labelWithString: "")
        remapLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let changeRemap = NSButton(title: "Change…", target: self,
                                   action: #selector(changeRemapButton))
        changeRemap.bezelStyle = .rounded
        changeRemap.controlSize = .small
        remapOffButton = NSButton(title: "Turn Off", target: self, action: #selector(turnOffRemap))
        remapOffButton.bezelStyle = .rounded
        remapOffButton.controlSize = .small
        let remapRow = NSStackView(views: [remapLabel, changeRemap, remapOffButton])
        remapRow.orientation = .horizontal
        remapRow.spacing = 10
        content.addArrangedSubview(remapRow)
        remapNote = wrapped("", size: 11, color: .secondaryLabelColor)
        content.addArrangedSubview(remapNote)
        refreshRemap()

        content.addArrangedSubview(separator())
        content.addArrangedSubview(header("Microphone"))
        micPopup = NSPopUpButton()
        micPopup.target = self
        micPopup.action = #selector(micChanged)
        content.addArrangedSubview(micPopup)
        micNote = wrapped("", size: 11, color: .secondaryLabelColor)
        content.addArrangedSubview(micNote)
        rebuildMicPopup()

        content.addArrangedSubview(separator())
        content.addArrangedSubview(header("Language"))
        content.addArrangedSubview(wrapped(
            "Tick nothing to auto-detect across all languages. Tick one to pin it. Tick a few "
            + "to detect only among those — which is what stops a short phrase being read as "
            + "the wrong language.",
            size: 11, color: .secondaryLabelColor))

        languageSearch = NSSearchField()
        languageSearch.placeholderString = "Search languages"
        languageSearch.target = self
        languageSearch.action = #selector(languageSearchChanged)
        languageSearch.delegate = self
        content.addArrangedSubview(languageSearch)
        languageSearch.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -44).isActive = true

        let langScroll = NSScrollView()
        langScroll.hasVerticalScroller = true
        langScroll.borderType = .bezelBorder
        langScroll.translatesAutoresizingMaskIntoConstraints = false
        langScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        languageTable = NSTableView()
        languageTable.rowHeight = 22
        languageTable.headerView = nil
        let langCol = NSTableColumn(identifier: .init("language"))
        langCol.width = 420
        languageTable.addTableColumn(langCol)
        languageTable.dataSource = self
        languageTable.delegate = self
        langScroll.documentView = languageTable
        content.addArrangedSubview(langScroll)
        langScroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -44).isActive = true

        languageHint = wrapped("", size: 11, color: .secondaryLabelColor)
        content.addArrangedSubview(languageHint)
        refreshLanguages()

        content.addArrangedSubview(separator())
        content.addArrangedSubview(header("Speech model"))
        modelLabel = NSTextField(labelWithString: "")
        modelLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let chooseModel = NSButton(title: "Choose or Download…", target: self,
                                   action: #selector(chooseModelTapped))
        chooseModel.bezelStyle = .rounded
        chooseModel.controlSize = .small
        let modelRow = NSStackView(views: [modelLabel, chooseModel])
        modelRow.orientation = .horizontal
        modelRow.spacing = 10
        content.addArrangedSubview(modelRow)
        content.addArrangedSubview(wrapped(
            "Bigger models hear more accurately and take longer. The picker shows the speed "
            + "you'd actually get on this Mac.", size: 11, color: .secondaryLabelColor))
        refreshModelLabel()

        content.addArrangedSubview(separator())
        content.addArrangedSubview(header("Cleanup"))
        let levelRow = NSStackView()
        levelRow.orientation = .horizontal
        levelRow.spacing = 18
        for level in CleanupLevel.allCases {
            let b = NSButton(radioButtonWithTitle: level.title, target: self,
                             action: #selector(levelChanged(_:)))
            b.tag = CleanupLevel.allCases.firstIndex(of: level) ?? 0
            b.state = (config.level == level) ? .on : .off
            levelButtons[level] = b
            levelRow.addArrangedSubview(b)
        }
        content.addArrangedSubview(levelRow)

        levelBlurb = wrapped(config.level.blurb, size: 11, color: .secondaryLabelColor)
        content.addArrangedSubview(levelBlurb)

        punctuationCheck = NSButton(checkboxWithTitle: "Spoken punctuation — say “question mark”, get “?”",
                                    target: nil, action: nil)
        punctuationCheck.state = config.spokenPunctuation ? .on : .off
        content.addArrangedSubview(punctuationCheck)

        jargonCheck = NSButton(checkboxWithTitle: "Learn new words automatically (with a 10s undo)",
                               target: nil, action: nil)
        jargonCheck.state = config.autoJargon ? .on : .off
        content.addArrangedSubview(jargonCheck)

        let cleanupSetup = NSButton(title: "Set Up Text Cleanup…", target: self,
                                    action: #selector(setUpCleanupTapped))
        cleanupSetup.bezelStyle = .rounded
        cleanupSetup.controlSize = .small
        content.addArrangedSubview(cleanupSetup)

        content.addArrangedSubview(separator())
        content.addArrangedSubview(header("While dictating"))
        let duckRow = NSStackView()
        duckRow.orientation = .horizontal
        duckRow.spacing = 18
        for setting in DuckSetting.allCases {
            let b = NSButton(radioButtonWithTitle: setting.title, target: self,
                             action: #selector(duckChanged(_:)))
            b.tag = DuckSetting.allCases.firstIndex(of: setting) ?? 0
            b.state = (config.ducking == setting) ? .on : .off
            b.isEnabled = AudioDucker.isSupported || setting == .off
            duckButtons[setting] = b
            duckRow.addArrangedSubview(b)
        }
        content.addArrangedSubview(duckRow)

        duckBlurb = wrapped(duckDescription, size: 11, color: .secondaryLabelColor)
        content.addArrangedSubview(duckBlurb)

        content.addArrangedSubview(separator())
        content.addArrangedSubview(header("Display & sound"))
        overlayCheck = NSButton(checkboxWithTitle: "Floating bar while dictating",
                                target: nil, action: nil)
        overlayCheck.state = config.showOverlay ? .on : .off
        content.addArrangedSubview(overlayCheck)

        soundsCheck = NSButton(checkboxWithTitle: "Play a sound when recording starts and stops",
                               target: nil, action: nil)
        soundsCheck.state = config.playSounds ? .on : .off
        content.addArrangedSubview(soundsCheck)

        boostCheck = NSButton(checkboxWithTitle: "Boost quiet audio before transcribing",
                              target: nil, action: nil)
        boostCheck.state = config.boostAudio ? .on : .off
        content.addArrangedSubview(boostCheck)

        content.addArrangedSubview(separator())
        content.addArrangedSubview(header("Updates"))
        autoUpdateCheck = NSButton(checkboxWithTitle: "Check for updates automatically",
                                   target: nil, action: nil)
        autoUpdateCheck.state = config.autoCheckUpdates ? .on : .off
        autoUpdateCheck.isEnabled = actions.updatesConfigured
        content.addArrangedSubview(autoUpdateCheck)

        let pending = actions.updateAvailable
        let checkNow = NSButton(title: pending == nil ? "Check Now" : "Update Now",
                                target: self, action: #selector(checkUpdatesTapped))
        checkNow.bezelStyle = .rounded
        checkNow.controlSize = .small
        checkNow.isEnabled = actions.updatesConfigured
        if pending != nil { checkNow.keyEquivalent = "\r" }   // the obvious thing to press
        let versionLabel = NSTextField(labelWithString: pending.map {
            "Version \(actions.appVersion) — \($0) available"
        } ?? "Version \(actions.appVersion)")
        versionLabel.font = pending == nil ? .systemFont(ofSize: 11)
                                           : .systemFont(ofSize: 11, weight: .semibold)
        versionLabel.textColor = pending == nil ? .secondaryLabelColor : .controlAccentColor
        let updateRow = NSStackView(views: [versionLabel, checkNow])
        updateRow.orientation = .horizontal
        updateRow.spacing = 10
        content.addArrangedSubview(updateRow)
        if !actions.updatesConfigured {
            content.addArrangedSubview(wrapped(
                "This build has no update feed configured, so it can't check.",
                size: 11, color: .secondaryLabelColor))
        }

        content.addArrangedSubview(separator())
        content.addArrangedSubview(header("Permissions"))
        permissionRows = NSStackView()
        permissionRows.orientation = .vertical
        permissionRows.alignment = .leading
        permissionRows.spacing = 6
        content.addArrangedSubview(permissionRows)
        refreshPermissions()

        content.addArrangedSubview(separator())
        content.addArrangedSubview(header("Personal dictionary"))
        content.addArrangedSubview(wrapped(
            "Terms on their own bias transcription toward that spelling. Give a term a "
            + "replacement and every transcript gets that substitution.",
            size: 11, color: .secondaryLabelColor))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.headerView = NSTableHeaderView()
        let termCol = NSTableColumn(identifier: .init("term"))
        termCol.title = "Heard / term"
        termCol.width = 200
        let replCol = NSTableColumn(identifier: .init("replacement"))
        replCol.title = "Replaced with"
        replCol.width = 200
        table.addTableColumn(termCol)
        table.addTableColumn(replCol)
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        content.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -44).isActive = true

        termField = NSTextField(string: "")
        termField.placeholderString = "Term (e.g. Qingyu)"
        replaceField = NSTextField(string: "")
        replaceField.placeholderString = "Replace with (optional)"
        let add = NSButton(title: "Add", target: self, action: #selector(addEntry))
        add.bezelStyle = .rounded
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeEntry))
        remove.bezelStyle = .rounded

        // The two fields share the leftover width equally; the buttons keep theirs.
        // Left to a single fill stack, the term field eats the row and the replacement
        // field collapses to nothing.
        let fields = NSStackView(views: [termField, replaceField])
        fields.orientation = .horizontal
        fields.spacing = 8
        fields.distribution = .fillEqually

        let addRow = NSStackView(views: [fields, add, remove])
        addRow.orientation = .horizontal
        addRow.spacing = 8
        addRow.distribution = .fill
        fields.setContentHuggingPriority(.defaultLow, for: .horizontal)
        add.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        remove.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        content.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -44).isActive = true

        content.addArrangedSubview(separator())
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let configFolder = NSButton(title: "Open Config Folder", target: self,
                                    action: #selector(openConfigFolderTapped))
        configFolder.bezelStyle = .rounded
        configFolder.controlSize = .small
        let buttons = NSStackView(views: [configFolder, NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        content.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -44).isActive = true

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "轻语 Settings"
        window.isReleasedWhenClosed = false
        // Keep it light whatever the system theme is doing — this panel is meant to
        // read as paper, not as another dark HUD.
        window.appearance = NSAppearance(named: .aqua)

        // Everything scrolls: the panel is now taller than a laptop screen, and clipping
        // the Save button off the bottom would be worse than a scroll bar.
        let scroller = NSScrollView()
        scroller.hasVerticalScroller = true
        scroller.drawsBackground = false
        scroller.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        scroller.contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroller.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroller.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroller.contentView.topAnchor),
        ])
        window.contentView = scroller
        contentStack = content
        window.setContentSize(NSSize(width: 520, height: min(content.fittingSize.height, 720)))
        window.delegate = self
    }

    private var contentStack: NSStackView!

    /// Re-fit after a control changed how tall the stack wants to be. Capped, because
    /// past a point the window has to scroll rather than grow.
    private func resize() {
        guard let stack = contentStack else { return }
        let height = min(stack.fittingSize.height, 720)
        guard abs(height - (window.contentView?.frame.height ?? 0)) > 1 else { return }
        window.setContentSize(NSSize(width: window.frame.width, height: height))
    }

    private func header(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        return f
    }

    private func wrapped(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: size)
        f.textColor = color
        f.isSelectable = false
        f.preferredMaxLayoutWidth = 460
        return f
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 476).isActive = true
        return b
    }

    // MARK: Push-to-talk

    private func refreshHotkeyLabel() {
        hotkeyLabel.stringValue = "Hold \(HotkeyCapture.name(for: config.pttKeyCode)) to talk"
    }

    @objc private func changeHotkey() {
        onCaptureKey { [weak self] keyCode in
            guard let self, let keyCode else { return }   // nil = Esc, keep the old key
            self.config.pttKeyCode = keyCode
            self.markEdited("pttKeyCode")
            self.refreshHotkeyLabel()
            self.refreshRemap()   // the new key may now collide with the remap button
        }
    }

    /// Bound button and why it might not be working. Set the same way push-to-talk is —
    /// by pressing the button — rather than from a list, because the number a mouse gives
    /// a thumb button rarely matches the number printed in its own software.
    private func refreshRemap() {
        remapLabel.stringValue = config.remapEnabled
            ? "Mouse button sends Return:  " + HotkeyCapture.name(for: config.remapButtonCode)
            : "Mouse button sends Return:  Off"
        remapOffButton.isEnabled = config.remapEnabled

        if !config.remapEnabled {
            remapNote.stringValue = "Press a mouse button to hit Return in any app — handy "
                + "for sending what you just dictated without reaching for the keyboard."
        } else if config.remapButtonCode == config.pttKeyCode {
            remapNote.stringValue = "⚠︎ That's already your push-to-talk button, so this stays "
                + "off until one of them changes."
        } else if !Permissions.accessibilityGranted {
            remapNote.stringValue = "⚠︎ Needs Accessibility. Unlike push-to-talk this has to "
                + "swallow the click, which macOS only allows with that permission granted."
        } else {
            remapNote.stringValue = "Sends Return in every app for as long as 轻语 is running."
        }
    }

    @objc private func changeRemapButton() {
        actions.captureMouseButton { [weak self] code in
            guard let self, let code else { return }   // nil = Esc, leave it alone
            self.config.remapEnabled = true
            self.config.remapButtonCode = code
            self.markEdited("remap")
            self.refreshRemap()
            self.resize()
        }
    }

    @objc private func turnOffRemap() {
        config.remapEnabled = false
        markEdited("remap")
        refreshRemap()
        resize()
    }

    @objc private func modeChanged(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else { return }
        for (key, button) in modeButtons { button.state = (key == value) ? .on : .off }
        config.hotkeyMode = value
        markEdited("hotkeyMode")
    }

    // MARK: Microphone

    /// System Default plus every connected input. A pinned device that isn't plugged in
    /// still gets a row, so the setting doesn't silently look like "System Default".
    private func rebuildMicPopup() {
        micPopup.removeAllItems()
        let devices = AudioDevices.inputs()
        let pinned = config.inputDeviceUID

        micPopup.addItem(withTitle: "System Default")
        micPopup.item(at: 0)?.representedObject = ""
        for device in devices {
            micPopup.addItem(withTitle: device.name)
            micPopup.lastItem?.representedObject = device.uid
        }

        if let uid = pinned, !uid.isEmpty, !devices.contains(where: { $0.uid == uid }) {
            micPopup.addItem(withTitle: "Pinned microphone (not connected)")
            micPopup.lastItem?.representedObject = uid
            micNote.stringValue = "That microphone isn't connected right now — 轻语 uses the "
                + "system default until it comes back."
        } else {
            micNote.stringValue = "Pinned by name, so 轻语 keeps using it even when macOS "
                + "switches the system default."
        }

        let index = micPopup.itemArray.firstIndex { ($0.representedObject as? String) == (pinned ?? "") }
        micPopup.selectItem(at: index ?? 0)
    }

    @objc private func micChanged() {
        let uid = (micPopup.selectedItem?.representedObject as? String) ?? ""
        config.inputDeviceUID = uid.isEmpty ? nil : uid
        markEdited("inputDeviceUID")
        rebuildMicPopup()
        resize()
    }

    // MARK: Language

    @objc private func languageSearchChanged() { refreshLanguages() }

    /// Ticked languages float to the top of an unfiltered list, so the current setting is
    /// visible without scrolling a hundred rows to find it.
    private func refreshLanguages() {
        let query = languageSearch.stringValue.trimmingCharacters(in: .whitespaces)
        let matches = Language.all.filter { $0.matches(query) }
        visibleLanguages = query.isEmpty
            ? matches.filter { selectedLanguages.contains($0.code) }
                + matches.filter { !selectedLanguages.contains($0.code) }
            : matches
        languageTable.reloadData()
        languageHint.stringValue = languageHintText
    }

    /// Same three states the menu bar describes: none = detect across everything, one =
    /// pinned, several = detect only among those.
    private var languageHintText: String {
        switch selectedLanguages.count {
        case 0: return "Detecting: all languages"
        case 1: return "Pinned to \(Language.label(selectedLanguages.first!))"
        default:
            let names = Language.all
                .filter { selectedLanguages.contains($0.code) }
                .map { Language.shortLabel($0.code) }
            return "Detecting only: " + names.joined(separator: ", ")
        }
    }

    @objc private func toggleLanguage(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < visibleLanguages.count else { return }
        let code = visibleLanguages[sender.tag].code
        if sender.state == .on { selectedLanguages.insert(code) } else { selectedLanguages.remove(code) }
        markEdited("languages")
        // Only the hint moves — re-sorting the list under the pointer mid-click, which a
        // full refresh would do, is hostile.
        languageHint.stringValue = languageHintText
    }

    // MARK: Actions

    @objc private func levelChanged(_ sender: NSButton) {
        let level = CleanupLevel.allCases[sender.tag]
        for (key, button) in levelButtons { button.state = (key == level) ? .on : .off }
        config.level = level
        markEdited("level")
        levelBlurb.stringValue = level.blurb
        window.setContentSize(NSSize(width: 520,
                                     height: (window.contentView?.fittingSize.height ?? 560)))
    }

    /// Explain the pick, and say plainly when the OS is too old rather than leaving
    /// two dead radio buttons with no reason given.
    private var duckDescription: String {
        guard AudioDucker.isSupported else {
            return "Needs macOS 14.4 or later — this Mac is on "
                 + ProcessInfo.processInfo.operatingSystemVersionString
                 + ", so other audio is left alone."
        }
        return config.ducking.blurb
    }

    @objc private func duckChanged(_ sender: NSButton) {
        let setting = DuckSetting.allCases[sender.tag]
        for (key, button) in duckButtons { button.state = (key == setting) ? .on : .off }
        config.ducking = setting
        markEdited("ducking")
        duckBlurb.stringValue = duckDescription
        window.setContentSize(NSSize(width: 520,
                                     height: (window.contentView?.fittingSize.height ?? 560)))
    }

    private func refreshModelLabel() {
        let file = (config.modelPath as NSString).lastPathComponent
        let name = SpeechModel.named(file)?.title ?? file
        let installed = FileManager.default.fileExists(atPath: config.modelPath)
        modelLabel.stringValue = installed ? name : "\(name) — not downloaded"
    }

    /// Three rows with a jump into the right System Settings pane. Rebuilt whenever the
    /// window comes back to the front, because the usual way to grant one of these is to
    /// leave, flip a switch, and come back.
    private func refreshPermissions() {
        permissionRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows: [(String, Bool, String)] = [
            ("Microphone", Permissions.microphoneGranted, "Microphone"),
            ("Accessibility", Permissions.accessibilityGranted, "Accessibility"),
            ("Input Monitoring", Permissions.inputMonitoringGranted, "ListenEvent"),
        ]
        for (name, granted, pane) in rows {
            let label = NSTextField(labelWithString: "\(granted ? "✓" : "✗")  \(name)")
            label.font = .systemFont(ofSize: 12)
            label.textColor = granted ? .labelColor : .systemOrange
            let button = NSButton(title: granted ? "Open…" : "Grant…", target: self,
                                  action: #selector(permissionTapped(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier(pane)
            let row = NSStackView(views: [label, button])
            row.orientation = .horizontal
            row.spacing = 10
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true
            permissionRows.addArrangedSubview(row)
        }
        if !Permissions.allGranted {
            permissionRows.addArrangedSubview(wrapped(
                "Push-to-talk needs Accessibility or Input Monitoring; the mouse-to-Return "
                + "binding needs Accessibility specifically.",
                size: 11, color: .secondaryLabelColor))
        }
    }

    @objc private func permissionTapped(_ sender: NSButton) {
        guard let pane = sender.identifier?.rawValue else { return }
        actions.openPermission(pane)
    }

    @objc private func chooseModelTapped() {
        actions.chooseModel()
        config = currentConfig()      // the chooser may have switched models
        refreshModelLabel()
    }

    @objc private func setUpCleanupTapped() { actions.setUpCleanup() }
    @objc private func openConfigFolderTapped() { actions.openConfigFolder() }
    @objc private func checkUpdatesTapped() { actions.checkForUpdates() }

    @objc private func addEntry() {
        let term = termField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let replacement = replaceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.removeAll { $0.term.lowercased() == term.lowercased() }
        entries.append(Entry(term: term, replacement: replacement.isEmpty ? nil : replacement))
        entries.sort { $0.term.lowercased() < $1.term.lowercased() }
        termField.stringValue = ""
        replaceField.stringValue = ""
        table.reloadData()
    }

    @objc private func removeEntry() {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return }
        entries.remove(at: row)
        table.reloadData()
    }

    @objc private func cancel() { close() }

    @objc private func save() {
        applyEdits()
        close()
    }

    /// Fold this window's edits into the app's config. Called by Save and by closing the
    /// window; `close()` orders out rather than closing, so neither path runs twice.
    private func applyEdits() {
        // Start from the app's config as it stands right now, not from the snapshot this
        // window opened with, then lay this window's edits on top. Writing the snapshot
        // back wholesale is what made a push-to-talk key set here lose to one set from the
        // menu bar (and vice versa), depending only on which was touched last.
        var out = currentConfig()

        // Only reachable here, so they always apply.
        out.customVocabulary = entries.filter { $0.replacement == nil }.map(\.term)
        out.replacements = entries.reduce(into: [String: String]()) { dict, entry in
            if let replacement = entry.replacement { dict[entry.term] = replacement }
        }
        out.spokenPunctuation = punctuationCheck.state == .on
        out.autoJargon = jargonCheck.state == .on
        out.showOverlay = overlayCheck.state == .on
        out.playSounds = soundsCheck.state == .on
        out.boostAudio = boostCheck.state == .on
        out.autoCheckUpdates = autoUpdateCheck.state == .on

        // Everything the menu bar can also change: apply only if touched in this window.
        if edited.contains("pttKeyCode")     { out.pttKeyCode = config.pttKeyCode }
        if edited.contains("hotkeyMode")     { out.hotkeyMode = config.hotkeyMode }
        if edited.contains("inputDeviceUID") { out.inputDeviceUID = config.inputDeviceUID }
        if edited.contains("level")          { out.level = config.level }
        if edited.contains("ducking")        { out.ducking = config.ducking }
        if edited.contains("remap") {
            out.remapEnabled = config.remapEnabled
            out.remapButtonCode = config.remapButtonCode
        }
        if edited.contains("languages") {
            // Keep the table's order rather than a Set's, so config.json reads the same
            // way twice running, and mirror `language` onto the single-pick case the way
            // the menu does — whisper takes one code, detectLanguages is our restriction.
            out.detectLanguages = Language.all.map(\.code).filter { selectedLanguages.contains($0) }
            out.language = out.detectLanguages.count == 1 ? out.detectLanguages[0] : "auto"
        }

        onSave(out)
    }

    private func close() {
        window.orderOut(nil)
        Self.open = nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === languageTable ? visibleLanguages.count : entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        if tableView === languageTable {
            let language = visibleLanguages[row]
            let check = NSButton(checkboxWithTitle: language.label, target: self,
                                 action: #selector(toggleLanguage(_:)))
            check.tag = row
            check.state = selectedLanguages.contains(language.code) ? .on : .off
            check.font = .systemFont(ofSize: 12)
            return check
        }
        let entry = entries[row]
        let text = tableColumn?.identifier.rawValue == "term"
            ? entry.term
            : (entry.replacement ?? "—")
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        if entry.replacement == nil && tableColumn?.identifier.rawValue != "term" {
            field.textColor = .tertiaryLabelColor
        }
        return field
    }
}

extension SettingsPanel: NSWindowDelegate {
    /// The red X (and ⌘W) apply, the way macOS's own Settings does. Save and Cancel both
    /// leave through `close()`, which orders the window out without asking the delegate,
    /// so this only ever fires for a close the user made from the window itself.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        applyEdits()
        return true
    }

    func windowWillClose(_ notification: Notification) { Self.open = nil }

    /// Granting a permission means leaving for System Settings and coming back, so the
    /// ✓/✗ rows have to re-read on return or they'd still show the old answer.
    func windowDidBecomeKey(_ notification: Notification) {
        guard permissionRows != nil else { return }
        refreshPermissions()
    }
}

extension SettingsPanel: NSSearchFieldDelegate {
    /// The search field's action only fires on Return; filtering has to track typing.
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === languageSearch else { return }
        refreshLanguages()
    }
}
