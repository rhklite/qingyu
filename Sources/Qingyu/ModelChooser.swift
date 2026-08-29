import Cocoa

/// A whisper model 轻语 can fetch, plus the copy the setup window shows for it.
///
/// Speed figures are for one ~5s utterance. Apple Silicon numbers were measured on an
/// M4 Max (Metal); Intel numbers are estimates scaled from the same CPU-only build, so
/// they're ranges — an 8-core i9 lands near the bottom, a 2017 dual-core near the top.
///
/// Counter-intuitively Medium is the *faster* model in both cases: Turbo carries the
/// full large-v3 encoder, and whisper always encodes a padded 30s window, so its
/// 4-layer decoder never gets to pay that back on short dictation clips.
struct SpeechModel {
    let file: String            // basename under ~/.config/qingyu/models
    let title: String
    let bytes: Int64
    let quality: String
    let speedAppleSilicon: String
    let speedIntel: String

    static let catalog: [SpeechModel] = [
        SpeechModel(
            file: "ggml-large-v3-turbo-q5_0.bin",
            title: "Turbo — large-v3-turbo",
            bytes: 574_041_195,
            quality: "Best accuracy, clearly stronger on 中文 / 日本語, names and accented English.",
            speedAppleSilicon: "≈0.7s",
            speedIntel: "≈5–10s"
        ),
        SpeechModel(
            file: "ggml-medium-q5_0.bin",
            title: "Medium",
            bytes: 539_212_467,
            quality: "Solid on clear English; noticeably weaker on 中文 / 日本語 and proper nouns.",
            speedAppleSilicon: "≈0.4s",
            speedIntel: "≈3–6s"
        ),
    ]

    /// Whole decimal MB, so the two models read consistently side by side —
    /// ByteCountFormatter renders one as "574 MB" and the other as "539.2 MB".
    var sizeLabel: String { "\(bytes / 1_000_000) MB" }

    var speed: String {
        #if arch(arm64)
        return speedAppleSilicon
        #else
        return speedIntel
        #endif
    }

    var localURL: URL { Config.modelsDir.appendingPathComponent(file) }

    var remoteURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")!
    }

    /// Present and plausibly complete. Half-size means a previous attempt was cut short
    /// outside our own download path (e.g. a manual curl), so treat it as absent.
    var isInstalled: Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        guard let size = (attrs?[.size] as? NSNumber)?.int64Value else { return false }
        return size > bytes / 2
    }

    /// On Apple Silicon both models land under a second, so accuracy wins outright.
    /// On Intel the same gap is measured in seconds of waiting, which changes the answer.
    static var recommended: SpeechModel {
        #if arch(arm64)
        return catalog[0]
        #else
        return catalog[1]
        #endif
    }

    static func named(_ file: String) -> SpeechModel? {
        catalog.first { $0.file == file }
    }

    static var anyInstalled: Bool { catalog.contains(where: \.isInstalled) }

    /// Models shipped inside the app bundle. The DMG no longer bundles any (they're
    /// downloaded on first run), but the fallback stays so an offline build can.
    static var bundled: [SpeechModel] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("models"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return catalog.filter { files.contains($0.file) }
    }
}

/// What a setup run decided. Fields left nil mean "not part of this run" — the menu can
/// reopen just the speech step or just the cleanup step.
struct SetupResult {
    var model: SpeechModel?
    var cleanupEnabled: Bool?
    var modelsDir: String?      // non-nil when the user moved the model folder
}

/// Setup window. Two steps, both skippable in their own way:
///
///  1. Models — the speech model, and below it the optional cleanup model, so both
///     downloads are chosen and costed on one screen instead of one being sprung on the
///     user after the first has finished.
///  2. Text cleanup — the same optional local-LLM pass on its own, for the menu item
///     that turns it on later. First-run setup handles it in step 1 and skips this.
///
/// Cleanup needs Ollama, which 轻语 can't install for you, so both places adapt to
/// whether Ollama is running and whether the model is pulled.
@MainActor
final class ModelChooser: NSObject {
    private enum Step { case speech, cleanup }

    private var window: NSWindow!
    private var cards: [ModelCard] = []
    private var selected: SpeechModel
    private var result = SetupResult()
    private var confirmed = false

