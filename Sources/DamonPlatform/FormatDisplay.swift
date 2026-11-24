import AppKit
import DamonPolicy

public struct FormatDisplay {
    public enum Certainty: String {
        case verified = "Verified source format"
        case estimated = "Music-reported rate, unverified"
        case panelSnapshot = "Music panel snapshot, unverified"
        case unknown = "Unknown source format"
    }

    public let format: Format
    public let certainty: Certainty

    public init(
        verified: Format, playback: Playback?, panel: PanelFormatSnapshot? = nil, epoch: Epoch? = nil
    ) {
        if playback?.state != .playing {
            format = Format()
            certainty = .unknown
        } else if verified.rate != nil || verified.depth != nil {
            format = verified
            certainty = .verified
        } else if let epoch, let format = panel?.matchingFormat(playback: playback, epoch: epoch) {
            self.format = format
            certainty = .panelSnapshot
        } else if let rate = playback?.reportedRate, rate > 0 {
            format = Format(rate: rate)
            certainty = .estimated
        } else {
            format = Format()
            certainty = .unknown
        }
    }

    @MainActor
    public func statusBarTitle(showRate: Bool, showDepth: Bool, warning: Bool) -> NSAttributedString {
        let label = format.label(showRate: showRate, showDepth: showDepth)
        let showsKnownField = (showRate && format.rate != nil) || (showDepth && format.depth != nil)
        let text = ((certainty == .estimated || certainty == .panelSnapshot) && showsKnownField ? "≈" : "")
            + (label.isEmpty ? "RateCue" : label)
        let title = NSMutableAttributedString(string: warning ? "⚠ " : "")
        let tint: NSColor? = switch certainty {
        case .verified where showsKnownField: .systemGreen
        case .estimated where showsKnownField, .panelSnapshot where showsKnownField: .systemOrange
        default: nil
        }
        title.append(NSAttributedString(string: text, attributes: tint.map { [.foregroundColor: $0] } ?? [:]))
        return title
    }
}

public struct PanelFormatSnapshot: Sendable {
    private let format: Format
    private let epoch: Epoch
    private let trackID: String

    public init(format: Format, epoch: Epoch, trackID: String) {
        self.format = format
        self.epoch = epoch
        self.trackID = trackID
    }

    public func matchingFormat(playback: Playback?, epoch: Epoch) -> Format? {
        guard self.epoch == epoch, let playback, playback.state == .playing, playback.trackID == trackID,
              let rate = format.rate, rate > 0, let depth = format.depth, (8...32).contains(depth),
              playback.reportedRate == nil || playback.reportedRate == rate else { return nil }
        return format
    }
}
