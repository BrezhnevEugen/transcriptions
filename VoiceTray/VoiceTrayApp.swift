import AppKit
import AVFAudio
import AVFoundation
import Carbon
import Security
import Speech
import SwiftUI

@main
struct VoiceTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let keychainStore = KeychainStore(service: "VoiceTray")
    private let debugLogStore = DebugLogStore()
    private lazy var menuBarController = MenuBarController(appDelegate: self)
    private lazy var recorder = AudioRecorder()
    private lazy var liveSpeechMonitor = LiveSpeechMonitor()
    private lazy var insertionService = TextInsertionService()
    private lazy var hotkeyManager = HotkeyManager { [weak self] in
        Task { await self?.toggleRecording() }
    }
    private var recordingTask: Task<Void, Never>?
    private var settingsWindow: NSWindow?
    private var debugWindow: NSWindow?
    private var targetApplicationBundleIdentifier: String?
    private var lastTargetApplicationBundleIdentifier: String?
    private var liveInsertedText = ""
    private var liveStableText = ""
    private var liveLatestPartialText = ""
    private var liveInsertedOutputText = ""
    private var liveInsertedAnyText = false
    private var liveInsertTask: Task<Void, Never>?
    private var currentStatus: AppStatus = .idle {
        didSet { menuBarController.update(status: currentStatus) }
    }
    private var autoStopTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("VoiceTray must stay available in the menu bar.")
        settingsStore.settings.enablePreviewBeforeInsert = false
        settingsStore.save()
        debugLogStore.log("App launched")
        debugLogStore.log("Insert mode: instant insert")
        menuBarController.install()
        hotkeyManager.registerDefaultHotkey()
        installTargetApplicationTracker()
        checkInitialPermissions()
        requestMicrophonePermissionOnFirstLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
    }

    func toggleRecording() async {
        if recorder.isRecording {
            debugLogStore.log("Stop recording requested")
            await stopAndProcessRecording()
        } else {
            await startRecording()
        }
    }

    func startRecordingFromMenu() {
        Task { await toggleRecording() }
    }

    func openSettings() {
        let view = SettingsView(
            settingsStore: settingsStore,
            keychainStore: keychainStore
        )
        let hostingController = NSHostingController(rootView: view)

        if settingsWindow == nil {
            let window = NSWindow(contentViewController: hostingController)
            window.title = "VoiceTray Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 520, height: 520))
            window.center()
            settingsWindow = window
        } else {
            settingsWindow?.contentViewController = hostingController
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func openDebugConsole() {
        let view = DebugConsoleView(debugLogStore: debugLogStore)
        let hostingController = NSHostingController(rootView: view)

        if debugWindow == nil {
            let window = NSWindow(contentViewController: hostingController)
            window.title = "VoiceTray Debug Console"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 760, height: 520))
            window.center()
            debugWindow = window
        } else {
            debugWindow?.contentViewController = hostingController
            debugWindow?.level = .floating
            debugWindow?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }

        NSApp.activate(ignoringOtherApps: true)
        debugWindow?.orderFrontRegardless()
        debugWindow?.makeKeyAndOrderFront(nil)
    }

    func requestMicrophonePermissionFromMenu() {
        Task {
            do {
                debugLogStore.log("Manual microphone permission request started")
                try recorder.triggerMicrophonePermissionProbe()
                try await ensureMicrophonePermission()
                debugLogStore.log("Microphone permission is available")
            } catch {
                debugLogStore.log("Microphone permission error: \(error.localizedDescription)")
                showError(error.localizedDescription)
            }
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func startRecording() async {
        do {
            targetApplicationBundleIdentifier = resolveTargetApplicationBundleIdentifier()
            liveInsertedText = ""
            liveStableText = ""
            liveLatestPartialText = ""
            liveInsertedOutputText = ""
            liveInsertedAnyText = false
            liveInsertTask = nil
            debugLogStore.log("Target app: \(targetApplicationBundleIdentifier ?? "unknown")")
            debugLogStore.log("Start recording requested")
            currentStatus = .listening
            try await ensureMicrophonePermission()
            startLiveSpeechMonitor()
            try recorder.start(maxDuration: settingsStore.settings.maxRecordingDurationSeconds) { [weak self] in
                self?.debugLogStore.log("Max recording duration reached")
                Task { await self?.stopAndProcessRecording() }
            }
            debugLogStore.log("Recording started")
            startSilenceAutoStopMonitor()
        } catch {
            debugLogStore.log("Recording start error: \(error.localizedDescription)")
            showError(error.localizedDescription)
            currentStatus = .error
            resetStatusSoon()
        }
    }

    private func stopAndProcessRecording() async {
        guard recorder.isRecording else { return }
        autoStopTask?.cancel()
        autoStopTask = nil
        liveSpeechMonitor.stop()
        debugLogStore.log("Live words monitor stopped")
        flushLatestLivePartialBeforeProcessing()

        do {
            currentStatus = .transcribing
            let audioURL = try recorder.stop()
            let audioSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.intValue ?? 0
            debugLogStore.log("Recording stopped: \(audioURL.lastPathComponent), \(audioSize) bytes")
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let settings = settingsStore.settings
            let platform = settings.aiPlatform
            debugLogStore.log("Selected AI platform: \(platform.title)")
            guard platform == .directAPI else {
                throw VoiceTrayError.platformUnavailable(platform.rawValue)
            }

            let apiKey = try keychainStore.read(key: "openai_api_key")
            debugLogStore.log("API key loaded from Keychain")
            let transcriber = OpenAITranscriptionService(apiKey: apiKey, settings: settings)
            debugLogStore.log("Sending audio to STT model: \(settings.transcriptionModel)")
            let transcription = try await transcriber.transcribe(audioFileURL: audioURL)
            debugLogStore.log("Transcription received, language: \(transcription.detectedLanguage ?? "unknown")")
            debugLogStore.log("Transcribed text: \(transcription.text)")

            var finalText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if settings.textProcessingMode != .raw {
                currentStatus = .translating
                debugLogStore.log("Text processing requested: \(settings.textProcessingMode.title), model: \(settings.textProcessingModel)")
                let processor = OpenAITextProcessingService(apiKey: apiKey, settings: settings)
                finalText = try await processor.process(
                    text: finalText,
                    sourceLanguage: transcription.detectedLanguage
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                debugLogStore.log("Processed text: \(finalText)")
            }

            if settings.targetLanguage != .auto {
                currentStatus = .translating
                debugLogStore.log("Translation requested: \(settings.targetLanguage.displayName), model: \(settings.translationModel)")
                let translator = OpenAITranslationService(apiKey: apiKey, settings: settings)
                finalText = try await translator.translate(
                    text: finalText,
                    sourceLanguage: transcription.detectedLanguage,
                    targetLanguage: settings.targetLanguage.displayName
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                debugLogStore.log("Translated text: \(finalText)")
            }

            guard !finalText.isEmpty else {
                throw VoiceTrayError.emptyTranscription
            }

            if settings.enablePreviewBeforeInsert {
                debugLogStore.log("Preview shown before insertion")
                finalText = await PreviewWindow.show(text: finalText) ?? ""
                guard !finalText.isEmpty else {
                    debugLogStore.log("Insertion cancelled from preview/copy")
                    currentStatus = .idle
                    return
                }
                debugLogStore.log("Preview accepted")
            }

            currentStatus = .inserting
            if liveInsertedAnyText {
                debugLogStore.log("Post-processing: replacing live draft with final text")
                await liveInsertTask?.value
                do {
                    try await insertionService.replaceLastInsertedText(
                        finalText,
                        replacingDraft: liveInsertedOutputText,
                        targetApplicationBundleIdentifier: targetApplicationBundleIdentifier
                    )
                    debugLogStore.log("Post-processing completed: live draft replaced")
                } catch VoiceTrayError.safeReplacementUnavailable {
                    debugLogStore.log("Post-processing: safe draft range not found. Appending processed text instead")
                    try await insertionService.insertText(
                        "\n" + finalText,
                        restoreClipboard: settings.restoreClipboardAfterInsert,
                        targetApplicationBundleIdentifier: targetApplicationBundleIdentifier
                    )
                    debugLogStore.log("Post-processing completed: processed text appended")
                }
            } else {
                debugLogStore.log("Insertion started. Accessibility trusted: \(AXIsProcessTrusted())")
                try await insertionService.insertText(
                    finalText,
                    restoreClipboard: settings.restoreClipboardAfterInsert,
                    targetApplicationBundleIdentifier: targetApplicationBundleIdentifier
                )
                debugLogStore.log("Insertion completed. Restore clipboard: \(settings.restoreClipboardAfterInsert)")
            }
            currentStatus = .idle
        } catch {
            debugLogStore.log("Pipeline error: \(error.localizedDescription)")
            showError(error.localizedDescription)
            currentStatus = .error
            resetStatusSoon()
        }
    }

    private func ensureMicrophonePermission() async throws {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return
            case .undetermined:
                let granted = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
                if !granted { throw VoiceTrayError.microphoneDenied }
                return
            case .denied:
                throw VoiceTrayError.microphoneDenied
            @unknown default:
                throw VoiceTrayError.microphoneDenied
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw VoiceTrayError.microphoneDenied }
        default:
            throw VoiceTrayError.microphoneDenied
        }
    }

    private func checkInitialPermissions() {
        if !AXIsProcessTrusted() {
            debugLogStore.log("Accessibility permission missing")
            menuBarController.setPermissionWarning()
        }
    }

    private func requestMicrophonePermissionOnFirstLaunch() {
        Task {
            let needsPrompt: Bool
            if #available(macOS 14.0, *) {
                needsPrompt = AVAudioApplication.shared.recordPermission == .undetermined
            } else {
                needsPrompt = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            }
            guard needsPrompt else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            debugLogStore.log("Auto microphone permission probe started")
            try? recorder.triggerMicrophonePermissionProbe()
            try? await ensureMicrophonePermission()
            debugLogStore.log("Auto microphone permission probe finished")
        }
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "VoiceTray"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func resetStatusSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            currentStatus = .idle
        }
    }

    private func resolveTargetApplicationBundleIdentifier() -> String? {
        let ignoredBundleIdentifiers: Set<String> = [
            Bundle.main.bundleIdentifier ?? "",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.finder"
        ]

        if let lastTargetApplicationBundleIdentifier,
           !ignoredBundleIdentifiers.contains(lastTargetApplicationBundleIdentifier) {
            return lastTargetApplicationBundleIdentifier
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           !ignoredBundleIdentifiers.contains(frontmost) {
            return frontmost
        }

        return NSWorkspace.shared.runningApplications
            .first { app in
                app.activationPolicy == .regular &&
                app.isActive &&
                !(app.bundleIdentifier.map { ignoredBundleIdentifiers.contains($0) } ?? false)
            }?
            .bundleIdentifier
    }

    private func installTargetApplicationTracker() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleIdentifier = application.bundleIdentifier,
                  !self.isIgnoredTargetBundleIdentifier(bundleIdentifier) else {
                return
            }
            self.lastTargetApplicationBundleIdentifier = bundleIdentifier
            self.debugLogStore.log("Last target app updated: \(application.localizedName ?? bundleIdentifier)")
        }
    }

    private func isIgnoredTargetBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        [
            Bundle.main.bundleIdentifier ?? "",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.finder"
        ].contains(bundleIdentifier)
    }

    private func startSilenceAutoStopMonitor() {
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var quietSince: Date?
            var lastTickSecond = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard recorder.isRecording else { return }

                let elapsed = Date().timeIntervalSince(startedAt)
                let elapsedSecond = Int(elapsed)
                if elapsedSecond > 0, elapsedSecond % 5 == 0, elapsedSecond != lastTickSecond {
                    lastTickSecond = elapsedSecond
                    debugLogStore.log("Recording active: \(elapsedSecond)s")
                }

                guard elapsed > 1.2 else { continue }
                let level = recorder.currentAveragePower()
                if level < -42 {
                    if quietSince == nil {
                        quietSince = Date()
                    }
                    if let quietSince, Date().timeIntervalSince(quietSince) > 12 {
                        debugLogStore.log("Long silence detected. Auto-stopping recording")
                        Task { await self.stopAndProcessRecording() }
                        return
                    }
                } else {
                    quietSince = nil
                }
            }
        }
    }

    private func startLiveSpeechMonitor() {
        let locale = liveSpeechLocale()
        liveSpeechMonitor.start(locale: locale) { [weak self] event in
            self?.debugLogStore.log(event)
        } onPartialText: { [weak self] partialText in
            self?.handleLivePartialText(partialText)
        }
    }

    private func liveSpeechLocale() -> Locale {
        switch settingsStore.settings.targetLanguage {
        case .english: return Locale(identifier: "en_US")
        case .german: return Locale(identifier: "de_DE")
        case .spanish: return Locale(identifier: "es_ES")
        case .french: return Locale(identifier: "fr_FR")
        case .russian, .auto: return Locale(identifier: "ru_RU")
        }
    }

    private func handleLivePartialText(_ partialText: String) {
        let normalizedPartial = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPartial.isEmpty else { return }
        liveLatestPartialText = normalizedPartial

        let stableText = stableLiveText(from: normalizedPartial)
        guard !stableText.isEmpty else { return }

        let delta = liveInsertionDelta(from: liveInsertedText, to: stableText)
        guard !delta.isEmpty else { return }

        liveStableText = stableText
        liveInsertedText = stableText
        liveInsertedOutputText += delta
        liveInsertedAnyText = true
        debugLogStore.log("Live insert: \(delta)")

        let previousTask = liveInsertTask
        liveInsertTask = Task {
            await previousTask?.value
            do {
                try await insertionService.insertText(
                    delta,
                    restoreClipboard: false,
                    targetApplicationBundleIdentifier: targetApplicationBundleIdentifier
                )
            } catch {
                debugLogStore.log("Live insert error: \(error.localizedDescription)")
            }
        }
    }

    private func flushLatestLivePartialBeforeProcessing() {
        let normalizedPartial = liveLatestPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPartial.isEmpty, normalizedPartial.count > liveInsertedText.count else { return }

        let delta = liveInsertionDelta(from: liveInsertedText, to: normalizedPartial)
        guard !delta.isEmpty else { return }

        liveStableText = normalizedPartial
        liveInsertedText = normalizedPartial
        liveInsertedOutputText += delta
        liveInsertedAnyText = true
        debugLogStore.log("Live flush on stop: \(delta)")

        let previousTask = liveInsertTask
        liveInsertTask = Task {
            await previousTask?.value
            do {
                try await insertionService.insertText(
                    delta,
                    restoreClipboard: false,
                    targetApplicationBundleIdentifier: targetApplicationBundleIdentifier
                )
            } catch {
                debugLogStore.log("Live flush error: \(error.localizedDescription)")
            }
        }
    }

    private func stableLiveText(from text: String) -> String {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
        guard words.count >= 2 else { return "" }

        let stableWords = words.dropLast()
        let stableText = stableWords.joined(separator: " ")
        guard stableText.count >= liveStableText.count else { return liveStableText }
        return stableText
    }

    private func liveInsertionDelta(from oldText: String, to newText: String) -> String {
        guard !newText.isEmpty else { return "" }
        guard !oldText.isEmpty else { return newText + " " }
        guard newText.hasPrefix(oldText) else {
            debugLogStore.log("Live correction ignored: \(newText)")
            return ""
        }

        let suffix = String(newText.dropFirst(oldText.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return "" }
        return suffix + " "
    }
}

