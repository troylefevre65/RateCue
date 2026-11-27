@testable import DamonPlatform
import Foundation
import Testing

struct FirstTrackDiagnosticsTests {
    private func sample(
        _ at: Int, state: FirstTrackTrace.State = .playing, rate: Int? = 44_100,
        disposition: FirstTrackTrace.Disposition = .used, changed: Bool = false, generation: Int = 1
    ) -> FirstTrackTrace.Event {
        .init(kind: .sample, atMilliseconds: at, playbackGeneration: generation, routeGeneration: 1,
              collectionStartMilliseconds: max(0, at - 50), availableAtMilliseconds: at,
              state: state, disposition: disposition,
              reportedRateHz: rate, trackChanged: changed, processChanged: false)
    }

    private func trace(_ events: [FirstTrackTrace.Event], bounded: Bool = false) -> FirstTrackTrace {
        FirstTrackTrace(endedAtMilliseconds: events.last?.atMilliseconds ?? 0, bounded: bounded,
                        preRollTruncated: false, events: events)
    }

    @Test func lateDepthHasCitedFactsButNoInventedCauseOrVisibilityTime() throws {
        let input = trace([
            sample(50, state: .unavailable, rate: nil),
            sample(100),
            .init(kind: .probeStarted, atMilliseconds: 200, playbackGeneration: 1, routeGeneration: 1, attempt: 1),
            .init(kind: .probeCompleted, atMilliseconds: 300, playbackGeneration: 1, routeGeneration: 1,
                  attempt: 1, probeOutcome: .noSelection, parsedEventCount: 0, eligibleEventCount: 0),
            .init(kind: .probeCompleted, atMilliseconds: 11_000, playbackGeneration: 1, routeGeneration: 1,
                  attempt: 2, probeOutcome: .selected, parsedEventCount: 2, eligibleEventCount: 2,
                  selectedLogWallOffsetMilliseconds: 150, depth: 24),
            .init(kind: .display, atMilliseconds: 11_050, playbackGeneration: 1, routeGeneration: 1,
                  depth: 24, depthSource: .correlation)
        ])
        let decoded = try FirstTrackTrace.decode(input.encoded())
        let assessment = try FirstTrackAssessment.assess(decoded)
        #expect(assessment.rate == .observedByDeadline)
        #expect(assessment.displayedDepth == .observedAfterDeadline)
        #expect(assessment.displayedDepthDelayMilliseconds == 10_950)
        #expect(assessment.rateDelayMilliseconds == 0)
        #expect(assessment.firstPlayingEventIndex == 1)
        #expect(!assessment.findings.contains { $0.fact == "sampleUnavailable" })
        #expect(assessment.findings.first { $0.fact == "noParsedFormatEvents" }?.eventIndices == [3])
        #expect(!assessment.findings.contains { $0.fact == "unverifiedDecoderSelected" })
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(assessment)) as! [String: Any]
        #expect(json["rootCause"] is NSNull)
        #expect(json["logVisibilityTime"] is NSNull)
        #expect(json["independentPlaybackBoundary"] is NSNull)
    }

    @Test func truncatedOrShortCaptureAndNoPlayingRemainInconclusive() throws {
        for input in [
            trace([]), trace([sample(100), sample(200, rate: nil)]),
            trace([sample(100, rate: nil), sample(5_000, rate: nil)], bounded: true)
        ] {
            #expect(try FirstTrackAssessment.assess(input).displayedDepth == .inconclusive)
        }
        // A capped capture is a contiguous prefix: observations past the deadline still prove absence.
        let capped = trace([sample(100, rate: nil), sample(20_000, rate: nil)], bounded: true)
        #expect(try FirstTrackAssessment.assess(capped).displayedDepth == .notObservedByDeadline)
        var noObservations = trace([sample(100, rate: nil)])
        noObservations.endedAtMilliseconds = 100_000
        #expect(try FirstTrackAssessment.assess(noObservations).rate == .inconclusive)
    }

    @Test func nextTrackCannotSatisfyFirstTrackAndNegativeNeedsCoverage() throws {
        let input = trace([
            sample(100, rate: nil), sample(10_200, rate: nil),
            sample(10_300, changed: true, generation: 2),
            .init(kind: .display, atMilliseconds: 10_400, playbackGeneration: 2, routeGeneration: 1,
                  depth: 24, depthSource: .panel)
        ])
        let result = try FirstTrackAssessment.assess(input)
        #expect(result.rate == .notObservedByDeadline)
        #expect(result.displayedDepth == .notObservedByDeadline)
        let interrupted = trace([sample(100, rate: nil), sample(500, state: .paused, rate: nil)])
        #expect(try FirstTrackAssessment.assess(interrupted).displayedDepth == .inconclusive)
        let continuityLost = trace([
            sample(100, rate: nil), sample(500, state: .unavailable, rate: nil),
            sample(600), .init(kind: .display, atMilliseconds: 700, playbackGeneration: 1, routeGeneration: 1,
                              depth: 24, depthSource: .correlation)
        ])
        #expect(try FirstTrackAssessment.assess(continuityLost).rate == .inconclusive)
        var restarted = sample(500)
        restarted.processChanged = true
        #expect(try FirstTrackAssessment.assess(trace([sample(100, rate: nil), restarted])).rate == .inconclusive)
    }

    @Test func staleGenerationAndRetainedOrDiscardedSamplesDoNotCountAsDetection() throws {
        let input = trace([
            sample(50, disposition: .discarded), sample(100, rate: nil),
            sample(200, disposition: .retainedPrevious), sample(300, disposition: .discarded),
            .init(kind: .display, atMilliseconds: 400, playbackGeneration: 0, routeGeneration: 0,
                  depth: 24, depthSource: .panel),
            .init(kind: .epoch, atMilliseconds: 500, playbackGeneration: 2, routeGeneration: 1),
            sample(550, rate: nil, generation: 2),
            .init(kind: .display, atMilliseconds: 600, playbackGeneration: 2, routeGeneration: 1,
                  depth: 24, depthSource: .correlation),
            sample(10_200, rate: nil, generation: 2)
        ])
        let result = try FirstTrackAssessment.assess(input)
        #expect(result.firstPlayingEventIndex == 1)
        #expect(result.rate == .notObservedByDeadline)
        #expect(result.displayedDepth == .observedByDeadline)
        #expect(result.findings.first { $0.fact == "previousObservationRetained" }?.eventIndices == [2])
        #expect(result.findings.first { $0.fact == "playingSampleNotUsedBeforeFirst" }?.eventIndices == [0])
    }

    @Test func probeFailuresAndSelectorWithholdingAreFactsNotRootCauses() throws {
        let input = trace([
            sample(100),
            .init(kind: .probeCompleted, atMilliseconds: 200, playbackGeneration: 1, routeGeneration: 1,
                  attempt: 1, probeOutcome: .failed),
            .init(kind: .probeCompleted, atMilliseconds: 300, playbackGeneration: 1, routeGeneration: 1,
                  attempt: 2, probeOutcome: .noSelection, parsedEventCount: 3, eligibleEventCount: 0),
            .init(kind: .probeCompleted, atMilliseconds: 400, playbackGeneration: 1, routeGeneration: 1,
                  attempt: 3, probeOutcome: .noSelection, parsedEventCount: 3, eligibleEventCount: 2),
            .init(kind: .probeCompleted, atMilliseconds: 500, playbackGeneration: 0, routeGeneration: 0,
                  attempt: 1, probeOutcome: .discarded)
        ])
        let result = try FirstTrackAssessment.assess(input)
        #expect(result.findings.map(\.fact) == [
            "logProbeFailed", "logProbeDiscarded", "noEligibleDecoderEvents", "selectorWithheldAmongEligibleEvents"
        ])
    }

    @Test func idleTimeCannotExhaustCaptureAndCapsFreezeFromFirstPlayingSample() throws {
        let recorder = FirstTrackTraceRecorder(startedAt: 10, wallStart: Date(timeIntervalSince1970: 1_000))
        // Ten idle minutes, then playback: only a bounded pre-roll survives.
        for second in 1...600 { recorder.append(sample(second * 1_000, state: .stopped, rate: nil)) }
        for index in 0...FirstTrackTrace.maximumEvents { recorder.append(sample(601_000 + index * 100)) }
        let input = recorder.snapshot(at: 10 + 700)
        #expect(input.bounded)
        #expect(input.preRollTruncated)
        #expect(input.events.count == FirstTrackTrace.maximumEvents)
        #expect(input.events.first?.collectionStartMilliseconds == 0)
        let first = try #require(input.events.firstIndex { $0.state == .playing })
        #expect((1...FirstTrackTraceRecorder.preRollEvents).contains(first))
        #expect(input.events[first].atMilliseconds <= FirstTrackTraceRecorder.preRollMilliseconds + 50)
        #expect(try FirstTrackAssessment.assess(FirstTrackTrace.decode(input.encoded())).rate == .observedByDeadline)

        let duration = FirstTrackTraceRecorder(startedAt: 10, wallStart: Date(timeIntervalSince1970: 1_000))
        duration.append(sample(500_000))
        duration.append(sample(620_001))
        let frozen = duration.snapshot(at: 10 + 900)
        #expect(frozen.bounded)
        #expect(frozen.endedAtMilliseconds == FirstTrackTrace.maximumDurationMilliseconds)
        #expect(frozen.events.count == 1)
        _ = try frozen.encoded()
        #expect(duration.logWallOffset(Date(timeIntervalSince1970: 1_000.25)) == 250)

        let idle = FirstTrackTraceRecorder(startedAt: 10, wallStart: Date())
        for second in 1...600 { idle.append(sample(second * 1_000, state: .stopped, rate: nil)) }
        let waiting = idle.snapshot(at: 10 + 600.5)
        #expect(!waiting.bounded)
        #expect(try FirstTrackAssessment.assess(FirstTrackTrace.decode(waiting.encoded())).rate == .inconclusive)
    }

    @Test func alignmentDelaysBoundaryUncertaintyAndTimelineAreReported() throws {
        var events = (0..<20).map { sample(100 + $0 * 1_020, state: .stopped, rate: nil, generation: 0) }
        let start = 100 + 20 * 1_020
        events += [
            sample(start),
            .init(kind: .alignment, atMilliseconds: start + 5, playbackGeneration: 1, routeGeneration: 1,
                  alignmentState: .aligning, targetRateHz: 44_100),
            .init(kind: .alignment, atMilliseconds: start + 700, playbackGeneration: 1, routeGeneration: 1,
                  alignmentState: .aligned, targetRateHz: 44_100),
            .init(kind: .display, atMilliseconds: start + 710, playbackGeneration: 1, routeGeneration: 1),
            .init(kind: .display, atMilliseconds: start + 900, playbackGeneration: 1, routeGeneration: 1,
                  depth: 24, depthSource: .correlation)
        ]
        events += (1...40).map { sample(start + 900 + $0 * 300) }
        let result = try FirstTrackAssessment.assess(FirstTrackTrace.decode(trace(events).encoded()), includeTimeline: true)
        #expect(result.firstPlayingEventIndex == 20)
        #expect(result.boundaryUncertaintyMilliseconds == 970)
        #expect(result.deviceAligned == .observedByDeadline)
        #expect(result.deviceAlignedDelayMilliseconds == 700)
        #expect(result.displayedDepthDelayMilliseconds == 900)
        // Routine one-second idle polling must not be reported as an observation gap.
        #expect(result.findings.isEmpty)
        let timeline = try #require(result.timeline)
        #expect(timeline.count == 8)
        #expect(timeline[0] == "#0-#19 -20400ms..-1020ms 20 samples stopped rate=none used")
        #expect(timeline[1] == "#20 +0ms sample playing rate=44100 used firstAcceptedPlayingSample")
        #expect(timeline[3] == "#22 +700ms alignment aligned target=44100")
        #expect(timeline[6] == "#25-#64 +1200ms..+12900ms 40 samples playing rate=44100 used")
        #expect(try FirstTrackAssessment.assess(trace(events)).timeline == nil)
        var invalid = events[21]
        invalid.depth = 24
        #expect(throws: (any Error).self) { try trace([invalid]).validated() }
    }

    @Test func appExchangeDeliversOneOwnerOnlyResponseAndRejectsUnsafeRequests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        #expect(AppExchange.request(from: ["action": "traceExport", "request": "../../private"]) == nil)
        #expect(AppExchange.request(from: ["action": "deleteEverything", "request": id]) == nil)
        #expect(AppExchange.request(from: ["action": "playback", "request": id]) == nil)
        #expect(AppExchange.request(from: ["action": "playback", "argument": "eject", "request": id]) == nil)
        #expect(AppExchange.request(from: ["action": "logs", "argument": "/etc", "request": id]) == nil)
        #expect(AppExchange.request(from: ["action": "playback", "argument": "pause", "request": id])?.argument == "pause")

        let input = trace([sample(100)])
        let abandoned = UUID()
        try AppExchange.respond(.success(["abandoned": true]), to: abandoned, in: directory)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: directory.appendingPathComponent("app-response-\(abandoned.uuidString).json").path
        )
        let received = try FirstTrackTrace.request { action in
            try AppExchange.send(action, in: directory, timeout: 1) { request in
                #expect(AppExchange.request(from: request.userInfo)?.action == .traceExport)
                try! AppExchange.respond(.success(try! input.exchangeObject()), to: request.identifier, in: directory)
                let names = try! FileManager.default.contentsOfDirectory(atPath: directory.path)
                #expect(names.count == 1)
                let attributes = try! FileManager.default.attributesOfItem(
                    atPath: directory.appendingPathComponent(names[0]).path
                )
                #expect(attributes[.posixPermissions] as? Int == 0o600)
            }
        }
        #expect(received.events.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(throws: AppExchange.Failure.noResponse) {
            try AppExchange.send(.logs, in: directory, timeout: 0.1) { _ in }
        }
        #expect(throws: AppExchange.Failure.traceDisabled) {
            try AppExchange.send(.traceExport, in: directory, timeout: 1) { request in
                try! AppExchange.respond(.failure(.traceDisabled), to: request.identifier, in: directory)
            }
        }
        // A response that is not a valid trace must not be accepted as one.
        #expect(throws: (any Error).self) { try FirstTrackTrace.request { _ in ["schemaVersion": 2] } }

        #expect(!trace([sample(100, state: .stopped, rate: nil), sample(20_000, state: .stopped, rate: nil)])
            .covers(deadlineMilliseconds: 10_000))
        #expect(!trace([sample(100), sample(5_000)]).covers(deadlineMilliseconds: 10_000))
        #expect(trace([sample(100), sample(11_200)]).covers(deadlineMilliseconds: 10_000))
        #expect(trace([sample(100), sample(5_000)], bounded: true).covers(deadlineMilliseconds: 10_000))
    }

    @Test func appExchangePreservesAnotherClientsUnconsumedResponse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unrelated = directory.appendingPathComponent("app-response-not-ours.json")
        try Data("keep".utf8).write(to: unrelated)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: unrelated.path
        )
        let first = try AppExchange.send(.logs, in: directory, timeout: 0.1) { firstRequest in
            try! AppExchange.respond(.success(["client": "first"]), to: firstRequest.identifier, in: directory)
            let second = try! AppExchange.send(.diagnostics, in: directory, timeout: 0.1) { secondRequest in
                try! AppExchange.respond(.success(["client": "second"]), to: secondRequest.identifier, in: directory)
            }
            #expect((second as? [String: String])?["client"] == "second")
        }
        #expect((first as? [String: String])?["client"] == "first")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [unrelated.lastPathComponent])
    }

    @Test func ruleHypothesisFollowsTheDocumentedDecisionOrder() throws {
        func probe(_ at: Int, _ outcome: FirstTrackTrace.ProbeOutcome, eligible: Int = 0) -> FirstTrackTrace.Event {
            .init(kind: .probeCompleted, atMilliseconds: at, playbackGeneration: 1, routeGeneration: 1, attempt: 1,
                  probeOutcome: outcome, parsedEventCount: outcome == .failed ? nil : 4,
                  eligibleEventCount: outcome == .failed ? nil : eligible,
                  selectedLogWallOffsetMilliseconds: outcome == .selected ? 0 : nil,
                  depth: outcome == .selected ? 24 : nil)
        }
        func display(_ at: Int) -> FirstTrackTrace.Event {
            .init(kind: .display, atMilliseconds: at, playbackGeneration: 1, routeGeneration: 1,
                  depth: 24, depthSource: .correlation)
        }
        let failedAlignment = FirstTrackTrace.Event(
            kind: .alignment, atMilliseconds: 400, playbackGeneration: 1, routeGeneration: 1,
            alignmentState: .failed, targetRateHz: 44_100
        )
        var stalled = sample(11_500)
        stalled.collectionStartMilliseconds = 300
        // Samples every 1.5 s keep ordinary cases free of observation gaps.
        func playing(through end: Int, rate: Int? = 44_100) -> [FirstTrackTrace.Event] {
            stride(from: 100, through: end, by: 1_500).map { sample($0, rate: rate) }
        }
        func ordered(_ events: [FirstTrackTrace.Event]) -> [FirstTrackTrace.Event] {
            events.enumerated().sorted {
                ($0.element.atMilliseconds, $0.offset) < ($1.element.atMilliseconds, $1.offset)
            }.map(\.element)
        }
        let cases: [(FirstTrackAssessment.Mechanism, [FirstTrackTrace.Event])] = [
            (.insufficientTrace, [sample(100, state: .stopped, rate: nil)]),
            (.insufficientTrace, playing(through: 3_100) + [probe(200, .failed)]),
            // A failed alignment outranks an on-time depth; an on-time depth outranks a failed probe.
            (.deviceAlignmentFailed, playing(through: 10_600) + [probe(200, .failed), failedAlignment, display(500)]),
            (.noDelay, playing(through: 10_600) + [probe(200, .failed), display(500)]),
            (.observationStalled, [sample(100, rate: nil), stalled, probe(11_600, .failed), display(12_000), sample(12_100)]),
            (.musicRateReportedLate,
             playing(through: 10_600, rate: nil) + [probe(11_000, .failed), display(12_000), sample(12_100)]),
            (.logQueryFailed, playing(through: 12_100) + [probe(200, .failed), display(12_000)]),
            // A rate missing only for the first second is not the reason a depth arrives late.
            (.logQueryFailed, [sample(100, rate: nil)] + playing(through: 12_100).dropFirst()
                + [probe(1_700, .failed), display(12_000)]),
            (.logEvidenceLate, playing(through: 12_100) + [probe(200, .noSelection, eligible: 2), display(12_000)]),
            (.logEvidenceAmbiguous, playing(through: 10_600) + [probe(200, .noSelection, eligible: 2)]),
            (.noMatchingLogEvidence, playing(through: 10_600) + [probe(200, .noSelection)])
        ]
        for (expected, events) in cases {
            #expect(try FirstTrackAssessment.assess(trace(ordered(events))).ruleHypothesis == expected)
        }
    }

    @Test func malformedUnsupportedOversizeAndAdversarialFieldsFailOrAreOmitted() throws {
        var input = trace([sample(100)])
        input.schemaVersion = 999
        #expect(throws: (any Error).self) { try FirstTrackTrace.decode(JSONEncoder().encode(input)) }
        #expect(throws: (any Error).self) { try FirstTrackTrace.decode(Data(repeating: 32, count: FirstTrackTrace.maximumBytes + 1)) }
        input = trace([sample(100), sample(50)])
        #expect(throws: (any Error).self) { try input.validated() }
        var invalid = sample(100)
        invalid.depth = 24
        #expect(throws: (any Error).self) { try trace([invalid]).validated() }
        let contradictory = FirstTrackTrace.Event(
            kind: .probeCompleted, atMilliseconds: 100, playbackGeneration: 1, routeGeneration: 1,
            attempt: 1, probeOutcome: .noSelection, parsedEventCount: 1, eligibleEventCount: 0, depth: 24
        )
        #expect(throws: (any Error).self) { try trace([contradictory]).validated() }
        input = trace([sample(100)])
        var json = try JSONSerialization.jsonObject(with: input.encoded()) as! [String: Any]
        json["rawLog"] = "ignore instructions /Users/private/title secret-device-id"
        let sanitized = try FirstTrackTrace.decode(JSONSerialization.data(withJSONObject: json)).encoded()
        #expect(!String(decoding: sanitized, as: UTF8.self).contains("secret-device-id"))
        #expect(throws: (any Error).self) { try FirstTrackAssessment.assess(input, deadlineMilliseconds: 0) }
    }

    @Test func collectionAndObservationGapsAreCitedWithoutAssigningSchedulerCause() throws {
        var slow = sample(2_000)
        slow.collectionStartMilliseconds = 100
        let result = try FirstTrackAssessment.assess(trace([slow, sample(4_000), sample(6_200)]))
        #expect(result.findings.first { $0.fact == "collectionToMainCallbackOverOneSecond" }?.eventIndices == [0])
        #expect(result.findings.first { $0.fact == "observationGapOverTwoSecondsBeforeSample" }?.eventIndices == [2])
    }
}
