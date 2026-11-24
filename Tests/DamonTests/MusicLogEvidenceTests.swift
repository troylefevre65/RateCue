@testable import DamonPlatform
import Foundation
import Testing

struct MusicLogEvidenceTests {
    @Test func playbackLogAnchorSurvivesPauseAndResetsOnTrackOrRestart() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var anchor = MusicPlaybackLogAnchor()
        anchor.observe(
            Playback(state: .playing, trackID: "track", position: 12, file: nil, reportedRate: 44_100),
            at: startedAt.addingTimeInterval(12)
        )
        #expect(anchor.startedAt(for: "track") == startedAt)

        anchor.observe(
            Playback(state: .paused, trackID: nil, position: nil, file: nil, reportedRate: nil),
            at: startedAt.addingTimeInterval(312)
        )
        anchor.observe(
            Playback(state: .playing, trackID: "track", position: 12, file: nil, reportedRate: 44_100),
            at: startedAt.addingTimeInterval(312)
        )
        #expect(anchor.startedAt(for: "track") == startedAt)

        anchor.observe(
            Playback(state: .stopped, trackID: nil, position: nil, file: nil, reportedRate: nil),
            at: startedAt.addingTimeInterval(612)
        )
        anchor.observe(
            Playback(state: .playing, trackID: "track", position: 12, file: nil, reportedRate: 44_100),
            at: startedAt.addingTimeInterval(612)
        )
        #expect(anchor.startedAt(for: "track") == startedAt)

        let replayedAt = startedAt.addingTimeInterval(700)
        anchor.observe(
            Playback(state: .stopped, trackID: nil, position: nil, file: nil, reportedRate: nil),
            at: replayedAt
        )
        anchor.observe(
            Playback(state: .playing, trackID: "track", position: 0, file: nil, reportedRate: 44_100),
            at: replayedAt.addingTimeInterval(20)
        )
        #expect(anchor.startedAt(for: "track") == replayedAt.addingTimeInterval(20))

        let restartedAt = replayedAt.addingTimeInterval(100)
        anchor.observe(
            Playback(state: .playing, trackID: "track", position: 4, file: nil, reportedRate: 44_100),
            at: restartedAt, restarted: true
        )
        #expect(anchor.startedAt(for: "track") == restartedAt.addingTimeInterval(-4))

        anchor.observe(
            Playback(state: .playing, trackID: "other", position: 8, file: nil, reportedRate: 96_000),
            at: restartedAt.addingTimeInterval(10)
        )
        #expect(anchor.startedAt(for: "track") == nil)
        #expect(anchor.startedAt(for: "other") == restartedAt.addingTimeInterval(2))
    }

    private func json(_ message: String, timestamp: String = "2026-11-23 22:37:53.626941-0700") -> Data {
        let event: [String: String] = ["timestamp": timestamp, "eventMessage": message]
        return try! JSONSerialization.data(withJSONObject: [event])
    }

    @Test func parsesDecoderReportAndAlternateSelection() throws {
        let report = "fpfs_ReportAudioPlaybackThroughFigLog: [Rendition Lossless] [SampleRate 44100] [BitDepth 16]"
        let start = "fpfs_StartTrackPlaying: <0x751e05aa00|I/NDR.01>"
        let alternate = "AudioGroup audio-alac-stereo-192000-24"
        let startEvent: [String: String] = [
            "timestamp": "2026-11-23 22:37:36.431078-0700", "eventMessage": start
        ]
        let reportEvent: [String: String] = [
            "timestamp": "2026-11-23 22:37:53.626941-0700",
            "eventMessage": "<0x751e05aa00|I/NDR.01>: \(report)"
        ]
        let parsed = try MusicLogEvidenceReader.parse(
            JSONSerialization.data(withJSONObject: [startEvent, reportEvent])
        )
        #expect(parsed.count == 1)
        #expect(parsed[0].source == .decoder)
        #expect(parsed[0].rate == 44_100)
        #expect(parsed[0].depth == 16)
        #expect(parsed[0].playbackStartAt != nil)
        let selected = try MusicLogEvidenceReader.parse(json(alternate))
        #expect(selected[0].source == .alternate)
        #expect(selected[0].rate == 192_000)
        #expect(selected[0].depth == 24)
    }

    @Test func rejectsMalformedUnknownOrLossyCandidates() throws {
        let messages = [
            "[SampleRate 44100] [BitDepth 0]",
            "AudioGroup audio-alac-stereo-192000-12",
            "AudioGroup audio-stereo-256",
            "[SampleRate nope] [BitDepth 24]"
        ]
        for message in messages {
            #expect(try MusicLogEvidenceReader.parse(json(message)).isEmpty)
        }
    }

    @Test func decoderReportWithoutMatchingLifecycleStartIsRejected() throws {
        let report = "<0x1|I/NDR.01>: fpfs_ReportAudioPlaybackThroughFigLog: [SampleRate 44100] [BitDepth 16]"
        #expect(try MusicLogEvidenceReader.parse(json(report)).isEmpty)
    }

    @Test func pairsCompleteLifecycleIdentityOutOfInputOrder() throws {
        let payload = Data(#"""
        [
          {"timestamp":"2026-11-23 10:00:01.000000-0800","eventMessage":"<0xB|I/NDR.01>: fpfs_ReportAudioPlaybackThroughFigLog: [SampleRate 44100] [BitDepth 24]"},
          {"timestamp":"2026-11-23 10:00:00.000000-0800","eventMessage":"<0xA|I/NDR.01>: fpfs_StartTrackPlaying"}
        ]
        """#.utf8)
        #expect(try MusicLogEvidenceReader.parse(payload).isEmpty)

        let sortedPayload = Data(#"""
        [
          {"timestamp":"2026-11-23 10:00:01.000000-0800","eventMessage":"<0xA|I/NDR.01>: fpfs_ReportAudioPlaybackThroughFigLog: [SampleRate 44100] [BitDepth 24]"},
          {"timestamp":"2026-11-23 10:00:00.000000-0800","eventMessage":"<0xA|I/NDR.01>: fpfs_StartTrackPlaying"}
        ]
        """#.utf8)
        let result = try MusicLogEvidenceReader.parse(sortedPayload)
        #expect(result.map(\.depth) == [24])
    }

    @Test func parsesEventsInTimestampOrder() throws {
        let old: [String: String] = [
            "timestamp": "2026-11-23 22:37:53.000000-0700",
            "eventMessage": "AudioGroup audio-alac-stereo-44100-24"
        ]
        let new: [String: String] = [
            "timestamp": "2026-11-23 22:37:54.000000-0700",
            "eventMessage": "AudioGroup audio-alac-stereo-44100-16"
        ]
        let data = try JSONSerialization.data(withJSONObject: [new, old])
        let parsed = try MusicLogEvidenceReader.parse(data)
        #expect(parsed.map(\.depth) == [24, 16])
    }
}
