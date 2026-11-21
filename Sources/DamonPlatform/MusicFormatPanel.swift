import ApplicationServices
import Foundation

public enum MusicFormatPanel {
    public struct Reading: Equatable, Sendable {
        public let rate: Int
        public let bitDepth: Int?
    }

    public enum Result: Equatable, Sendable {
        case accessibilityDenied
        case noOpenPanel
        case unrecognizedFormat
        case reading(Reading)
    }

    static func parse(_ text: String) -> Reading? {
        let formatPattern = #/^(?:([0-9]{1,2})[- ]bit\s*[/,]\s*)?([0-9]{1,3}(?:[.,][0-9]{1,3})?)\s*kHz\s+ALAC$/#
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let match = normalized.wholeMatch(of: formatPattern),
              let decimal = Decimal(string: match.2.replacingOccurrences(of: ",", with: "."),
                                    locale: Locale(identifier: "en_US_POSIX")),
              let rate = Int(exactly: NSDecimalNumber(decimal: decimal * 1_000).doubleValue),
              (8_000...384_000).contains(rate) else { return nil }
        let depth = match.1.flatMap { Int($0) }
        if let depth, !(8...32).contains(depth) { return nil }
        return Reading(rate: rate, bitDepth: depth)
    }

    public static func read(pid: pid_t) -> Result {
        guard AXIsProcessTrusted() else { return .accessibilityDenied }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        var readings: [Reading] = []
        var foundPanel = false
        for window in windows.prefix(4) {
            if (attribute(window, kAXMinimizedAttribute) as Bool?) == true { continue }
            var budget = 120
            let popovers = descendants(window, depth: 4, budget: &budget, deadline: deadline) {
                (attribute($0, kAXRoleAttribute) as String?) == kAXPopoverRole
            }
            for panel in popovers {
                var panelBudget = 24
                let elements = descendants(panel, depth: 4, budget: &panelBudget, deadline: deadline) { _ in true }
                // Only the Lossless popover, not a catalog row, settings description, or track title.
                let containsBadge = elements.contains {
                    (attribute($0, kAXIdentifierAttribute) as String?) == "apple.music.lossless"
                }
                guard containsBadge else { continue }
                foundPanel = true
                readings.append(contentsOf: elements.compactMap { element in
                    guard (attribute(element, kAXRoleAttribute) as String?) == kAXStaticTextRole,
                          let text: String = attribute(element, kAXValueAttribute) else { return nil }
                    return parse(text)
                })
            }
        }
        guard foundPanel else { return .noOpenPanel }
        guard readings.count == 1, let reading = readings.first else { return .unrecognizedFormat }
        return .reading(reading)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func descendants(
        _ element: AXUIElement, depth: Int, budget: inout Int, deadline: TimeInterval,
        matching: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
        guard depth > 0, budget > 0, ProcessInfo.processInfo.systemUptime < deadline else { return [] }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        var matches: [AXUIElement] = []
        // Inspect shallow siblings first so a library/queue subtree cannot starve adjacent popovers.
        let inspected = children.prefix(budget)
        budget -= inspected.count
        for child in inspected where ProcessInfo.processInfo.systemUptime < deadline {
            if matching(child) { matches.append(child) }
        }
        for child in inspected where ProcessInfo.processInfo.systemUptime < deadline {
            matches.append(contentsOf: descendants(child, depth: depth - 1, budget: &budget, deadline: deadline, matching: matching))
        }
        return matches
    }
}
