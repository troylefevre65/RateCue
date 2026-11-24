import AppKit
import Foundation

public enum DamonCLI {
    private static let usage = """
    RateCue CLI
    Usage: RateCue <command>

      --version                                    Show the application version and build.
      devices                                      List Core Audio outputs as JSON.
      config show                                  Read RateCue preferences as JSON.
      config set [options]                         Update RateCue preferences.
        --device <uid|exact-name|none>
        --local-audio <file-or-folder> | --clear-local-audio
        --monitor-music <on|off>
        --auto-switch <on|off>
        --show-rate <on|off>
        --show-depth <on|off>
      authorize-music                              Request Music Automation access explicitly.
      status                                       Read a fresh Music and device snapshot as JSON.
      menu-status                                  Read the running menu app's latest diagnostics.
      log-format                                   Read current Music format events from unified logs.
      probe-format [--panel|--fresh-panel]         Read unqualified Music format evidence without switching.
      playback <play|pause|next>                   Send one playback command to the running Music app.
      check --rate <Hz> --depth <bits> [options]    Check the current source format and Music output.
        --device <uid|exact-name>                  Defaults to the saved preferred device.
        --device-rate <Hz>                         Also check the device's nominal rate.
      test-fixture --kit <folder> [options]        Play and verify the 96 kHz / 24-bit test fixture once.
        --device <uid|exact-name>                  Defaults to the saved preferred device.
        --allow-interrupt                          Allow replacing active or paused playback.
      test-switch --kit <folder> --device <uid|exact-name> --allow-rate-write
                                                    Run a guarded 44.1 -> 96 -> 44.1 kHz lab trial.

      --make-qualification-kit <new-folder>        Generate and validate the fixture kit.
      --make-fixtures <new-folder>                  Generate the short fixture set.
      --compare-pcm <reference> <candidate> [--offset-frames <N>]
      --diagnose                                   Print a human-readable output-device list.

    Run the executable without arguments to open RateCue. Status and check do not start Music,
    play tracks, request permissions, or change audio settings; they do not include amber panel
    estimates. Use probe-format for unqualified Music evidence. Playback and fixture trials
    can change playback; test-switch can change the selected device's rate.
    Device lists and configuration output can contain device identifiers or local paths.
    Check exit codes:
    0 = all assertions matched, 1 = mismatch or unavailable evidence, 2 = invalid invocation.
    """

    private struct CommandError: LocalizedError {
        let message: String
        let exitCode: Int32

        init(_ message: String, exitCode: Int32 = 2) {
            self.message = message
            self.exitCode = exitCode
        }

        var errorDescription: String? { message }
    }

    private struct DeviceInfo: Encodable {
        struct Range: Encodable {
            let minimumHz: Double
            let maximumHz: Double
        }

        let uid: String
        let name: String
        let nominalRateHz: Int?
        let rateSettable: Bool
        let availableRates: [Range]

        init(_ device: OutputDevice) {
            uid = device.uid
            name = device.name
            nominalRateHz = device.nominalRate
            rateSettable = device.isRateSettable
            availableRates = device.availableRates.map { Range(minimumHz: $0.lowerBound, maximumHz: $0.upperBound) }
        }
    }

    private struct Observation: Encodable {
        let message: String
        let playbackState: String?
        let sourceRateHz: Int?
        let sourceBitDepth: Int?
        let activeOutputs: [DeviceInfo]
        let preferredOutput: DeviceInfo?
        let monitorMusicEnabled: Bool

        init(sample: PlaybackSample, settings: DamonSettings) {
            message = sample.message
            playbackState = sample.playback?.state.rawValue
            sourceRateHz = sample.format?.rate
            sourceBitDepth = sample.format?.depth
            activeOutputs = sample.activeOutputs.map(DeviceInfo.init)
            preferredOutput = sample.preferredOutput(uid: settings.preferredOutputUID).map(DeviceInfo.init)
            monitorMusicEnabled = settings.monitorMusic
        }
    }

    private struct CheckResult: Encodable {
        let passed: Bool
        let issues: [String]
        let observation: Observation
    }

