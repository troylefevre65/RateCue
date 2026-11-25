import Foundation

public struct MusicLogEvidence: Equatable, Sendable, Encodable {
    public enum Source: String, Sendable, Encodable {
        case decoder
        case alternate
    }

    public let source: Source
    public let at: Date
    public let playbackStartAt: Date?
    public let rate: Int
    public let depth: Int

    public init(source: Source, at: Date, playbackStartAt: Date? = nil, rate: Int, depth: Int) {
        self.source = source
        self.at = at
        self.playbackStartAt = playbackStartAt
        self.rate = rate
        self.depth = depth
    }
}

public enum MusicLogProbeTiming {
    public static let firstProbeDelay: TimeInterval = 0.1
    public static let retryDelays: [TimeInterval] = [0, 0.25, 0.75, 1.5, 3, 6, 12]
    public static let maximumAttempts = retryDelays.count + 1

    public static func nextProbe(after completionAt: TimeInterval, attempts: Int) -> TimeInterval? {
        guard attempts > 0, attempts <= retryDelays.count else { return nil }
        return completionAt + retryDelays[attempts - 1]
    }
}

public struct TransientPlaybackObservationHold: Sendable {
    public static let limit = 2
    private var misses = 0

    public init() {}

    public mutating func retainPrevious(
        observedPlaybackAvailable: Bool, sameProcess: Bool, previousWasPlaying: Bool
    ) -> Bool {
        guard !observedPlaybackAvailable else {
            misses = 0
            return false
        }
        guard sameProcess, previousWasPlaying, misses < Self.limit else { return false }
        misses += 1
        return true
    }
}

public struct MusicPlaybackLogAnchor: Sendable {
    private var trackID: String?
    private var startedAt: Date?
    private var interrupted = false
    private var lastPosition: Double?

    public init() {}

    public mutating func observe(_ playback: Playback?, at: Date, restarted: Bool = false) {
        guard let playback else { return }
        switch playback.state {
        case .playing:
            guard let trackID = playback.trackID, !trackID.isEmpty,
                  let position = playback.position, position.isFinite, position >= 0 else { return }
            let resumedFromBeginning = interrupted && position < 1 && (lastPosition ?? position) >= 1
            if restarted || self.trackID != trackID || startedAt == nil || resumedFromBeginning {
                self.trackID = trackID
                startedAt = at.addingTimeInterval(-position)
            }
            lastPosition = position
            interrupted = false
        case .paused, .stopped:
            interrupted = true
        }
    }

    public func startedAt(for trackID: String) -> Date? {
        self.trackID == trackID ? startedAt : nil
    }
}

public enum MusicLogEvidenceReader {
    private final class ProcessDeadline: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var cancelled = false

        init(_ process: Process) {
            self.process = process
        }

        func schedule(seconds: TimeInterval) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                self.lock.lock()
                let shouldTerminate = !self.cancelled
                self.lock.unlock()
                if shouldTerminate, self.process.isRunning { self.process.terminate() }
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private struct Event: Decodable {
        let timestamp: String
        let eventMessage: String
    }

    public static func parse(_ data: Data) throws -> [MusicLogEvidence] {
        let events = try JSONDecoder().decode([Event].self, from: data)
        let reportPattern = #/\[SampleRate ([0-9]{5,6})\] \[BitDepth (8|16|20|24|32)\]/#
        let alternatePattern = #/AudioGroup audio-alac-stereo-([0-9]{5,6})-(8|16|20|24|32)/#
        let lifecyclePattern = #/(<[^>]*\|I\/[A-Z0-9.]+>)/#
        let timestampFormat = DateFormatter()
        timestampFormat.locale = Locale(identifier: "en_US_POSIX")
        timestampFormat.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSxx"
        timestampFormat.timeZone = TimeZone(secondsFromGMT: 0)
        let datedEvents = events.compactMap { event -> (Event, Date)? in
            timestampFormat.date(from: event.timestamp).map { (event, $0) }
        }.sorted { $0.1 < $1.1 }
        var starts: [String: Date] = [:]
        return datedEvents.compactMap { event, at in
            let lifecycleID = event.eventMessage.firstMatch(of: lifecyclePattern).map { String($0.1) }
            if event.eventMessage.contains("fpfs_StartTrackPlaying"), let lifecycleID {
                starts[lifecycleID] = at
                return nil
            }
            if let match = event.eventMessage.firstMatch(of: reportPattern),
               let rate = Int(match.1), let depth = Int(match.2),
               let lifecycleID, let start = starts[lifecycleID],
               at.timeIntervalSince(start) >= 0, at.timeIntervalSince(start) <= 90 {
                return MusicLogEvidence(
                    source: .decoder, at: at, playbackStartAt: start, rate: rate, depth: depth
                )
            }
            if let match = event.eventMessage.firstMatch(of: alternatePattern),
               let rate = Int(match.1), let depth = Int(match.2) {
                return MusicLogEvidence(
                    source: .alternate, at: at, playbackStartAt: nil, rate: rate, depth: depth
                )
            }
            return nil
        }
    }

    public static func collect(last seconds: Int = 6) throws -> [MusicLogEvidence] {
        try collect(arguments: ["--last", "\(max(1, min(900, seconds)))s"])
    }

    public static func collect(around date: Date, radius: TimeInterval = 30) throws -> [MusicLogEvidence] {
        let start = date.addingTimeInterval(-max(1, radius))
        let end = date.addingTimeInterval(max(1, radius))
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ssxx"
        format.timeZone = TimeZone(secondsFromGMT: 0)
        return try collect(arguments: ["--start", format.string(from: start), "--end", format.string(from: end)])
    }

    private static func collect(arguments: [String]) throws -> [MusicLogEvidence] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show"] + arguments + [
            "--style", "json",
            "--predicate",
            #"process == "Music" AND (eventMessage CONTAINS "fpfs_StartTrackPlaying" OR eventMessage CONTAINS "fpfs_ReportAudioPlaybackThroughFigLog" OR eventMessage CONTAINS "AudioGroup audio-alac-stereo")"#
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessDeadline(process)
        deadline.schedule(seconds: 20)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "MusicLogEvidenceReader", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "The system log query failed or timed out."])
        }
        return try parse(data)
    }
}
