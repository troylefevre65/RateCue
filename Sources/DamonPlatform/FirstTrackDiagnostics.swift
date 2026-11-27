import Foundation

/// Observation-only pilot. No identifiers, free-form messages, or raw log records.
public struct FirstTrackTrace: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case sample, epoch, probeStarted, probeCompleted, display, alignment
    }
    public enum State: String, Codable, Sendable { case playing, paused, stopped, unavailable }
    public enum Disposition: String, Codable, Sendable { case used, retainedPrevious, discarded }
    public enum ProbeOutcome: String, Codable, Sendable { case selected, noSelection, failed, discarded }
    public enum DepthSource: String, Codable, Sendable { case qualifiedLocal, panel, correlation }
    public enum Alignment: String, Codable, Sendable {
        case idle, unavailable, unknown, unsupportedRoute, monitorOnly, unsupportedRate
        case unavailableReadback, off, aligning, aligned, failed, drift
    }

    public struct Event: Codable, Sendable {
        public var kind: Kind
        public var atMilliseconds: Int
        public var playbackGeneration: Int
        public var routeGeneration: Int
        public var collectionStartMilliseconds: Int?
        public var availableAtMilliseconds: Int?
        public var state: State?
        public var disposition: Disposition?
        public var reportedRateHz: Int?
        public var trackChanged: Bool?
        public var processChanged: Bool?
        public var attempt: Int?
        public var probeOutcome: ProbeOutcome?
        public var parsedEventCount: Int?
        public var eligibleEventCount: Int?
        public var selectedLogWallOffsetMilliseconds: Int?
        public var depth: Int?
        public var depthSource: DepthSource?
        public var alignmentState: Alignment?
        public var targetRateHz: Int?

        public init(
            kind: Kind, atMilliseconds: Int, playbackGeneration: Int, routeGeneration: Int,
            collectionStartMilliseconds: Int? = nil, availableAtMilliseconds: Int? = nil, state: State? = nil,
            disposition: Disposition? = nil, reportedRateHz: Int? = nil,
            trackChanged: Bool? = nil, processChanged: Bool? = nil,
            attempt: Int? = nil, probeOutcome: ProbeOutcome? = nil,
            parsedEventCount: Int? = nil, eligibleEventCount: Int? = nil,
            selectedLogWallOffsetMilliseconds: Int? = nil, depth: Int? = nil, depthSource: DepthSource? = nil,
            alignmentState: Alignment? = nil, targetRateHz: Int? = nil
        ) {
            self.kind = kind
            self.atMilliseconds = atMilliseconds
            self.playbackGeneration = playbackGeneration
            self.routeGeneration = routeGeneration
            self.collectionStartMilliseconds = collectionStartMilliseconds
            self.availableAtMilliseconds = availableAtMilliseconds
            self.state = state
            self.disposition = disposition
            self.reportedRateHz = reportedRateHz
            self.trackChanged = trackChanged
            self.processChanged = processChanged
            self.attempt = attempt
            self.probeOutcome = probeOutcome
            self.parsedEventCount = parsedEventCount
            self.eligibleEventCount = eligibleEventCount
            self.selectedLogWallOffsetMilliseconds = selectedLogWallOffsetMilliseconds
            self.depth = depth
            self.depthSource = depthSource
            self.alignmentState = alignmentState
            self.targetRateHz = targetRateHz
        }

        var isUsedPlayingSample: Bool { kind == .sample && state == .playing && disposition == .used }
    }

    public var schemaVersion = 2
    public var clockBasis = "processUptimeRelativeToFirstRetainedEvent"
    public var sessionBoundary = "captureStartNotListeningSession"
    public var endedAtMilliseconds: Int
    public var bounded: Bool
    /// Observations older than the retained pre-roll were dropped before the first accepted playing sample.
    public var preRollTruncated: Bool
    public var events: [Event]

    public static let maximumEvents = 512
    public static let maximumDurationMilliseconds = 120_000
    public static let maximumBytes = 256 * 1_024

    public enum TraceError: Error { case invalidTrace, oversized }

    public func validated() throws -> FirstTrackTrace {
        guard schemaVersion == 2, clockBasis == "processUptimeRelativeToFirstRetainedEvent",
              sessionBoundary == "captureStartNotListeningSession",
              (0...Self.maximumDurationMilliseconds).contains(endedAtMilliseconds),
              events.count <= Self.maximumEvents else { throw TraceError.invalidTrace }
        var previous = 0
        for event in events {
            guard event.atMilliseconds >= previous, event.atMilliseconds <= endedAtMilliseconds,
                  (0...1_000_000).contains(event.playbackGeneration),
                  (0...1_000_000).contains(event.routeGeneration),
                  event.collectionStartMilliseconds.map({ (0...event.atMilliseconds).contains($0) }) ?? true,
                  event.availableAtMilliseconds.map({
                      ((event.collectionStartMilliseconds ?? 0)...event.atMilliseconds).contains($0)
                  }) ?? true,
                  event.reportedRateHz.map({ (1...768_000).contains($0) }) ?? true,
                  event.targetRateHz.map({ (1...768_000).contains($0) }) ?? true,
                  event.depth.map({ (1...32).contains($0) }) ?? true,
                  event.attempt.map({ (1...MusicLogProbeTiming.maximumAttempts).contains($0) }) ?? true,
                  event.parsedEventCount.map({ (0...1_000_000).contains($0) }) ?? true,
                  event.eligibleEventCount.map({ (0...(event.parsedEventCount ?? 0)).contains($0) }) ?? true,
                  event.selectedLogWallOffsetMilliseconds.map({ (-1_000_000_000...1_000_000_000).contains($0) }) ?? true
            else { throw TraceError.invalidTrace }
            switch event.kind {
            case .sample:
                guard event.state != nil, event.disposition != nil, event.collectionStartMilliseconds != nil,
                      event.availableAtMilliseconds != nil, event.trackChanged != nil,
                      event.processChanged != nil else { throw TraceError.invalidTrace }
            case .probeStarted:
                guard event.attempt != nil else { throw TraceError.invalidTrace }
            case .probeCompleted:
                guard let outcome = event.probeOutcome, event.attempt != nil else { throw TraceError.invalidTrace }
                if outcome == .selected || outcome == .noSelection {
                    guard event.parsedEventCount != nil, event.eligibleEventCount != nil else {
                        throw TraceError.invalidTrace
                    }
                }
                if outcome == .selected {
                    guard event.eligibleEventCount! > 0, [16, 24].contains(event.depth ?? 0),
                          event.selectedLogWallOffsetMilliseconds != nil else { throw TraceError.invalidTrace }
                } else {
                    guard event.depth == nil, event.selectedLogWallOffsetMilliseconds == nil else {
                        throw TraceError.invalidTrace
                    }
                }
                if outcome == .failed || outcome == .discarded {
                    guard event.parsedEventCount == nil, event.eligibleEventCount == nil else {
                        throw TraceError.invalidTrace
                    }
                }
            case .display:
                guard (event.depth == nil) == (event.depthSource == nil) else { throw TraceError.invalidTrace }
            case .alignment:
                guard event.alignmentState != nil else { throw TraceError.invalidTrace }
            case .epoch: break
            }
            // Reject cross-kind fields, rather than allowing fabricated facts into replay.
            let allowed: Set<String> = switch event.kind {
            case .sample:
                ["collectionStartMilliseconds", "availableAtMilliseconds", "state", "disposition",
                 "reportedRateHz", "trackChanged", "processChanged"]
            case .epoch: []
            case .probeStarted: ["attempt"]
            case .probeCompleted:
                ["attempt", "probeOutcome", "parsedEventCount", "eligibleEventCount",
                 "selectedLogWallOffsetMilliseconds", "depth"]
            case .display: ["depth", "depthSource"]
            case .alignment: ["alignmentState", "targetRateHz"]
            }
            let data = try JSONEncoder().encode(event)
            let keys = Set((try JSONSerialization.jsonObject(with: data) as! [String: Any]).keys)
            guard keys.subtracting(["kind", "atMilliseconds", "playbackGeneration", "routeGeneration"])
                .isSubset(of: allowed) else { throw TraceError.invalidTrace }
            previous = event.atMilliseconds
        }
        return self
    }

    public func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw TraceError.oversized }
        return data
    }

    public static func decode(_ data: Data) throws -> FirstTrackTrace {
        guard data.count <= maximumBytes else { throw TraceError.oversized }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }

    /// Explicit offline input only. Bound the read even if the file grows.
    public static func read(from url: URL) throws -> FirstTrackTrace {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw TraceError.invalidTrace }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try decode(data)
    }
}

