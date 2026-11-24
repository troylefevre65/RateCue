@testable import DamonPlatform
import ApplicationServices
import Foundation
import Testing

private final class PanelNode {
    let role: String
    let identifier: String?
    let value: String?
    var children: [PanelNode]
    var unreadable = false

    init(_ role: String, identifier: String? = nil, value: String? = nil, children: [PanelNode] = []) {
        self.role = role
        self.identifier = identifier
        self.value = value
        self.children = children
    }
}

private struct UnreadableTree: Error {}

struct MusicPanelTests {
    private var tree: MusicFormatPanel.TreeAccess<PanelNode> {
        .init(minimized: { _ in false }, children: {
            if $0.unreadable { throw UnreadableTree() }
            return $0.children
        }, role: { $0.role }, identifier: { $0.identifier }, value: { $0.value })
    }

    private func window(open: Bool) -> PanelNode {
        let close = PanelNode(kAXButtonRole, identifier: "Music.nowPlaying.dismissalGrabber")
        let badge = PanelNode(kAXButtonRole, identifier: "Music.nowPlaying.audioBadge")
        let panel = PanelNode(kAXPopoverRole, children: [
            PanelNode(kAXImageRole, identifier: "apple.music.lossless"),
            PanelNode(kAXStaticTextRole, value: "24-bit 96 kHz ALAC")
        ])
        let body = PanelNode(kAXGroupRole, children: [badge])
        let root = PanelNode(kAXGroupRole, children: open ? [close, body, panel] : [close, body])
        return PanelNode(kAXWindowRole, children: [root])
    }

    @Test func freshProbeScansAClosedThenOpenedPanelWithoutControllingMusic() throws {
        let root = window(open: false)
        let opened = window(open: true)
        let result = try MusicObserver.probeFreshPanel(
            trackID: { "fixture" }, trackRate: { 96_000 },
            panel: { MusicFormatPanel.scan(windows: [root], tree: tree, withinBudget: { true }) },
            stillPlaying: { true }, now: { 0 }, sleep: { _ in Issue.record("The simulated panel should already be open.") },
            onReady: { root.children = opened.children }
        )
        #expect(result.losslessPanel?.rateHz == 96_000)
        #expect(result.losslessPanel?.bitDepth == 24)
        #expect(result.losslessPanel?.freshness == "openedDuringProbe")
    }

    @Test func freshProbeRejectsAnAlreadyOpenSyntheticPanel() {
        let root = window(open: true)
        do {
            _ = try MusicObserver.probeFreshPanel(
                trackID: { "fixture" }, trackRate: { 96_000 },
                panel: { MusicFormatPanel.scan(windows: [root], tree: tree, withinBudget: { true }) },
                stillPlaying: { true }, now: { 0 }, sleep: { _ in }, onReady: {}
            )
            Issue.record("An existing panel may belong to a previous track.")
        } catch {
            #expect(error as? MusicObserver.FreshPanelError == .alreadyOpen)
        }
    }

    @Test func incompleteTreeIsNotMistakenForAClosedPanel() {
        let root = window(open: false)
        root.unreadable = true
        #expect(MusicFormatPanel.scan(windows: [root], tree: tree, withinBudget: { true }) == .unavailable)
        root.unreadable = false
        #expect(MusicFormatPanel.scan(windows: [root], tree: tree, withinBudget: { false }) == .unavailable)
    }