    @MainActor
    public static func run(_ args: [String]) -> Int32 {
        let store = SettingsStore()
        do {
            switch args.first {
            case "help", "--help", "-h":
                try requireArgumentCount(args, 1)
                print(usage)
            case "version", "--version":
                try requireArgumentCount(args, 1)
                print(try AppInformation().versionDescription)
            case "devices":
                try requireArgumentCount(args, 1)
                try printJSON(connectedDevices().map(DeviceInfo.init))
            case "config":
                switch args.dropFirst().first {
                case "show":
                    try requireArgumentCount(args, 2)
                case "set":
                    let edits = try configurationEdits(Array(args.dropFirst(2)), devices: connectedDevices)
                    try store.apply(edits)
                default:
                    throw CommandError("Use 'config show' or 'config set'.")
                }
                try printJSON(store.read())
            case "authorize-music":
                try requireArgumentCount(args, 1)
                guard let pid = musicPID else { throw CommandError("Open Music before requesting Automation access.", exitCode: 1) }
                let status = MusicObserver.requestPermission(pid: pid)
                guard status == 0 else {
                    throw CommandError("Music Automation unavailable (\(status)). Review System Settings > Privacy & Security > Automation for this launcher.",
                                       exitCode: 1)
                }
                print("Music Automation is authorized for this launcher.")
            case "status":
                try requireArgumentCount(args, 1)
                let settings = try store.read()
                try printJSON(Observation(sample: observe(settings), settings: settings))
            case "menu-status":
                try requireArgumentCount(args, 1)
                let snapshot = try MenuDiagnosticsStore().read()
                guard snapshot.schemaVersion == 1 else {
                    throw CommandError("Unsupported menu diagnostics schema \(snapshot.schemaVersion).", exitCode: 1)
                }
                guard validMenuSnapshot(snapshot, now: Date()) else {
                    throw CommandError("Menu diagnostics are stale or no longer belong to a running RateCue app.", exitCode: 1)
                }
                try printJSON(snapshot, dateEncodingStrategy: .iso8601)
            case "log-format":
                try requireArgumentCount(args, 1)
                try printJSON(MusicLogEvidenceReader.collect(last: 900), dateEncodingStrategy: .iso8601)
            case "probe-format":
                let options = try parseOptions(Array(args.dropFirst()), allowed: [], flags: ["--panel", "--fresh-panel"])
                guard options["--panel"] == nil || options["--fresh-panel"] == nil else {
                    throw CommandError("Use either --panel or --fresh-panel, not both.")
                }
                guard let pid = musicPID else { throw CommandError("Open Music before probing the format.", exitCode: 1) }
                let permission = MusicObserver.requestPermission(pid: pid, askIfNeeded: false)
                guard permission == 0 else {
                    throw CommandError("Music Automation unavailable (\(permission)). Run authorize-music explicitly.", exitCode: 1)
                }
                if options["--fresh-panel"] != nil {
                    let result = try MusicObserver.probeFreshPanel(pid: pid) {
                        FileHandle.standardError.write(Data("Open Music's Lossless panel now; waiting up to 15 seconds.\n".utf8))
                    }
                    try printJSON(result)
                } else {
                    try printJSON(MusicObserver.probeFormat(pid: pid, readPanel: options["--panel"] != nil))
                }
            case "playback":
                try requireArgumentCount(args, 2)
                guard let action = MusicObserver.TransportAction(rawValue: args[1]) else {
                    throw CommandError("Use 'playback play', 'playback pause', or 'playback next'.")
                }
                guard let pid = musicPID else { throw CommandError("Open Music before controlling playback.", exitCode: 1) }
                let permission = MusicObserver.requestPermission(pid: pid, askIfNeeded: false)
                guard permission == 0 else {
                    throw CommandError("Music Automation unavailable (\(permission)). Run authorize-music explicitly.", exitCode: 1)
                }
                let result = try MusicObserver.control(action, pid: pid)
                try printJSON(result)
                return result.confirmed ? 0 : 1
            case "check":
                let options = try parseOptions(Array(args.dropFirst()), allowed: ["--rate", "--depth", "--device", "--device-rate"])
                let rate = try positiveInteger(options, "--rate")
                let depth = try positiveInteger(options, "--depth")
                guard depth <= 32 else { throw CommandError("--depth must be at most 32.") }
                let deviceRate = try options["--device-rate"].map { _ in try positiveInteger(options, "--device-rate") }
                let settings = try store.read()
                let uid = try expectedDevice(options["--device"], settings: settings)
                let sample = observe(settings)
                let issues = check(sample: sample, rate: rate, depth: depth, uid: uid, deviceRate: deviceRate)
                try printJSON(CheckResult(passed: issues.isEmpty, issues: issues, observation: Observation(sample: sample, settings: settings)))
                return issues.isEmpty ? 0 : 1
            case "test-fixture":
                return try runFixture(Array(args.dropFirst()), store: store)
            case "test-switch":
                return try runSwitchTrial(Array(args.dropFirst()), store: store)
            default:
                throw CommandError("Unknown command '\(args.first ?? "")'. Run 'RateCue --help' for usage.")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("RateCue: \(error.localizedDescription)\n".utf8))
            return (error as? CommandError)?.exitCode ?? 1
        }
    }

