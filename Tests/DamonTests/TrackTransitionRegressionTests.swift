@testable import DamonPlatform
import Foundation
import Testing

/// Replays Music unified-log lifecycles and playback samples for track transitions.
/// Fixtures mirror Music's real `fpfs_StartTrackPlaying` / `fpfs_ReportAudioPlaybackThroughFigLog` lines.
struct TrackTransitionRegressionTests {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSxx"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private enum Line {
        case start(String, String)
        case report(String, String, rate: Int, depth: Int)
        case render(String, String)
    }

    private static func date(_ time: String) -> Date {
        formatter.date(from: "2026-11-25 \(time)-0700")!
    }

    private static func parse(_ lines: [Line]) throws -> [MusicLogEvidence] {
        let events: [[String: String]] = lines.map { line in
            switch line {
            case let .start(time, token):
                [
                    "timestamp": "2026-11-25 \(time)-0700",
                    "eventMessage": "<<<< FigStreamPlayer >>>> fpfs_StartTrackPlaying: [QE Critical][0x7b63acb800|P/GR]: "
                        + "<\(token)>: (58): playback switches; startTime nan desiredRate is 1.000000 rate 0.000000 "
                        + "at currentTime 0.000000 track 1"
                ]
            case let .render(time, token):
                [
                    "timestamp": "2026-11-25 \(time)-0700",
                    "eventMessage": "<<<< FigStreamPlayer >>>> fpfs_StartTrackPlaying: <\(token)> ordered rendering "
                        + "for track 4 from 0 to 0; first to display is 0 should preroll 0"
                ]
            case let .report(time, token, rate, depth):
                [
                    "timestamp": "2026-11-25 \(time)-0700",
                    "eventMessage": "<<<< FigStreamPlayer >>>> fpfs_ReportAudioPlaybackThroughFigLog: "
                        + "[QE Critical][0x7b63acb800|P/GR]: <\(token)>: [AudioFormat qlac is  decodable] "
                        + "[AudioChannels 2] [SampleRate \(rate)] [BitDepth \(depth)]"
                ]
            }
        }
        return try MusicLogEvidenceReader.parse(JSONSerialization.data(withJSONObject: events))
    }

    private static func selector(
        rate: Int, estimatedStart: String, previousRate: Int? = 44_100, trackChanged: Bool
    ) -> MusicLogLifecycleSelector {
        .forEpoch(
            reportedRate: rate, estimatedStart: date(estimatedStart),
            previousKnownRate: previousRate, trackChanged: trackChanged
        )
    }

    // Captured 2026-11-25: restart of a 24-bit track at 13:34:20, skip to a 16-bit track at 13:34:28.
    private static let restartThenSkip: [Line] = [
        .start("13:33:40.488", "0x7b648d8000|I/NJB.01"),
        .report("13:33:40.527", "0x7b648d8000|I/NJB.01", rate: 44_100, depth: 24),
        .render("13:34:20.596", "0x7b648d8000|I/NJB.01"),
        .report("13:34:20.628", "0x7b648d8000|I/NJB.01", rate: 44_100, depth: 24),
        .start("13:34:28.661", "0x7b66338000|I/SFC.01"),
        .report("13:34:28.697", "0x7b66338000|I/SFC.01", rate: 44_100, depth: 16),
        .report("13:34:28.698", "0x7b66338000|I/SFC.01", rate: 44_100, depth: 16)
    ]

    @Test func skipToNextTrackAfterRestartPublishesTheNewTrack() throws {
        let events = try Self.parse(Self.restartThenSkip)
        let skip = Self.selector(rate: 44_100, estimatedStart: "13:34:28.700", trackChanged: true)
        #expect(skip.select(from: events)?.depth == 16)
        #expect(skip.eligible(events).allSatisfy { $0.depth == 16 })
    }

    @Test func skipWithLateReportDoesNotBorrowThePreviousTracksLifecycle() throws {
        let events = try Self.parse(Array(Self.restartThenSkip.prefix(5)))
        let skip = Self.selector(rate: 44_100, estimatedStart: "13:34:28.700", trackChanged: true)
        #expect(skip.select(from: events) == nil)
    }

    @Test func restartFromZeroPublishesTheRestartedLifecycle() throws {
        let events = try Self.parse(Array(Self.restartThenSkip.prefix(4)))
        let restart = Self.selector(rate: 44_100, estimatedStart: "13:34:20.600", trackChanged: false)
        #expect(restart.select(from: events)?.depth == 24)
    }

    @Test func naturalAdvanceWithLateDecoderReportPublishes() throws {
        let events = try Self.parse([
            .start("13:40:45.488", "0x7b52d2dc00|I/TYJ.01"),
            .report("13:41:00.191", "0x7b52d2dc00|I/TYJ.01", rate: 44_100, depth: 16),
            .start("13:44:34.647", "0x7b656c0000|I/UYW.01"),
            .report("13:44:55.306", "0x7b656c0000|I/UYW.01", rate: 44_100, depth: 24)
        ])
        let advance = Self.selector(rate: 44_100, estimatedStart: "13:44:34.700", trackChanged: true)
        #expect(advance.select(from: events)?.depth == 24)
        let beforeReport = try Self.parse([
            .start("13:40:45.488", "0x7b52d2dc00|I/TYJ.01"),
            .report("13:41:00.191", "0x7b52d2dc00|I/TYJ.01", rate: 44_100, depth: 16),
            .start("13:44:34.647", "0x7b656c0000|I/UYW.01")
        ])
        #expect(advance.select(from: beforeReport) == nil)
    }

    @Test func rateChangeAllowsPrebufferedLifecycleButSameRateSkipDoesNot() throws {
        let events = try Self.parse([
            .start("13:00:00.000", "0x1|I/AAA.01"),
            .report("13:00:20.000", "0x1|I/AAA.01", rate: 96_000, depth: 24)
        ])
        let rateChange = Self.selector(
            rate: 96_000, estimatedStart: "13:00:16.000", previousRate: 44_100, trackChanged: true
        )
        #expect(rateChange.select(from: events)?.depth == 24)
        let sameRateSkip = Self.selector(
            rate: 96_000, estimatedStart: "13:00:16.000", previousRate: 96_000, trackChanged: true
        )
        #expect(sameRateSkip.select(from: events) == nil)
    }

    @Test func rapidDoubleSkipIsAmbiguousUntilOneLifecycleClearlyWins() throws {
        let events = try Self.parse([
            .start("13:10:00.000", "0x1|I/AAA.01"),
            .report("13:10:00.050", "0x1|I/AAA.01", rate: 44_100, depth: 24),
            .start("13:10:01.500", "0x2|I/BBB.01"),
            .report("13:10:01.550", "0x2|I/BBB.01", rate: 44_100, depth: 16)
        ])
        let secondSkip = Self.selector(rate: 44_100, estimatedStart: "13:10:01.600", trackChanged: true)
        #expect(secondSkip.select(from: events) == nil)
        let settled = try Self.parse([
            .start("13:10:00.000", "0x1|I/AAA.01"),
            .report("13:10:00.050", "0x1|I/AAA.01", rate: 44_100, depth: 24),
            .start("13:10:04.500", "0x2|I/BBB.01"),
            .report("13:10:04.550", "0x2|I/BBB.01", rate: 44_100, depth: 16)
        ])
        let later = Self.selector(rate: 44_100, estimatedStart: "13:10:04.600", trackChanged: true)
        #expect(later.select(from: settled)?.depth == 16)
    }

    @Test func pauseAndResumeKeepsTheOriginalLifecycle() throws {
        let events = try Self.parse([
            .start("13:20:00.000", "0x1|I/AAA.01"),
            .report("13:20:18.000", "0x1|I/AAA.01", rate: 88_200, depth: 24)
        ])
        let start = Self.date("13:20:00.000")
        var anchor = MusicPlaybackLogAnchor()
        anchor.observe(
            Playback(state: .playing, trackID: "t", position: 30, file: nil, reportedRate: 88_200),
            at: start.addingTimeInterval(30)
        )
        anchor.observe(
            Playback(state: .paused, trackID: nil, position: nil, file: nil, reportedRate: nil),
            at: start.addingTimeInterval(31)
        )
        anchor.observe(
            Playback(state: .playing, trackID: "t", position: 30, file: nil, reportedRate: 88_200),
            at: start.addingTimeInterval(300)
        )
        let anchoredStart = try #require(anchor.startedAt(for: "t"))
        let resumed = MusicLogLifecycleSelector.forEpoch(
            reportedRate: 88_200, estimatedStart: anchoredStart, previousKnownRate: 88_200, trackChanged: false
        )
        #expect(resumed.select(from: events)?.depth == 24)
    }

    // Captured 2026-11-26: Back pressed twice. The first press restarts the 24-bit track (12:24:17.6),
    // the second goes to the previous, 16-bit track (12:24:19.3). Music showed the new track from 12:24:18.6.
    private static let backTwice: [Line] = [
        .start("12:24:11.269", "0x7b0000a000|I/AAA.01"),
        .report("12:24:11.309", "0x7b0000a000|I/AAA.01", rate: 44_100, depth: 24),
        .start("12:24:17.647", "0x7b0000a000|I/AAA.01"),
        .report("12:24:17.683", "0x7b0000a000|I/AAA.01", rate: 44_100, depth: 24),
        .start("12:24:19.263", "0x7b0000b000|I/BBB.01"),
        .report("12:24:19.297", "0x7b0000b000|I/BBB.01", rate: 44_100, depth: 16)
    ]

    @Test func backTwiceUsesWhatIsKnownAboutThePreviousTracksLifecycle() throws {
        let events = try Self.parse(Self.backTwice)
        var ledger = MusicLogLifecycleLedger()
        let first = Self.selector(rate: 44_100, estimatedStart: "12:24:11.300", trackChanged: true)
        #expect(first.select(from: Array(events.prefix(1)))?.depth == 24)
        ledger.attribute(try #require(first.attributableLifecycle(from: Array(events.prefix(1)))), to: "old")

        var back = Self.selector(rate: 44_100, estimatedStart: "12:24:18.600", trackChanged: true)
        // Timing alone cannot tell the restart from the new track, and they disagree: withhold.
        #expect(back.select(from: events) == nil)
        #expect(back.attributableLifecycle(from: events) == nil)
        back.excludedLifecycles = ledger.lifecycles(notBelongingTo: "new")
        #expect(back.select(from: events)?.depth == 16)
        #expect(back.attributableLifecycle(from: events)?.contains("BBB.01") == true)
        // The same track is never excluded from its own lifecycle, and the ledger stays bounded.
        #expect(ledger.lifecycles(notBelongingTo: "old").isEmpty)
        for index in 0..<100 { ledger.attribute("L\(index)", to: "t\(index)") }
        #expect(ledger.lifecycles(notBelongingTo: "new").count == MusicLogLifecycleLedger.capacity)
    }

    @Test func competingLifecyclesThatAgreeOnDepthPublishWithoutBeingAttributed() throws {
        // Captured 2026-11-26 12:26: a restart and the previous track 1.9 s apart, both 16-bit.
        let events = try Self.parse([
            .start("12:26:00.476", "0x7b0000c000|I/CCC.01"),
            .report("12:26:00.515", "0x7b0000c000|I/CCC.01", rate: 44_100, depth: 16),
            .start("12:26:02.331", "0x7b0000d000|I/DDD.01"),
            .report("12:26:02.372", "0x7b0000d000|I/DDD.01", rate: 44_100, depth: 16)
        ])
        let back = Self.selector(rate: 44_100, estimatedStart: "12:26:01.700", trackChanged: true)
        #expect(back.select(from: events)?.depth == 16)
        #expect(back.attributableLifecycle(from: events) == nil)
    }

    @Test func itemStartedEarlyIsAcceptedOnceItsReportArrivesAtTheBoundary() throws {
        // Captured 2026-11-26: the next item's lifecycle started at 12:24:22 but it reported, and Music
        // showed it as current, only at 12:24:36.
        let events = try Self.parse([
            .start("12:24:19.263", "0x7b0000b000|I/BBB.01"),
            .report("12:24:19.297", "0x7b0000b000|I/BBB.01", rate: 44_100, depth: 16),
            .start("12:24:22.076", "0x7b0000e000|I/AAA.02"),
            .report("12:24:36.271", "0x7b0000e000|I/AAA.02", rate: 44_100, depth: 24)
        ])
        let next = Self.selector(rate: 44_100, estimatedStart: "12:24:36.000", trackChanged: true)
        #expect(next.select(from: events)?.depth == 24)
        // Before that report exists, the previous track's old report must not be borrowed.
        #expect(next.select(from: Array(events.dropLast())) == nil)
    }

    @Test func skipAnchorIgnoresStalePreviousTrackPosition() {
        let previousSampleAt = Self.date("13:34:28.500")
        let skipObservedAt = Self.date("13:34:28.700")
        var anchor = MusicPlaybackLogAnchor()
        anchor.observe(
            Playback(state: .playing, trackID: "old", position: 47, file: nil, reportedRate: 44_100),
            at: previousSampleAt
        )
        anchor.observe(
            Playback(state: .playing, trackID: "new", position: 47.2, file: nil, reportedRate: 44_100),
            at: skipObservedAt
        )
        let estimate = anchor.startedAt(for: "new") ?? .distantPast
        withKnownIssue("Anchor trusts Music's first post-skip position; position cap not yet applied") {
            #expect(abs(estimate.timeIntervalSince(Self.date("13:34:28.661"))) < 2)
        }
    }
}
