import AudioToolbox
import CoreServices
import DamonPolicy
import Foundation

public struct Playback: Sendable {
    public enum State: String, Sendable { case playing, paused, stopped }

    public let state: State
    public let trackID: String?
    public let position: Double?
    public let file: URL?
    public let reportedRate: Int?
}

public enum MusicObservationError: LocalizedError {
    case rejected(Int)
    case unexpectedResponse
    case changedDuringRead

    public var errorDescription: String? {
        switch self {
        case .rejected(-1743): "Music Automation permission denied. Enable RateCue in System Settings > Privacy & Security > Automation."
        case let .rejected(code): "Music could not be read (Apple event \(code))."
        case .unexpectedResponse: "Music returned an unrecognized playback state."
        case .changedDuringRead: "Track changed during observation; waiting for a stable reading."
        }
    }
}

public enum MusicObserver {
    private typealias Descriptor = NSAppleEventDescriptor

    private static func code(_ string: StaticString) -> UInt32 {
        string.withUTF8Buffer { $0.reduce(0) { ($0 << 8) | UInt32($1) } }
    }

    static func property(_ name: StaticString, in object: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        // Standard Apple Events property object specifier; Music publishes these property codes in its scripting dictionary.
        let parent = object ?? Descriptor.null()
        let key = Descriptor(typeCode: code(name))
        guard var container = parent.aeDesc?.pointee, var keyData = key.aeDesc?.pointee else {
            throw MusicObservationError.unexpectedResponse
        }
        var result = AEDesc()
        let status = withExtendedLifetime((parent, key)) {
            CreateObjSpecifier(code("prop"), &container, code("prop"), &keyData, false, &result)
        }
        guard status == noErr else { throw MusicObservationError.rejected(Int(status)) }
        return Descriptor(aeDescNoCopy: &result)
    }