/// Keeps a short pre-roll until the first accepted playing sample, then a bounded prefix from there.
/// Idle time before playback therefore cannot exhaust the capture.
public final class FirstTrackTraceRecorder {
    public static let preRollEvents = 64
    public static let preRollMilliseconds = 30_000

    private let startedAt: TimeInterval
    private let wallStart: Date
    private var events: [FirstTrackTrace.Event] = []
    private var truncated = false
    private var base: Int?
    private var frozenAt: Int?

    public init(startedAt: TimeInterval, wallStart: Date) {
        self.startedAt = startedAt
        self.wallStart = wallStart
    }

    /// Unrebased milliseconds since capture start; `snapshot` rebases to the first retained event.
    public func milliseconds(at: TimeInterval) -> Int {
        let value = (at - startedAt) * 1_000
        guard value.isFinite else { return 1_000_000_000_000_000 }
        return Int(max(0, min(1e15, value)).rounded())
    }

    public func logWallOffset(_ date: Date) -> Int {
        let value = date.timeIntervalSince(wallStart) * 1_000
        guard value.isFinite else { return 0 }
        return Int(max(-1e15, min(1e15, value)).rounded())
    }

    private static func origin(_ events: [FirstTrackTrace.Event]) -> Int {
        events.map { $0.collectionStartMilliseconds ?? $0.atMilliseconds }.min() ?? 0
    }