enum AppStatus: String {
    case idle = "Ready"
    case listening = "Listening"
    case transcribing = "Transcribing"
    case translating = "Translating"
    case inserting = "Inserting"
    case error = "Error"

    var symbolName: String {
        switch self {
        case .idle: return "mic"
        case .listening: return "waveform"
        case .transcribing: return "text.bubble"
        case .translating: return "globe"
        case .inserting: return "keyboard"
        case .error: return "exclamationmark.triangle"
        }
    }

    var menuTitle: String {
        switch self {
        case .idle: return "VoiceTray"
        case .listening: return "REC"
        case .transcribing: return "STT"
        case .translating: return "TR"
        case .inserting: return "INS"
        case .error: return "ERR"
        }
    }
}

struct DebugLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

final class DebugLogStore: ObservableObject {
    @Published private(set) var entries: [DebugLogEntry] = []
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func log(_ message: String) {
        DispatchQueue.main.async {
            let entry = DebugLogEntry(timestamp: Date(), message: message)
            self.entries.append(entry)
            if self.entries.count > 500 {
                self.entries.removeFirst(self.entries.count - 500)
            }
        }
    }

    func clear() {
        entries.removeAll()
    }

    func exportText() -> String {
        entries
            .map { "[\(formatter.string(from: $0.timestamp))] \($0.message)" }
            .joined(separator: "\n")
    }

