import DamonPolicy
import Foundation

public struct RateReadback: Sendable {
    public let rate: Int?
    public let at: TimeInterval
}

public enum RateConfirmation {
    enum Continuity {
        case confirmed(PlaybackSample)
        case failed(String)
    }

    static func poll(
        _ request: WriteRequest, read: () -> Int?, now: () -> TimeInterval, sleep: (TimeInterval) -> Void
    ) -> RateReadback {
        while true {
            let rate = read()
            let at = now()
            let remaining = request.deadline - at
            if rate == request.rate || remaining <= 0 {
                return RateReadback(rate: rate, at: at)
            }
            sleep(min(0.01, remaining))
        }
    }

    static func confirmContinuity(
        after readback: TimeInterval, device: OutputDevice, format: Format, file: URL, trackID: String,
        observe: () -> PlaybackSample, now: () -> TimeInterval, sleep: (TimeInterval) -> Void,
        stillEnabled: () -> Bool = { true }
    ) -> Continuity {
        let deadline = readback + 2
        while stillEnabled() {
            let sample = observe()
            guard stillEnabled() else { break }
            if let outputs = sample.outputs, !outputs.contains(where: { $0.endpoint == device.endpoint }) {
                return .failed("The selected device disconnected after readback.")
            }
            if let route = sample.route, route != [device.objectID] {
                return .failed("Music moved to a different or multiple outputs after readback.")
            }
            if let rate = sample.preferredOutput(uid: device.uid)?.nominalRate, rate != format.rate {
                return .failed("The device rate changed after matching readback.")
            }
            if let playback = sample.playback {
                guard playback.state == .playing, playback.trackID == trackID else {
                    return .failed("Music stopped, paused, or changed track after readback.")
                }
                if let observedFile = playback.file, canonical(observedFile) != file {
                    return .failed("Music changed the active file after readback.")
                }
            }
            if let observedFormat = sample.format, observedFormat != format {
                return .failed("Music changed the active format after readback.")
            }
            let remaining = deadline - now()
            if sample.at >= readback, sample.playback?.file.map(canonical) == file, sample.route == [device.objectID],
               sample.format == format, sample.preferredOutput(uid: device.uid)?.nominalRate == format.rate {
                return remaining >= 0 ? .confirmed(sample) : .failed("Playback and route confirmation arrived after the continuity deadline.")
            }
            if remaining <= 0 { return .failed("Could not reconfirm playback and route after readback: \(sample.message)") }
            sleep(min(0.02, remaining))
        }
        return .failed("RateCue preferences changed or the write was cancelled before verification.")
    }

    static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    public struct Outcome: Sendable {
        public let disposition: WriteDisposition
        public let readback: RateReadback?
        public let warning: String?
        public let verifiedSample: PlaybackSample?

        init(disposition: WriteDisposition, readback: RateReadback?, warning: String?, verifiedSample: PlaybackSample? = nil) {
            self.disposition = disposition
            self.readback = readback
            self.warning = warning
            self.verifiedSample = verifiedSample
        }
    }

    public static func apply(
        _ request: WriteRequest, device: OutputDevice, sample: PlaybackSample, musicPID: pid_t, settings: DamonSettings
    ) -> Outcome {
        guard let file = sample.playback?.file.map(canonical), let trackID = sample.playback?.trackID,
              let format = sample.format, format.rate == request.rate, request.endpoint == device.endpoint,
              let folder = settings.authorizedAudio else {
            return Outcome(disposition: .failed, readback: nil, warning: "No qualified local source for this write.")
        }
        let now = { ProcessInfo.processInfo.systemUptime }
        let store = SettingsStore()
        func stillEnabled() -> Bool {
            guard !Task.isCancelled, let current = try? store.read() else { return false }
            return current.autoSwitch && current.monitorMusic && current.preferredOutputUID == settings.preferredOutputUID
                && current.authorizedAudioPath == settings.authorizedAudioPath
        }
        do {
            guard stillEnabled(), try MusicObserver.playingFixture(file, pid: musicPID, trackID: trackID), stillEnabled() else {
                return Outcome(disposition: .failed, readback: nil, warning: "Playback or settings changed before the rate write.")
            }
        } catch {
            return Outcome(disposition: .failed, readback: nil, warning: "Could not recheck Music before the write: \(error.localizedDescription)")
        }

        let status = AudioHardware.setRate(request.rate, device: device, musicPID: musicPID, deadline: request.deadline)
        let disposition = AudioHardware.writeDisposition(status)
        guard disposition == .submitted else {
            return Outcome(disposition: disposition, readback: nil,
                           warning: disposition == .failed ? "Core Audio rejected the rate write (\(status))." : nil)
        }
        let readback = poll(request, read: { AudioHardware.readRate(on: device) }, now: now, sleep: Thread.sleep(forTimeInterval:))
        guard readback.rate == request.rate, readback.at <= request.deadline else {
            return Outcome(disposition: disposition, readback: readback, warning: "Device rate was not confirmed within the alignment deadline.")
        }
        let continuity = confirmContinuity(
            after: readback.at, device: device, format: format, file: file, trackID: trackID,
            observe: { PlaybackSample.collect(pid: musicPID, automation: true, folder: folder) },
            now: now, sleep: Thread.sleep(forTimeInterval:), stillEnabled: stillEnabled
        )
        switch continuity {
        case let .confirmed(sample):
            return Outcome(disposition: disposition, readback: readback, warning: nil, verifiedSample: sample)
        case let .failed(warning):
            return Outcome(disposition: disposition, readback: readback, warning: warning)
        }
    }
}