    public func append(_ event: FirstTrackTrace.Event) {
        guard frozenAt == nil else { return }
        guard let base else {
            events.append(event)
            let floor = event.atMilliseconds - Self.preRollMilliseconds
            let stale = events.firstIndex { $0.atMilliseconds >= floor } ?? 0
            let excess = max(stale, events.count - Self.preRollEvents)
            if excess > 0 {
                events.removeFirst(excess)
                truncated = true
            }
            if event.isUsedPlayingSample { self.base = Self.origin(events) }
            return
        }
        guard events.count < FirstTrackTrace.maximumEvents,
              event.atMilliseconds - base <= FirstTrackTrace.maximumDurationMilliseconds else {
            frozenAt = min(event.atMilliseconds, base + FirstTrackTrace.maximumDurationMilliseconds)
            return
        }
        events.append(event)
    }

    public func snapshot(at: TimeInterval) -> FirstTrackTrace {
        let origin = base ?? Self.origin(events)
        let elapsed = (frozenAt ?? milliseconds(at: at)) - origin
        let rebased = events.map { event in
            var event = event
            event.atMilliseconds -= origin
            event.collectionStartMilliseconds = event.collectionStartMilliseconds.map { $0 - origin }
            event.availableAtMilliseconds = event.availableAtMilliseconds.map { $0 - origin }
            event.selectedLogWallOffsetMilliseconds = event.selectedLogWallOffsetMilliseconds.map {
                max(-1_000_000_000, min(1_000_000_000, $0 - origin))
            }
            return event
        }
        let limit = FirstTrackTrace.maximumDurationMilliseconds
        return FirstTrackTrace(
            endedAtMilliseconds: events.isEmpty ? 0 : max(rebased.last!.atMilliseconds, min(max(0, elapsed), limit)),
            bounded: frozenAt != nil || elapsed > limit, preRollTruncated: truncated, events: rebased
        )
    }
}