    private let includeSpeech: Bool
    private let fullSetup: Bool     // first run: also walk permissions + cleanup
    private let includeCleanup: Bool    // cleanup as its own step (menu item)
    private let cleanupInPicker: Bool   // cleanup offered alongside the speech model
    private let ollamaModel: String
    private var modelsDirLabel: NSTextField!
    private let ollama: OllamaClient
    private let downloader = ModelDownloader()

    // Speech step
    private var pickerView: NSStackView!
    private var continueButton: NSButton!
    private var errorLabel: NSTextField!
    private var cleanupCard: CleanupCard?

    // Shared progress view (whisper download and Ollama pull both use it)
    private var progressView: NSStackView!
    private var progressBar: NSProgressIndicator!
    private var progressTitle: NSTextField!
    private var progressDetail: NSTextField!

    // Cleanup step
    private var cleanupView: NSStackView!
    private var cleanupStatus: NSTextField!
    private var cleanupButtons: NSStackView!
    private var ollamaState: OllamaState = .unreachable

    // Permissions step
    private var permissionsView: NSStackView!
    private var permissionRows: NSTextField!

    #if arch(arm64)
    private static let isAppleSilicon = true
    #else
    private static let isAppleSilicon = false
    #endif

    private init(current: SpeechModel?, includeSpeech: Bool, fullSetup: Bool,
                 includeCleanup: Bool, cleanupInPicker: Bool,
                 ollamaURL: String, ollamaModel: String) {
        self.selected = current ?? SpeechModel.recommended
        self.includeSpeech = includeSpeech
        self.fullSetup = fullSetup
        self.includeCleanup = includeCleanup
        self.cleanupInPicker = cleanupInPicker
        self.ollamaModel = ollamaModel
        self.ollama = OllamaClient(baseURL: ollamaURL)
        super.init()
        buildWindow()
    }

    /// Full first-run setup: both models → permissions. The returned speech model is
    /// guaranteed to be on disk. `fullSetup: false` runs just the speech model step.
    static func present(current: SpeechModel?, fullSetup: Bool,
                        ollamaURL: String, ollamaModel: String) -> SetupResult? {
        ModelChooser(current: current, includeSpeech: true, fullSetup: fullSetup,
                     includeCleanup: false, cleanupInPicker: fullSetup,
                     ollamaURL: ollamaURL, ollamaModel: ollamaModel).run()
    }

    /// Just the cleanup step, for the menu.
    static func presentCleanup(ollamaURL: String, ollamaModel: String) -> Bool? {
        ModelChooser(current: nil, includeSpeech: false, fullSetup: false,
                     includeCleanup: true, cleanupInPicker: false,
                     ollamaURL: ollamaURL, ollamaModel: ollamaModel).run()?.cleanupEnabled
    }

    private func run() -> SetupResult? {
        NSApp.activate(ignoringOtherApps: true)
        if includeSpeech { showPicker() } else { enterCleanupStep() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        downloader.cancel()
        ollama.cancel()
        return confirmed ? result : nil
    }

    private func finishSetup() {
        confirmed = true
        NSApp.stopModal()
    }

    // MARK: Window

    private func buildWindow() {
        buildPickerView()
        buildProgressView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 508, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "轻语 Setup"
        window.isReleasedWhenClosed = false
        window.level = .floating
    }

    private func show(_ view: NSStackView) {
        window.contentView = view
        window.setContentSize(NSSize(width: 508, height: view.fittingSize.height))
    }

    private func label(_ text: String, font: NSFont,
                       color: NSColor = .labelColor, width: CGFloat? = nil) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        if let width { field.preferredMaxLayoutWidth = width }
        return field
    }