    func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

struct DebugConsoleView: View {
    @ObservedObject var debugLogStore: DebugLogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("VoiceTray Debug Console")
                    .font(.headline)
                Spacer()
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(debugLogStore.exportText(), forType: .string)
                }
                Button("Clear") {
                    debugLogStore.clear()
                }
            }

            Text("Shows recording → STT → translation → preview → insertion events. No API key is logged.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(debugLogStore.entries) { entry in
                            Text("[\(debugLogStore.timestamp(entry.timestamp))] \(entry.message)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: debugLogStore.entries) { entries in
                    if let last = entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 460)
    }
}

final class MenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var appDelegate: AppDelegate?
    private let statusMenuItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private let recordMenuItem = NSMenuItem(title: "Start Recording", action: #selector(record), keyEquivalent: "r")

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func install() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: AppStatus.idle.symbolName, accessibilityDescription: "VoiceTray")
            button.title = " VoiceTray"
        }

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        recordMenuItem.target = self
        menu.addItem(recordMenuItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let debugConsole = NSMenuItem(title: "Debug Console…", action: #selector(openDebugConsole), keyEquivalent: "d")
        debugConsole.target = self
        menu.addItem(debugConsole)

        let accessibility = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)

        let microphoneRequest = NSMenuItem(title: "Request Microphone Access", action: #selector(requestMicrophoneAccess), keyEquivalent: "")
        microphoneRequest.target = self
        menu.addItem(microphoneRequest)

        let microphoneSettings = NSMenuItem(title: "Open Microphone Settings", action: #selector(openMicrophoneSettings), keyEquivalent: "")
        microphoneSettings.target = self
        menu.addItem(microphoneSettings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func update(status: AppStatus) {
        DispatchQueue.main.async {
            self.statusMenuItem.title = status.rawValue
            self.recordMenuItem.title = status == .listening ? "Stop Recording" : "Start Recording"
            self.statusItem.button?.image = NSImage(systemSymbolName: status.symbolName, accessibilityDescription: status.rawValue)
            self.statusItem.button?.title = " \(status.menuTitle)"
        }
    }

    func setPermissionWarning() {
        statusMenuItem.title = "Accessibility permission recommended"
    }

    @objc private func record() {
        appDelegate?.startRecordingFromMenu()
    }

    @objc private func openSettings() {
        appDelegate?.openSettings()
    }

    @objc private func openDebugConsole() {
        appDelegate?.openDebugConsole()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func requestMicrophoneAccess() {
        appDelegate?.requestMicrophonePermissionFromMenu()
    }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func quit() {
        appDelegate?.quit()
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    let keychainStore: KeychainStore
    @State private var apiKey = ""
    @State private var savedMessage = ""

    var body: some View {
        Form {
            Picker("AI platform", selection: $settingsStore.settings.aiPlatform) {
                ForEach(AIPlatform.allCases) { platform in
                    Text(platform.title).tag(platform)
                }
            }

            if settingsStore.settings.aiPlatform != .directAPI {
                Text("This platform is listed for research. Production use requires an official external integration. Use Direct API for the current MVP.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Target language", selection: $settingsStore.settings.targetLanguage) {
                ForEach(TargetLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }

            Picker("Text processing", selection: $settingsStore.settings.textProcessingMode) {
                ForEach(TextProcessingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            TextField("OpenAI transcription model", text: $settingsStore.settings.transcriptionModel)
            TextField("OpenAI text processing model", text: $settingsStore.settings.textProcessingModel)
            TextField("OpenAI translation model", text: $settingsStore.settings.translationModel)
            SecureField("OpenAI API key", text: $apiKey)

            Toggle("Preview before insert", isOn: $settingsStore.settings.enablePreviewBeforeInsert)
            Toggle("Restore clipboard after insert", isOn: $settingsStore.settings.restoreClipboardAfterInsert)
            Stepper("Max recording: \(settingsStore.settings.maxRecordingDurationSeconds)s", value: $settingsStore.settings.maxRecordingDurationSeconds, in: 5...300, step: 5)

            HStack {
                Button("Save") {
                    settingsStore.save()
                    if !apiKey.isEmpty {
                        try? keychainStore.save(apiKey, key: "openai_api_key")
                    }
                    savedMessage = "Saved"
                }
                Button("Check Accessibility") {
                    if !AXIsProcessTrusted() {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                Text(savedMessage)
                    .foregroundStyle(.secondary)
            }

            Text("Default hotkey: Control + Option + Space")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear {
            apiKey = (try? keychainStore.read(key: "openai_api_key")) ?? ""
        }
        .onChange(of: settingsStore.settings) { _ in
            settingsStore.save()
        }
    }
}

final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings
    private let defaults = UserDefaults.standard
    private let key = "app_settings_v1"

    init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

struct AppSettings: Codable, Equatable {
    var aiPlatform: AIPlatform = .directAPI
    var targetLanguage: TargetLanguage = .auto
    var textProcessingMode: TextProcessingMode = .claudeStyle
    var transcriptionModel = "gpt-4o-mini-transcribe"
    var textProcessingModel = "gpt-4.1-mini"
    var translationModel = "gpt-4.1-mini"
    var maxRecordingDurationSeconds = 60
    var restoreClipboardAfterInsert = true
    var enablePreviewBeforeInsert = false
}

enum AIPlatform: String, Codable, CaseIterable, Identifiable {
    case directAPI
    case cursor
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directAPI: return "Direct API"
        case .cursor: return "Cursor"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

enum TextProcessingMode: String, Codable, CaseIterable, Identifiable {
    case raw
    case claudeStyle
    case cursorStyle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raw: return "Raw transcription"
        case .claudeStyle: return "Claude-style cleanup"
        case .cursorStyle: return "Cursor-style technical cleanup"
        }
    }
}

enum TargetLanguage: String, Codable, CaseIterable, Identifiable {
    case auto
    case russian
    case english
    case german
    case spanish
    case french

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto / Original"
        case .russian: return "Russian"
        case .english: return "English"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .french: return "French"
        }
    }
}

final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var maxDurationTimer: Timer?
    private var timeoutHandler: (() -> Void)?
    private var permissionEngine: AVAudioEngine?

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func start(maxDuration: Int, timeoutHandler: @escaping () -> Void) throws {
        self.timeoutHandler = timeoutHandler
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voicetray-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        recorder.record()
        self.recorder = recorder
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(maxDuration), repeats: false) { [weak self] _ in
            self?.timeoutHandler?()
        }
    }

    func triggerMicrophonePermissionProbe() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 128, format: format) { _, _ in }
        try engine.start()
        permissionEngine = engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak input] in
            input?.removeTap(onBus: 0)
            self?.permissionEngine?.stop()
            self?.permissionEngine = nil
        }
    }

    func stop() throws -> URL {
        guard let recorder else { throw VoiceTrayError.notRecording }
        maxDurationTimer?.invalidate()
        recorder.stop()
        self.recorder = nil
        return recorder.url
    }

    func currentAveragePower() -> Float {
        guard let recorder, recorder.isRecording else { return -160 }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }
}

final class LiveSpeechMonitor {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var lastPartial = ""
    private var committedText = ""
    private var isMonitoring = false

    func start(locale: Locale, log: @escaping (String) -> Void, onPartialText: @escaping (String) -> Void) {
        stop()
        isMonitoring = true
        lastPartial = ""
        committedText = ""
        log("Instant live words monitor starting")

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            guard status == .authorized else {
                log("Instant live words unavailable: Speech permission \(Self.authorizationDescription(status))")
                return
            }

            DispatchQueue.main.async {
                self.startRecognition(locale: locale, log: log, onPartialText: onPartialText)
            }
        }
    }

    func stop() {
        isMonitoring = false
        stopCurrentRecognition()
        committedText = ""
        lastPartial = ""
    }

    private func startRecognition(locale: Locale, log: @escaping (String) -> Void, onPartialText: @escaping (String) -> Void) {
        guard isMonitoring else { return }
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "ru_RU"))
        guard let recognizer, recognizer.isAvailable else {
            log("Instant live words unavailable: recognizer is not available for \(locale.identifier)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        self.request = request
        lastPartial = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            if !engine.isRunning {
                try engine.start()
            }
            log("Instant live words active: \(recognizer.locale.identifier)")
        } catch {
            input.removeTap(onBus: 0)
            log("Instant live words failed to start: \(error.localizedDescription)")
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let partial = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = self.combinedText(with: partial)
                if !text.isEmpty, text != self.lastPartial {
                    self.lastPartial = text
                    log("Instant live words: \(text)")
                    onPartialText(text)
                }
                if result.isFinal {
                    self.committedText = text
                    self.restartRecognition(locale: locale, log: log, onPartialText: onPartialText)
                }
            }
            if let error {
                log("Instant live words segment ended: \(error.localizedDescription)")
                self.restartRecognition(locale: locale, log: log, onPartialText: onPartialText)
            }
        }
    }

    private func restartRecognition(locale: Locale, log: @escaping (String) -> Void, onPartialText: @escaping (String) -> Void) {
        guard isMonitoring else { return }
        stopCurrentRecognition()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startRecognition(locale: locale, log: log, onPartialText: onPartialText)
        }
    }

    private func stopCurrentRecognition() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
    }

    private func combinedText(with partial: String) -> String {
        guard !committedText.isEmpty else { return partial }
        guard !partial.isEmpty else { return committedText }
        return committedText + " " + partial
    }

    private static func authorizationDescription(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
}
struct TranscriptionResult {
    let text: String
    let detectedLanguage: String?
}