    @Test func aLargeUnrelatedQueueDoesNotHideTheNowPlayingPanel() {
        let root = window(open: true)
        let body = root.children[0].children[1]
        let queue = PanelNode(kAXGroupRole)
        queue.unreadable = true
        body.children.append(queue)
        #expect(MusicFormatPanel.scan(windows: [root], tree: tree, withinBudget: { true })
                == .reading(.init(rate: 96_000, bitDepth: 24)))
    }

    @Test func anUnrecognizedOrDuplicateNowPlayingRootIsNotTreatedAsClosed() {
        let one = window(open: false)
        #expect(MusicFormatPanel.scan(windows: [PanelNode(kAXWindowRole)], tree: tree, withinBudget: { true }) == .unavailable)
        #expect(MusicFormatPanel.scan(windows: [one, window(open: false)], tree: tree, withinBudget: { true }) == .unavailable)
    }

    @Test func automaticReadOpensAndClosesOnlyTheObservedPanel() throws {
        let reading = MusicFormatPanel.Reading(rate: 44_100, bitDepth: 16)
        var open = false
        var presses = 0
        let result = try MusicFormatPanel.automaticRead(
            inspect: {
                .init(result: open ? .reading(reading) : .noOpenPanel, badge: 1, panel: open ? 2 : nil)
            },
            press: { badge in
                #expect(badge == 1)
                presses += 1
                open = true
            }, dismiss: { panel in
                #expect(panel == 2)
                presses += 1
                open = false
            }, same: ==, check: {}, now: { 0 }, sleep: { _ in Issue.record("Panel should already be ready.") }
        )
        #expect(result == reading)
        #expect(presses == 2)
        #expect(!open)
    }

    @Test func automaticReadReopensAnExistingPanelToEstablishFreshness() throws {
        let reading = MusicFormatPanel.Reading(rate: 44_100, bitDepth: 24)
        var state = 1
        var presses = 0
        var dismissals = 0
        let result = try MusicFormatPanel.automaticRead(
            inspect: {
                .init(result: state == 0 ? .noOpenPanel : .reading(reading),
                      badge: 1, panel: state == 0 ? nil : 2)
            },
            press: { _ in presses += 1; state = 1 },
            dismiss: { _ in dismissals += 1; state = 0 },
            same: ==, check: {}, now: { 0 }, sleep: { _ in }
        )
        #expect(result == reading)
        #expect(presses == 1)
        #expect(dismissals == 1)
        #expect(state == 1)
    }

    @Test func automaticReadNeverTouchesAnUnobservablePanel() {
        let cases: [(MusicFormatPanel.Inspection<Int>, MusicFormatPanel.AutomaticError)] = [
            (.init(result: .noOpenPanel, badge: 1, otherPanelOpen: true), .otherPanelOpen),
            (.init(result: .accessibilityDenied), .accessibilityDenied),
            (.init(result: .unavailable), .unavailable),
            (.init(result: .unavailable, issue: "Incomplete scan"), .inspectionFailed("Incomplete scan"))
        ]
        for (observation, expected) in cases {
            #expect(throws: expected) {
                _ = try MusicFormatPanel.automaticRead(
                    inspect: { observation }, press: { _ in Issue.record("Must not press the badge.") },
                    dismiss: { _ in Issue.record("Must not dismiss a panel.") },
                    same: ==, check: {}, now: { 0 }, sleep: { _ in }
                )
            }
        }
    }

    @Test func automaticReadStopsIfThePanelOrPlaybackChanges() {
        var presses = 0
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try MusicFormatPanel.automaticRead(
                inspect: { .init(result: .noOpenPanel, badge: 1) },
                press: { _ in presses += 1 }, dismiss: { _ in presses += 1 }, same: ==,
                check: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                }, now: { 0 }, sleep: { _ in }
            )
        }
        #expect(presses == 1)

        presses = 0
        var inspections = 0
        #expect(throws: MusicFormatPanel.AutomaticError.panelChanged) {
            _ = try MusicFormatPanel.automaticRead(
                inspect: { () -> MusicFormatPanel.Inspection<Int> in
                    inspections += 1
                    if inspections == 1 { return .init(result: .noOpenPanel, badge: 1) }
                    return .init(result: .reading(.init(rate: 44_100, bitDepth: 16)),
                                 badge: 1, panel: inspections == 2 ? 2 : 3)
                },
                press: { _ in presses += 1 }, dismiss: { _ in presses += 1 },
                same: ==, check: {}, now: { 0 }, sleep: { _ in }
            )
        }
        #expect(presses == 1)
    }

    @Test func automaticReadContinuesWhenPlaybackValidationSucceeds() throws {
        var validations = 0
        var presses = 0
        var open = false
        let reading = MusicFormatPanel.Reading(rate: 44_100, bitDepth: 16)
        let result = try MusicFormatPanel.automaticRead(
            inspect: {
                .init(result: open ? .reading(reading) : .noOpenPanel,
                      badge: 1, panel: open ? 2 : nil)
            },
            press: { _ in presses += 1; open = true },
            dismiss: { _ in presses += 1; open = false },
            same: ==,
            check: {
                try MusicFormatPanel.checkAutomaticInteraction(
                    checkAvailability: {}, validatePlayback: { validations += 1 }
                )
            }, now: { 0 }, sleep: { _ in }
        )
        #expect(result == reading)
        #expect(validations > 0)
        #expect(presses == 2)
    }

    @Test func automaticReadDoesNotDismissIfCancelledDuringPlaybackValidation() {
        let reading = MusicFormatPanel.Reading(rate: 44_100, bitDepth: 16)
        var open = false
        var cancelled = false
        var inspections = 0
        var dismissals = 0
        #expect(throws: CancellationError.self) {
            _ = try MusicFormatPanel.automaticRead(
                inspect: { () -> MusicFormatPanel.Inspection<Int> in
                    inspections += 1
                    return .init(result: open ? .reading(reading) : .noOpenPanel,
                                 badge: 1, panel: open ? 2 : nil)
                },
                press: { _ in open = true }, dismiss: { _ in dismissals += 1 }, same: ==,
                check: {
                    try MusicFormatPanel.checkAutomaticInteraction(checkAvailability: {
                        if cancelled { throw CancellationError() }
                    }, validatePlayback: {
                        if open && inspections == 3 { cancelled = true }
                    })
                }, now: { 0 }, sleep: { _ in }
            )
        }
        #expect(open)
        #expect(dismissals == 0)
    }

    @Test func automaticReadClosesAnIncompletePanelButDoesNotGuessDepth() {
        var open = false
        var time: TimeInterval = 0
        #expect(throws: MusicFormatPanel.AutomaticError.depthNotShown) {
            _ = try MusicFormatPanel.automaticRead(
                inspect: {
                    .init(result: open ? .reading(.init(rate: 44_100, bitDepth: nil)) : .noOpenPanel,
                          badge: 1, panel: open ? 2 : nil)
                },
                press: { _ in open = true }, dismiss: { _ in open = false }, same: ==, check: {},
                now: { time }, sleep: { time += $0 }
            )
        }
        #expect(!open)
    }

    @Test func automaticReadDoesNotReportSuccessWhenClosingFails() {
        var open = false
        var presses = 0
        var time: TimeInterval = 0
        #expect(throws: MusicFormatPanel.AutomaticError.closeUnconfirmed("Music's Lossless panel is still open.")) {
            _ = try MusicFormatPanel.automaticRead(
                inspect: {
                    .init(result: open ? .reading(.init(rate: 44_100, bitDepth: 24)) : .noOpenPanel,
                          badge: 1, panel: open ? 2 : nil)
                },
                press: { _ in presses += 1; open = true }, dismiss: { _ in presses += 1 },
                same: ==, check: {},
                now: { time }, sleep: { time += $0 }
            )
        }
        #expect(presses == 2)
    }

    @Test func automaticReadWaitsForTransientUnavailabilityAfterDismissing() throws {
        let reading = MusicFormatPanel.Reading(rate: 44_100, bitDepth: 16)
        var state = 0
        var time: TimeInterval = 0
        let result = try MusicFormatPanel.automaticRead(
            inspect: { () -> MusicFormatPanel.Inspection<Int> in
                switch state {
                case 0, 3: .init(result: .noOpenPanel, badge: 1)
                case 1: .init(result: .reading(reading), badge: 1, panel: 2)
                default: .init(result: .unavailable, issue: "Temporary Accessibility failure")
                }
            },
            press: { _ in state = 1 }, dismiss: { _ in state = 2 }, same: ==, check: {},
            now: { time }, sleep: { time += $0; state = 3 }
        )
        #expect(result == reading)
    }

    @Test func automaticReadRetriesTransientObservationsWithoutRepeatingActions() throws {
        let reading = MusicFormatPanel.Reading(rate: 44_100, bitDepth: 16)
        var state = 0
        var beforeFailures = 2
        var afterFailures = 2
        var presses = 0
        var dismissals = 0
        var time: TimeInterval = 0
        let result = try MusicFormatPanel.automaticRead(
            inspect: { () -> MusicFormatPanel.Inspection<Int> in
                if state == 0, beforeFailures > 0 {
                    beforeFailures -= 1
                    return .init(result: .unavailable, issue: "Temporary timeout", retryable: true)
                }
                if state == 1, afterFailures > 0 {
                    afterFailures -= 1
                    return .init(result: .unavailable, issue: "Temporary timeout", retryable: true)
                }
                return .init(result: state == 1 ? .reading(reading) : .noOpenPanel,
                             badge: 1, panel: state == 1 ? 2 : nil)
            },
            press: { _ in presses += 1; state = 1 }, dismiss: { _ in dismissals += 1; state = 2 },
            same: ==, check: {}, now: { time }, sleep: { time += $0 }
        )
        #expect(result == reading)
        #expect(presses == 1)
        #expect(dismissals == 1)
    }

    @Test func automaticReadNeverRetriesAnUncertainOpeningAction() {
        var presses = 0
        #expect(throws: MusicFormatPanel.AutomaticError.actionFailed(-25204)) {
            _ = try MusicFormatPanel.automaticRead(
                inspect: { .init(result: .noOpenPanel, badge: 1) },
                press: { _ in presses += 1; throw MusicFormatPanel.AutomaticError.actionFailed(-25204) },
                dismiss: { _ in Issue.record("An unconfirmed action must not dismiss a panel.") },
                same: ==, check: {}, now: { 0 }, sleep: { _ in }
            )
        }
        #expect(presses == 1)
    }
}
