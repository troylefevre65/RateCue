// The Accessibility prompt key is imported from the SDK as a legacy mutable global.
@preconcurrency import ApplicationServices
import AppKit
import Foundation

public enum MusicFormatPanel {
    public static let accessibilityGuidance = "In RateCue, choose Accessibility Access to check or request permission. In System Settings > Privacy & Security, look for Device Control and Data Access or Accessibility, depending on macOS."

    public static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    @MainActor
    public static func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public struct Reading: Equatable, Sendable {
        public let rate: Int
        public let bitDepth: Int?
    }

    public enum Result: Equatable, Sendable {
        case accessibilityDenied
        case unavailable
        case noOpenPanel
        case unrecognizedFormat
        case reading(Reading)
    }

    public enum AutomaticError: LocalizedError, Equatable {
        case accessibilityDenied, unavailable, inspectionFailed(String), musicInUse, alreadyOpen, otherPanelOpen, panelChanged
        case timedOut, unrecognizedFormat, depthNotShown, actionFailed(Int32), closeUnconfirmed(String)

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied: "Accessibility access is not enabled."
            case .unavailable: "Music's Now Playing view is unavailable."
            case let .inspectionFailed(detail): detail
            case .musicInUse: "Music is active; automatic panel reading was skipped to avoid interrupting you."
            case .alreadyOpen: "Music's Lossless panel is already open; close it before the next automatic check."
            case .otherPanelOpen: "Another Music panel is open; automatic reading was skipped."
            case .panelChanged: "Music's panel changed during the automatic check."
            case .timedOut: "Music's Lossless panel did not open in time."
            case .unrecognizedFormat: "Music's Lossless panel did not show one recognizable format."
            case .depthNotShown: "Music's Lossless panel did not show bit depth."
            case let .actionFailed(code): "Music's Lossless panel action failed (Accessibility error \(code))."
            case let .closeUnconfirmed(detail): "RateCue could not confirm that Music's Lossless panel closed. \(detail)"
            }
        }
    }

    static func parse(_ text: String) -> Reading? {
        let formatPattern = #/^(?:([0-9]{1,2})[- ]bit(?:\s*[/,]\s*|\s+))?([0-9]{1,3}(?:[.,][0-9]{1,3})?)\s*kHz\s+ALAC$/#
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
        inspect(pid: pid).result
    }

    private static func inspect(pid: pid_t) -> Inspection<AXUIElement> {
        guard AXIsProcessTrusted() else { return Inspection(result: .accessibilityDenied) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        do {
            guard let windows: [AXUIElement] = try attribute(app, kAXWindowsAttribute),
                  !windows.isEmpty, windows.count <= 4 else {
                return Inspection(result: .unavailable, issue: "Music has no accessible window or too many windows.")
            }
            let tree = TreeAccess<AXUIElement>(
                minimized: { try attribute($0, kAXMinimizedAttribute) },
                children: { try attribute($0, kAXChildrenAttribute) },
                role: { try attribute($0, kAXRoleAttribute) },
                identifier: { try attribute($0, kAXIdentifierAttribute) },
                value: { try attribute($0, kAXValueAttribute) }
            )
            return inspect(windows: windows, tree: tree, withinBudget: { ProcessInfo.processInfo.systemUptime < deadline })
        } catch let error as Unavailable {
            return Inspection(result: .unavailable, issue: error.detail, retryable: error.retryable)
        } catch {
            return Inspection(result: .unavailable, issue: "Music Accessibility read failed: \(error.localizedDescription)")
        }
    }

    struct Inspection<Node> {
        let result: Result
        var badge: Node?
        var panel: Node?
        var otherPanelOpen = false
        var issue: String?
        var retryable = false
    }

    struct TreeAccess<Node> {
        let minimized: (Node) throws -> Bool?
        let children: (Node) throws -> [Node]?
        let role: (Node) throws -> String?
        let identifier: (Node) throws -> String?
        let value: (Node) throws -> String?
    }

    static func scan<Node>(windows: [Node], tree: TreeAccess<Node>, withinBudget: () -> Bool) -> Result {
        inspect(windows: windows, tree: tree, withinBudget: withinBudget).result
    }

    private static func inspect<Node>(
        windows: [Node], tree: TreeAccess<Node>, withinBudget: () -> Bool
    ) -> Inspection<Node> {
        do {
            guard !windows.isEmpty, windows.count <= 4 else {
                return Inspection(result: .unavailable, issue: "Music has no accessible window or too many windows.")
            }
            var roots: [Node] = []
            for window in windows {
                if try tree.minimized(window) == true { continue }
                roots.append(contentsOf: try nowPlayingRoots(window, tree: tree, withinBudget: withinBudget))
            }
            guard roots.count == 1, let root = roots.first else {
                return Inspection(result: .unavailable, issue: "Music's Now Playing view is missing or ambiguous.")
            }
            let elements = try descendants(root, tree: tree, withinBudget: withinBudget, maximumDepth: 2)
            var badges: [Node] = []
            for element in elements {
                guard withinBudget(), let role = try tree.role(element) else {
                    return Inspection(result: .unavailable, issue: "Music's Now Playing badge scan was incomplete.")
                }
                if role == kAXButtonRole, try tree.identifier(element) == "Music.nowPlaying.audioBadge" {
                    badges.append(element)
                }
            }
            var panels: [(Node, [Reading])] = []
            var otherPanelOpen = false
            for element in try tree.children(root) ?? [] {
                guard withinBudget(), let role = try tree.role(element) else {
                    return Inspection(result: .unavailable, issue: "Music's panel scan was incomplete.")
                }
                guard role == kAXPopoverRole else { continue }
                let contents = try descendants(element, tree: tree, withinBudget: withinBudget)
                var isLosslessPanel = false
                var values: [Reading] = []
                for child in contents {
                    guard withinBudget(), let childRole = try tree.role(child) else {
                        return Inspection(result: .unavailable, issue: "Music's panel contents could not be read completely.")
                    }
                    if try tree.identifier(child) == "apple.music.lossless" {
                        isLosslessPanel = true
                    }
                    if childRole == kAXStaticTextRole, let text = try tree.value(child),
                       let reading = parse(text) {
                        values.append(reading)
                    }
                }
                if isLosslessPanel {
                    panels.append((element, values))
                } else {
                    otherPanelOpen = true
                }
            }
            let issue = badges.count == 1 ? nil : "Music's Lossless badge is missing or ambiguous."
            return Inspection(result: classify(badges: badges.count, panels: panels.map(\.1)),
                              badge: badges.count == 1 ? badges.first : nil,
                              panel: panels.count == 1 ? panels.first?.0 : nil,
                              otherPanelOpen: otherPanelOpen, issue: issue)
        } catch let error as Unavailable {
            return Inspection(result: .unavailable, issue: error.detail, retryable: error.retryable)
        } catch {
            return Inspection(result: .unavailable, issue: "Music Accessibility read failed: \(error.localizedDescription)")
        }
    }

    static func classify(badges: Int, panels: [[Reading]]) -> Result {
        guard badges == 1 else { return .unavailable }
        guard !panels.isEmpty else { return .noOpenPanel }
        guard panels.count == 1, let readings = panels.first, readings.count == 1, let reading = readings.first else {
            return .unrecognizedFormat
        }
        return .reading(reading)
    }

    public static func readAutomatically(pid: pid_t, validatePlayback: () throws -> Void) throws -> Reading {
        try automaticRead(
            inspect: { inspect(pid: pid) },
            press: { element in
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                guard result == .success else { throw AutomaticError.actionFailed(result.rawValue) }
            },
            dismiss: { element in
                let result = AXUIElementPerformAction(element, kAXCancelAction as CFString)
                guard result == .success else { throw AutomaticError.actionFailed(result.rawValue) }
            },
            same: { CFEqual($0, $1) },
            check: {
                try checkAutomaticInteraction(checkAvailability: {
                    guard !Task.isCancelled else { throw CancellationError() }
                    guard let music = NSRunningApplication(processIdentifier: pid) else { throw AutomaticError.unavailable }
                    guard !music.isActive else { throw AutomaticError.musicInUse }
                }, validatePlayback: validatePlayback)
            },
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: Thread.sleep(forTimeInterval:)
        )
    }

    static func checkAutomaticInteraction(checkAvailability: () throws -> Void, validatePlayback: () throws -> Void) throws {
        try checkAvailability()
        try validatePlayback()
        try checkAvailability()
    }

    static func automaticRead<Node>(
        inspect: () -> Inspection<Node>, press: (Node) throws -> Void, dismiss: (Node) throws -> Void,
        same: (Node, Node) -> Bool,
        check: () throws -> Void, now: () -> TimeInterval, sleep: (TimeInterval) -> Void
    ) throws -> Reading {
        func observe(until deadline: TimeInterval) throws -> Inspection<Node> {
            while true {
                try check()
                let observation = inspect()
                guard observation.result == .unavailable, observation.retryable, now() < deadline else {
                    return observation
                }
                sleep(min(0.15, max(0, deadline - now())))
            }
        }
        let initial = try observe(until: now() + 3)
        switch initial.result {
        case .accessibilityDenied: throw AutomaticError.accessibilityDenied
        case .unavailable: throw initial.issue.map(AutomaticError.inspectionFailed) ?? AutomaticError.unavailable
        case .reading, .unrecognizedFormat: throw AutomaticError.alreadyOpen
        case .noOpenPanel: break
        }
        guard !initial.otherPanelOpen else { throw AutomaticError.otherPanelOpen }
        guard let badge = initial.badge else { throw AutomaticError.unavailable }
        try check()
        // A failed or timed-out action may already have taken effect; never repeat it.
        try press(badge)

        let deadline = now() + 2
        var observedPanel: Node?
        var observation = try observe(until: deadline)
        while true {
            try check()
            switch observation.result {
            case .accessibilityDenied: throw AutomaticError.accessibilityDenied
            case .unavailable: throw observation.issue.map(AutomaticError.inspectionFailed) ?? AutomaticError.unavailable
            case .noOpenPanel:
                if observedPanel != nil { throw AutomaticError.panelChanged }
            case .reading, .unrecognizedFormat:
                guard !observation.otherPanelOpen, let currentBadge = observation.badge,
                      same(badge, currentBadge), let panel = observation.panel else { throw AutomaticError.panelChanged }
                if let observedPanel, !same(observedPanel, panel) { throw AutomaticError.panelChanged }
                observedPanel = panel
            }
            if case let .reading(reading) = observation.result, reading.bitDepth != nil { break }
            guard now() < deadline else { break }
            sleep(min(0.15, max(0, deadline - now())))
            observation = try observe(until: deadline)
        }
        guard let panel = observedPanel else { throw AutomaticError.timedOut }
        try check()
        let latest = try observe(until: now() + 1)
        if latest.result == .accessibilityDenied { throw AutomaticError.accessibilityDenied }
        if latest.result == .unavailable {
            throw latest.issue.map(AutomaticError.inspectionFailed) ?? AutomaticError.unavailable
        }
        guard !latest.otherPanelOpen, let currentBadge = latest.badge, same(badge, currentBadge),
              let currentPanel = latest.panel, same(panel, currentPanel) else { throw AutomaticError.panelChanged }
        let outcome: Swift.Result<Reading, AutomaticError>
        switch latest.result {
        case let .reading(value):
            outcome = value.bitDepth == nil ? .failure(.depthNotShown) : .success(value)
        case .unrecognizedFormat: outcome = .failure(.unrecognizedFormat)
        default: throw AutomaticError.panelChanged
        }
        try check()
        try dismiss(panel)
        let closeDeadline = now() + 1.5
        while true {
            try check()
            let closed = try observe(until: closeDeadline)
            let detail: String
            switch closed.result {
            case .noOpenPanel: return try outcome.get()
            case .accessibilityDenied: throw AutomaticError.accessibilityDenied
            case .unavailable: detail = closed.issue ?? "Music's view could not be read."
            case .reading, .unrecognizedFormat:
                guard let currentBadge = closed.badge, same(badge, currentBadge),
                      let currentPanel = closed.panel, same(panel, currentPanel) else { throw AutomaticError.panelChanged }
                detail = "Music's Lossless panel is still open."
            }
            guard now() < closeDeadline else { throw AutomaticError.closeUnconfirmed(detail) }
            sleep(min(0.1, max(0, closeDeadline - now())))
        }
    }

    private struct Unavailable: Error {
        let detail: String
        var retryable = false
    }

    private static func nowPlayingRoots<Node>(
        _ window: Node, tree: TreeAccess<Node>, withinBudget: () -> Bool
    ) throws -> [Node] {
        var pending: [(node: Node, parent: Node?, depth: Int)] = [(window, nil, 0)]
        var roots: [Node] = []
        var count = 0
        while let (node, parent, depth) = pending.popLast() {
            guard count < 2_000, withinBudget() else { throw Unavailable(detail: "Music's window scan exceeded its time or size limit.") }
            guard let role = try tree.role(node) else { throw Unavailable(detail: "A Music window element has no accessible role.") }
            count += 1
            if role == kAXButtonRole, try tree.identifier(node) == "Music.nowPlaying.dismissalGrabber" {
                guard let parent, try tree.role(parent) == kAXGroupRole else {
                    throw Unavailable(detail: "Music's Now Playing view has an unexpected layout.")
                }
                roots.append(parent)
            }
            guard depth < 3 else { continue }
            let children = try tree.children(node) ?? []
            pending.append(contentsOf: children.map { ($0, node, depth + 1) })
        }
        return roots
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) throws -> T? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if status == .noValue || status == .attributeUnsupported { return nil }
        guard status == .success, let result = value as? T else {
            throw Unavailable(detail: "Music Accessibility attribute \(name) failed (error \(status.rawValue)).",
                              retryable: status == .cannotComplete)
        }
        return result
    }

    private static func descendants<Node>(
        _ element: Node, tree: TreeAccess<Node>, withinBudget: () -> Bool, maximumDepth: Int? = nil
    ) throws -> [Node] {
        var pending: [(Node, Int)] = [(element, 0)]
        var found: [Node] = []
        while let (current, depth) = pending.popLast() {
            guard found.count < 2_000, withinBudget() else {
                throw Unavailable(detail: "Music's panel scan exceeded its time or size limit.")
            }
            found.append(current)
            if let maximumDepth, depth == maximumDepth { continue }
            let children = try tree.children(current) ?? []
            guard depth < 10 || children.isEmpty else {
                throw Unavailable(detail: "Music's panel tree exceeded its depth limit.")
            }
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return found
    }
}