    private static func get(_ object: Descriptor, pid: pid_t) throws -> Descriptor {
        let event = Descriptor(eventClass: code("core"), eventID: code("getd"),
                               targetDescriptor: Descriptor(processIdentifier: pid), returnID: -1, transactionID: 0)
        event.setParam(object, forKeyword: code("----"))
        // Do not allow a background observation to generate a permission prompt. The app's explicit toggle does that.
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 0.35)
        if let error = reply.paramDescriptor(forKeyword: code("errn")), error.int32Value != 0 {
            throw MusicObservationError.rejected(Int(error.int32Value))
        }
        guard let result = reply.paramDescriptor(forKeyword: code("----")) else {
            throw MusicObservationError.unexpectedResponse
        }
        return result
    }

    private static func playbackState(pid: pid_t) throws -> Playback.State {
        switch try get(property("pPlS"), pid: pid).enumCodeValue {
        case code("kPSP"): .playing
        case code("kPSp"): .paused
        case code("kPSS"), code("kPSF"), code("kPSR"): .stopped
        default: throw MusicObservationError.unexpectedResponse
        }
    }

    public static func observe(pid: pid_t, readLocation: Bool, includeRateEstimate: Bool = false) throws -> Playback {
        let state = try playbackState(pid: pid)
        guard state == .playing else { return Playback(state: state, trackID: nil, position: nil, file: nil, reportedRate: nil) }
        let track = try property("pTrk")
        let persistentID = try property("pPIS", in: track)
        let id = try get(persistentID, pid: pid).stringValue
        let position = try? get(property("pPos"), pid: pid).doubleValue
        var rate: Int?
        var file: URL?
        if readLocation, let trackClass = try? get(property("pcls", in: track), pid: pid),
           trackClass.typeCodeValue == code("cFlT") {
            file = try? get(property("pLoc", in: track), pid: pid).fileURLValue
        }
        if file != nil || includeRateEstimate,
           let sampleRate = try? get(property("pSRt", in: track), pid: pid).int32Value, sampleRate > 0 {
            rate = Int(sampleRate)
        }
        guard let id, !id.isEmpty, try get(persistentID, pid: pid).stringValue == id,
              try playbackState(pid: pid) == .playing else {
            throw MusicObservationError.changedDuringRead
        }
        return Playback(state: .playing, trackID: id, position: position, file: file, reportedRate: rate)
    }

    struct FormatProbe: Encodable {
        struct TrackRate: Encodable {
            let status: String
            var rateHz: Int?
            var appleEventError: Int?
        }

        struct Panel: Encodable {
            let status: String
            var rateHz: Int?
            var bitDepth: Int?
            var freshness: String?
        }

        let playbackState: String
        let trackProperty: TrackRate?
        let losslessPanel: Panel?
    }

    // These observations do not qualify the source format, even when the readings agree.
    static func probeFormat(pid: pid_t, readPanel: Bool) throws -> FormatProbe {
        let state = try playbackState(pid: pid)
        guard state == .playing else {
            return FormatProbe(playbackState: state.rawValue, trackProperty: nil, losslessPanel: nil)
        }
        let track = try property("pTrk")
        let persistentID = try property("pPIS", in: track)
        let rateProperty = try property("pSRt", in: track)
        return try probePlayingFormat(
            trackID: { try get(persistentID, pid: pid).stringValue },
            trackRate: { Int(try get(rateProperty, pid: pid).int32Value) },
            panel: readPanel ? { MusicFormatPanel.read(pid: pid) } : nil,
            stillPlaying: { try playbackState(pid: pid) == .playing }
        )
    }

    static func probePlayingFormat(
        trackID: () throws -> String?, trackRate: () throws -> Int, panel: (() -> MusicFormatPanel.Result)?,
        stillPlaying: () throws -> Bool
    ) throws -> FormatProbe {
        guard let initialID = try trackID(), !initialID.isEmpty else { throw MusicObservationError.changedDuringRead }
        let property: FormatProbe.TrackRate
        do {
            let rate = try trackRate()
            property = rate > 0 ? .init(status: "reported", rateHz: rate) : .init(status: "notReported")
        } catch MusicObservationError.rejected(let code) {
            property = .init(status: "unavailable", appleEventError: code)
        } catch {
            property = .init(status: "unavailable", appleEventError: (error as NSError).code)
        }
        let reading: FormatProbe.Panel? = switch panel?() {
        case .none: nil
        case .accessibilityDenied: .init(status: "accessibilityDenied")
        case .unavailable: .init(status: "unavailable")
        case .noOpenPanel: .init(status: "noOpenPanel")
        case .unrecognizedFormat: .init(status: "unrecognizedFormat")
        case let .reading(format): .init(status: "reported", rateHz: format.rate, bitDepth: format.bitDepth, freshness: "notEstablished")
        }
        guard try trackID() == initialID, try stillPlaying() else { throw MusicObservationError.changedDuringRead }
        return FormatProbe(playbackState: Playback.State.playing.rawValue, trackProperty: property, losslessPanel: reading)
    }

    enum FreshPanelError: LocalizedError, Equatable {
        case notPlaying, accessibilityDenied, unavailable, alreadyOpen, unrecognizedFormat, timedOut

        var errorDescription: String? {
            switch self {
            case .notPlaying: "Music must be playing before starting the panel check."
            case .accessibilityDenied: "\(MusicFormatPanel.accessibilityGuidance) For CLI checks, also allow your terminal."
            case .unavailable: "Music's Now Playing panel could not be observed reliably."
            case .alreadyOpen: "Close Music's Lossless panel before starting the fresh-panel check."
            case .unrecognizedFormat: "Music's open panel did not show one recognizable ALAC format."
            case .timedOut: "The Lossless panel was not observed opening before the deadline."
            }
        }
    }

    public static func readFreshPanel(
        pid: pid_t, expectedTrackID: String, onReady: @Sendable () -> Void
    ) throws -> MusicFormatPanel.Reading {
        let result = try probeFreshPanel(pid: pid, onReady: onReady, expectedTrackID: expectedTrackID)
        guard let panel = result.losslessPanel, panel.status == "reported", let rate = panel.rateHz,
              panel.freshness == "openedDuringProbe" else { throw FreshPanelError.unavailable }
        return MusicFormatPanel.Reading(rate: rate, bitDepth: panel.bitDepth)
    }

    public static func readOpenPanel(pid: pid_t, expectedTrackID: String) throws -> MusicFormatPanel.Result {
        let track = try property("pTrk")
        let persistentID = try property("pPIS", in: track)
        return try readOpenPanel(
            expectedTrackID: expectedTrackID, trackID: { try get(persistentID, pid: pid).stringValue },
            stillPlaying: { try playbackState(pid: pid) == .playing }, panel: { MusicFormatPanel.read(pid: pid) }
        )
    }

    public static func readAutomaticPanel(pid: pid_t, expectedTrackID: String) throws -> MusicFormatPanel.Reading {
        let track = try property("pTrk")
        let persistentID = try property("pPIS", in: track)
        return try MusicFormatPanel.readAutomatically(pid: pid) {
            guard !expectedTrackID.isEmpty, try get(persistentID, pid: pid).stringValue == expectedTrackID,
                  try playbackState(pid: pid) == .playing else { throw MusicObservationError.changedDuringRead }
        }
    }

    static func readOpenPanel(
        expectedTrackID: String, trackID: () throws -> String?, stillPlaying: () throws -> Bool,
        panel: () -> MusicFormatPanel.Result
    ) throws -> MusicFormatPanel.Result {
        guard !expectedTrackID.isEmpty, try trackID() == expectedTrackID, try stillPlaying() else {
            throw MusicObservationError.changedDuringRead
        }
        let result = panel()
        guard try trackID() == expectedTrackID, try stillPlaying() else { throw MusicObservationError.changedDuringRead }
        return result
    }

    static func probeFreshPanel(pid: pid_t, onReady: () -> Void, expectedTrackID: String? = nil) throws -> FormatProbe {
        guard try playbackState(pid: pid) == .playing else { throw FreshPanelError.notPlaying }
        let track = try property("pTrk")
        let persistentID = try property("pPIS", in: track)
        let rateProperty = try property("pSRt", in: track)
        return try probeFreshPanel(
            trackID: { try get(persistentID, pid: pid).stringValue },
            trackRate: { Int(try get(rateProperty, pid: pid).int32Value) },
            panel: { MusicFormatPanel.read(pid: pid) },
            stillPlaying: { try playbackState(pid: pid) == .playing },
            now: { ProcessInfo.processInfo.systemUptime }, sleep: Thread.sleep(forTimeInterval:),
            onReady: onReady, expectedTrackID: expectedTrackID, shouldContinue: { !Task.isCancelled }
        )
    }

    static func probeFreshPanel(
        trackID: () throws -> String?, trackRate: () throws -> Int, panel: () -> MusicFormatPanel.Result,
        stillPlaying: () throws -> Bool, now: () -> TimeInterval, sleep: (TimeInterval) -> Void,
        onReady: () -> Void, timeout: TimeInterval = 15, expectedTrackID: String? = nil,
        shouldContinue: () -> Bool = { true }
    ) throws -> FormatProbe {
        guard shouldContinue() else { throw CancellationError() }
        guard let initialID = try trackID(), !initialID.isEmpty, try stillPlaying() else {
            throw FreshPanelError.notPlaying
        }
        guard expectedTrackID == nil || expectedTrackID == initialID else { throw MusicObservationError.changedDuringRead }
        func checkTrack() throws {
            guard shouldContinue() else { throw CancellationError() }
            guard try trackID() == initialID, try stillPlaying() else { throw MusicObservationError.changedDuringRead }
        }
        let initialPanel = panel()
        try checkTrack()
        switch initialPanel {
        case .noOpenPanel: break
        case .accessibilityDenied: throw FreshPanelError.accessibilityDenied
        case .unavailable: throw FreshPanelError.unavailable
        case .reading, .unrecognizedFormat: throw FreshPanelError.alreadyOpen
        }
        onReady()
        let deadline = now() + timeout
        while now() < deadline {
            try checkTrack()
            let observation = panel()
            try checkTrack()
            guard now() <= deadline else { break }
            switch observation {
            case let .reading(format):
                let result = try probePlayingFormat(trackID: trackID, trackRate: trackRate, panel: { .reading(format) },
                                                    stillPlaying: stillPlaying)
                try checkTrack()
                guard now() <= deadline else { throw FreshPanelError.timedOut }
                return FormatProbe(playbackState: result.playbackState, trackProperty: result.trackProperty,
                                   losslessPanel: .init(status: "reported", rateHz: format.rate, bitDepth: format.bitDepth,
                                                        freshness: "openedDuringProbe"))
            case .noOpenPanel:
                sleep(min(0.2, max(0, deadline - now())))
            case .accessibilityDenied: throw FreshPanelError.accessibilityDenied
            case .unavailable: throw FreshPanelError.unavailable
            case .unrecognizedFormat: throw FreshPanelError.unrecognizedFormat
            }
        }
        throw FreshPanelError.timedOut
    }

    public static func requestPermission(pid: pid_t, askIfNeeded: Bool = true) -> OSStatus {
        let target = Descriptor(processIdentifier: pid)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, code("core"), code("getd"), askIfNeeded)
    }

    enum TransportAction: String {
        case play, pause, next

        var eventID: StaticString {
            switch self {
            case .play: "Play"
            case .pause: "Paus"
            case .next: "Next"
            }
        }
    }

    struct TransportSnapshot {
        let state: Playback.State
        var trackID: String?
    }

    struct TransportResult: Encodable {
        let action: String
        let playbackState: String
        let confirmed: Bool
        let commandSent: Bool
        var trackChanged: Bool?
        var message: String?
    }

    struct TransportError: LocalizedError {
        let action: TransportAction
        let code: Int32

        var errorDescription: String? { "Music rejected \(action.rawValue) (Apple event \(code))." }
    }

    static func control(_ action: TransportAction, pid: pid_t) throws -> TransportResult {
        try runTransport(action, read: {
            let state = try playbackState(pid: pid)
            guard action == .next, state != .stopped else { return TransportSnapshot(state: state) }
            do {
                let track = try property("pTrk")
                let id = try get(property("pPIS", in: track), pid: pid).stringValue
                return TransportSnapshot(state: state, trackID: id?.isEmpty == false ? id : nil)
            } catch MusicObservationError.rejected(-1728) {
                return TransportSnapshot(state: state)
            }
        }, send: {
            let event = Descriptor(eventClass: code("hook"), eventID: code(action.eventID),
                                   targetDescriptor: Descriptor(processIdentifier: pid), returnID: -1, transactionID: 0)
            let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 2)
            if let error = reply.paramDescriptor(forKeyword: code("errn")), error.int32Value != 0 {
                throw TransportError(action: action, code: error.int32Value)
            }
        }, now: { ProcessInfo.processInfo.systemUptime }, sleep: Thread.sleep(forTimeInterval:))
    }

    static func runTransport(
        _ action: TransportAction, read: () throws -> TransportSnapshot, send: () throws -> Void,
        now: () -> TimeInterval, sleep: (TimeInterval) -> Void
    ) throws -> TransportResult {
        let before = try read()
        func result(_ sample: TransportSnapshot, confirmed: Bool, sent: Bool, message: String? = nil) -> TransportResult {
            TransportResult(action: action.rawValue, playbackState: sample.state.rawValue, confirmed: confirmed,
                            commandSent: sent, trackChanged: action == .next ? confirmed : nil, message: message)
        }
        if (action == .play && before.state == .playing) || (action == .pause && before.state == .paused) {
            return result(before, confirmed: true, sent: false)
        }
        if action == .pause && before.state == .stopped {
            return result(before, confirmed: false, sent: false, message: "Music is stopped; there is nothing to pause.")
        }
        if action == .next && (before.state == .stopped || before.trackID == nil) {
            return result(before, confirmed: false, sent: false, message: "No current track could be identified to skip.")
        }

        try send()
        let deadline = now() + 2
        while true {
            let after = try read()
            let confirmed = switch action {
            case .play: after.state == .playing
            case .pause: after.state == .paused
            case .next: after.state != .stopped && after.trackID.map { $0 != before.trackID } == true
            }
            let remaining = deadline - now()
            if confirmed && remaining >= 0 { return result(after, confirmed: true, sent: true) }
            if remaining <= 0 {
                return result(after, confirmed: false, sent: true, message: "Music did not confirm the requested change.")
            }
            sleep(min(0.05, remaining))
        }
    }

    struct FixturePlaybackError: LocalizedError {
        let errorDescription: String?
    }

    static func fixturePlayEvent(_ file: URL, pid: pid_t) -> NSAppleEventDescriptor {
        let event = Descriptor(eventClass: code("hook"), eventID: code("Play"),
                               targetDescriptor: Descriptor(processIdentifier: pid), returnID: -1, transactionID: 0)
        event.setParam(Descriptor(fileURL: file), forKeyword: code("----"))
        event.setParam(Descriptor(boolean: true), forKeyword: code("POne"))
        return event
    }

    @discardableResult
    static func playFixture(_ file: URL, pid: pid_t, allowInterrupt: Bool, replacing previousFixture: URL? = nil) throws -> TimeInterval {
        let state = try get(property("pPlS"), pid: pid).enumCodeValue
        if !allowInterrupt && state != code("kPSS") {
            guard let previousFixture, try playingFixture(previousFixture, pid: pid) else {
                let message = previousFixture == nil
                    ? "Music is not stopped. Stop it first or explicitly pass --allow-interrupt for a read-only fixture trial."
                    : "Music left the current test fixture; playback was not changed."
                throw FixturePlaybackError(errorDescription: message)
            }
        }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let reply = try fixturePlayEvent(file, pid: pid).sendEvent(options: [.waitForReply, .neverInteract], timeout: 2)
        if let error = reply.paramDescriptor(forKeyword: code("errn")), error.int32Value != 0 {
            throw FixturePlaybackError(errorDescription: "Music rejected the one-time fixture playback request (Apple event \(error.int32Value)).")
        }
        return requestedAt
    }

    static func playingFixture(_ file: URL, pid: pid_t, trackID: String? = nil) throws -> Bool {
        guard try get(property("pPlS"), pid: pid).enumCodeValue == code("kPSP") else { return false }
        let track = try property("pTrk")
        if let trackID, try get(property("pPIS", in: track), pid: pid).stringValue != trackID { return false }
        let location = try get(property("pLoc", in: track), pid: pid).fileURLValue
        return location?.resolvingSymlinksInPath().standardizedFileURL == file
    }
}

