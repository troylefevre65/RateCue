import AppKit
import DamonPolicy

public struct FormatDisplay {
    public enum Certainty: String {
        case verified = "Verified source format"
        case estimated = "Music-reported rate, unverified"
        case unknown = "Unknown source format"
    }

    public let format: Format
    public let certainty: Certainty

    public init(verified: Format, playback: Playback?) {
        if playback?.state != .playing {
            format = Format()
            certainty = .unknown
        } else if verified.rate != nil || verified.depth != nil {
            format = verified
            certainty = .verified
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
        let text = (certainty == .estimated && showsKnownField ? "≈" : "") + (label.isEmpty ? "Damon" : label)
        let title = NSMutableAttributedString(string: warning ? "⚠ " : "")
        let tint: NSColor? = switch certainty {
        case .verified where showsKnownField: .systemGreen
        case .estimated where showsKnownField: .systemOrange
        default: nil
        }
        title.append(NSAttributedString(string: text, attributes: tint.map { [.foregroundColor: $0] } ?? [:]))
        return title
    }
}