final class OpenAITranscriptionService {
    private let apiKey: String
    private let settings: AppSettings

    init(apiKey: String, settings: AppSettings) {
        self.apiKey = apiKey
        self.settings = settings
    }

    func transcribe(audioFileURL: URL) async throws -> TranscriptionResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        var body = Data()
        body.appendMultipartField(name: "model", value: settings.transcriptionModel, boundary: boundary)
        body.appendMultipartField(name: "response_format", value: "json", boundary: boundary)
        body.appendMultipartFile(name: "file", filename: audioFileURL.lastPathComponent, contentType: "audio/mp4", data: audioData, boundary: boundary)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        return TranscriptionResult(text: decoded.text, detectedLanguage: decoded.language)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw VoiceTrayError.providerError(message)
        }
    }
}

struct OpenAITranscriptionResponse: Decodable {
    let text: String
    let language: String?
}

final class OpenAITextProcessingService {
    private let apiKey: String
    private let settings: AppSettings

    init(apiKey: String, settings: AppSettings) {
        self.apiKey = apiKey
        self.settings = settings
    }

    func process(text: String, sourceLanguage: String?) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = prompt(for: settings.textProcessingMode, text: text, sourceLanguage: sourceLanguage)
        let payload = OpenAIResponseRequest(model: settings.textProcessingModel, input: prompt)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Provider error"
            throw VoiceTrayError.providerError(message)
        }

        let decoded = try JSONDecoder().decode(OpenAIResponseResponse.self, from: data)
        if let output = decoded.outputText, !output.isEmpty {
            return output
        }
        return decoded.output?
            .flatMap { $0.content ?? [] }
            .compactMap { $0.text }
            .joined(separator: "\n") ?? ""
    }

    private func prompt(for mode: TextProcessingMode, text: String, sourceLanguage: String?) -> String {
        switch mode {
        case .raw:
            return text
        case .claudeStyle:
            return """
            You are a careful dictation editor similar to high-quality assistant chat input cleanup.
            Rewrite the dictated text into the user's intended message.
            Remove speech disfluencies, duplicated words, false starts, and filler.
            Preserve the user's meaning, tone, language, paragraph structure, technical terms, names, commands, URLs, filenames, code identifiers, and Markdown.
            Do not answer the message. Do not add new facts. Output only the cleaned text.
            Source language: \(sourceLanguage ?? "auto")

            Dictation:
            \(text)
            """
        case .cursorStyle:
            return """
            You are a technical dictation editor for coding chats and IDE prompts.
            Convert the dictated text into a concise, actionable developer prompt.
            Fix repeated words, broken syllables, punctuation, casing, and obvious speech-recognition artifacts.
            Preserve all code identifiers, file paths, commands, URLs, issue names, model names, keyboard shortcuts, and exact technical intent.
            If the text is casual chat, keep it casual; if it is a coding instruction, make it crisp like a Cursor/agent prompt.
            Do not solve the task. Do not add requirements. Output only the cleaned text.
            Source language: \(sourceLanguage ?? "auto")

            Dictation:
            \(text)
            """
        }
    }
}