public enum LocalRendition {
    public enum Failure: String, Error {
        case outsideApprovedFolder = "Current file is not authorized for inspection"
        case notReadable = "Current file is unreadable"
        case formatUnsupported = "Current file is not supported stereo integer PCM or ALAC"
        case missingMusicRate = "Music did not report a sample rate for the current file"
        case rateMismatch = "Music's track rate disagrees with the current file header"
    }

    public static func inspect(url: URL, in approvedLocation: URL, reportedRate: Int?) -> Result<Format, Failure> {
        let file = url.resolvingSymlinksInPath().standardizedFileURL
        let approved = approvedLocation.resolvingSymlinksInPath().standardizedFileURL
        guard file.isFileURL, approved.isFileURL,
              let scope = try? approved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
            return .failure(.outsideApprovedFolder)
        }
        let permitted = if scope.isDirectory == true {
            file.pathComponents.count > approved.pathComponents.count && file.pathComponents.starts(with: approved.pathComponents)
        } else {
            scope.isRegularFile == true && file.path == approved.path
        }
        guard permitted else { return .failure(.outsideApprovedFolder) }
        guard ["wav", "aif", "aiff", "caf", "m4a"].contains(file.pathExtension.lowercased()) else {
            return .failure(.formatUnsupported)
        }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
              values.isRegularFile == true, values.isReadable == true else { return .failure(.notReadable) }
        var id: AudioFileID?
        guard AudioFileOpenURL(file as CFURL, .readPermission, 0, &id) == noErr, let id else { return .failure(.notReadable) }
        defer { AudioFileClose(id) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(id, kAudioFilePropertyDataFormat, &size, &format) == noErr,
              format.mChannelsPerFrame == 2, let rate = Int(exactly: format.mSampleRate), rate > 0,
              let depth = PCMComparison.integerBitDepth(format) else {
            return .failure(.formatUnsupported)
        }
        guard let reportedRate, reportedRate > 0 else { return .failure(.missingMusicRate) }
        guard reportedRate == rate else { return .failure(.rateMismatch) }
        return .success(Format(rate: rate, depth: depth))
    }
}