public struct FirstTrackAssessment: Encodable {
    public enum Outcome: String, Encodable {
        case observedByDeadline, observedAfterDeadline, notObservedByDeadline, inconclusive
    }
    public struct Finding: Encodable {
        public let fact: String
        public let eventIndices: [Int]
    }
    /// A label the trace is consistent with, chosen by a fixed decision order. Never a proven root cause.
    public enum Mechanism: String, Encodable, CaseIterable, Sendable {
        case insufficientTrace, deviceAlignmentFailed, noDelay, observationStalled, musicRateReportedLate
        case logQueryFailed, logEvidenceLate, logEvidenceAmbiguous, noMatchingLogEvidence
    }
    public let diagnosticVersion = 2
    public let deadlineMilliseconds: Int
    public let firstPlayingEventIndex: Int?
    /// Unobserved interval before the first accepted playing sample; playback may have begun anywhere in it.
    public let boundaryUncertaintyMilliseconds: Int?
    public let rate: Outcome
    public let rateDelayMilliseconds: Int?
    public let displayedDepth: Outcome
    public let displayedDepthDelayMilliseconds: Int?
    public let deviceAligned: Outcome
    public let deviceAlignedDelayMilliseconds: Int?
    public let findings: [Finding]
    public let ruleHypothesis: Mechanism
    public let timeline: [String]?

    private enum CodingKeys: String, CodingKey {
        case diagnosticVersion, deadlineMilliseconds, firstPlayingEventIndex, boundaryUncertaintyMilliseconds
        case rate, rateDelayMilliseconds, displayedDepth, displayedDepthDelayMilliseconds
        case deviceAligned, deviceAlignedDelayMilliseconds, findings, ruleHypothesis, timeline
        case rootCause, independentPlaybackBoundary, logVisibilityTime
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(diagnosticVersion, forKey: .diagnosticVersion)
        try container.encode(deadlineMilliseconds, forKey: .deadlineMilliseconds)
        try container.encode(firstPlayingEventIndex, forKey: .firstPlayingEventIndex)
        try container.encode(boundaryUncertaintyMilliseconds, forKey: .boundaryUncertaintyMilliseconds)
        try container.encode(rate, forKey: .rate)
        try container.encode(rateDelayMilliseconds, forKey: .rateDelayMilliseconds)
        try container.encode(displayedDepth, forKey: .displayedDepth)
        try container.encode(displayedDepthDelayMilliseconds, forKey: .displayedDepthDelayMilliseconds)
        try container.encode(deviceAligned, forKey: .deviceAligned)
        try container.encode(deviceAlignedDelayMilliseconds, forKey: .deviceAlignedDelayMilliseconds)
        try container.encode(findings, forKey: .findings)
        try container.encode(ruleHypothesis, forKey: .ruleHypothesis)
        try container.encodeIfPresent(timeline, forKey: .timeline)
        // Version 2 never asserts these; explicit nulls keep the unknowns visible.
        try container.encodeNil(forKey: .rootCause)
        try container.encodeNil(forKey: .independentPlaybackBoundary)
        try container.encodeNil(forKey: .logVisibilityTime)
    }

