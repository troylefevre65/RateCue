import DamonPolicy
import Foundation

public struct PlaybackSample: Sendable {
    public static let musicBundleID = "com.apple.Music"

    public let outputs: [OutputDevice]?
    public let playback: Playback?
    public let format: Format?
    public let route: [UInt32]?
    public let message: String
    public let at: TimeInterval

    public var activeOutputs: [OutputDevice] {
        outputs?.filter { route?.contains($0.objectID) == true } ?? []
    }

    public func preferredOutput(uid: String?) -> OutputDevice? {
        let matches = outputs?.filter { $0.uid == uid } ?? []
        return matches.count == 1 ? matches.first : nil
    }

    public static func collect(
        pid: pid_t?, automation: Bool, folder: URL?, checkPermission: Bool = false, includeRateEstimate: Bool = false
    ) -> PlaybackSample {
        let at = ProcessInfo.processInfo.systemUptime
        func unavailable(_ message: String) -> PlaybackSample {
            PlaybackSample(outputs: AudioHardware.outputs(), playback: nil, format: nil, route: nil, message: message, at: at)
        }
        guard automation else { return unavailable("Music monitoring is off") }
        guard let pid else { return unavailable("Waiting for Music") }
        if checkPermission {
            let status = MusicObserver.requestPermission(pid: pid, askIfNeeded: false)
            guard status == 0 else {
                return unavailable("Music Automation unavailable (\(status)). Run authorize-music to request access for this launcher.")
            }
        }
        do {
            let playback = try MusicObserver.observe(pid: pid, readLocation: folder != nil, includeRateEstimate: includeRateEstimate)
            var format: Format?
            let message: String
            switch playback.state {
            case .playing:
                if let folder, let file = playback.file {
                    switch LocalRendition.inspect(url: file, in: folder, reportedRate: playback.reportedRate) {
                    case let .success(rendition):
                        format = rendition
                        message = "Music track rate and authorized local file header agree"
                    case let .failure(failure):
                        message = failure.rawValue
                    }
                } else if folder == nil {
                    message = "No qualified catalog format; authorize a test file or fixture folder to test local playback"
                } else {
                    message = "Music did not report a location for the current file track"
                }
            case .paused: message = "Music paused"
            case .stopped: message = "Music stopped"
            }
            let route = playback.state == .playing ? AudioHardware.confirmedMusicOutputs(pid: pid) : nil
            return PlaybackSample(outputs: AudioHardware.outputs(), playback: playback, format: format, route: route, message: message, at: at)
        } catch {
            let code = (error as NSError).code
            let message = code == -1743
                ? "Music Automation denied. Review System Settings > Privacy & Security > Automation."
                : (error as? MusicObservationError)?.errorDescription ?? "Music observation failed (error \(code))"
            return unavailable(message)
        }
    }
}
