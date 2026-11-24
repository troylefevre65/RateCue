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
    private var activationObserver: NSObjectProtocol?
    private let audioRefresh = AudioRefreshGate()
    private lazy var audioChanges = AudioChangeMonitor(
        onChange: { [weak self] in self?.audioRefresh.signal() },
        onError: { [weak self] message in self?.appendLog(message) }
    )
    private var model = AlignmentMachine()
    private var epoch = Epoch(playback: 0, route: 0)
    private var playbackBoundary: TimeInterval = 0
    private var observedTrackChange = false
    private let verifier = VerificationMonitor()
    private var previous: PlaybackSample?
    private var previousDevice: OutputDevice?
    private var previousMusicPID: pid_t?
    private var currentFormat = Format()
    private var panelSnapshot: PanelFormatSnapshot?
    private var depthCorrelation = BitDepthCorrelationEngine()
    private var logEvidenceTask: Task<Void, Never>?
    private var lastLogEvidenceProbeAt = 0.0
    private var logEvidenceBackfilledEpoch: Epoch?
    private var logEvidenceFailures = 0
    private var logEvidenceAttempts = 0
    private var logEvidenceStatus = "Not attempted"
    private var logPlaybackAnchor = MusicPlaybackLogAnchor()
    private let menuDiagnostics = MenuDiagnosticsStore()
    private var lastMenuDiagnosticsAt = 0.0
    private var lastMenuDiagnosticsSignature: String?
    private var lastMenuDiagnosticsWriteAt = 0.0
    private var menuDiagnosticsError: String?
    private var panelTask: Task<Void, Never>?
    private var panelPrompt: String?
    private var automaticPanelTask: Task<Void, Never>?
    private var automaticPanelAttemptEpoch: Epoch?
    private var automaticPanelRetryAt: TimeInterval?
    private var automaticPanelStatus: String?
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
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleApplicationActivation()
            }
        }
        audioChanges.start()
        updateButton()
        refresh = Task { [weak self] in
            while let self, !Task.isCancelled {
                let version = self.audioRefresh.version
                await self.tick()
                let interval = self.model.state == .aligning ? 50 :
                    self.previous?.playback?.state == .playing ? 300 :
                    self.automation && self.previous?.playback != nil ? 500 : 1_000
                await self.audioRefresh.wait(since: version, milliseconds: interval)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refresh?.cancel()
        panelTask?.cancel()
        automaticPanelTask?.cancel()
        logEvidenceTask?.cancel()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        audioRefresh.stop()
        audioChanges.stop()
        verifier.stop()
    }

    private func scheduleLogEvidenceRead() {
        let now = ProcessInfo.processInfo.systemUptime
        guard logEvidenceTask == nil, now - lastLogEvidenceProbeAt >= 3,
              logEvidenceBackfilledEpoch != epoch, logEvidenceAttempts < 5,
              automation, let pid = previousMusicPID,
              let playback = previous?.playback, playback.state == .playing,
              let trackID = playback.trackID, let reportedRate = playback.reportedRate else { return }
        guard let context = depthContext(for: previous) else { return }
        let selectedEpoch = epoch
        let elapsed = max(0, playback.position ?? now - playbackBoundary)
        let estimatedStart = logPlaybackAnchor.startedAt(for: trackID)
            ?? Date().addingTimeInterval(-elapsed)
        lastLogEvidenceProbeAt = now
        logEvidenceAttempts += 1
        logEvidenceTask = Task { [weak self] in
            let outcome = await Task.detached {
                Result { try MusicLogEvidenceReader.collect(around: estimatedStart, radius: 30) }
            }.value
            guard let self else { return }
            self.logEvidenceTask = nil
            defer { self.audioRefresh.signal() }
            guard !Task.isCancelled, self.epoch == selectedEpoch, self.previousMusicPID == pid,
                  self.previous?.playback?.trackID == trackID,
                  self.previous?.playback?.state == .playing else { return }
            switch outcome {
            case let .success(events):
                self.logEvidenceFailures = 0
                let eligible = events.filter { event in
                    guard event.source == .decoder, let start = event.playbackStartAt else { return false }
                    return abs(start.timeIntervalSince(estimatedStart)) <= 15
                        && event.rate == reportedRate && [16, 24].contains(event.depth)
                }
                let event = eligible.min {
                    let left = $0.playbackStartAt.map { abs($0.timeIntervalSince(estimatedStart)) } ?? .greatestFiniteMagnitude
                    let right = $1.playbackStartAt.map { abs($0.timeIntervalSince(estimatedStart)) } ?? .greatestFiniteMagnitude
                    return left < right
                }
                if let event, let candidate = DepthCandidate(rawValue: event.depth) {
                    self.logEvidenceBackfilledEpoch = selectedEpoch
                    let source: DepthEvidenceSource = event.source == .decoder ? .decoderLog : .musicLog
                    let strength: DepthEvidenceStrength = event.source == .decoder ? .direct : .moderate
                    self.depthCorrelation.observe(
                        DepthObservation(
                            context: context, at: ProcessInfo.processInfo.systemUptime,
                            source: source, candidate: candidate, strength: strength,
                            persistsForContext: true
                        )
                    )
                    self.logEvidenceStatus =
                        "\(event.source.rawValue) \(event.rate) Hz / \(event.depth)-bit at "
                        + event.at.formatted(date: .omitted, time: .standard)
                } else {
                    self.logEvidenceStatus = "No current rate-consistent decoder format event in backfill."
                    if self.logEvidenceAttempts >= 5 {
                        self.logEvidenceBackfilledEpoch = selectedEpoch
                    }
                }
                self.updateButton()
            case let .failure(error):
                self.logEvidenceFailures += 1
                self.lastLogEvidenceProbeAt = ProcessInfo.processInfo.systemUptime + (self.logEvidenceFailures == 1 ? 12 : 57)
                let message = "Music log read failed: \(error.localizedDescription)"
                self.logEvidenceStatus = message
                self.appendLog(message)
                if self.logEvidenceAttempts >= 5 {
                    self.logEvidenceBackfilledEpoch = selectedEpoch
                }
            }
        }
    }

    private func tick() async {
        guard reloadSettings() else { return }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).first?.processIdentifier
        let enabled = automation
        let folder = approvedFolder
        let generation = preferenceGeneration
        let audioVersion = audioRefresh.version
        let sample = await Task.detached {
            PlaybackSample.collect(pid: pid, automation: enabled, folder: folder, includeRateEstimate: true)
        }.value
        guard !Task.isCancelled, reloadSettings(), generation == preferenceGeneration, audioVersion == audioRefresh.version else { return }
        let formatChanged = previous?.format != sample.format
        let repeatOrSeek = if let old = previous?.playback?.position, let new = sample.playback?.position {
            old - new > 0.5 && new >= 0 && new < 1
        } else { false }
        let playbackChanged = previous?.playback?.trackID != sample.playback?.trackID
            || previous?.playback?.state != sample.playback?.state
            || previous?.playback?.reportedRate != sample.playback?.reportedRate
            || previousMusicPID != pid || formatChanged || repeatOrSeek
        logPlaybackAnchor.observe(
            sample.playback, at: Date(),
            restarted: repeatOrSeek || previousMusicPID != pid
        )
        if previous?.playback?.reportedRate != sample.playback?.reportedRate {
            automaticPanelTask?.cancel()
            automaticPanelAttemptEpoch = nil
            automaticPanelRetryAt = nil
            automaticPanelStatus = nil
            panelSnapshot = nil
        }
        let preferred = sample.preferredOutput(uid: preferredUID)
        audioChanges.update(preferred: preferred, musicPID: pid)
        let routeChanged = previous?.route != sample.route || previousDevice?.objectID != preferred?.objectID
            || previousDevice?.uid != preferred?.uid || appliedPreferenceGeneration != generation
        if playbackChanged || routeChanged || previous == nil {
            automaticPanelTask?.cancel()
            automaticPanelStatus = nil
            panelSnapshot = nil
            writeWarning = nil
            observedTrackChange = if let old = previous?.playback?.trackID, let new = sample.playback?.trackID {
                old != new
            } else { false }
            playbackBoundary = sample.at
            epoch = Epoch(playback: epoch.playback + (playbackChanged ? 1 : 0), route: epoch.route + (routeChanged ? 1 : 0))
            logEvidenceBackfilledEpoch = nil
            logEvidenceFailures = 0
            logEvidenceAttempts = 0
            logEvidenceStatus = "Waiting for current-track decoder evidence…"
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
        scheduleAutomaticPanelRead()
        scheduleLogEvidenceRead()
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
            if next.invalidatesAutomaticPanelRead(comparedTo: settings) {
                automaticPanelTask?.cancel()
                automaticPanelAttemptEpoch = nil
                automaticPanelRetryAt = nil
                automaticPanelStatus = nil
                if next.monitorMusic != automation { panelSnapshot = nil }
            }
            settings = next
            settingsError = nil
            return true
        } catch {
            automaticPanelTask?.cancel()
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
            alert("Could not update RateCue preferences", detail: error.localizedDescription)
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

    private func formatDisplay() -> FormatDisplay {
        return FormatDisplay(
            verified: currentFormat, playback: previous?.playback, panel: panelSnapshot, epoch: epoch,
            depthEstimate: depthResolution(for: previous)
        )
    }

    private func depthResolution(for sample: PlaybackSample?) -> DepthResolution? {
        guard let context = depthContext(for: sample) else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let correlated = depthCorrelation.resolve(
            context: context, rateHz: sample?.playback?.reportedRate, now: now
        )
        return correlated
    }

    private func depthContext(for sample: PlaybackSample?) -> DepthContext? {
        guard let trackID = sample?.playback?.trackID else { return nil }
        let routeID = sample?.route?.map(String.init).joined(separator: ",")
            ?? sample?.preferredOutput(uid: preferredUID)?.endpoint
            ?? previousDevice?.endpoint
            ?? "unconfirmed"
        guard !routeID.isEmpty else { return nil }
        return DepthContext(epoch: epoch, trackID: trackID, routeID: routeID)
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let display = formatDisplay()
        let warning = [.unavailable, .failed, .drift, .unsupportedRate, .unsupportedRoute, .unavailableReadback].contains(model.state)
            || writeWarning != nil || verifier.outcome == .failed
        let title = if let panelPrompt {
            NSAttributedString(string: panelPrompt)
        } else {
            display.statusBarTitle(showRate: showRate, showDepth: showDepth, warning: warning)
        }
        if !button.attributedTitle.isEqual(to: title) { button.attributedTitle = title }
        let correlation = depthResolution(for: previous).map {
            " • Bit-depth: 16-bit \($0.posterior16)% / 24-bit \($0.posterior24)%"
        } ?? ""
        button.toolTip = "\(display.certainty.rawValue) • \(status(sample: previous))\(correlation)"
        button.setAccessibilityLabel("RateCue: \(title.string). \(display.certainty.rawValue).")
        publishMenuDiagnostics(display: display, title: title.string)
    }

    private func publishMenuDiagnostics(display: FormatDisplay, title: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMenuDiagnosticsAt >= 0.25 else { return }
        lastMenuDiagnosticsAt = now
        let resolution = depthResolution(for: previous)
        let snapshot = MenuDiagnosticsSnapshot(
            snapshotAt: Date(),
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            menuTitle: title,
            certainty: display.certainty.rawValue,
            correlationScore: resolution?.score ?? 0,
            correlatedDepth: resolution?.candidate?.rawValue,
            correlationConflict: resolution?.conflict ?? false,
            usedHighRatePrior: resolution?.usedHighRatePrior ?? false,
            correlationProvenance: resolution?.provenance.map(\.rawValue) ?? [],
            playbackState: previous?.playback?.state.rawValue,
            automaticPanelStatus: automaticPanelStatus,
            logEvidenceStatus: logEvidenceStatus,
            mostLikelyDepth: (resolution?.posterior24 ?? 50) > (resolution?.posterior16 ?? 50) ? 24 : 16,
            publicationStatus: {
                guard let resolution else { return "noContext" }
                if resolution.candidate != nil { return "published" }
                if resolution.conflict { return "withheldForConflict" }
                if !resolution.evidenceAvailable { return "priorOnly" }
                return "belowNinetyPercentThreshold"
            }(),
            posterior16: resolution?.posterior16 ?? 50,
            posterior24: resolution?.posterior24 ?? 50,
            evidenceAvailable: resolution?.evidenceAvailable ?? false,
            correlationModelVersion: resolution?.modelVersion ?? 1,
            prior16: resolution?.prior16 ?? 50,
            prior24: resolution?.prior24 ?? 50,
            unroundedProbability24: resolution?.unroundedProbability24 ?? 0.5,
            contributions: resolution?.contributions.map {
                MenuDiagnosticsSnapshot.Contribution(
                    source: $0.source,
                    candidate: $0.candidate?.rawValue,
                    strength: $0.strength,
                    likelihoodRatio: $0.likelihoodRatio,
                    logOddsContribution: $0.logOddsContribution
                )
            } ?? []
        )
        let signature = "\(snapshot.menuTitle)|\(snapshot.certainty)|\(snapshot.posterior16)|\(snapshot.posterior24)|"
            + "\(snapshot.evidenceAvailable)|\(snapshot.correlationConflict)|\(snapshot.publicationStatus)|"
            + "\(snapshot.correlationProvenance.joined(separator: ","))|"
            + "\(snapshot.automaticPanelStatus ?? "")|\(snapshot.logEvidenceStatus)|"
            + "\(snapshot.playbackState ?? "")|"
            + "\(snapshot.contributions.map { "\($0.source):\($0.candidate ?? 0):\($0.logOddsContribution)" }.joined(separator: ","))"
        guard signature != lastMenuDiagnosticsSignature || now - lastMenuDiagnosticsWriteAt >= 2 else { return }
        do {
            try menuDiagnostics.write(snapshot)
            lastMenuDiagnosticsSignature = signature
            lastMenuDiagnosticsWriteAt = now
            menuDiagnosticsError = nil
        } catch {
            let message = error.localizedDescription
            if menuDiagnosticsError != message {
                appendLog("Could not publish menu diagnostics: \(message)")
                menuDiagnosticsError = message
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let sample = previous
        let preferred = previousDevice
        let display = formatDisplay()
        menu.removeAllItems()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        append(version.map { "RateCue \($0)" } ?? "RateCue")
        let trackRate = display.format.rate.map {
            ([.estimated, .panelSnapshot, .correlated].contains(display.certainty) ? "≈" : "") + "\($0) Hz"
        } ?? "—"
        let trackDepth = display.format.depth.map { "\($0)-bit" } ?? "—"
        append("Track Format: \(trackRate) / \(trackDepth)")
        append("Evidence status: \(display.certainty.rawValue)")
        append("Status: \(status(sample: sample))")
        append("Preferred Device: " + (preferred?.name ?? (preferredUID == nil ? "Not selected" : "Unavailable")))
        let active = sample?.activeOutputs ?? []
        append("Active Output: " + (active.isEmpty ? "Unconfirmed" : active.map(\.name).joined(separator: ", ")))
        menu.addItem(.separator())

        let devices = NSMenu(title: "Select Output Device")
        for device in sample?.outputs ?? [] {
            let entry = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = device.uid
            entry.state = device.uid == preferredUID ? .on : .off
            entry.toolTip = device.uid
            devices.addItem(entry)
        }
        if devices.items.isEmpty {
            devices.addItem(NSMenuItem(title: "No output devices", action: nil, keyEquivalent: ""))
        }
        append("Select Output Device").submenu = devices
        append("Monitor Apple Music", action: #selector(toggleAutomation)).state = automation ? .on : .off
        let canAutoSwitch = !qualifiedConfigurations.isEmpty
        if canAutoSwitch {
            append("Auto Switch Sample Rate", action: #selector(toggleAutomatic)).state =
                automatic ? .on : .off
        }

        let displayOptions = NSMenu(title: "Display Options")
        append("Show Sample Rate", action: #selector(toggleRate), to: displayOptions).state = showRate ? .on : .off
        append("Show Bit Depth", action: #selector(toggleDepth), to: displayOptions).state = showDepth ? .on : .off
        append("Display Options").submenu = displayOptions
        menu.addItem(.separator())

        let musicEvidence = NSMenu(title: "Music Evidence")
        append(
            "Automatically Read Music Panel (Experimental)",
            action: #selector(toggleAutomaticPanelRead), to: musicEvidence
        ).state = settings.autoReadMusicPanel ? .on : .off
        let panelAvailable = panelTask == nil && automaticPanelTask == nil
        append(
            "Read Open Music Lossless Panel…",
            action: panelAvailable ? #selector(readMusicFormatPanel) : nil, to: musicEvidence
        )
        append(
            panelAvailable ? "Read Fresh Music Lossless Panel…" : "Reading Music Lossless Panel…",
            action: panelAvailable ? #selector(readFreshMusicFormatPanel) : nil, to: musicEvidence
        )
        musicEvidence.addItem(.separator())
        append("Accessibility Access…", action: #selector(showAccessibilityAccess), to: musicEvidence)
        append("Music Evidence").submenu = musicEvidence

        let verification = NSMenu(title: "Verification")
        verification.addItem(NSMenuItem(
            title: profile == nil ? "No calibrated profile for the preferred device" : verifier.description,
            action: nil, keyEquivalent: ""
        ))
        if let profile {
            if profile.camera?.isValid == true {
                let camera = NSMenuItem(
                    title: "Verify DAC LEDs with Camera", action: #selector(toggleCamera), keyEquivalent: ""
                )
                camera.target = self
                camera.state = defaults.bool(forKey: "cameraVerification") ? .on : .off
                verification.addItem(camera)
            }
            if profile.microphone?.isValid == true {
                let relay = NSMenuItem(
                    title: "Confirm DAC Relay with Microphone", action: #selector(toggleRelay), keyEquivalent: ""
                )
                relay.target = self
                relay.state = defaults.bool(forKey: "relayVerification") ? .on : .off
                verification.addItem(relay)
            }
        }
        verification.addItem(NSMenuItem(
            title: "Digital sample integrity not established", action: nil, keyEquivalent: ""
        ))
        append("Verification").submenu = verification

        let diagnostics = NSMenu(title: "Advanced Diagnostics")
        if let resolution = depthResolution(for: sample) {
            let candidate = resolution.candidate.map { "\($0.rawValue)-bit" } ?? "unknown"
            let provenance = resolution.provenance.map(\.rawValue).joined(separator: ", ")
            let sources = provenance.isEmpty ? "no contributing observations" : provenance
            let prior = resolution.usedHighRatePrior ? "; high-rate prior" : ""
            append(
                "Bit-depth: 16-bit \(resolution.posterior16)% / 24-bit \(resolution.posterior24)%",
                to: diagnostics
            )
            append(
                "Correlation: \(resolution.evidenceAvailable ? "evidence" : "prior only")"
                    + " (\(candidate); \(sources)\(prior))",
                to: diagnostics
            )
            append(
                "Depth prior: 16-bit \(resolution.prior16)% / 24-bit \(resolution.prior24)%",
                to: diagnostics
            )
            for contribution in resolution.contributions {
                let candidate = contribution.candidate.map { "\($0.rawValue)-bit" } ?? "unknown"
                let ratio = contribution.likelihoodRatio.map { String(format: "%.2fx", $0) } ?? "—"
                let odds = String(format: "%+.3f", contribution.logOddsContribution)
                append(
                    "Influence: \(contribution.source) → \(candidate), "
                        + "\(contribution.strength), LR \(ratio), log-odds \(odds)",
                    to: diagnostics
                )
            }
        } else {
            append("Bit-depth: 50% / 50% (no current playback context)", to: diagnostics)
        }
        if settings.autoReadMusicPanel, let automaticPanelStatus {
            append("Automatic depth: \(automaticPanelStatus)", to: diagnostics)
        }
        append("Preferred Device Rate: " + (preferred?.nominalRate.map { "\($0) Hz" } ?? "—"), to: diagnostics)
        if let sample, sample.message != status(sample: sample) {
            append("Music: \(sample.message)", to: diagnostics)
        }
        diagnostics.addItem(.separator())
        append("Logs…", action: #selector(showLogs), to: diagnostics)
        append("Copy Diagnostics", action: #selector(copyDiagnostics), to: diagnostics)
        append("Qualification Snapshot…", action: #selector(showQualificationSnapshot), to: diagnostics)
        diagnostics.addItem(.separator())
        append("Choose Authorized Local Audio…", action: #selector(chooseLocalAudio), to: diagnostics)
        if approvedFolder != nil {
            append("Stop Inspecting Local Audio Files", action: #selector(removeFolder), to: diagnostics)
        }
        append("Advanced Diagnostics").submenu = diagnostics
        menu.addItem(.separator())

        append("About RateCue…", action: #selector(showAbout))
        append("Help…", action: #selector(showHelp))
        append("Credits…", action: #selector(showCredits))
        menu.addItem(.separator())
        let login = SMAppService.mainApp.status
        append("Launch at Login", action: #selector(toggleLogin)).state =
            login == .enabled ? .on : login == .requiresApproval ? .mixed : .off
        append("Quit RateCue", action: #selector(quit), key: "q")
    }

    @discardableResult
    private func append(
        _ title: String, action: Selector? = nil, key: String = "", to targetMenu: NSMenu? = nil
    ) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
        row.target = self
        (targetMenu ?? menu).addItem(row)
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

    @objc private func toggleAutomaticPanelRead() {
        if settings.autoReadMusicPanel {
            updatePreference(.autoReadMusicPanel(false))
            return
        }
        let prompt = NSAlert()
        prompt.messageText = "Automatically read Music's Lossless panel?"
        prompt.informativeText = """
            This experimental feature reads Music's Lossless panel after playback, route, or reported-rate changes, including while Music is active. It opens a closed panel or closes and reopens an existing panel to establish freshness, then restores the open state. The interaction can be interrupted by playback or interface changes.

            Music's Now Playing view must be available and RateCue needs Accessibility access. The result can be stale, remains amber and unverified, and never authorizes a DAC rate change.
            """
        prompt.addButton(withTitle: "Enable Experimental Reading")
        prompt.addButton(withTitle: "Cancel")
        NSApp.activate()
        if prompt.runModal() == .alertFirstButtonReturn {
            updatePreference(.autoReadMusicPanel(true))
        }
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
        panel.message = "Choose one fixture file or a dedicated folder. RateCue checks only the file associated with the current Music track."
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
        alert("RateCue session diagnostics", detail: logs.isEmpty ? "No events yet." : logs.suffix(16).joined(separator: "\n"))
    }

    private func depthDiagnosticText() -> String {
        guard let resolution = depthResolution(for: previous) else { return "unavailable" }
        let contributions = resolution.contributions.map { contribution in
            let candidate = contribution.candidate.map { "\($0.rawValue)-bit" } ?? "unknown"
            let ratio = contribution.likelihoodRatio.map { String(format: "%.2fx", $0) } ?? "—"
            let odds = String(format: "%+.3f", contribution.logOddsContribution)
            return "\(contribution.source): \(candidate), \(contribution.strength), LR \(ratio), log-odds \(odds)"
        }.joined(separator: "; ")
        let mostLikely = resolution.posterior16 == resolution.posterior24
            ? "tied"
            : resolution.posterior16 > resolution.posterior24 ? "16-bit" : "24-bit"
        let candidate = if let candidate = resolution.candidate {
            "\(candidate.rawValue)-bit"
        } else if resolution.conflict {
            "withheld (conflict)"
        } else if !resolution.evidenceAvailable {
            "withheld (prior only)"
        } else {
            "withheld (below 90%)"
        }
        return "16-bit \(resolution.posterior16)% / 24-bit \(resolution.posterior24)%; "
            + "model \(resolution.modelVersion); most likely \(mostLikely); candidate \(candidate); "
            + "conflict \(resolution.conflict); evidence available \(resolution.evidenceAvailable); "
            + "prior \(resolution.prior16)/\(resolution.prior24); contributions: \(contributions)"
    }

    @objc private func copyDiagnostics() {
        let display = formatDisplay()
        let text = """
            Track format: \(display.statusBarTitle(showRate: true, showDepth: true, warning: false).string)
            Evidence status: \(display.certainty.rawValue)
            Bit-depth posterior: \(depthDiagnosticText())
            Music monitoring: \(automation ? "on" : "off")
            Accessibility access: \(MusicFormatPanel.hasAccessibilityAccess ? "enabled" : "not enabled")
            Automatic panel reading: \(settings.autoReadMusicPanel ? "on" : "off")
            Automatic depth: \(automaticPanelStatus ?? "No automatic check result")
            Status: \(status(sample: previous))
            """
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(text, forType: .string) {
            alert("Could not copy diagnostics", detail: "The clipboard could not accept the diagnostic text.")
        }
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
        prompt.messageText = "RateCue qualification snapshot"
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
        panel.nameFieldStringValue = "RateCue-qualification.json"
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

    private func handleApplicationActivation() {
        guard settings.autoReadMusicPanel else { return }
        updateButton()
        audioRefresh.signal()
    }

    private func scheduleAutomaticPanelRead() {
        guard settings.autoReadMusicPanel, automation, panelTask == nil, automaticPanelTask == nil,
              panelSnapshot == nil,
              automaticPanelAttemptEpoch != epoch
                || automaticPanelRetryAt.map({ $0 <= ProcessInfo.processInfo.systemUptime }) == true,
              currentFormat.rate == nil, currentFormat.depth == nil,
              let pid = previousMusicPID, let playback = previous?.playback, playback.state == .playing,
              let trackID = playback.trackID else { return }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            automaticPanelStatus = "Music is unavailable."
            return
        }
        let selectedEpoch = epoch
        automaticPanelAttemptEpoch = selectedEpoch
        automaticPanelRetryAt = nil
        automaticPanelStatus = "Reading Music's panel…"
        automaticPanelTask = Task { [weak self] in
            let worker = Task.detached {
                try MusicObserver.readAutomaticPanel(pid: pid, expectedTrackID: trackID)
            }
            let outcome = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self else { return }
            self.automaticPanelTask = nil
            defer { self.audioRefresh.signal() }
            guard !Task.isCancelled, self.settings.autoReadMusicPanel,
                  self.epoch == selectedEpoch, self.previousMusicPID == pid else { return }
            switch outcome {
            case let .success(reading):
                if !self.acceptPanelReading(
                    reading, epoch: selectedEpoch, trackID: trackID, pid: pid, automatic: true
                ) {
                    self.automaticPanelRetryAt = ProcessInfo.processInfo.systemUptime + 2
                }
            case let .failure(error):
                let message = "\(error.localizedDescription) Music's panel may remain open."
                self.automaticPanelStatus = message
                self.automaticPanelRetryAt = ProcessInfo.processInfo.systemUptime + 2
                self.appendLog("Automatic panel read: \(message)")
                self.updateButton()
            }
        }
    }

    @objc private func readMusicFormatPanel() {
        guard panelTask == nil, automaticPanelTask == nil else { return }
        guard automation, let pid = previousMusicPID, let playback = previous?.playback, playback.state == .playing,
              let trackID = playback.trackID else {
            alert("Music is not being monitored", detail: "Enable Monitor Apple Music and start a track before reading the panel.")
            return
        }
        let selectedEpoch = epoch
        panelSnapshot = nil
        updateButton()
        panelTask = Task {
            defer {
                panelTask = nil
                audioRefresh.signal()
            }
            let outcome = await Task.detached { () -> Result<MusicFormatPanel.Result, Error> in
                Result { try MusicObserver.readOpenPanel(pid: pid, expectedTrackID: trackID) }
            }.value
            let reading: MusicFormatPanel.Result
            switch outcome {
            case let .success(result): reading = result
            case let .failure(error):
                alert("Music panel check failed", detail: error.localizedDescription)
                return
            }
            let text: String
            switch reading {
            case .accessibilityDenied:
                text = "\(MusicFormatPanel.accessibilityGuidance) This manual check only reads the panel."
            case .unavailable:
                text = "Music's Now Playing view could not be observed reliably. Make the Now Playing view visible and try again."
            case .noOpenPanel:
                text = "No readable Lossless panel was found. Open the Lossless badge in Music's Now Playing view and leave the panel open while requesting this diagnostic."
            case .unrecognizedFormat:
                text = "The open panel did not expose exactly one recognizable ALAC format."
            case let .reading(format):
                let depth = format.bitDepth.map { "\($0)-bit" } ?? "bit depth not shown"
                guard format.bitDepth != nil else {
                    alert("Music Lossless panel diagnostic", detail: "\(format.rate) Hz ALAC, \(depth). RateCue will not infer a bit depth.")
                    return
                }
                let prompt = NSAlert()
                prompt.messageText = "Music reports \(format.rate) Hz / \(depth)"
                prompt.informativeText = """
                    Music's panel can retain a previous track's format. Only display this snapshot if you just opened the panel on the current track.

                    RateCue will show it in amber as unverified. It will not authorize a DAC rate change.
                    """
                prompt.addButton(withTitle: "Display Estimate")
                prompt.addButton(withTitle: "Cancel")
                NSApp.activate()
                if prompt.runModal() == .alertFirstButtonReturn {
                    acceptPanelReading(format, epoch: selectedEpoch, trackID: trackID, pid: pid)
                }
                return
            }
            alert("Music Lossless panel diagnostic", detail: text)
        }
    }

    @objc private func showAccessibilityAccess() {
        if MusicFormatPanel.hasAccessibilityAccess {
            alert("Accessibility access enabled", detail: "macOS reports that this running RateCue build can access Music's interface. Manual panel checks only read it; the opt-in experimental reader can also open and close its Lossless panel.")
            return
        }
        let prompt = NSAlert()
        prompt.messageText = "Accessibility access is not enabled"
        prompt.informativeText = """
            RateCue needs Accessibility access to read Music's Lossless panel. This permission can allow an app to control other apps. Manual panel checks only read it; the opt-in experimental reader can also open and close Music's Lossless panel.

            Select Request Access to let macOS show its permission prompt. \(MusicFormatPanel.accessibilityGuidance)
            """
        prompt.addButton(withTitle: "Request Access")
        prompt.addButton(withTitle: "Cancel")
        NSApp.activate()
        if prompt.runModal() == .alertFirstButtonReturn {
            MusicFormatPanel.requestAccessibilityAccess()
        }
    }

    @objc private func readFreshMusicFormatPanel() {
        guard panelTask == nil, automaticPanelTask == nil else { return }
        let instructions = NSAlert()
        instructions.messageText = "Read Music's Lossless Panel"
        instructions.informativeText = """
            Leave the current track playing and close Music's Lossless panel. Select Start, then open the Lossless badge in Music when the menu bar says “Open Music badge”.

            If Music explicitly shows bit depth, RateCue displays it in amber as an unverified snapshot. It clears when playback or the output route changes and never changes the DAC setting.
            """
        instructions.addButton(withTitle: "Start")
        instructions.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard instructions.runModal() == .alertFirstButtonReturn else { return }
        guard automation, let pid = previousMusicPID, let playback = previous?.playback, playback.state == .playing,
              let trackID = playback.trackID else {
            alert("Music is not being monitored", detail: "Enable Monitor Apple Music and start a track before reading the panel.")
            return
        }
        let selectedEpoch = epoch
        panelSnapshot = nil
        panelPrompt = "Checking Music…"
        updateButton()
        let notifyReady: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.panelTask != nil, self.epoch == selectedEpoch else { return }
                self.panelPrompt = "Open Music badge"
                self.updateButton()
            }
        }
        panelTask = Task { [weak self] in
            let worker = Task.detached {
                try MusicObserver.readFreshPanel(pid: pid, expectedTrackID: trackID, onReady: notifyReady)
            }
            let outcome = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self else { return }
            self.panelTask = nil
            self.panelPrompt = nil
            guard !Task.isCancelled else { self.updateButton(); return }
            guard self.automation, self.epoch == selectedEpoch, self.previousMusicPID == pid,
                  self.previous?.playback?.state == .playing, self.previous?.playback?.trackID == trackID else {
                self.updateButton()
                self.alert("Music changed during the panel check", detail: "No bit-depth snapshot was saved. Start the check again on the current track.")
                return
            }
            switch outcome {
            case let .success(reading):
                self.acceptPanelReading(reading, epoch: selectedEpoch, trackID: trackID, pid: pid)
            case let .failure(error):
                self.updateButton()
                self.alert("Music panel check failed", detail: error.localizedDescription)
            }
        }
    }

    @discardableResult
    private func acceptPanelReading(
        _ reading: MusicFormatPanel.Reading, epoch selectedEpoch: Epoch, trackID: String, pid: pid_t, automatic: Bool = false
    ) -> Bool {
        func fail(_ title: String, _ detail: String) {
            updateButton()
            if automatic {
                automaticPanelStatus = detail
                appendLog("Automatic panel read: \(detail)")
            } else {
                alert(title, detail: detail)
            }
        }
        guard automation, epoch == selectedEpoch, previousMusicPID == pid,
              previous?.playback?.state == .playing, previous?.playback?.trackID == trackID else {
            fail("Music changed during the panel check", "No bit-depth snapshot was saved because playback changed.")
            return false
        }
        guard let depth = reading.bitDepth else {
            fail("Bit depth not shown", "Music's panel did not report a bit depth. RateCue will not infer one.")
            return false
        }
        if let rate = previous?.playback?.reportedRate, rate != reading.rate {
            fail("Music format readings disagree", "The panel and track sample-rate readings differ, so no bit-depth snapshot was saved.")
            return false
        }
        panelSnapshot = PanelFormatSnapshot(format: Format(rate: reading.rate, depth: depth), epoch: selectedEpoch, trackID: trackID)
        if automatic { automaticPanelStatus = "Unverified Music panel snapshot." }
        if let context = depthContext(for: previous), let candidate = DepthCandidate(rawValue: reading.bitDepth ?? 0) {
            depthCorrelation.observe(
                DepthObservation(
                    context: context, at: ProcessInfo.processInfo.systemUptime, source: .musicPanel,
                    candidate: candidate, strength: .moderate, persistsForContext: true
                )
            )
        }
        updateButton()
        return true
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

    @objc private func showAbout() {
        do {
            let info = try AppInformation()
            let credits = try AppInformation.credits()
            let formatted = NSAttributedString(
                string: credits,
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
            )
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: info.name,
                .applicationVersion: info.version,
                .version: info.build,
                .credits: formatted
            ])
        } catch {
            alert("About RateCue is unavailable", detail: error.localizedDescription)
        }
    }

    @objc private func showHelp() {
        alert("RateCue Help", detail: """
            Getting started
            Open Music, enable Monitor Apple Music, and select your preferred output device in the RateCue menu. Grant Music Automation access when asked; if access was denied, review System Settings > Privacy & Security > Automation.

            Reading the display
            Green indicates a qualified local source format. Amber with ≈ is an unverified Music-reported rate or panel snapshot; — means unknown. Status can still say Unknown Format when an amber estimate is displayed. A matching rate alone does not prove bit-perfect playback.

            Music panel and permissions
            Use Music Evidence → Accessibility Access to check or request permission. Open Music's Lossless panel and choose Music Evidence → Read Open Music Lossless Panel to display a user-confirmed amber snapshot. Automatically Read Music Panel is opt-in and experimental: after playback, route, or reported-rate changes it briefly opens and closes the panel, even while Music is active. Those changes invalidate the old snapshot. Use Advanced Diagnostics → Copy Diagnostics to copy a status summary.

            Local files and verification
            Advanced Diagnostics contains logs, copied diagnostics, qualification snapshots, and authorized local-audio tools. Catalog source depth and automatic catalog switching remain unqualified. Verification controls appear only for a calibrated device profile and still require separate permission.

            Build and test
            On macOS 15 or later with Xcode 16 and Swift 6, run sh Scripts/check.sh from the project folder. Use the bundled executable with --help for CLI commands.
            """)
    }

    @objc private func showCredits() {
        do {
            alert("RateCue Credits", detail: try AppInformation.credits())
        } catch {
            alert("Credits are unavailable", detail: error.localizedDescription)
        }
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
        FileHandle.standardError.write(Data("Usage: RateCue \(command) <new-folder>\n".utf8))
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
        FileHandle.standardError.write(Data("Usage: RateCue --compare-pcm <reference> <candidate> [--offset-frames <nonnegative-integer>]\n".utf8))
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