final class OpenAITranslationService {
    private let apiKey: String
    private let settings: AppSettings

    init(apiKey: String, settings: AppSettings) {
        self.apiKey = apiKey
        self.settings = settings
    }

    func translate(text: String, sourceLanguage: String?, targetLanguage: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        Translate the text to \(targetLanguage). Preserve filenames, commands, URLs, Markdown, code identifiers, quotes, lists, and technical terms. Do not add information.
        Source language: \(sourceLanguage ?? "auto")

        \(text)
        """
        let payload = OpenAIResponseRequest(model: settings.translationModel, input: prompt)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Provider error"
            throw VoiceTrayError.providerError(message)
        }

        let decoded = try JSONDecoder().decode(OpenAIResponseResponse.self, from: data)
        if let output = decoded.outputText, !output.isEmpty {
            return output
        }
        let text = decoded.output?
            .flatMap { $0.content ?? [] }
            .compactMap { $0.text }
            .joined(separator: "\n") ?? ""
        return text
    }
}

struct OpenAIResponseRequest: Encodable {
    let model: String
    let input: String
}

struct OpenAIResponseResponse: Decodable {
    let outputText: String?
    let output: [OpenAIOutput]?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }
}

struct OpenAIOutput: Decodable {
    let content: [OpenAIContent]?
}

struct OpenAIContent: Decodable {
    let text: String?
}

final class TextInsertionService {
    func insertText(_ text: String, restoreClipboard: Bool, targetApplicationBundleIdentifier: String?) async throws {
        try await pasteText(text, restoreClipboard: restoreClipboard, targetApplicationBundleIdentifier: targetApplicationBundleIdentifier)
    }

    func replaceLastInsertedText(_ text: String, replacingDraft draft: String, targetApplicationBundleIdentifier: String?) async throws {
        guard AXIsProcessTrusted() else {
            throw VoiceTrayError.accessibilityDeniedCopied
        }

        try await activateTargetApplication(bundleIdentifier: targetApplicationBundleIdentifier)
        try await Task.sleep(nanoseconds: 200_000_000)

        guard selectDraftSuffixIfFocused(draft) else {
            throw VoiceTrayError.safeReplacementUnavailable
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        try await pasteText(text, restoreClipboard: false, targetApplicationBundleIdentifier: nil)
    }

    private func pasteText(_ text: String, restoreClipboard: Bool, targetApplicationBundleIdentifier: String?) async throws {
        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            throw VoiceTrayError.accessibilityDeniedCopied
        }

        try await activateTargetApplication(bundleIdentifier: targetApplicationBundleIdentifier)

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        if restoreClipboard {
            try await Task.sleep(nanoseconds: 600_000_000)
            pasteboard.clearContents()
            if let oldString {
                pasteboard.setString(oldString, forType: .string)
            }
        }
    }

    private func activateTargetApplication(bundleIdentifier: String?) async throws {
        guard let bundleIdentifier,
              let targetApplication = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return
        }
        targetApplication.activate(options: [.activateIgnoringOtherApps])
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    private func selectDraftSuffixIfFocused(_ draft: String) -> Bool {
        let candidates = replacementCandidates(for: draft)
        guard !candidates.isEmpty else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedElement = focusedValue else {
            return false
        }

        let element = focusedElement as! AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let currentValue = valueRef as? String else {
            return false
        }

        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
              let selectedRangeValue = selectedRangeRef,
              CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else {
            return false
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue as! AXValue, .cfRange, &selectedRange), selectedRange.length == 0 else {
            return false
        }

        let nsValue = currentValue as NSString
        for candidate in candidates {
            let candidateLength = (candidate as NSString).length
            guard selectedRange.location >= candidateLength else { continue }
            let start = selectedRange.location - candidateLength
            let previousText = nsValue.substring(with: NSRange(location: start, length: candidateLength))
            guard previousText == candidate else { continue }

            var replacementRange = CFRange(location: start, length: candidateLength)
            guard let axRange = AXValueCreate(.cfRange, &replacementRange) else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success
        }

        return false
    }

    private func replacementCandidates(for draft: String) -> [String] {
        let exact = draft
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        for candidate in [exact, trimmed] where !candidate.isEmpty && !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        return candidates
    }
}
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private let handler: () -> Void
    private var eventHandler: EventHandlerRef?

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func registerDefaultHotkey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handler()
            return noErr
        }, 1, &eventType, selfPointer, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x56545259), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}

final class KeychainStore {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func save(_ value: String, key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw VoiceTrayError.keychainError(status) }
    }

    func read(key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw VoiceTrayError.missingAPIKey
        }
        return value
    }
}

enum PreviewWindow {
    @MainActor
    static func show(text: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Preview transcription"
        alert.informativeText = "Edit text before inserting."
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 220))
        let textView = NSTextView(frame: scrollView.bounds)
        textView.string = text
        textView.isEditable = true
        textView.font = .systemFont(ofSize: 14)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        alert.accessoryView = scrollView

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return textView.string
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(textView.string, forType: .string)
            return nil
        default:
            return nil
        }
    }
}

enum VoiceTrayError: LocalizedError {
    case microphoneDenied
    case accessibilityDeniedCopied
    case missingAPIKey
    case keychainError(OSStatus)
    case providerError(String)
    case emptyTranscription
    case notRecording
    case platformUnavailable(String)
    case safeReplacementUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "No microphone access. Allow VoiceTray in System Settings → Privacy & Security → Microphone."
        case .accessibilityDeniedCopied:
            return "No Accessibility permission. The text remains in clipboard. Allow VoiceTray in System Settings → Privacy & Security → Accessibility."
        case .missingAPIKey:
            return "OpenAI API key is missing. Add it in VoiceTray Settings."
        case .keychainError(let status):
            return "Keychain error: \(status)."
        case .providerError(let message):
            return "AI provider error: \(message)"
        case .emptyTranscription:
            return "Speech was not recognized. Try recording again."
        case .notRecording:
            return "Recording is not active."
        case .platformUnavailable(let platform):
            return "\(platform) is available as a research option only. Use Direct API in the current MVP."
        case .safeReplacementUnavailable:
            return "Final text is ready, but VoiceTray could not safely select only the live draft. The draft was left untouched to avoid erasing existing chat text."
        }
    }
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(name: String, filename: String, contentType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