    public static func assess(
        _ input: FirstTrackTrace, deadlineMilliseconds: Int = 10_000, includeTimeline: Bool = false
    ) throws -> Self {
        let trace = try input.validated()
        guard (1...FirstTrackTrace.maximumDurationMilliseconds).contains(deadlineMilliseconds) else {
            throw FirstTrackTrace.TraceError.invalidTrace
        }
        let events = trace.events
        let timeline = includeTimeline ? FirstTrackTimeline.rows(trace) : nil
        guard let first = events.firstIndex(where: \.isUsedPlayingSample) else {
            let failures = events.indices.filter { events[$0].kind == .sample && events[$0].state == .unavailable }
            return Self(deadlineMilliseconds: deadlineMilliseconds, firstPlayingEventIndex: nil,
                        boundaryUncertaintyMilliseconds: nil, rate: .inconclusive, rateDelayMilliseconds: nil,
                        displayedDepth: .inconclusive, displayedDepthDelayMilliseconds: nil,
                        deviceAligned: .inconclusive, deviceAlignedDelayMilliseconds: nil,
                        findings: failures.isEmpty ? [] : [Finding(fact: "sampleUnavailable", eventIndices: failures)],
                        ruleHypothesis: .insufficientTrace, timeline: timeline)
        }
        let boundary = events[first].atMilliseconds
        let end = events.indices.dropFirst(first + 1).first {
            let event = events[$0]
            return event.kind == .sample && event.disposition == .used
                && (event.trackChanged == true || event.processChanged == true || event.state != .playing)
        } ?? events.count
        let window = Array(first..<end)
        let deadlineAt = boundary + deadlineMilliseconds
        func currentGeneration(_ index: Int) -> Bool {
            guard let sample = window.last(where: {
                $0 <= index && events[$0].kind == .sample && events[$0].disposition == .used
            }) else { return false }
            return events[index].playbackGeneration == events[sample].playbackGeneration
                && events[index].routeGeneration == events[sample].routeGeneration
        }
        let rateIndex = window.first { events[$0].isUsedPlayingSample && events[$0].reportedRateHz != nil }
        let depthIndex = window.first {
            events[$0].kind == .display && events[$0].depth != nil && currentGeneration($0)
        }
        let alignedIndex = window.first {
            events[$0].kind == .alignment && events[$0].alignmentState == .aligned && currentGeneration($0)
        }
        // The capture is a contiguous prefix, so a capped trace still proves absence up to its last event.
        let covered = window.contains {
            events[$0].atMilliseconds >= deadlineAt
                && (events[$0].kind == .display || (events[$0].kind == .sample && events[$0].disposition == .used))
        }
        func outcome(_ index: Int?) -> (Outcome, Int?) {
            guard let index else { return (covered ? .notObservedByDeadline : .inconclusive, nil) }
            let delay = events[index].atMilliseconds - boundary
            return (delay <= deadlineMilliseconds ? .observedByDeadline : .observedAfterDeadline, delay)
        }

        var findings: [Finding] = []
        func add(_ fact: String, in range: Range<Int>, where matches: (FirstTrackTrace.Event) -> Bool) {
            let citations = range.filter { events[$0].atMilliseconds <= deadlineAt && matches(events[$0]) }
            if !citations.isEmpty { findings.append(Finding(fact: fact, eventIndices: citations)) }
        }
        let observed = first..<end
        add("playingSampleNotUsedBeforeFirst", in: 0..<first) {
            $0.kind == .sample && $0.state == .playing && $0.disposition != .used
        }
        add("sampleUnavailable", in: observed) { $0.kind == .sample && $0.state == .unavailable }
        add("previousObservationRetained", in: observed) { $0.disposition == .retainedPrevious }
        add("sampleDiscarded", in: observed) { $0.kind == .sample && $0.disposition == .discarded }
        add("playingWithoutReportedRate", in: observed) { $0.isUsedPlayingSample && $0.reportedRateHz == nil }
        add("collectionToMainCallbackOverOneSecond", in: observed) {
            $0.kind == .sample && ($0.availableAtMilliseconds ?? 0) - ($0.collectionStartMilliseconds ?? 0) > 1_000
        }
        let samples = (0..<end).filter { events[$0].kind == .sample }
        func gapBefore(_ position: Int) -> Int? {
            guard position > 0 else { return nil }
            return (events[samples[position]].collectionStartMilliseconds ?? 0)
                - (events[samples[position - 1]].availableAtMilliseconds ?? 0)
        }
        // Normal polling waits up to one second while idle; only longer gaps are reported.
        let gaps = samples.indices.filter {
            samples[$0] > first && events[samples[$0]].atMilliseconds <= deadlineAt
                && (gapBefore($0) ?? 0) > FirstTrackTimeline.gapMilliseconds
        }.map { samples[$0] }
        if !gaps.isEmpty { findings.append(Finding(fact: "observationGapOverTwoSecondsBeforeSample", eventIndices: gaps)) }
        add("logProbeFailed", in: observed) { $0.probeOutcome == .failed }
        add("logProbeDiscarded", in: observed) { $0.probeOutcome == .discarded }
        add("noParsedFormatEvents", in: observed) { $0.probeOutcome == .noSelection && $0.parsedEventCount == 0 }
        add("noEligibleDecoderEvents", in: observed) {
            $0.probeOutcome == .noSelection && ($0.parsedEventCount ?? 0) > 0 && $0.eligibleEventCount == 0
        }
        add("selectorWithheldAmongEligibleEvents", in: observed) {
            $0.probeOutcome == .noSelection && ($0.eligibleEventCount ?? 0) > 0
        }
        add("unverifiedDecoderSelected", in: observed) { $0.probeOutcome == .selected }
        add("alignmentFailed", in: observed) { $0.kind == .alignment && $0.alignmentState == .failed }
        add("generationChanged", in: (first + 1)..<end) { $0.kind == .epoch }

        let (rate, rateDelay) = outcome(rateIndex)
        let (depth, depthDelay) = outcome(depthIndex)
        let (aligned, alignedDelay) = outcome(alignedIndex)
        // The whole first-track window is used, so this label is retrospective like the late outcomes.
        func any(_ matches: (FirstTrackTrace.Event) -> Bool) -> Bool { window.contains { matches(events[$0]) } }
        let stalled = samples.indices.contains {
            let event = events[samples[$0]]
            return samples[$0] >= first
                && ((event.availableAtMilliseconds ?? 0) - (event.collectionStartMilliseconds ?? 0) > 1_000
                    || (gapBefore($0) ?? 0) > FirstTrackTimeline.gapMilliseconds)
        }
        let hypothesis: Mechanism = if depth == .inconclusive {
            .insufficientTrace
        } else if any({ $0.kind == .alignment && $0.alignmentState == .failed }) {
            .deviceAlignmentFailed
        } else if depth == .observedByDeadline {
            .noDelay
        } else if stalled {
            .observationStalled
        } else if rate != .observedByDeadline,
                  any({ $0.kind == .sample && $0.state == .playing && $0.reportedRateHz == nil }) {
            // Music often omits the rate for the first second or two; that alone is not the delay.
            .musicRateReportedLate
        } else if any({ $0.probeOutcome == .failed }) {
            .logQueryFailed
        } else if depth == .observedAfterDeadline {
            .logEvidenceLate
        } else if any({ $0.probeOutcome == .noSelection && ($0.eligibleEventCount ?? 0) > 0 }) {
            .logEvidenceAmbiguous
        } else {
            .noMatchingLogEvidence
        }
        return Self(deadlineMilliseconds: deadlineMilliseconds, firstPlayingEventIndex: first,
                    boundaryUncertaintyMilliseconds: samples.firstIndex(of: first).flatMap(gapBefore).map { max(0, $0) },
                    rate: rate, rateDelayMilliseconds: rateDelay,
                    displayedDepth: depth, displayedDepthDelayMilliseconds: depthDelay,
                    deviceAligned: aligned, deviceAlignedDelayMilliseconds: alignedDelay,
                    findings: findings, ruleHypothesis: hypothesis, timeline: timeline)
    }
}