    @MainActor
    private static var musicPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: PlaybackSample.musicBundleID).first?.processIdentifier
    }

    static func validMenuSnapshot(
        _ snapshot: MenuDiagnosticsSnapshot, now: Date, maximumAge: TimeInterval = 5,
        isCurrentMenuProcess: (pid_t) -> Bool = { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "org.damon.BitStreamManager"
        }
    ) -> Bool {
        let age = now.timeIntervalSince(snapshot.snapshotAt)
        return (0...maximumAge).contains(age) && isCurrentMenuProcess(snapshot.processIdentifier)
    }

    @MainActor
    private static func observe(_ settings: DamonSettings) -> PlaybackSample {
        PlaybackSample.collect(pid: musicPID, automation: settings.monitorMusic, folder: settings.authorizedAudio, checkPermission: true)
    }

    @MainActor
    private static func runFixture(_ args: [String], store: SettingsStore) throws -> Int32 {
        let options = try parseOptions(args, allowed: ["--kit", "--device"], flags: ["--allow-interrupt"])
        guard let kit = options["--kit"] else { throw CommandError("Pass --kit with the path to a qualification kit.") }
        let settings = try store.read()
        guard !settings.autoSwitch else {
            throw CommandError("Turn Auto Switch off before starting the fixture trial.", exitCode: 1)
        }
        let uid = try expectedDevice(options["--device"], settings: settings)
        guard let pid = musicPID else { throw CommandError("Open Music before running the fixture trial.", exitCode: 1) }
        let permission = MusicObserver.requestPermission(pid: pid, askIfNeeded: false)
        guard permission == 0 else {
            throw CommandError("Music Automation unavailable (\(permission)). Run authorize-music explicitly.", exitCode: 1)
        }
        let fixture = try QualificationFixtures.prepareTrial(in: URL(fileURLWithPath: kit, isDirectory: true))
        guard try !store.read().autoSwitch else {
            throw CommandError("Auto Switch was enabled before the fixture could start.", exitCode: 1)
        }
        try MusicObserver.playFixture(fixture, pid: pid, allowInterrupt: options["--allow-interrupt"] != nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            let sample = PlaybackSample.collect(pid: pid, automation: true, folder: fixture)
            var issues = check(sample: sample, rate: QualificationFixtures.trialRate, depth: QualificationFixtures.trialDepth,
                               uid: uid, deviceRate: nil, fixture: fixture)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let autoSwitchEnabled = try store.read().autoSwitch
            if remaining <= 0 { issues.append("The fixture was not verified within the 10-second observation window.") }
            if autoSwitchEnabled { issues.append("Auto Switch was enabled during the fixture trial.") }
            if issues.isEmpty || remaining <= 0 || autoSwitchEnabled {
                var trialSettings = settings
                trialSettings.monitorMusic = true
                try printJSON(CheckResult(passed: issues.isEmpty, issues: issues,
                                          observation: Observation(sample: sample, settings: trialSettings)))
                return issues.isEmpty ? 0 : 1
            }
            Thread.sleep(forTimeInterval: min(0.2, remaining))
        } while true
    }

    private static func expectedDevice(_ selector: String?, settings: DamonSettings) throws -> String {
        if let selector { return try resolveDevice(selector, in: connectedDevices()).uid }
        guard let uid = settings.preferredOutputUID else {
            throw CommandError("Pass --device or configure a preferred output first.")
        }
        return uid
    }

    @MainActor
    private static func runSwitchTrial(_ args: [String], store: SettingsStore) throws -> Int32 {
        let options = try parseOptions(args, allowed: ["--kit", "--device"], flags: ["--allow-rate-write"])
        guard let kit = options["--kit"], let selector = options["--device"], options["--allow-rate-write"] != nil else {
            throw CommandError("Pass --kit, an explicit --device, and --allow-rate-write for the hardware trial.")
        }
        guard try !store.read().autoSwitch else {
            throw CommandError("Turn regular Auto Switch off before running the lab trial.", exitCode: 1)
        }
        let device = try resolveDevice(selector, in: connectedDevices())
        guard device.isWiredExternal, device.nominalRate == 44_100, device.supports(44_100), device.supports(96_000) else {
            throw CommandError("The trial requires a wired output already set to 44100 Hz with both 44100 and 96000 Hz writable.", exitCode: 1)
        }
        guard let pid = musicPID else { throw CommandError("Open Music before running the switch trial.", exitCode: 1) }
        let permission = MusicObserver.requestPermission(pid: pid, askIfNeeded: false)
        guard permission == 0 else {
            throw CommandError("Music Automation unavailable (\(permission)). Run authorize-music explicitly.", exitCode: 1)
        }
        let directory = URL(fileURLWithPath: kit, isDirectory: true)
        func fixture(_ rate: Int, _ depth: Int) throws -> SwitchTrial.Fixture {
            SwitchTrial.Fixture(file: try QualificationFixtures.prepareTrial(in: directory, rate: rate, depth: depth),
                                rate: rate, depth: depth)
        }
        let high = try fixture(96_000, 24)
        let baseline = try fixture(44_100, 16)
        let sameRate = try fixture(44_100, 24)
        let driver = SwitchTrial.Driver(
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: Thread.sleep(forTimeInterval:),
            play: { file, prior in
                guard try !store.read().autoSwitch else {
                    throw CommandError("Auto Switch was enabled; the lab trial cannot continue.", exitCode: 1)
                }
                return try MusicObserver.playFixture(file, pid: pid, allowInterrupt: false, replacing: prior)
            },
            observe: { PlaybackSample.collect(pid: pid, automation: true, folder: $0) },
            write: { request, current, file in
                guard try !store.read().autoSwitch, try MusicObserver.playingFixture(file, pid: pid),
                      AudioHardware.musicHasExclusiveOutput(pid: pid, deviceID: current.objectID) else {
                    throw CommandError("The fixture or exclusive Music route changed before the write.", exitCode: 1)
                }
                return AudioHardware.setRate(request.rate, device: current, musicPID: pid, deadline: request.deadline)
            },
            readRate: { AudioHardware.readRate(on: device) }
        )
        let report = SwitchTrial.run(device: device, high: high, baseline: baseline, sameRate: sameRate, driver: driver)
        try printJSON(report)
        return report.passed ? 0 : 1
    }

    static func check(sample: PlaybackSample, rate: Int, depth: Int, uid: String, deviceRate: Int?, fixture: URL? = nil) -> [String] {
        var issues: [String] = []
        if sample.playback?.state != .playing { issues.append("Music playback is not confirmed.") }
        if let fixture, sample.playback?.file?.resolvingSymlinksInPath().standardizedFileURL != fixture {
            issues.append("Music did not identify the exact fixture. A library copy outside the test scope cannot verify this trial.")
        }
        if sample.format?.rate != rate { issues.append("Expected source sample rate \(rate) Hz.") }
        if sample.format?.depth != depth { issues.append("Expected source bit depth \(depth).") }
        let expected = sample.preferredOutput(uid: uid)
        if expected.map({ sample.route == [$0.objectID] }) != true {
            issues.append("Music is not confirmed on the expected single output.")
        }
        if let deviceRate, expected?.nominalRate != deviceRate {
            issues.append("Expected device nominal rate \(deviceRate) Hz.")
        }
        return issues
    }

    static func configurationEdits(_ args: [String], devices: () throws -> [OutputDevice]) throws -> [SettingEdit] {
        let options = try parseOptions(args, allowed: ["--device", "--local-audio", "--monitor-music", "--auto-switch", "--show-rate", "--show-depth"],
                                       flags: ["--clear-local-audio"])
        guard !options.isEmpty else { throw CommandError("Provide at least one option to 'config set'.") }
        guard options["--local-audio"] == nil || options["--clear-local-audio"] == nil else {
            throw CommandError("Use only one of --local-audio and --clear-local-audio.")
        }
        var edits: [SettingEdit] = []
        for (key, edit) in [
            ("--monitor-music", SettingEdit.monitorMusic),
            ("--auto-switch", SettingEdit.autoSwitch),
            ("--show-rate", SettingEdit.showSampleRate),
            ("--show-depth", SettingEdit.showBitDepth)
        ] {
            if let value = options[key] {
                guard value == "on" || value == "off" else { throw CommandError("\(key) expects 'on' or 'off'.") }
                edits.append(edit(value == "on"))
            }
        }
        if let path = options["--local-audio"] {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            let properties = try? url.resourceValues(forKeys: [.isReadableKey, .isDirectoryKey, .isRegularFileKey])
            guard properties?.isReadable == true, properties?.isDirectory == true || properties?.isRegularFile == true else {
                throw CommandError("--local-audio needs an existing, readable file or directory.")
            }
            edits.append(.localAudio(url))
        } else if options["--clear-local-audio"] != nil {
            edits.append(.localAudio(nil))
        }
        if let selector = options["--device"] {
            let uid = selector == "none" ? nil : try resolveDevice(selector, in: devices()).uid
            edits.append(.device(uid))
        }
        return edits
    }

    static func resolveDevice(_ selector: String, in devices: [OutputDevice]) throws -> OutputDevice {
        let byUID = devices.filter { $0.uid == selector }
        let matches = byUID.isEmpty ? devices.filter { $0.name == selector } : byUID
        guard let device = matches.first else {
            throw CommandError("No connected output matches '\(selector)'. Run 'RateCue devices' to list outputs.")
        }
        guard matches.count == 1 else { throw CommandError("'\(selector)' is ambiguous. Select an exact UID from 'RateCue devices'.") }
        return device
    }

    private static func connectedDevices() throws -> [OutputDevice] {
        guard let outputs = AudioHardware.outputs() else { throw CommandError("Core Audio device list unavailable.", exitCode: 1) }
        return outputs
    }

    private static func parseOptions(_ args: [String], allowed: Set<String>, flags: Set<String> = []) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < args.count {
            let key = args[index]
            guard allowed.contains(key) || flags.contains(key) else { throw CommandError("Unknown option '\(key)'.") }
            guard options[key] == nil else { throw CommandError("Option \(key) was given more than once.") }
            index += 1
            if flags.contains(key) {
                options[key] = ""
            } else {
                guard index < args.count, !args[index].isEmpty, !args[index].hasPrefix("--") else {
                    throw CommandError("Missing value for \(key).")
                }
                options[key] = args[index]
                index += 1
            }
        }
        return options
    }

    private static func positiveInteger(_ options: [String: String], _ key: String) throws -> Int {
        guard let value = options[key].flatMap(Int.init), value > 0 else {
            throw CommandError("\(key) requires a positive integer.")
        }
        return value
    }

    private static func requireArgumentCount(_ args: [String], _ count: Int) throws {
        guard args.count == count else { throw CommandError("Unexpected arguments. Run 'RateCue --help' for usage.") }
    }

    private static func printJSON(
        _ value: some Encodable, dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .deferredToDate
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateEncodingStrategy
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
