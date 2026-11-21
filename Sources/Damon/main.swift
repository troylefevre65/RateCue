import AppKit
import AVFoundation
import DamonPlatform
import DamonPolicy
import Foundation
import ServiceManagement

private let musicBundleID = PlaybackSample.musicBundleID

private struct QualificationSnapshot: Encodable {
    let schemaVersion = 1
    let snapshotAt = Date()
    let status: String
    let music: String
    let observationAgeMilliseconds: Int?
    let playbackState: String?
    let activeOutputs: [String]
    let sourceRateHz: Int?
    let sourceBitDepth: Int?
    let preferredDeviceRateHz: Int?
    let autoSwitchEnabled: Bool
}

@MainActor
private final class DamonApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let store = SettingsStore()
    private var settings = DamonSettings()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var refresh: Task<Void, Never>?
    private var model = AlignmentMachine()
    private var epoch = Epoch(playback: 0, route: 0)
    private var playbackBoundary: TimeInterval = 0
    private var observedTrackChange = false
    private let verifier = VerificationMonitor()
    private var previous: PlaybackSample?
    private var previousDevice: OutputDevice?
    private var previousMusicPID: pid_t?
    private var currentFormat = Format()
    private var lastMessage = ""
    private var permissionMessage: String?
    private var settingsError: String?
    private var writeWarning: String?
    private var logs: [String] = []
    private var preferenceGeneration = 0
    private var appliedPreferenceGeneration = -1
    private var showRate: Bool { settings.showSampleRate }
    private var showDepth: Bool { settings.showBitDepth }
    private var automatic: Bool { settings.autoSwitch }
    private var automation: Bool { settings.monitorMusic }
    private var preferredUID: String? { settings.preferredOutputUID }
    private var approvedFolder: URL? { settings.authorizedAudio }
    private let qualifiedConfigurations = Bundle.main.object(forInfoDictionaryKey: "DamonQualifiedLocalOutputs") as? [[String: String]] ?? []
    private var verificationProfiles: [SensorProfile] = []

    private var profile: SensorProfile? { verificationProfiles.first { $0.deviceUID == preferredUID } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "DamonSensorProfiles") {
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
                verificationProfiles = try PropertyListDecoder().decode([SensorProfile].self, from: data)
            } catch {
                appendLog("Hardware verification profiles could not be read: \(error.localizedDescription)")
            }
        }
        menu.delegate = self
        item.menu = menu
        updateButton()
        refresh = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                let interval = self.model.state == .aligning ? 50 :
                    self.previous?.playback?.state == .playing ? 300 :
                    self.automation && self.previous?.playback != nil ? 500 : 1_000
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refresh?.cancel()
        verifier.stop()
    }

    private func tick() async {
        guard reloadSettings() else { return }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).first?.processIdentifier
        let enabled = automation
        let folder = approvedFolder
        let generation = preferenceGeneration
        let sample = await Task.detached {
            PlaybackSample.collect(pid: pid, automation: enabled, folder: folder, includeRateEstimate: true)
        }.value
        guard !Task.isCancelled, reloadSettings(), generation == preferenceGeneration else { return }
        let formatChanged = previous?.format != sample.format
        let repeatOrSeek = if let old = previous?.playback?.position, let new = sample.playback?.position {
            old - new > 0.5 && new >= 0 && new < 1
        } else { false }
        let playbackChanged = previous?.playback?.trackID != sample.playback?.trackID
            || previous?.playback?.state != sample.playback?.state || previousMusicPID != pid || formatChanged || repeatOrSeek
        let preferred = sample.preferredOutput(uid: preferredUID)
        let routeChanged = previous?.route != sample.route || previousDevice?.objectID != preferred?.objectID
            || previousDevice?.uid != preferred?.uid || appliedPreferenceGeneration != generation
        if playbackChanged || routeChanged || previous == nil {
            writeWarning = nil
            observedTrackChange = if let old = previous?.playback?.trackID, let new = sample.playback?.trackID {
                old != new
            } else { false }
            playbackBoundary = sample.at
            epoch = Epoch(playback: epoch.playback + (playbackChanged ? 1 : 0), route: epoch.route + (routeChanged ? 1 : 0))
        }
        appliedPreferenceGeneration = generation
        previous = sample
        previousDevice = preferred
        previousMusicPID = pid
        let now = ProcessInfo.processInfo.systemUptime
        let evidence = sample.format.map { [Evidence(epoch: epoch, source: .musicMetadata, at: sample.at, format: $0)] } ?? []
        let resolution = Confidence.resolve(evidence, epoch: epoch, since: playbackBoundary, now: now)
        let routeConfirmed = preferred.map { sample.route == [$0.objectID] } ?? false
        verifier.configure(profile: profile, playing: sample.playback?.state == .playing && routeConfirmed,
                           cameraEnabled: defaults.bool(forKey: "cameraVerification"),
                           microphoneEnabled: defaults.bool(forKey: "relayVerification"))
        func alignmentInput(readback: Int?) -> AlignmentInput {
            var endpoints = sample.outputs.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.endpoint, $0.nominalRate) }) }
            if let preferred, readback != preferred.nominalRate {
                endpoints?[preferred.endpoint] = .some(readback)
            }
            return AlignmentInput(
                epoch: epoch, playbackBoundary: playbackBoundary, playing: sample.playback?.state == .playing,
                enabled: automatic, devicePresent: preferredUID == nil || preferred != nil,
                preferredIsConfirmedRoute: routeConfirmed, qualified: preferred.map(isQualified) ?? false,
                supportsTarget: resolution.format.rate.map { preferred?.supports($0) == true } ?? false,
                target: resolution.format.rate, readback: readback, endpoint: preferred?.endpoint, observedEndpoints: endpoints
            )
        }
        currentFormat = resolution.format
        let request = model.step(alignmentInput(readback: preferred?.nominalRate), now: now)
        var verified: WriteRequest?
        var confirmedAt: TimeInterval?
        if let request {
            if let pid, let preferred {
                writeWarning = nil
                verifier.advance(epoch: epoch, target: currentFormat.rate, state: .aligning, write: nil,
                                 trackChanged: observedTrackChange, profile: profile, now: now)
                updateButton()
                let activeSettings = settings
                let worker = Task.detached(priority: .userInitiated) {
                    RateConfirmation.apply(request, device: preferred, sample: sample, musicPID: pid, settings: activeSettings)
                }
                let outcome = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                model.receive(outcome.disposition, for: request)
                guard !Task.isCancelled, reloadSettings(), generation == preferenceGeneration else { return }
                guard NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).first?.processIdentifier == pid else {
                    return
                }
                if let readback = outcome.readback, readback.rate == request.rate {
                    _ = model.step(alignmentInput(readback: readback.rate), now: readback.at)
                    if let confirmedSample = outcome.verifiedSample, model.confirmedWrite == request {
                        previous = confirmedSample
                        previousDevice = confirmedSample.preferredOutput(uid: preferredUID)
                        verified = request
                        confirmedAt = readback.at
                        let elapsed = Int(((readback.at - request.requestedAt) * 1_000).rounded())
                        appendLog("Readback confirmed \(request.rate) Hz in \(elapsed) ms; playback and route rechecked")
                    }
                }
                writeWarning = outcome.warning
            } else {
                model.receive(.failed, for: request)
                writeWarning = "Music or the selected device disappeared before the rate write."
            }
        }
        verifier.advance(epoch: epoch, target: resolution.format.rate, state: writeWarning == nil ? model.state : .failed,
                         write: verified, trackChanged: observedTrackChange, profile: profile,
                         now: ProcessInfo.processInfo.systemUptime, confirmedAt: confirmedAt)
        let message = status(sample: previous)
        if message != lastMessage {
            appendLog(message)
            lastMessage = message
        }
        updateButton()
    }

    private func isQualified(_ output: OutputDevice) -> Bool {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return output.isWiredExternal && qualifiedConfigurations.contains {
            $0["macOS"] == version && $0["deviceUID"] == output.uid
        }
    }

    private func reloadSettings() -> Bool {
        do {
            let next = try store.read()
            if next.autoSwitch != automatic || next.monitorMusic != automation || next.preferredOutputUID != preferredUID
                || next.authorizedAudioPath != settings.authorizedAudioPath {
                preferenceGeneration += 1
                permissionMessage = nil
            }
            settings = next
            settingsError = nil
            return true
        } catch {
            let message = error.localizedDescription
            if settingsError != message { appendLog(message) }
            settingsError = message
            updateButton()
            return false
        }
    }

    private func updatePreference(_ edit: SettingEdit) {
        do {
            try store.apply([edit])
            if reloadSettings() { updateButton() }
        } catch {
            alert("Could not update Damon preferences", detail: error.localizedDescription)
        }
    }

    private func status(sample: PlaybackSample?) -> String {
        if let settingsError { return settingsError }
        if let permissionMessage { return permissionMessage }
        if let sample, sample.outputs == nil { return "Core Audio device list unavailable" }
        if model.state == .unavailable { return model.state.rawValue }
        if preferredUID == nil && sample?.playback?.state == .playing { return "Select a preferred output device" }
        if let sample, sample.playback?.state != .playing { return sample.message }
        if let writeWarning { return writeWarning }
        return model.state.rawValue
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let display = FormatDisplay(verified: currentFormat, playback: previous?.playback)
        let warning = [.unavailable, .failed, .drift, .unsupportedRate, .unsupportedRoute, .unavailableReadback].contains(model.state)
            || writeWarning != nil || verifier.outcome == .failed
        let title = display.statusBarTitle(showRate: showRate, showDepth: showDepth, warning: warning)
        if !button.attributedTitle.isEqual(to: title) { button.attributedTitle = title }
        button.toolTip = "\(display.certainty.rawValue) • \(status(sample: previous))"
        button.setAccessibilityLabel("Damon: \(title.string). \(display.certainty.rawValue).")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let sample = previous
        let preferred = previousDevice
        let display = FormatDisplay(verified: currentFormat, playback: sample?.playback)
        menu.removeAllItems()
        append("Damon")
        append("Preferred Device: " + (preferred?.name ?? (preferredUID == nil ? "Not selected" : "Unavailable")))
        let active = sample?.activeOutputs ?? []
        append("Active Output: " + (active.isEmpty ? "Unconfirmed" : active.map(\.name).joined(separator: ", ")))
        let trackRate = display.format.rate.map { (display.certainty == .estimated ? "≈" : "") + "\($0) Hz" } ?? "—"
        let trackDepth = display.format.depth.map { "\($0)-bit" } ?? "—"
        append("Track Format: \(trackRate) / \(trackDepth)")
        append("Confidence: \(display.certainty.rawValue)")
        append("Preferred Device Rate: " + (preferred?.nominalRate.map { "\($0) Hz" } ?? "—"))
        append("Status: \(status(sample: sample))")
        if let sample, sample.message != status(sample: sample) { append("Music: \(sample.message)") }
        menu.addItem(.separator())
        append("Show Sample Rate", action: #selector(toggleRate)).state = showRate ? .on : .off
        append("Show Bit Depth", action: #selector(toggleDepth)).state = showDepth ? .on : .off
        append("Auto Switch Sample Rate", action: #selector(toggleAutomatic)).state = automatic ? .on : .off
        append("Monitor Apple Music", action: #selector(toggleAutomation)).state = automation ? .on : .off
        append("Choose Authorized Local Audio…", action: #selector(chooseLocalAudio))
        if approvedFolder != nil { append("Stop Inspecting Local Audio Files", action: #selector(removeFolder)) }
        menu.addItem(.separator())
        let devices = NSMenu()
        for device in sample?.outputs ?? [] {
            let entry = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = device.uid
            entry.state = device.uid == preferredUID ? .on : .off
            entry.toolTip = device.uid
            devices.addItem(entry)
        }
        if devices.items.isEmpty { devices.addItem(NSMenuItem(title: "No output devices", action: nil, keyEquivalent: "")) }
        append("Select Output Device").submenu = devices
        let verification = NSMenu()
        verification.addItem(NSMenuItem(title: profile == nil ? "No calibrated profile for the preferred device" : verifier.description,
                                       action: nil, keyEquivalent: ""))
        let camera = NSMenuItem(title: "Verify DAC LEDs with Camera", action: profile?.camera?.isValid == true ? #selector(toggleCamera) : nil,
                                keyEquivalent: "")
        camera.target = self
        camera.state = defaults.bool(forKey: "cameraVerification") ? .on : .off
        verification.addItem(camera)
        let relay = NSMenuItem(title: "Confirm DAC Relay with Microphone",
                               action: profile?.microphone?.isValid == true ? #selector(toggleRelay) : nil, keyEquivalent: "")
        relay.target = self
        relay.state = defaults.bool(forKey: "relayVerification") ? .on : .off
        verification.addItem(relay)
        verification.addItem(NSMenuItem(title: "Digital sample integrity not established", action: nil, keyEquivalent: ""))
        append("Verification Status").submenu = verification
        append("Logs…", action: #selector(showLogs))
        append("Qualification Snapshot…", action: #selector(showQualificationSnapshot))
        append("Read Open Music Lossless Panel…", action: #selector(readMusicFormatPanel))
        menu.addItem(.separator())
        let login = SMAppService.mainApp.status
        append("Launch at Login", action: #selector(toggleLogin)).state = login == .enabled ? .on : login == .requiresApproval ? .mixed : .off
        append("Check for Updates…", action: #selector(checkForUpdates))
        append("Quit Damon", action: #selector(quit), key: "q")
    }

    @discardableResult
    private func append(_ title: String, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
        row.target = self
        menu.addItem(row)
        return row
    }

    private func appendLog(_ message: String) {
        logs.append("\(Date().formatted(date: .omitted, time: .standard))  \(message)")
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }

    @objc private func toggleRate() {
        updatePreference(.showSampleRate(!showRate))
    }

    @objc private func toggleDepth() {
        updatePreference(.showBitDepth(!showDepth))
    }

    @objc private func toggleAutomatic() {
        updatePreference(.autoSwitch(!automatic))
    }

    @objc private func toggleAutomation() {
        permissionMessage = nil
        preferenceGeneration += 1
        if automation {
            updatePreference(.monitorMusic(false))
            return
        }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).first?.processIdentifier else {
            alert("Open Music first", detail: "Start Apple Music, then enable monitoring to grant read-only Automation access.")
            return
        }
        let generation = preferenceGeneration
        Task {
            let status = await Task.detached { MusicObserver.requestPermission(pid: pid) }.value
            guard reloadSettings(), generation == preferenceGeneration else { return }
            if status == 0 {
                updatePreference(.monitorMusic(true))
            } else {
                permissionMessage = "Music Automation not enabled (status \(status))"
                alert("Music Automation not enabled", detail: "Review System Settings > Privacy & Security > Automation. Status: \(status).")
            }
        }
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        updatePreference(.device(uid))
    }

    @objc private func chooseLocalAudio() {
        let panel = NSOpenPanel()
        panel.title = "Authorize inspection of local stereo lossless files"
        panel.message = "Choose one fixture file or a dedicated folder. Damon checks only the file associated with the current Music track."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.updatePreference(.localAudio(url))
        }
    }

    @objc private func removeFolder() {
        updatePreference(.localAudio(nil))
    }

    @objc private func toggleCamera() { toggleVerification("cameraVerification", media: .video) }
    @objc private func toggleRelay() { toggleVerification("relayVerification", media: .audio) }

    private func toggleVerification(_ key: String, media: AVMediaType) {
        if defaults.bool(forKey: key) {
            defaults.set(false, forKey: key)
            verifier.stop()
            preferenceGeneration += 1
        } else {
            Task {
                if await AVCaptureDevice.requestAccess(for: media) {
                    defaults.set(true, forKey: key)
                    preferenceGeneration += 1
                } else {
                    alert("Hardware verification access denied", detail: "Access can be granted in System Settings > Privacy & Security.")
                }
            }
        }
    }

    @objc private func showLogs() {
        alert("Damon session diagnostics", detail: logs.isEmpty ? "No events yet." : logs.suffix(16).joined(separator: "\n"))
    }

    @objc private func showQualificationSnapshot() {
        let sample = appliedPreferenceGeneration == preferenceGeneration ? previous : nil
        let outputs = sample?.activeOutputs ?? []
        let snapshot = QualificationSnapshot(
            status: sample == nil ? "No current observation" : status(sample: sample),
            music: sample?.message ?? "No observation yet",
            observationAgeMilliseconds: sample.map { Int(max(0, ProcessInfo.processInfo.systemUptime - $0.at) * 1_000) },
            playbackState: sample?.playback?.state.rawValue,
            activeOutputs: outputs.map(\.name), sourceRateHz: sample == nil ? nil : currentFormat.rate,
            sourceBitDepth: sample == nil ? nil : currentFormat.depth,
            preferredDeviceRateHz: sample == nil ? nil : previousDevice?.nominalRate,
            autoSwitchEnabled: automatic
        )
        let route = snapshot.activeOutputs.isEmpty ? "Unconfirmed" : snapshot.activeOutputs.joined(separator: ", ")
        let rate = snapshot.sourceRateHz.map { "\($0) Hz" } ?? "Unknown"
        let depth = snapshot.sourceBitDepth.map { "\($0)-bit" } ?? "Unknown"
        let deviceRate = snapshot.preferredDeviceRateHz.map { "\($0) Hz" } ?? "Unknown"
        let text = """
            Status: \(snapshot.status)
            Music: \(snapshot.music)
            Active Output: \(route)
            Source Rate / Bit Depth: \(rate) / \(depth)
            Preferred Device Rate: \(deviceRate)
            """
        let prompt = NSAlert()
        prompt.messageText = "Damon qualification snapshot"
        prompt.informativeText = text
        prompt.addButton(withTitle: "Done")
        prompt.addButton(withTitle: "Copy")
        prompt.addButton(withTitle: "Save JSON…")
        NSApp.activate()
        switch prompt.runModal() {
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .alertThirdButtonReturn:
            saveQualificationSnapshot(snapshot)
        default:
            break
        }
    }

    private func saveQualificationSnapshot(_ snapshot: QualificationSnapshot) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Damon-qualification.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                self?.alert("Could not save qualification snapshot", detail: error.localizedDescription)
            }
        }
    }

    @objc private func readMusicFormatPanel() {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).first?.processIdentifier else {
            alert("Music is not open", detail: "Open Music and its Now Playing Lossless panel first.")
            return
        }
        Task {
            let reading = await Task.detached { MusicFormatPanel.read(pid: pid) }.value
            let text: String
            switch reading {
            case .accessibilityDenied:
                text = "This optional diagnostic needs Accessibility permission in System Settings > Privacy & Security. Damon only reads the panel and does not open or control it."
            case .noOpenPanel:
                text = "No readable Lossless panel was found. Open the Lossless badge in Music's Now Playing view and leave the panel open while requesting this diagnostic."
            case .unrecognizedFormat:
                text = "The open panel did not expose exactly one recognizable ALAC format."
            case let .reading(format):
                let depth = format.bitDepth.map { "\($0)-bit" } ?? "bit depth not shown"
                text = "\(format.rate) Hz ALAC, \(depth). This is a Music panel reading only. It does not authorize a rate change."
            }
            alert("Music Lossless panel diagnostic", detail: text)
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            appendLog("Launch at Login: \(error.localizedDescription)")
            alert("Launch at Login could not be changed", detail: error.localizedDescription)
        }
    }

    @objc private func checkForUpdates() {
        alert("Local development build", detail: "No update service is configured. Rebuild Damon from this workspace for updates.")
    }

    @objc private func quit() { NSApp.terminate(self) }

    private func alert(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }
}

let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
if let command = arguments.first, ["--make-fixtures", "--make-qualification-kit"].contains(command) {
    guard arguments.count == 2 else {
        FileHandle.standardError.write(Data("Usage: Damon \(command) <new-folder>\n".utf8))
        exit(2)
    }
    do {
        let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
        if command == "--make-qualification-kit" {
            try QualificationFixtures.generateKit(at: folder)
        } else {
            try QualificationFixtures.generate(at: folder)
        }
        print("Generated ALAC fixtures and WAV references in \(folder.path)")
    } catch {
        FileHandle.standardError.write(Data("Fixture generation failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}

if arguments.first == "--compare-pcm" {
    let offset: Int64?
    if arguments.count == 3 {
        offset = nil
    } else if arguments.count == 5, arguments[3] == "--offset-frames",
              let parsed = Int64(arguments[4]), parsed >= 0 {
        offset = parsed
    } else {
        FileHandle.standardError.write(Data("Usage: Damon --compare-pcm <reference> <candidate> [--offset-frames <nonnegative-integer>]\n".utf8))
        exit(2)
    }
    do {
        let report = try PCMComparison.compare(reference: URL(fileURLWithPath: arguments[1]),
                                               candidate: URL(fileURLWithPath: arguments[2]), offset: offset)
        print(report.summary)
        exit(report.verdict == .identical ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("PCM comparison failed: \(error.localizedDescription)\n".utf8))
        exit(2)
    }
}

if arguments.first == "--diagnose" {
    guard let outputs = AudioHardware.outputs() else {
        FileHandle.standardError.write(Data("Core Audio device list unavailable\n".utf8))
        exit(1)
    }
    for output in outputs {
        let rate = output.nominalRate.map { "\($0) Hz" } ?? "rate unknown"
        let ranges = output.availableRates.map { "\($0.lowerBound)...\($0.upperBound)" }.joined(separator: ", ")
        print("\(output.name): \(rate); \(output.isRateSettable ? "writable" : "read-only"); \(ranges)")
    }
    exit(0)
}

if !arguments.isEmpty {
    exit(DamonCLI.run(arguments))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let delegate = DamonApp()
app.delegate = delegate
app.run()