/// Compact, typed rendering of a validated trace. Rows contain only enumerated words and integers.
public enum FirstTrackTimeline {
    public static let gapMilliseconds = 2_000
    public static let maximumRows = 120

    public static func rows(_ trace: FirstTrackTrace) -> [String] {
        let events = trace.events
        let first = events.firstIndex(where: \.isUsedPlayingSample)
        let zero = first.map { events[$0].atMilliseconds } ?? 0
        func time(_ milliseconds: Int) -> String {
            let value = milliseconds - zero
            return (value < 0 ? "" : "+") + "\(value)ms"
        }
        func generations(_ event: FirstTrackTrace.Event) -> String {
            "\(event.playbackGeneration)/\(event.routeGeneration)"
        }
        var rows: [String] = []
        // Runs break on a generation change, which its own row already reports.
        var run: (start: Int, end: Int, count: Int, key: String, text: String)?
        func flush() {
            guard let current = run else { return }
            run = nil
            rows.append(current.count == 1
                ? "#\(current.start) \(time(events[current.start].atMilliseconds)) sample \(current.text)"
                : "#\(current.start)-#\(current.end) \(time(events[current.start].atMilliseconds))..\(time(events[current.end].atMilliseconds)) \(current.count) samples \(current.text)")
        }
        var previousSample: Int?
        var previousDisplay: String?
        for (index, event) in events.enumerated() {
            switch event.kind {
            case .sample:
                var text = "\(event.state!.rawValue) rate=\(event.reportedRateHz.map(String.init) ?? "none") \(event.disposition!.rawValue)"
                if event.trackChanged == true { text += " trackChanged" }
                if event.processChanged == true { text += " processChanged" }
                let key = "\(text) \(generations(event))"
                var notes: [String] = []
                if index == first { notes.append("firstAcceptedPlayingSample") }
                let collection = (event.availableAtMilliseconds ?? 0) - (event.collectionStartMilliseconds ?? 0)
                if collection > 1_000 { notes.append("collectionTook=\(collection)ms") }
                if let previousSample {
                    let gap = (event.collectionStartMilliseconds ?? 0)
                        - (events[previousSample].availableAtMilliseconds ?? 0)
                    if gap > gapMilliseconds { notes.append("gapBefore=\(gap)ms") }
                }
                previousSample = index
                if notes.isEmpty, let current = run, current.key == key {
                    run = (current.start, index, current.count + 1, key, text)
                } else {
                    flush()
                    if notes.isEmpty {
                        run = (index, index, 1, key, text)
                    } else {
                        rows.append("#\(index) \(time(event.atMilliseconds)) sample \(text) \(notes.joined(separator: " "))")
                    }
                }
                continue
            case .display:
                let value = "display depth=\(event.depth.map(String.init) ?? "none")"
                    + (event.depthSource.map { " source=\($0.rawValue)" } ?? "")
                let key = "\(value) \(generations(event))"
                if key == previousDisplay { continue }
                previousDisplay = key
                flush()
                rows.append("#\(index) \(time(event.atMilliseconds)) \(value)")
            case .epoch:
                flush()
                rows.append("#\(index) \(time(event.atMilliseconds)) generationChanged playback/route=\(generations(event))")
            case .probeStarted:
                flush()
                rows.append("#\(index) \(time(event.atMilliseconds)) logProbe \(event.attempt!) started")
            case .probeCompleted:
                flush()
                var row = "#\(index) \(time(event.atMilliseconds)) logProbe \(event.attempt!) \(event.probeOutcome!.rawValue)"
                if let parsed = event.parsedEventCount, let eligible = event.eligibleEventCount {
                    row += " parsed=\(parsed) eligible=\(eligible)"
                }
                if let depth = event.depth { row += " depth=\(depth)" }
                // The record's own log timestamp; wall-clock derived, so approximate against these times.
                if let logged = event.selectedLogWallOffsetMilliseconds { row += " recordLogged=\(time(logged))" }
                rows.append(row)
            case .alignment:
                flush()
                rows.append("#\(index) \(time(event.atMilliseconds)) alignment \(event.alignmentState!.rawValue)"
                    + " target=\(event.targetRateHz.map(String.init) ?? "none")")
            }
        }
        flush()
        rows.append("captureEnded \(time(trace.endedAtMilliseconds))"
            + (trace.bounded ? " capReached" : "") + (trace.preRollTruncated ? " earlierObservationsDropped" : ""))
        if rows.count > maximumRows {
            let omitted = rows.count - maximumRows
            rows = Array(rows.prefix(maximumRows - 1)) + ["rowsOmitted=\(omitted) \(rows.last!)"]
        }
        return rows
    }
}