    private func stack() -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 14
        s.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        return s
    }

    private func buttonRow(_ buttons: [NSButton], in parent: NSStackView) -> NSStackView {
        let row = NSStackView(views: [NSView()] + buttons)
        row.orientation = .horizontal
        row.spacing = 10
        parent.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: parent.widthAnchor, constant: -48).isActive = true
        return row
    }

    private func button(_ title: String, _ selector: Selector, isDefault: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: self, action: selector)
        b.bezelStyle = .rounded
        if isDefault { b.keyEquivalent = "\r" }
        return b
    }

    // MARK: Step 1 — speech model

    private func buildPickerView() {
        pickerView = stack()
        pickerView.addArrangedSubview(label(cleanupInPicker ? "Choose your models" : "Choose your speech model",
                                            font: .systemFont(ofSize: 20, weight: .semibold)))
        pickerView.addArrangedSubview(label(hardwareBlurb, font: .systemFont(ofSize: 12),
                                            color: .secondaryLabelColor, width: 460))

        for model in SpeechModel.catalog {
            let card = ModelCard(model: model,
                                 isRecommended: model.file == SpeechModel.recommended.file) { [weak self] in
                self?.select(model)
            }
            cards.append(card)
            pickerView.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: pickerView.widthAnchor, constant: -48).isActive = true
        }

        // The cleanup model is a second download, so it belongs next to the first one
        // rather than sprung on the user after half a gigabyte has already landed.
        if cleanupInPicker {
            let card = CleanupCard(model: ollamaModel, sizeLabel: cleanupModelSize,
                                   blurb: cleanupCardBlurb,
                                   // Apple Silicon runs the pass in about half a second, so
                                   // it earns its place by default; on Intel it costs seconds
                                   // per phrase, which is not a default worth making for
                                   // someone who hasn't tried it yet.
                                   startsOn: Self.isAppleSilicon,
                                   onToggle: { [weak self] _ in self?.refreshSelection() },
                                   onGetOllama: { [weak self] in self?.openOllamaSite() },
                                   onRecheck: { [weak self] in self?.probeOllamaForPicker() })
            cleanupCard = card
            pickerView.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: pickerView.widthAnchor, constant: -48).isActive = true
        }

        let dirRow = modelsDirRow()
        pickerView.addArrangedSubview(dirRow)
        dirRow.widthAnchor.constraint(equalTo: pickerView.widthAnchor, constant: -48).isActive = true

        errorLabel = label("", font: .systemFont(ofSize: 11), color: .systemRed, width: 460)
        errorLabel.isHidden = true
        pickerView.addArrangedSubview(errorLabel)
        pickerView.addArrangedSubview(label(speechFootnote, font: .systemFont(ofSize: 11),
                                            color: .tertiaryLabelColor, width: 460))

        continueButton = button("Continue", #selector(confirmSpeech), isDefault: true)
        _ = buttonRow([continueButton], in: pickerView)
    }

    private var hardwareBlurb: String {
        Self.isAppleSilicon
            ? "This Mac has Apple Silicon, so transcription runs on the GPU (Metal) and both models "
              + "land well under a second — the difference isn't something you'll feel. Take the more "
              + "accurate one."
            : "This Mac has an Intel processor. Metal can't help here — whisper's GPU kernels need an "
              + "Apple-family GPU — so transcription runs on the CPU, and the model decides how long "
              + "you wait after releasing the key. That makes this a real trade-off:"
    }

    private var speechFootnote: String {
        let timing = Self.isAppleSilicon
            ? "Timings are for one ~5s sentence."
            : "Timings are estimates for one ~5s sentence and scale with your CPU."
        return timing + " The model is downloaded once and reused after that — you can switch "
            + "later from the menu bar → Speech Model."
    }

    private func showPicker() {
        show(pickerView)
        refreshSelection()
        if cleanupInPicker { probeOllamaForPicker() }
    }

    private func probeOllamaForPicker() {
        cleanupCard?.setState(nil, model: ollamaModel)      // "checking…"
        ollama.probe(model: ollamaModel) { [weak self] state in
            guard let self else { return }
            self.ollamaState = state
            self.cleanupCard?.setState(state, model: self.ollamaModel)
            self.refreshSelection()
            self.window.setContentSize(NSSize(width: 508, height: self.pickerView.fittingSize.height))
        }
    }

    private func select(_ model: SpeechModel) {
        selected = model
        refreshSelection()
    }

    /// True when the user asked for cleanup and Ollama can actually deliver it.
    private var cleanupRequested: Bool {
        (cleanupCard?.isOn ?? false) && ollamaState != .unreachable
    }

    private func refreshSelection() {
        for card in cards { card.setSelected(card.model.file == selected.file) }

        // Name every download the button is about to start, so half a gigabyte plus two
        // gigabytes is a number the user saw before clicking rather than after.
        var pending: [String] = []
        if !selected.isInstalled { pending.append(selected.sizeLabel) }
        if cleanupRequested, ollamaState == .needsModel {
            pending.append(cleanupModelSize ?? ollamaModel)
        }
        continueButton.title = pending.isEmpty ? "Continue" : "Download (\(pending.joined(separator: " + ")))"
    }

    @objc private func confirmSpeech() {
        result.model = selected
        if cleanupInPicker { result.cleanupEnabled = cleanupRequested }
        if selected.isInstalled {
            afterSpeechReady()
            return
        }
        errorLabel.isHidden = true
        beginSpeechDownload()
    }

    /// Speech model is on disk. Pull the cleanup model too if it was asked for and isn't
    /// already there, then carry on to permissions.
    private func afterSpeechReady() {
        guard cleanupInPicker, cleanupRequested, ollamaState == .needsModel else {
            advancePastSpeech()
            return
        }
        startCleanupPull(then: { [weak self] in self?.advancePastSpeech() })
    }

    private func advancePastSpeech() {
        if fullSetup { enterPermissionsStep() } else { advancePastPermissions() }
    }

    private func advancePastPermissions() {
        if includeCleanup { enterCleanupStep() } else { finishSetup() }
    }

    // MARK: Models folder

    private func modelsDirRow() -> NSStackView {
        modelsDirLabel = label(Self.prettyPath(Config.modelsDir), font: .systemFont(ofSize: 11),
                               color: .secondaryLabelColor)
        modelsDirLabel.lineBreakMode = .byTruncatingMiddle
        modelsDirLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let caption = label("Save to:", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseModelsDir))
        choose.bezelStyle = .rounded
        choose.controlSize = .small

        let row = NSStackView(views: [caption, modelsDirLabel, NSView(), choose])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private static func prettyPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// Let the user park half a gigabyte somewhere other than the home folder — an
    /// external drive, a bigger volume. Applied immediately so the "✓ DOWNLOADED"
    /// badges and the button label reflect the new location.
    @objc private func chooseModelsDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Config.modelsDir
        panel.prompt = "Use Folder"
        panel.message = "Where should 轻语 keep its speech models?"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Config.applyModelsDir(url.path)
        result.modelsDir = Config.modelsDir == Config.defaultModelsDir ? nil : Config.modelsDir.path
        modelsDirLabel.stringValue = Self.prettyPath(Config.modelsDir)
        for card in cards { card.refreshBadge() }
        refreshSelection()
        window.setContentSize(NSSize(width: 508, height: pickerView.fittingSize.height))
    }

    // MARK: Step 1.5 — permissions

    private func enterPermissionsStep() {
        buildPermissionsViewIfNeeded()
        refreshPermissionRows()
        show(permissionsView)
    }

    private func buildPermissionsViewIfNeeded() {
        guard permissionsView == nil else { return }
        permissionsView = stack()
        permissionsView.addArrangedSubview(label("Permissions",
                                                 font: .systemFont(ofSize: 20, weight: .semibold)))
        permissionsView.addArrangedSubview(label(
            "Microphone is a simple yes/no prompt. The other two are stored system-wide, so "
            + "System Settings will ask for an administrator password — if this Mac isn't yours "
            + "to administer, you can skip them.",
            font: .systemFont(ofSize: 12), color: .secondaryLabelColor, width: 460))

        permissionRows = label("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                               width: 460)
        permissionsView.addArrangedSubview(permissionRows)

        permissionsView.addArrangedSubview(label(
            "Without Accessibility, 轻语 still records and transcribes — it just puts the text on "
            + "your clipboard for you to paste with ⌘V, and you start dictation from the menu bar "
            + "instead of the ⌥ key. Nothing here blocks you from continuing.",
            font: .systemFont(ofSize: 11), color: .tertiaryLabelColor, width: 460))

        let request = button("Request Permissions…", #selector(requestPermissions))
        let recheck = button("Check Again", #selector(refreshPermissionRows))
        let cont = button("Continue", #selector(continuePastPermissions), isDefault: true)
        _ = buttonRow([request, recheck, cont], in: permissionsView)
    }

    @objc private func refreshPermissionRows() {
        func row(_ name: String, _ granted: Bool, _ why: String) -> String {
            "\(granted ? "✓" : "○")  \(name) — \(why)"
        }
        permissionRows.stringValue = [
            row("Microphone", Permissions.microphoneGranted, "record your voice (no password)"),
            row("Accessibility", Permissions.accessibilityGranted, "paste automatically (admin)"),
            row("Input Monitoring", Permissions.inputMonitoringGranted, "the push-to-talk key (admin)"),
        ].joined(separator: "\n")
        window.setContentSize(NSSize(width: 508, height: permissionsView.fittingSize.height))
    }

    @objc private func requestPermissions() {
        Permissions.requestAll()
        Permissions.openPrivacySettings(pane: "Accessibility")
    }

    @objc private func continuePastPermissions() {
        advancePastPermissions()
    }

    // MARK: Shared progress view

    private func buildProgressView() {
        progressView = stack()
        progressTitle = label("", font: .systemFont(ofSize: 17, weight: .semibold), width: 460)
        progressView.addArrangedSubview(progressTitle)

        progressBar = NSProgressIndicator()
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressView.addArrangedSubview(progressBar)
        progressBar.widthAnchor.constraint(equalTo: progressView.widthAnchor, constant: -48).isActive = true

        progressDetail = label("Starting…", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                               color: .secondaryLabelColor, width: 460)
        progressView.addArrangedSubview(progressDetail)

        progressNote = label("", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor, width: 460)
        progressView.addArrangedSubview(progressNote)

        let cancel = button("Cancel", #selector(cancelProgress))
        cancel.keyEquivalent = "\u{1b}"
        _ = buttonRow([cancel], in: progressView)
    }

    private var progressNote: NSTextField!

    private func showProgress(title: String, note: String) {
        progressTitle.stringValue = title
        progressNote.stringValue = note
        progressBar.doubleValue = 0
        progressDetail.stringValue = "Connecting…"
        show(progressView)
    }

    @objc private func cancelProgress() {
        downloader.cancel()
        ollama.cancel()
        if includeSpeech && result.model != nil && !(result.model?.isInstalled ?? false) {
            showPicker()          // cancelled the speech download — back to the picker
        } else if cleanupInPicker {
            // Cancelling the optional second download shouldn't cost the first one, which
            // has already landed — drop cleanup and carry on with the rest of setup.
            result.cleanupEnabled = false
            cleanupCard?.setOn(false)
            advancePastSpeech()
        } else {
            enterCleanupStep()    // cancelled the Ollama pull — back to the cleanup step
        }
    }

    private func beginSpeechDownload() {
        let model = selected
        showProgress(title: "Downloading \(model.title)",
                     note: "One-time download into ~/.config/qingyu/models. 轻语 works offline afterwards.")

        downloader.start(model: model) { [weak self] progress in
            self?.updateBytesProgress(progress.fraction, received: progress.received,
                                      total: progress.total, rate: progress.bytesPerSecond,
                                      eta: progress.secondsRemaining)
        } onFinish: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.afterSpeechReady()
            case .failure(let error):
                self.showPicker()
                self.errorLabel.stringValue = "Download failed: \(error.localizedDescription)"
                self.errorLabel.isHidden = false
                self.show(self.pickerView)
            }
        }
    }

    private func updateBytesProgress(_ fraction: Double, received: Int64, total: Int64,
                                     rate: Double, eta: Double?) {
        progressBar.doubleValue = fraction
        let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        var line = total > 0
            ? "\(got) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
            : got
        if rate > 1 {
            line += " · \(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file))/s"
        }
        if let eta, eta < 3600 {
            let mins = Int(eta) / 60, secs = Int(eta) % 60
            line += mins > 0 ? " · about \(mins)m \(secs)s left" : " · about \(secs)s left"
        }
        progressDetail.stringValue = line
    }

    // MARK: Step 2 — text cleanup

    private func enterCleanupStep() {
        buildCleanupViewIfNeeded()
        cleanupStatus.stringValue = "Checking for Ollama…"
        setCleanupButtons([button("Skip", #selector(skipCleanup))])
        show(cleanupView)
        ollama.probe(model: ollamaModel) { [weak self] state in
            self?.applyOllamaState(state)
        }
    }

    private func buildCleanupViewIfNeeded() {
        guard cleanupView == nil else { return }
        cleanupView = stack()
        cleanupView.addArrangedSubview(label("Clean up the text? (optional)",
                                             font: .systemFont(ofSize: 20, weight: .semibold)))
        cleanupView.addArrangedSubview(label(
            "A small language model can tidy each transcript before it's pasted: drop “um” and "
            + "“uh”, fix punctuation and capitalization, and respect your custom vocabulary. It "
            + "runs locally through Ollama — nothing is uploaded.",
            font: .systemFont(ofSize: 12), color: .secondaryLabelColor, width: 460))
        cleanupView.addArrangedSubview(label(cleanupCostBlurb, font: .systemFont(ofSize: 12),
                                             color: .secondaryLabelColor, width: 460))

        cleanupStatus = label("", font: .systemFont(ofSize: 12, weight: .medium), width: 460)
        cleanupView.addArrangedSubview(cleanupStatus)

        cleanupView.addArrangedSubview(label(
            "轻语 works fine without this — you just get whisper's raw transcript, and you can "
            + "turn cleanup on later from the menu bar.",
            font: .systemFont(ofSize: 11), color: .tertiaryLabelColor, width: 460))

        cleanupButtons = buttonRow([], in: cleanupView)
    }

    /// Only the default model's size is known before pulling — Ollama can't report the
    /// size of a model it hasn't fetched, and config.json can point at any model.
    private var cleanupModelSize: String? {
        ollamaModel == "qwen2.5:3b" ? "~1.9 GB" : nil
    }

    private var cleanupDownloadLabel: String {
        cleanupModelSize.map { "Download \(ollamaModel) (\($0))" } ?? "Download \(ollamaModel)"
    }

    /// Same trade-off as `cleanupCostBlurb`, compressed to fit on the picker card.
    private var cleanupCardBlurb: String {
        let base = "Tidies each transcript before it's pasted — drops “um” and “uh”, fixes "
            + "punctuation, respects your custom words. Runs locally through Ollama; nothing "
            + "is uploaded. "
        return base + (Self.isAppleSilicon
            ? "About half a second per phrase on this Mac."
            : "On this Intel Mac it runs on the CPU and adds several seconds per phrase — "
              + "easy to regret, and leaving it off is a perfectly good choice.")
    }

    /// The honest cost, which differs enough per architecture to change the answer.
    private var cleanupCostBlurb: String {
        let size = cleanupModelSize.map { "a \($0) model" } ?? "a one-time model download"
        return Self.isAppleSilicon
            ? "It costs roughly half a second per phrase on this Mac, and needs \(size)."
            : "On this Intel Mac it runs on the CPU and adds several seconds per phrase on top of "
              + "transcription, and needs \(size). Worth trying, but easy to regret — "
              + "leaving it off is a perfectly good choice here."
    }

    private func setCleanupButtons(_ buttons: [NSButton]) {
        for view in cleanupButtons.arrangedSubviews.dropFirst() { view.removeFromSuperview() }
        for b in buttons { cleanupButtons.addArrangedSubview(b) }
        window.setContentSize(NSSize(width: 508, height: cleanupView.fittingSize.height))
    }

    private func applyOllamaState(_ state: OllamaState) {
        ollamaState = state
        switch state {
        case .ready:
            cleanupStatus.stringValue = "✓ Ollama is running and \(ollamaModel) is installed."
            cleanupStatus.textColor = .systemGreen
            setCleanupButtons([button("Skip", #selector(skipCleanup)),
                               button("Enable Cleanup", #selector(enableCleanup), isDefault: true)])
        case .needsModel:
            cleanupStatus.stringValue = "Ollama is running, but \(ollamaModel) hasn't been downloaded yet."
            cleanupStatus.textColor = .labelColor
            setCleanupButtons([button("Skip", #selector(skipCleanup)),
                               button(cleanupDownloadLabel, #selector(pullCleanupModel),
                                      isDefault: true)])
        case .unreachable:
            // Be explicit that the escape hatch has a cost: Ollama's installer places a
            // CLI in /usr/local/bin and will ask for an admin password. Nothing 轻语 does
            // needs one, and skipping here costs only the cleanup pass.
            cleanupStatus.stringValue = "Ollama isn't installed, or its server isn't running. "
                + "轻语 can't install it for you, and Ollama's own installer asks for an "
                + "administrator password — skip this if you don't have one."
            cleanupStatus.textColor = .secondaryLabelColor
            setCleanupButtons([button("Skip", #selector(skipCleanup), isDefault: true),
                               button("Get Ollama…", #selector(openOllamaSite)),
                               button("Check Again", #selector(recheckOllama))])
        }
    }

    @objc private func skipCleanup() {
        result.cleanupEnabled = false
        finishSetup()
    }

    @objc private func enableCleanup() {
        result.cleanupEnabled = true
        finishSetup()
    }

    @objc private func openOllamaSite() {
        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
    }

    @objc private func recheckOllama() {
        cleanupStatus.stringValue = "Checking for Ollama…"
        cleanupStatus.textColor = .labelColor
        setCleanupButtons([button("Skip", #selector(skipCleanup))])
        ollama.probe(model: ollamaModel) { [weak self] state in
            self?.applyOllamaState(state)
        }
    }

    @objc private func pullCleanupModel() {
        startCleanupPull(then: { [weak self] in self?.finishSetup() })
    }

    private func startCleanupPull(then next: @escaping () -> Void) {
        showProgress(title: "Downloading \(ollamaModel)",
                     note: "Ollama stores this model itself; 轻语 just asks it to fetch one.")
        ollama.pull(model: ollamaModel) { [weak self] progress in
            guard let self else { return }
            // Ollama reports progress per layer, and the manifest/config layers are a few
            // hundred bytes each — showing those would read "490 bytes of 490 bytes" and
            // yank the bar back to zero between weight layers. Only the real ones drive it.
            if progress.total > 5_000_000 {
                self.updateBytesProgress(progress.fraction, received: progress.completed,
                                         total: progress.total, rate: 0, eta: nil)
            } else if !progress.status.isEmpty {
                self.progressDetail.stringValue = progress.status
            }
        } onFinish: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.result.cleanupEnabled = true
                self.ollamaState = .ready
                self.cleanupCard?.setState(.ready, model: self.ollamaModel)
                next()
            case .failure(let error):
                // The speech model is already on disk by now, so a failure here is not a
                // failed setup — put the user back where they can retry or drop cleanup.
                if self.cleanupInPicker {
                    self.showPicker()
                    self.errorLabel.stringValue = "\(self.ollamaModel) download failed: "
                        + error.localizedDescription
                    self.errorLabel.isHidden = false
                } else {
                    self.enterCleanupStep()
                    self.cleanupStatus.stringValue = "Download failed: \(error.localizedDescription)"
                    self.cleanupStatus.textColor = .systemRed
                }
            }
        }
    }
}

/// The cleanup model, as an opt-in card on the model picker: a checkbox rather than a
/// radio, because it sits alongside the speech choice instead of competing with it.
///
/// Unlike a whisper model this one isn't ours to fetch — Ollama owns it — so the card
/// carries its own status line and, when Ollama is missing, the two buttons that are the
/// only way forward from there.
@MainActor
private final class CleanupCard: NSView {
    private let check = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let actions = NSStackView()
    private let onToggle: (Bool) -> Void
    private let onGetOllama: () -> Void
    private let onRecheck: () -> Void

    var isOn: Bool { check.state == .on }

    init(model: String, sizeLabel: String?, blurb: String, startsOn: Bool,
         onToggle: @escaping (Bool) -> Void,
         onGetOllama: @escaping () -> Void,
         onRecheck: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onGetOllama = onGetOllama
        self.onRecheck = onRecheck
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        check.setButtonType(.switch)
        check.target = self
        check.action = #selector(toggled)
        check.state = startsOn ? .on : .off
        check.attributedTitle = Self.heading(model: model, sizeLabel: sizeLabel)
        check.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(wrappingLabelWithString: blurb)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 380
        detail.isSelectable = false

        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.preferredMaxLayoutWidth = 380
        status.isSelectable = false

        let get = NSButton(title: "Get Ollama…", target: self, action: #selector(getOllama))
        get.bezelStyle = .rounded
        get.controlSize = .small
        let recheck = NSButton(title: "Check Again", target: self, action: #selector(recheckOllama))
        recheck.bezelStyle = .rounded
        recheck.controlSize = .small
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.addArrangedSubview(get)
        actions.addArrangedSubview(recheck)
        actions.isHidden = true

        let text = NSStackView(views: [check, detail, status, actions])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            bottomAnchor.constraint(equalTo: text.bottomAnchor, constant: 11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func heading(model: String, sizeLabel: String?) -> NSAttributedString {
        let s = NSMutableAttributedString(
            string: "Text cleanup — \(model)",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        if let sizeLabel {
            s.append(NSAttributedString(
                string: "   \(sizeLabel)",
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return s
    }

    /// `nil` means the probe is still in flight.
    func setState(_ state: OllamaState?, model: String) {
        switch state {
        case nil:
            status.stringValue = "Checking for Ollama…"
            status.textColor = .secondaryLabelColor
            actions.isHidden = true
            check.isEnabled = true
        case .ready:
            status.stringValue = "✓ Ollama is running and \(model) is already downloaded."
            status.textColor = .systemGreen
            actions.isHidden = true
            check.isEnabled = true
        case .needsModel:
            status.stringValue = "Ollama is running — \(model) will be downloaded with your speech model."
            status.textColor = .secondaryLabelColor
            actions.isHidden = true
            check.isEnabled = true
        case .unreachable:
            // Ollama's own installer wants an admin password, which 轻语 never does —
            // say so here rather than letting someone hit that wall unprepared.
            status.stringValue = "Ollama isn't installed or isn't running, and 轻语 can't install it "
                + "for you. Its installer asks for an administrator password — leave this off if "
                + "you don't have one."
            status.textColor = .secondaryLabelColor
            actions.isHidden = false
            check.state = .off
            check.isEnabled = false
        }
    }

    func setOn(_ on: Bool) { check.state = on ? .on : .off }

    @objc private func toggled() { onToggle(isOn) }
    @objc private func getOllama() { onGetOllama() }
    @objc private func recheckOllama() { onRecheck() }
}

/// One clickable model row: radio dot, title, size, speed on *this* Mac, quality note.
@MainActor
private final class ModelCard: NSView {
    let model: SpeechModel
    private let radio = NSButton()
    private let onClick: () -> Void
    private let isRecommended: Bool
    private var titleField: NSTextField!

    init(model: SpeechModel, isRecommended: Bool, onClick: @escaping () -> Void) {
        self.model = model
        self.onClick = onClick
        self.isRecommended = isRecommended
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        radio.setButtonType(.radio)
        radio.title = ""
        radio.target = self
        radio.action = #selector(clicked)
        radio.translatesAutoresizingMaskIntoConstraints = false

        titleField = NSTextField(labelWithAttributedString: NSAttributedString(string: ""))
        refreshBadge()
        let speedField = NSTextField(labelWithString: "\(model.speed) per sentence on this Mac")
        speedField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let qualityField = NSTextField(wrappingLabelWithString: model.quality)
        qualityField.font = .systemFont(ofSize: 11)
        qualityField.textColor = .secondaryLabelColor
        qualityField.preferredMaxLayoutWidth = 380
        qualityField.isSelectable = false

        let text = NSStackView(views: [titleField, speedField, qualityField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(radio)
        addSubview(text)
        NSLayoutConstraint.activate([
            radio.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            radio.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            text.leadingAnchor.constraint(equalTo: radio.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            bottomAnchor.constraint(equalTo: text.bottomAnchor, constant: 11),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Rebuilt on demand: moving the models folder changes whether this model counts
    /// as already downloaded, and the badge is the whole point of the row.
    func refreshBadge() {
        let heading = NSMutableAttributedString(
            string: model.title,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        heading.append(NSAttributedString(
            string: "   \(model.sizeLabel)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        if isRecommended {
            heading.append(NSAttributedString(
                string: "   RECOMMENDED",
                attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                             .foregroundColor: NSColor.controlAccentColor]))
        }
        // Downloaded already? Say so — it's the difference between instant and a
        // half-gigabyte wait, which should be visible before clicking.
        if model.isInstalled {
            heading.append(NSAttributedString(
                string: "   ✓ DOWNLOADED",
                attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                             .foregroundColor: NSColor.systemGreen]))
        }
        titleField.attributedStringValue = heading
    }

    @objc private func clicked() { onClick() }

    func setSelected(_ on: Bool) {
        radio.state = on ? .on : .off
        layer?.borderColor = (on ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = (on
            ? NSColor.controlAccentColor.withAlphaComponent(0.08)
            : NSColor.clear).cgColor
    }
}
