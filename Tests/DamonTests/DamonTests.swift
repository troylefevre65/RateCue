@testable import DamonPlatform
import AppKit
import CoreAudio
import DamonPolicy
import Foundation
import CoreServices
import Testing

struct DamonTests {
    private let epoch = Epoch(playback: 4, route: 8)
    private let next = Epoch(playback: 5, route: 8)

    @Test func ranksOnlyQualifiedSourceEvidence() {
        let evidence = [
            Evidence(epoch: epoch, source: .musicMetadata, at: 5, format: Format(rate: 44_100, depth: 16)),
            Evidence(epoch: epoch, source: .sourceStream, at: 5, format: Format(rate: 96_000)),
            Evidence(epoch: epoch, source: .dacLED, at: 5, format: Format(rate: 48_000, depth: 24)),
            Evidence(epoch: next, source: .sourceStream, at: 5, format: Format(rate: 192_000)),
            Evidence(epoch: epoch, source: .sourceStream, at: 3, format: Format(rate: 192_000))
        ]
        let result = Confidence.resolve(evidence, epoch: epoch, since: 4, now: 6)
        #expect(result.format == Format(rate: 96_000))
        #expect(result.lowerTierDisagrees)
        #expect(result == Confidence.resolve(evidence.reversed(), epoch: epoch, since: 4, now: 6))
        let onlyHardware = evidence.filter { $0.source == .dacLED }
        #expect(Confidence.resolve(onlyHardware, epoch: epoch, since: 4, now: 6).format == Format())
    }

    @Test func depthCorrelationRequiresFreshSamePlaybackEvidence() {
        let context = DepthContext(epoch: epoch, trackID: "track", routeID: "device")
        var engine = BitDepthCorrelationEngine(capacity: 4, freshness: 2)
        engine.observe(.init(context: context, at: 10, source: .musicPanel, candidate: .bit16, strength: .strong))
        engine.observe(.init(
            context: .init(epoch: next, trackID: "track", routeID: "device"),
            at: 10, source: .decoderLog, candidate: .bit24, strength: .strong
        ))
        let resolved = engine.resolve(context: context, rateHz: 44_100, now: 10.5)
        #expect(resolved.candidate == .bit16)
        #expect(resolved.score == 95)
        #expect(resolved.posterior16 == 95)
        #expect(resolved.posterior24 == 5)
        #expect(!resolved.conflict)
        #expect(!resolved.usedHighRatePrior)
        #expect(resolved.provenance == [.musicPanel])
        #expect(engine.resolve(context: context, rateHz: 44_100, now: 12.1).candidate == nil)
    }

    @Test func depthCorrelationUsesHighRateOnlyAsATieBreaker() {
        let context = DepthContext(epoch: epoch, trackID: "track", routeID: "device")
        var engine = BitDepthCorrelationEngine()
        engine.observe(.init(context: context, at: 10, source: .musicPanel, candidate: .bit16, strength: .moderate))
        engine.observe(.init(context: context, at: 10, source: .correlation, candidate: .bit24, strength: .moderate))
        let lowRate = engine.resolve(context: context, rateHz: 48_000, now: 10.1)
        #expect(lowRate.candidate == nil)
        #expect(lowRate.conflict)
        let highRate = engine.resolve(context: context, rateHz: 88_200, now: 10.1)
        #expect(highRate.candidate == nil)
        #expect(highRate.usedHighRatePrior)
        #expect(highRate.conflict)
        #expect(highRate.posterior16 == 30)
        #expect(highRate.posterior24 == 70)
    }

    @Test func newerSameSourceDepthSupersedesOlderEvidence() {
        let context = DepthContext(epoch: epoch, trackID: "track", routeID: "device")
        var engine = BitDepthCorrelationEngine()
        engine.observe(.init(
            context: context, at: 10, source: .musicPanel, candidate: .bit24,
            strength: .strong, persistsForContext: true
        ))
        engine.observe(.init(
            context: context, at: 11, source: .musicPanel, candidate: .bit16,
            strength: .strong, persistsForContext: true
        ))
        let result = engine.resolve(context: context, rateHz: 44_100, now: 20)
        #expect(!result.conflict)
        #expect(result.posterior16 == 95)
        #expect(result.posterior24 == 5)
        #expect(result.candidate == .bit16)

        engine.observe(.init(
            context: context, at: 10.5, source: .musicPanel, candidate: .bit24,
            strength: .strong, persistsForContext: true
        ))
        let unchanged = engine.resolve(context: context, rateHz: 44_100, now: 20)
        #expect(unchanged.posterior16 == 95)
        #expect(unchanged.posterior24 == 5)
    }

    @Test func persistentPanelEvidenceSurvivesTransientCapacityPressure() {
        let context = DepthContext(epoch: epoch, trackID: "track", routeID: "device")
        var engine = BitDepthCorrelationEngine(capacity: 2, freshness: 1)
        engine.observe(.init(
            context: context, at: 10, source: .musicPanel, candidate: .bit24,
            strength: .strong, persistsForContext: true
        ))
        engine.observe(.init(
            context: context, at: 11, source: .musicLog, candidate: .bit24, strength: .weak
        ))
        engine.observe(.init(
            context: context, at: 12, source: .decoderLog, candidate: .bit24, strength: .weak
        ))
        let result = engine.resolve(context: context, rateHz: 44_100, now: 20)
        #expect(result.evidenceAvailable)
        #expect(result.posterior24 > 50)
        #expect(result.provenance.contains(.musicPanel))
    }

    @Test func explicitFresh16BitEvidenceBlocksTheHighRatePrior() {
        let context = DepthContext(epoch: epoch, trackID: "track", routeID: "device")
        var engine = BitDepthCorrelationEngine()
        engine.observe(.init(context: context, at: 10, source: .musicPanel, candidate: .bit16, strength: .moderate))
        engine.observe(.init(context: context, at: 10, source: .musicLog, candidate: .bit24, strength: .moderate))
        let result = engine.resolve(context: context, rateHz: 96_000, now: 10.1)
        #expect(result.candidate == nil)
        #expect(result.usedHighRatePrior)
        #expect(result.conflict)
        #expect(result.contributions.filter { $0.logOddsContribution != 0 && $0.source != "ratePrior" }.map(\.source) == ["musicLog"])
    }

    @Test func highRatePriorNeverOverturnsA16BitEvidenceLead() {
        let context = DepthContext(epoch: epoch, trackID: "track", routeID: "device")
        var engine = BitDepthCorrelationEngine()
        engine.observe(.init(context: context, at: 10, source: .musicLog, candidate: .bit16, strength: .strong))
        engine.observe(.init(context: context, at: 10, source: .decoderLog, candidate: .bit16, strength: .strong))
        engine.observe(.init(context: context, at: 10, source: .localHeader, candidate: .bit16, strength: .strong))
        engine.observe(.init(context: context, at: 10, source: .musicLog, candidate: .bit24, strength: .moderate))
        let result = engine.resolve(context: context, rateHz: 96_000, now: 10.1)
        #expect(result.candidate == nil)
        #expect(result.usedHighRatePrior)
        #expect(result.posterior16 > result.posterior24)
        #expect(result.conflict)
    }

    @Test func depthCorrelationPrefersIndependentCorroborationAndBoundsCapacity() {
        let context = DepthContext(epoch: epoch, trackID: "track", routeID: "device")
        var engine = BitDepthCorrelationEngine(capacity: 2)
        engine.observe(.init(context: context, at: 10, source: .musicPanel, candidate: .bit16, strength: .weak))
        engine.observe(.init(context: context, at: 10.1, source: .musicLog, candidate: .bit24, strength: .strong))
        engine.observe(.init(context: context, at: 10.2, source: .decoderLog, candidate: .bit24, strength: .strong))
        let result = engine.resolve(context: context, rateHz: 44_100, now: 10.3)
        #expect(result.candidate == nil)
        #expect(result.score == 79)
        #expect(result.provenance == [.decoderLog, .musicLog])
        #expect(result.contributions.filter { $0.source != "ratePrior" && $0.logOddsContribution != 0 }.count == 1)
        #expect(result.contributions.filter { $0.source != "ratePrior" && $0.logOddsContribution == 0 }.count == 1)
    }

    @Test func depthCorrelationReturnsRatePriorsWithoutEvidence() {
        let context = DepthContext(epoch: epoch, trackID: "track", routeID: "device")
        let engine = BitDepthCorrelationEngine()
        let redBook = engine.resolve(context: context, rateHz: 44_100, now: 10)
        #expect(redBook.posterior16 == 70)
        #expect(redBook.posterior24 == 30)
        #expect(!redBook.evidenceAvailable)
        #expect(redBook.candidate == nil)
        let highResolution = engine.resolve(context: context, rateHz: 96_000, now: 10)
        #expect(highResolution.posterior16 == 30)
        #expect(highResolution.posterior24 == 70)
        #expect(!highResolution.evidenceAvailable)
        let extremeHighResolution = engine.resolve(context: context, rateHz: 192_000, now: 10)
        #expect(extremeHighResolution.posterior16 == 5)
        #expect(extremeHighResolution.posterior24 == 95)
        #expect(extremeHighResolution.candidate == nil)
        #expect(!extremeHighResolution.evidenceAvailable)
        let unknownRate = engine.resolve(context: context, rateHz: nil, now: 10)
        #expect(unknownRate.posterior16 == 50)
        #expect(unknownRate.posterior24 == 50)
    }

    @Test func acceptedPanelEvidencePersistsOnlyWithinItsPlaybackContext() {
        let context = DepthContext(epoch: epoch, trackID: "track", routeID: "device")
        var engine = BitDepthCorrelationEngine(freshness: 1)
        engine.observe(.init(
            context: context, at: 10, source: .musicPanel, candidate: .bit24,
            strength: .strong, persistsForContext: true
        ))
        let retained = engine.resolve(context: context, rateHz: 44_100, now: 20)
        #expect(retained.evidenceAvailable)
        #expect(retained.posterior24 == 79)
        #expect(retained.posterior16 == 21)
        let nextContext = DepthContext(epoch: next, trackID: "track", routeID: "device")
        let invalidated = engine.resolve(context: nextContext, rateHz: 44_100, now: 20)
        #expect(!invalidated.evidenceAvailable)
        #expect(invalidated.posterior16 == 70)
        #expect(invalidated.posterior24 == 30)
    }

    @Test func sameTierConflictNeverFallsBack() {
        let evidence = [
            Evidence(epoch: epoch, source: .sourceStream, at: 5, format: Format(rate: 96_000, depth: 24)),
            Evidence(epoch: epoch, source: .sourceStream, at: 5, format: Format(rate: 88_200, depth: 24)),
            Evidence(epoch: epoch, source: .musicMetadata, at: 5, format: Format(rate: 96_000))
        ]
        let result = Confidence.resolve(evidence, epoch: epoch, since: 4, now: 6)
        #expect(result.rateConflict)
        #expect(result.format == Format())
    }

    @Test func sameRateDepthAttributionIgnoresOldAndPrefetchedPlaybackInstances() {
        let earlier = Epoch(playback: 3, route: 8)
        let future = Epoch(playback: 5, route: 8)
        let evidence = [
            Evidence(epoch: earlier, source: .musicMetadata, at: 10.1, format: Format(rate: 44_100, depth: 16)),
            Evidence(epoch: epoch, source: .musicMetadata, at: 9.9, format: Format(rate: 44_100, depth: 16)),
            Evidence(epoch: epoch, source: .musicMetadata, at: 10.2, format: Format(rate: 44_100, depth: 24)),
            Evidence(epoch: future, source: .musicMetadata, at: 10.3, format: Format(rate: 44_100, depth: 16)),
            Evidence(epoch: epoch, source: .musicMetadata, at: 11.0, format: Format(rate: 44_100, depth: 16))
        ]
        let first = Confidence.resolve(evidence, epoch: epoch, since: 10, now: 10.5)
        #expect(first.format == Format(rate: 44_100, depth: 24))
        #expect(!first.depthConflict)
        #expect(first == Confidence.resolve(evidence.reversed(), epoch: epoch, since: 10, now: 10.5))
        let nextInstance = Confidence.resolve(evidence, epoch: future, since: 10, now: 10.5)
        #expect(nextInstance.format == Format(rate: 44_100, depth: 16))
    }

    @Test func conflictingCurrentDepthDoesNotFallBackOrInvalidateKnownRate() {
        let evidence = [
            Evidence(epoch: epoch, source: .sourceStream, at: 5, format: Format(rate: 44_100, depth: 16)),
            Evidence(epoch: epoch, source: .sourceStream, at: 5.1, format: Format(rate: 44_100, depth: 24)),
            Evidence(epoch: epoch, source: .musicMetadata, at: 5.2, format: Format(rate: 44_100, depth: 24))
        ]
        let result = Confidence.resolve(evidence, epoch: epoch, since: 5, now: 6)
        #expect(result.format == Format(rate: 44_100))
        #expect(result.depthConflict)
        #expect(!result.rateConflict)
    }

    private func input(
        generation: Epoch? = nil, boundary: Double = 10, playing: Bool = true, enabled: Bool = true,
        present: Bool = true, route: Bool = true, qualified: Bool = true, supported: Bool = true,
        target: Int? = 96_000, readback: Int? = 44_100
    ) -> AlignmentInput {
        AlignmentInput(epoch: generation ?? epoch, playbackBoundary: boundary, playing: playing, enabled: enabled,
                       devicePresent: present, preferredIsConfirmedRoute: route, qualified: qualified,
                       supportsTarget: supported, target: target, readback: readback,
                       endpoint: present ? "device" : nil, observedEndpoints: present ? ["device": readback] : [:])
    }

    @Test func rejectsAllUnconfirmedWriteConditions() {
        for (sample, expected) in [
            (input(playing: false), AlignmentState.idle), (input(enabled: false), .off),
            (input(present: false), .unavailable), (input(route: false), .unsupportedRoute),
            (input(qualified: false), .monitorOnly), (input(supported: false), .unsupportedRate),
            (input(target: nil), .unknown), (input(readback: nil), .unavailableReadback),
            (input(readback: 96_000), .aligned)
        ] {
            var machine = AlignmentMachine()
            #expect(machine.step(sample, now: 10.1) == nil)
            #expect(machine.state == expected)
        }
    }

    @Test func confirmsReadbackWithoutChasingDrift() throws {
        var machine = AlignmentMachine()
        let request = machine.step(input(), now: 10.1)
        let write = try #require(request)
        machine.receive(.submitted, for: write)
        #expect(machine.step(input(), now: 10.2) == nil)
        #expect(machine.state == .aligning)
        #expect(machine.confirmedWrite == nil)
        #expect(machine.step(input(readback: 96_000), now: 10.3) == nil)
        #expect(machine.confirmedWrite == write)
        #expect(machine.state == .aligned)
        #expect(machine.step(input(), now: 10.4) == nil)
        #expect(machine.state == .drift)
    }

    @Test func allowsOnlyOneTransientRetryWithinOriginalDeadline() throws {
        var machine = AlignmentMachine()
        let request = machine.step(input(), now: 11.8)
        let first = try #require(request)
        #expect(first.deadline == 12)
        machine.receive(.transientFailure, for: first)
        let secondRequest = machine.step(input(), now: 11.9)
        let retry = try #require(secondRequest)
        #expect(retry.attempt == 2)
        #expect(retry.deadline == first.deadline)
        machine.receive(.transientFailure, for: retry)
        #expect(machine.step(input(), now: 11.95) == nil)
        #expect(machine.state == .failed)
        var noTime = AlignmentMachine()
        #expect(noTime.step(input(), now: 12) == nil)
        #expect(noTime.state == .failed)
    }

    @Test func ignoresSupersededWriteConfirmation() throws {
        var machine = AlignmentMachine()
        let request = machine.step(input(), now: 10.1)
        let write = try #require(request)
        let latest = input(generation: next, boundary: 10.2, target: 48_000)
        #expect(machine.step(latest, now: 10.2) == nil)
        machine.receive(.submitted, for: write)
        #expect(machine.step(latest, now: 10.3) == nil)
        #expect(machine.step(latest, now: write.deadline) == nil)
        #expect(machine.state == .failed)
        let reread = input(generation: next, boundary: 10.2, target: 48_000, readback: 96_000)
        let latestRequest = machine.step(reread, now: 10.7)
        let nextWrite = try #require(latestRequest)
        #expect(nextWrite.epoch == next)
        #expect(nextWrite.rate == 48_000)
        #expect(machine.confirmedWrite == nil)
        machine.receive(.failed, for: write)
        #expect(machine.step(reread, now: 10.8) == nil)
        #expect(machine.state == .aligning)
    }

    @Test func requiresActualWriteAndFreshCorrelatedHardwareEvidence() {
        let verifier = TransitionVerification(epoch: epoch, rate: 96_000, confirmedAt: 10.2, trackChanged: true, writeStarted: 10)
        let below = LEDReading(epoch: epoch, at: 10.3, rate: 96_000, lockedAndStable: true, confidence: 0.95)
        let good = LEDReading(epoch: epoch, at: 10.3, rate: 96_000, lockedAndStable: true, confidence: 0.96)
        let wrong = LEDReading(epoch: epoch, at: 10.4, rate: 48_000, lockedAndStable: true, confidence: 0.99)
        let beforeWrite = RelayReading(epoch: epoch, at: 9.99)
        let click = RelayReading(epoch: epoch, at: 10.1)
        #expect(verifier.evaluate(led: [below], relay: [click], now: 12.2) == .incomplete)
        #expect(verifier.evaluate(led: [good], relay: [beforeWrite], now: 12.2) == .dacRateConfirmed)
        #expect(verifier.evaluate(led: [good], relay: [click], now: 10.4) == .transitionVerified)
        #expect(verifier.evaluate(led: [good, wrong], relay: [click], now: 10.5) == .failed)
        let sameRate = TransitionVerification(epoch: epoch, rate: 96_000, confirmedAt: 10.2, trackChanged: true, writeStarted: nil)
        #expect(sameRate.evaluate(led: [good], relay: [click], now: 10.4) == .dacRateConfirmed)
    }

    @Test func menuNeverSubstitutesAnUnknownField() {
        let format = Format(rate: 44_100)
        #expect(format.label(showRate: true, showDepth: true) == "44.1k / —")
        #expect(format.label(showRate: false, showDepth: true) == "—")
        #expect(format.label(showRate: true, showDepth: false) == "44.1k")
        #expect(format.label(showRate: false, showDepth: false).isEmpty)
    }

    @MainActor
    @Test func menuShowsUnqualifiedMusicRateInAmberWithoutGuessingDepth() {
        let playback = Playback(state: .playing, trackID: "catalog", position: nil, file: nil, reportedRate: 96_000)
        let display = FormatDisplay(verified: Format(), playback: playback)
        let title = display.statusBarTitle(showRate: true, showDepth: true, warning: false)
        #expect(display.certainty == .estimated)
        #expect(title.string == "≈96k / —")
        #expect(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemOrange)
        let depthOnly = display.statusBarTitle(showRate: false, showDepth: true, warning: false)
        #expect(depthOnly.string == "—")
        #expect(depthOnly.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @MainActor
    @Test func menuDisplaysCorrelatedDepthAsASeparateEstimate() {
        let playback = Playback(state: .playing, trackID: "catalog", position: nil, file: nil, reportedRate: 96_000)
        let estimate = DepthResolution(
            candidate: .bit24, score: 70, conflict: false, usedHighRatePrior: true, provenance: []
        )
        let display = FormatDisplay(verified: Format(), playback: playback, depthEstimate: estimate)
        #expect(display.certainty == .correlated)
        #expect(display.statusBarTitle(showRate: true, showDepth: true, warning: false).string == "≈96k / 24")
    }

    @MainActor
    @Test func menuPrefersVerifiedFormatAndClearsTheColorWhenPlaybackStops() {
        let verified = Format(rate: 44_100, depth: 16)
        let playback = Playback(state: .playing, trackID: "local", position: nil, file: nil, reportedRate: 96_000)
        let display = FormatDisplay(verified: verified, playback: playback)
        let title = display.statusBarTitle(showRate: true, showDepth: true, warning: false)
        #expect(title.string == "44.1k / 16")
        #expect(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemGreen)
        let stopped = Playback(state: .stopped, trackID: nil, position: nil, file: nil, reportedRate: nil)
        let idle = FormatDisplay(verified: verified, playback: stopped)
        let cleared = idle.statusBarTitle(showRate: true, showDepth: true, warning: false)
        #expect(cleared.string == "— / —")
        #expect(cleared.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @MainActor
    @Test func menuDisplaysExplicitPanelDepthOnlyAsAnEstimate() {
        let playback = Playback(state: .playing, trackID: "catalog", position: nil, file: nil, reportedRate: 96_000)
        let snapshot = PanelFormatSnapshot(format: Format(rate: 96_000, depth: 24), epoch: epoch, trackID: "catalog")
        let display = FormatDisplay(verified: Format(), playback: playback, panel: snapshot, epoch: epoch)
        let title = display.statusBarTitle(showRate: true, showDepth: true, warning: false)
        #expect(title.string == "≈96k / 24")
        #expect(display.certainty == .panelSnapshot)
        #expect(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemOrange)
        #expect(display.statusBarTitle(showRate: false, showDepth: true, warning: false).string == "≈24")
        let confirmed = FormatDisplay(verified: Format(rate: 96_000, depth: 16), playback: playback, panel: snapshot, epoch: epoch)
        #expect(confirmed.certainty == .verified)
        #expect(confirmed.format == Format(rate: 96_000, depth: 16))
    }

    @Test func panelSnapshotIsNotReusedForAChangedTrackRouteOrConflictingRate() {
        let snapshot = PanelFormatSnapshot(format: Format(rate: 96_000, depth: 24), epoch: epoch, trackID: "first")
        let first = Playback(state: .playing, trackID: "first", position: nil, file: nil, reportedRate: 96_000)
        let other = Playback(state: .playing, trackID: "other", position: nil, file: nil, reportedRate: 96_000)
        let conflicting = Playback(state: .playing, trackID: "first", position: nil, file: nil, reportedRate: 44_100)
        let paused = Playback(state: .paused, trackID: nil, position: nil, file: nil, reportedRate: nil)
        #expect(snapshot.matchingFormat(playback: first, epoch: epoch) == Format(rate: 96_000, depth: 24))
        #expect(snapshot.matchingFormat(playback: other, epoch: epoch) == nil)
        #expect(snapshot.matchingFormat(playback: first, epoch: next) == nil)
        #expect(snapshot.matchingFormat(playback: conflicting, epoch: epoch) == nil)
        #expect(snapshot.matchingFormat(playback: paused, epoch: epoch) == nil)
        let unknown = PanelFormatSnapshot(format: Format(rate: 96_000), epoch: epoch, trackID: "first")
        #expect(unknown.matchingFormat(playback: first, epoch: epoch) == nil)
    }

    @MainActor
    @Test func activeMusicKeepsAValidExperimentalPanelSnapshotVisible() {
        let playback = Playback(state: .playing, trackID: "catalog", position: nil, file: nil, reportedRate: 44_100)
        let snapshot = PanelFormatSnapshot(format: Format(rate: 44_100, depth: 16), epoch: epoch, trackID: "catalog")
        let display = FormatDisplay(verified: Format(), playback: playback, panel: snapshot, epoch: epoch)
        #expect(display.statusBarTitle(showRate: true, showDepth: true, warning: false).string == "≈44.1k / 16")
        let qualified = FormatDisplay(verified: Format(rate: 44_100, depth: 24), playback: playback, panel: snapshot,
                                      epoch: epoch)
        #expect(qualified.certainty == .verified)
        #expect(qualified.format.depth == 24)
    }

    @Test func automaticPanelReadingIsOptInAndPersists() throws {
        let domain = "org.damon.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SettingsStore(domain: domain)
        #expect(try !store.read().autoReadMusicPanel)
        try store.apply([.autoReadMusicPanel(true)])
        #expect(try store.read().autoReadMusicPanel)
        try store.apply([.autoReadMusicPanel(false)])
        #expect(try !store.read().autoReadMusicPanel)
    }

    @Test func menuDiagnosticsStoreRoundTripsCorrelationState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = MenuDiagnosticsSnapshot(
            snapshotAt: Date(timeIntervalSince1970: 1_800_000_000),
            processIdentifier: 123,
            menuTitle: "≈44.1k / 16",
            certainty: "Music panel snapshot, unverified",
            correlationScore: 95,
            correlatedDepth: 16,
            correlationConflict: false,
            usedHighRatePrior: false,
            correlationProvenance: ["musicPanel"],
            playbackState: "playing",
            automaticPanelStatus: "Unverified Music panel snapshot.",
            posterior16: 95,
            posterior24: 5,
            evidenceAvailable: true,
            contributions: [
                .init(
                    source: "ratePrior", candidate: 16, strength: "prior",
                    likelihoodRatio: 0.428571, logOddsContribution: -0.847297
                ),
                .init(
                    source: "musicPanel", candidate: 16, strength: "strong",
                    likelihoodRatio: 9, logOddsContribution: -2.197225
                )
            ]
        )
        let store = MenuDiagnosticsStore(directory: directory)
        try store.write(snapshot)
        #expect(try store.read() == snapshot)
        let data = try Data(contentsOf: store.url)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"posterior16\" : 95"))
        #expect(json.contains("\"correlationProvenance\" : ["))
        #expect(json.contains("\"schemaVersion\" : 1"))
        #expect(json.contains("\"correlationModelVersion\" : 1"))
        #expect(json.contains("\"snapshotAt\" : \"2027-"))
        #expect(!json.contains("trackID"))
    }

    @Test func menuDiagnosticsRejectStaleOrReplacedProcesses() {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        func snapshot(_ at: TimeInterval, pid: Int32 = 123) -> MenuDiagnosticsSnapshot {
            MenuDiagnosticsSnapshot(
                snapshotAt: Date(timeIntervalSince1970: at),
                processIdentifier: pid,
                menuTitle: "≈44.1k / 16",
                certainty: "Music panel snapshot, unverified",
                correlationScore: 100,
                correlatedDepth: 16,
                correlationConflict: false,
                usedHighRatePrior: false,
                correlationProvenance: ["musicPanel"],
                playbackState: "playing",
                automaticPanelStatus: "Unverified Music panel snapshot."
            )
        }
        #expect(DamonCLI.validMenuSnapshot(snapshot(1_800_000_096), now: now) { $0 == 123 })
        #expect(!DamonCLI.validMenuSnapshot(snapshot(1_800_000_090), now: now) { $0 == 123 })
        #expect(!DamonCLI.validMenuSnapshot(snapshot(1_800_000_102), now: now) { $0 == 123 })
        #expect(!DamonCLI.validMenuSnapshot(snapshot(1_800_000_099), now: now) { _ in false })
    }

    @Test func monitoringOrPanelSettingChangesInvalidateAutomaticReads() {
        var previous = DamonSettings()
        previous.monitorMusic = true
        previous.autoReadMusicPanel = true
        var next = previous
        next.monitorMusic = false
        #expect(next.invalidatesAutomaticPanelRead(comparedTo: previous))
        next = previous
        next.autoReadMusicPanel = false
        #expect(next.invalidatesAutomaticPanelRead(comparedTo: previous))
        next = previous
        next.showBitDepth = false
        #expect(!next.invalidatesAutomaticPanelRead(comparedTo: previous))
    }

    @Test func constructsNestedReadOnlyMusicPropertySpecifier() throws {
        let track = try MusicObserver.property("pTrk")
        let property = try MusicObserver.property("pSRt", in: track)
        #expect(property.descriptorType == 0x6f626a20)
    }

    @Test func fixturePlaybackRequestTargetsTheFileAndPlaysOnce() {
        let fixture = URL(fileURLWithPath: "/tmp/Damon test tone.m4a")
        let request = MusicObserver.fixturePlayEvent(fixture, pid: getpid())
        #expect(request.paramDescriptor(forKeyword: 0x2d2d2d2d)?.fileURLValue == fixture)
        #expect(request.paramDescriptor(forKeyword: 0x504f6e65)?.booleanValue == true)
    }

    @Test func parsesOnlyExplicitFormatWithoutInferringBitDepth() {
        #expect(MusicFormatPanel.parse("44.1 kHz ALAC") == .init(rate: 44_100, bitDepth: nil))
        #expect(MusicFormatPanel.parse("24-bit 96 kHz ALAC") == .init(rate: 96_000, bitDepth: 24))
        #expect(MusicFormatPanel.parse("16-bit 44.1 kHz ALAC") == .init(rate: 44_100, bitDepth: 16))
        #expect(MusicFormatPanel.parse("24-bit / 176,4 kHz ALAC") == .init(rate: 176_400, bitDepth: 24))
        #expect(MusicFormatPanel.parse("24-bit96 kHz ALAC") == nil)
        #expect(MusicFormatPanel.parse("Lossless up to 192 kHz ALAC") == nil)
        #expect(MusicFormatPanel.parse("256 kHz AAC") == nil)
        #expect(MusicFormatPanel.parse("99-bit / 44.1 kHz ALAC") == nil)
    }

    @Test func panelObservationRequiresAUniqueBadgeAndFormat() {
        let reading = MusicFormatPanel.Reading(rate: 96_000, bitDepth: 24)
        #expect(MusicFormatPanel.classify(badges: 0, panels: []) == .unavailable)
        #expect(MusicFormatPanel.classify(badges: 2, panels: []) == .unavailable)
        #expect(MusicFormatPanel.classify(badges: 1, panels: []) == .noOpenPanel)
        #expect(MusicFormatPanel.classify(badges: 1, panels: [[]]) == .unrecognizedFormat)
        #expect(MusicFormatPanel.classify(badges: 1, panels: [[reading], [reading]]) == .unrecognizedFormat)
        #expect(MusicFormatPanel.classify(badges: 1, panels: [[reading, reading]]) == .unrecognizedFormat)
        #expect(MusicFormatPanel.classify(badges: 1, panels: [[reading]]) == .reading(reading))
    }

    @Test func catalogProbeKeepsUnreportedTrackRateSeparateFromThePanel() throws {
        let result = try MusicObserver.probePlayingFormat(
            trackID: { "same-track" }, trackRate: { 0 },
            panel: { .reading(.init(rate: 44_100, bitDepth: nil)) }, stillPlaying: { true }
        )
        #expect(result.trackProperty?.status == "notReported")
        #expect(result.trackProperty?.rateHz == nil)
        #expect(result.losslessPanel?.rateHz == 44_100)
        #expect(result.losslessPanel?.bitDepth == nil)
        #expect(result.losslessPanel?.freshness == "notEstablished")
    }

    @Test func catalogProbeRejectsEvidenceTakenAcrossATrackChange() {
        var activeTrack = "first"
        #expect(throws: MusicObservationError.self) {
            _ = try MusicObserver.probePlayingFormat(
                trackID: { activeTrack },
                trackRate: { activeTrack = "second"; return 96_000 },
                panel: nil, stillPlaying: { true }
            )
        }
    }

    @Test func freshPanelProbeRequiresClosedThenOpenForTheSameTrack() throws {
        var readings: [MusicFormatPanel.Result] = [
            .noOpenPanel, .noOpenPanel, .reading(.init(rate: 96_000, bitDepth: 24))
        ]
        var time = 0.0
        var ready = false
        let result = try MusicObserver.probeFreshPanel(
            trackID: { "track" }, trackRate: { 44_100 }, panel: { readings.removeFirst() },
            stillPlaying: { true }, now: { time }, sleep: { time += $0 }, onReady: { ready = true }
        )
        #expect(ready)
        #expect(result.trackProperty?.rateHz == 44_100)
        #expect(result.losslessPanel?.rateHz == 96_000)
        #expect(result.losslessPanel?.bitDepth == 24)
        #expect(result.losslessPanel?.freshness == "openedDuringProbe")
    }

    @Test func freshPanelJSONOmitsUnreportedBitDepth() throws {
        var readings: [MusicFormatPanel.Result] = [.noOpenPanel, .reading(.init(rate: 44_100, bitDepth: nil))]
        let result = try MusicObserver.probeFreshPanel(
            trackID: { "track" }, trackRate: { 44_100 }, panel: { readings.removeFirst() },
            stillPlaying: { true }, now: { 0 }, sleep: { _ in }, onReady: {}
        )
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        let panel = try #require(json["losslessPanel"] as? [String: Any])
        #expect(panel["rateHz"] as? Int == 44_100)
        #expect(panel["bitDepth"] == nil)
        #expect(panel["freshness"] as? String == "openedDuringProbe")
    }

    @Test func freshPanelProbeRejectsAnExistingOrUnobservablePanel() {
        for (initial, expected) in [
            (MusicFormatPanel.Result.reading(.init(rate: 96_000, bitDepth: 24)), MusicObserver.FreshPanelError.alreadyOpen),
            (.unrecognizedFormat, .alreadyOpen), (.unavailable, .unavailable), (.accessibilityDenied, .accessibilityDenied)
        ] {
            var ready = false
            do {
                _ = try MusicObserver.probeFreshPanel(
                    trackID: { "track" }, trackRate: { 96_000 }, panel: { initial },
                    stillPlaying: { true }, now: { 0 }, sleep: { _ in }, onReady: { ready = true }
                )
                Issue.record("The probe accepted an existing or unobservable panel.")
            } catch {
                #expect(error as? MusicObserver.FreshPanelError == expected)
            }
            #expect(!ready)
        }
    }

    @Test func panelPermissionErrorNamesTheCurrentAndEarlierSettingsLocations() {
        let guidance = MusicObserver.FreshPanelError.accessibilityDenied.errorDescription
        #expect(guidance?.contains("Device Control and Data Access") == true)
        #expect(guidance?.contains("Accessibility") == true)
    }

    @Test func freshPanelProbeRejectsATrackChangeDuringThePanelRead() {
        var track = "before"
        var reads = 0
        #expect(throws: MusicObservationError.self) {
            _ = try MusicObserver.probeFreshPanel(
                trackID: { track }, trackRate: { 96_000 }, panel: {
                    reads += 1
                    if reads == 1 { return .noOpenPanel }
                    track = "after"
                    return .reading(.init(rate: 96_000, bitDepth: 24))
                }, stillPlaying: { true }, now: { 0 }, sleep: { _ in }, onReady: {}
            )
        }
    }

    @Test func freshPanelProbeRejectsAnUnexpectedTrackBeforeReadingThePanel() {
        var panelRead = false
        #expect(throws: MusicObservationError.self) {
            _ = try MusicObserver.probeFreshPanel(
                trackID: { "new" }, trackRate: { 96_000 }, panel: { panelRead = true; return .noOpenPanel },
                stillPlaying: { true }, now: { 0 }, sleep: { _ in }, onReady: {}, expectedTrackID: "old"
            )
        }
        #expect(!panelRead)
    }

    @Test func openPanelReadingRequiresTheSamePlayingTrackBeforeAndAfter() throws {
        let expected = MusicFormatPanel.Result.reading(.init(rate: 44_100, bitDepth: 24))
        let result = try MusicObserver.readOpenPanel(
            expectedTrackID: "track", trackID: { "track" }, stillPlaying: { true }, panel: { expected }
        )
        #expect(result == expected)
        var current = "track"
        #expect(throws: MusicObservationError.self) {
            _ = try MusicObserver.readOpenPanel(
                expectedTrackID: "track", trackID: { current }, stillPlaying: { true },
                panel: { current = "other"; return expected }
            )
        }
    }

    @Test func freshPanelProbeRejectsAnAmbiguousPanelAfterOpening() {
        var readings: [MusicFormatPanel.Result] = [.noOpenPanel, .unrecognizedFormat]
        do {
            _ = try MusicObserver.probeFreshPanel(
                trackID: { "track" }, trackRate: { 96_000 }, panel: { readings.removeFirst() },
                stillPlaying: { true }, now: { 0 }, sleep: { _ in }, onReady: {}
            )
            Issue.record("The probe accepted an ambiguous opened panel.")
        } catch {
            #expect(error as? MusicObserver.FreshPanelError == .unrecognizedFormat)
        }
    }

    @Test func freshPanelProbeTimesOutWithoutGuessingDepth() {
        var time = 0.0
        do {
            _ = try MusicObserver.probeFreshPanel(
                trackID: { "track" }, trackRate: { 96_000 }, panel: { .noOpenPanel },
                stillPlaying: { true }, now: { time }, sleep: { time += $0 }, onReady: {}, timeout: 0.4
            )
            Issue.record("The probe succeeded without an opened panel.")
        } catch {
            #expect(error as? MusicObserver.FreshPanelError == .timedOut)
        }
    }

    @Test func musicTransportWaitsForPlayAndMakesPauseIdempotent() throws {
        var states: [Playback.State] = [.paused, .paused, .playing]
        var commands = 0
        var time = 0.0
        let play = try MusicObserver.runTransport(.play, read: {
            .init(state: states.removeFirst())
        }, send: { commands += 1 }, now: { time }, sleep: { time += $0 })
        #expect(play.confirmed && play.commandSent)
        #expect(play.playbackState == "playing")
        let pause = try MusicObserver.runTransport(.pause, read: { .init(state: .paused) }, send: {
            commands += 1
        }, now: { time }, sleep: { time += $0 })
        #expect(pause.confirmed && !pause.commandSent)
        #expect(commands == 1)
    }

    @Test func musicTransportConfirmsNextOnlyWhenAnotherTrackAppears() throws {
        let before = MusicObserver.TransportSnapshot(state: .playing, trackID: "first")
        var trackIDs: [String?] = ["first", nil, "first", "second"]
        var commands = 0
        var time = 0.0
        let next = try MusicObserver.runTransport(.next, read: {
            .init(state: .playing, trackID: trackIDs.removeFirst())
        }, send: { commands += 1 }, now: { time }, sleep: { time += $0 })
        #expect(next.confirmed && next.trackChanged == true)
        #expect(trackIDs.isEmpty)

        let unchanged = try MusicObserver.runTransport(.next, read: { before }, send: {
            commands += 1
        }, now: { time }, sleep: { time += $0 })
        #expect(!unchanged.confirmed && unchanged.trackChanged == false)
        #expect(commands == 2)
    }

    @Test func classifierNeedsLockAndDistinctRateAndUsesCalibrationScore() throws {
        let data = Data("""
            {"deviceUID":"dac","camera":{"deviceID":"camera","lock":{"x":0,"y":0,"width":0.1,"height":0.1},
             "minimumBrightness":0.5,"minimumMargin":0.2,"indicators":[
              {"rate":44100,"confidence":0.98,"region":{"x":0.1,"y":0,"width":0.1,"height":0.1}},
              {"rate":96000,"confidence":0.95,"region":{"x":0.2,"y":0,"width":0.1,"height":0.1}}]}}
            """.utf8)
        let profile = try JSONDecoder().decode(SensorProfile.self, from: data)
        let camera = try #require(profile.camera)
        #expect(camera.isValid)
        #expect(camera.classify(lockBrightness: 0.4, levels: [0.9, 0.1]) == nil)
        #expect(camera.classify(lockBrightness: 0.9, levels: [0.9, 0.85]) == nil)
        #expect(camera.classify(lockBrightness: 0.9, levels: [0.9, 0.2])?.rate == 44_100)
        #expect(camera.classify(lockBrightness: 0.9, levels: [0.1, 0.8])?.confidence == 0.95)
    }

    @Test(arguments: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000])
    func readsAuthorizedALACFixtureWithKnownRateAndDepth(rate: Int) throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("damon-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        for depth in rate == 44_100 ? [16, 24] : [24] {
            let encoded = try QualificationFixtures.writePair(to: folder, rate: rate, depth: depth, frames: 512)
            let reference = encoded.deletingPathExtension().appendingPathExtension("wav")
            #expect(LocalRendition.inspect(url: encoded, in: folder, reportedRate: rate) == .success(Format(rate: rate, depth: depth)))
            #expect(LocalRendition.inspect(url: encoded, in: folder, reportedRate: rate + 1) == .failure(.rateMismatch))
            #expect(LocalRendition.inspect(url: encoded, in: folder, reportedRate: nil) == .failure(.missingMusicRate))
            let comparison = try PCMComparison.compare(reference: reference, candidate: encoded)
            #expect(comparison.verdict == .identical)
            #expect(comparison.referenceFrames == 512)
        }
    }

    @Test func comparesFullReferenceWindowAndReportsFirstChangedSample() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("damon-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let encoded = try QualificationFixtures.writePair(to: folder, rate: 44_100, depth: 16, frames: 512)
        let reference = encoded.deletingPathExtension().appendingPathExtension("wav")
        let capture = folder.appendingPathComponent("capture.wav")
        let pcm = try Data(contentsOf: reference)
        let lead = 3
        let trailer = 4
        let stereoFrameSize = 4
        let headerSize = 44
        var recording = Data(pcm.prefix(headerSize))
        recording.append(Data(repeating: 0, count: lead * stereoFrameSize))
        recording.append(contentsOf: pcm.dropFirst(headerSize))
        recording.append(Data(repeating: 0, count: trailer * stereoFrameSize))
        func writeSize(at offset: Int, _ value: Int) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { recording.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        writeSize(at: 4, recording.count - 8)
        writeSize(at: 40, recording.count - headerSize)
        try recording.write(to: capture)
        #expect(try PCMComparison.compare(reference: reference, candidate: capture).verdict == .differentLength)
        #expect(try PCMComparison.compare(reference: reference, candidate: capture, offset: Int64(lead)).verdict == .identical)
        #expect(try PCMComparison.compare(reference: reference, candidate: capture, offset: Int64(lead + trailer + 1)).verdict == .differentLength)
        let changedFrame = 110
        recording[headerSize + (lead + changedFrame) * stereoFrameSize + 2] ^= 1
        try recording.write(to: capture)
        let comparison = try PCMComparison.compare(reference: reference, candidate: capture, offset: Int64(lead))
        #expect(comparison.verdict == .differentSample(frame: Int64(changedFrame), channel: 2))
    }

    @Test func acceptsZeroPaddedCaptureButDoesNotAuthorizeNeighboringFiles() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("damon-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let encoded = try QualificationFixtures.writePair(to: folder, rate: 44_100, depth: 16, frames: 512)
        let reference = encoded.deletingPathExtension().appendingPathExtension("wav")
        let padded = folder.appendingPathComponent("padded.wav")
        let conversion = Process()
        conversion.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        conversion.arguments = ["-f", "WAVE", "-d", "LEI32", reference.path, padded.path]
        try conversion.run()
        conversion.waitUntilExit()
        try #require(conversion.terminationStatus == 0)
        let comparison = try PCMComparison.compare(reference: reference, candidate: padded)
        #expect(comparison.verdict == .identical)
        #expect(comparison.candidateBitDepth == 32)
        #expect(LocalRendition.inspect(url: encoded, in: encoded, reportedRate: 44_100) == .success(Format(rate: 44_100, depth: 16)))
        #expect(LocalRendition.inspect(url: padded, in: encoded, reportedRate: 44_100) == .failure(.outsideApprovedFolder))
    }

    @Test func rejectsSymlinksThatLeaveAuthorizedFixtureFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("damon-test-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("approved", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let outside = try QualificationFixtures.writePair(to: root, rate: 44_100, depth: 16, frames: 512)
        let inside = folder.appendingPathComponent("linked.m4a")
        try fm.createSymbolicLink(at: inside, withDestinationURL: outside)
        #expect(LocalRendition.inspect(url: inside, in: folder, reportedRate: 44_100) == .failure(.outsideApprovedFolder))
    }

    @Test func cliConfigurationRejectsAmbiguousDevicesAndMalformedEdits() throws {
        let first = output(uid: "first", id: 17)
        let second = output(uid: "second", id: 19)
        #expect(throws: (any Error).self) {
            try DamonCLI.configurationEdits(["--device", "Test DAC"], devices: { [first, second] })
        }
        #expect(try DamonCLI.resolveDevice("second", in: [first, second]).objectID == 19)
        for options in [
            ["--show-rate", "off", "--show-rate", "on"],
            ["--auto-switch", "yes"],
            ["--local-audio", "/does-not-exist", "--clear-local-audio"]
        ] {
            #expect(throws: (any Error).self) {
                try DamonCLI.configurationEdits(options, devices: { [] })
            }
        }
    }

    @Test func sharedPreferencesPreserveLegacyScopeAndSeeExternalChanges() throws {
        let domain = "org.damon.tests.\(UUID().uuidString)"
        let legacy = try #require(UserDefaults(suiteName: domain))
        defer { legacy.removePersistentDomain(forName: domain) }
        let store = SettingsStore(domain: domain)
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        legacy.set(folder, forKey: "approvedFolder")
        #expect(try store.read().authorizedAudio?.path == folder.path)

        let edits = try DamonCLI.configurationEdits(["--device", "Test DAC", "--show-rate", "off", "--clear-local-audio"],
                                                   devices: { [output(uid: "first", id: 17)] })
        try store.apply(edits)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", domain, "showDepth", "-bool", "false"]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let updated = try store.read()
        #expect(updated.preferredOutputUID == "first")
        #expect(updated.showSampleRate == false)
        #expect(updated.showBitDepth == false)
        #expect(updated.authorizedAudio == nil)
    }

    @Test func cliCheckRequiresPlayingSourceAndAnExactRouteNotJustMatchingOutputRate() {
        let dac = output(uid: "first", id: 17)
        let playback = Playback(state: .playing, trackID: "fixture", position: nil, file: nil, reportedRate: 96_000)
        func sample(source: Format?, route: [UInt32]) -> PlaybackSample {
            PlaybackSample(outputs: [dac], playback: playback, format: source, route: route, message: "Fixture", at: 1)
        }
        let format = Format(rate: 96_000, depth: 24)
        #expect(DamonCLI.check(sample: sample(source: format, route: [17]), rate: 96_000, depth: 24,
                              uid: "first", deviceRate: 96_000).isEmpty)
        #expect(DamonCLI.check(sample: sample(source: nil, route: [17]), rate: 96_000, depth: 24,
                              uid: "first", deviceRate: 96_000).count == 2)
        #expect(DamonCLI.check(sample: sample(source: format, route: [17, 19]), rate: 96_000, depth: 24,
                              uid: "first", deviceRate: 96_000) == ["Music is not confirmed on the expected single output."])
    }

    @Test func fixtureCheckRejectsAnotherFileEvenWhenItsFormatMatches() {
        let dac = output(uid: "first", id: 17)
        let expected = URL(fileURLWithPath: "/tmp/fixture.m4a").resolvingSymlinksInPath().standardizedFileURL
        func issues(for file: URL) -> [String] {
            let playback = Playback(state: .playing, trackID: "fixture", position: nil, file: file, reportedRate: 96_000)
            let sample = PlaybackSample(outputs: [dac], playback: playback, format: Format(rate: 96_000, depth: 24),
                                        route: [17], message: "Fixture", at: 1)
            return DamonCLI.check(sample: sample, rate: 96_000, depth: 24, uid: "first", deviceRate: nil, fixture: expected)
        }
        #expect(issues(for: URL(fileURLWithPath: "/tmp/other.m4a")).count == 1)
        #expect(issues(for: expected).isEmpty)
    }

    @Test func switchTrialTimesReadbackAndDoesNotWriteForDepthOnlyChanges() {
        let (report, writes) = simulateSwitchTrial(acknowledgementDelay: 0.04, observationDelay: 0.65)
        #expect(report.passed)
        #expect(report.restored)
        #expect(report.finalRateHz == 44_100)
        #expect(writes == [96_000, 44_100])
        #expect(report.transitions.map(\.outcome) == ["switched", "switched", "alreadyMatched"])
        #expect(report.transitions.prefix(2).allSatisfy { ($0.alignmentReadbackMs ?? .infinity) < 100 })
        #expect(report.transitions.allSatisfy { ($0.requestToReadbackMs ?? .infinity) <= 2_000 })
    }

    @Test func switchTrialRejectsLateReadbackAndDoesNotRacePendingWrites() {
        let (report, writes) = simulateSwitchTrial(acknowledgementDelay: 0.55)
        #expect(!report.passed)
        #expect(!report.restored)
        #expect(writes == [96_000])
        #expect(report.transitions.first?.alignmentReadbackMs == nil)
    }

    @Test func switchTrialDoesNotWriteToAnUnconfirmedRoute() {
        let (report, writes) = simulateSwitchTrial(acknowledgementDelay: 0.04, route: [17, 19])
        #expect(!report.passed)
        #expect(report.restored)
        #expect(writes.isEmpty)
    }

    @Test func switchTrialSeparatesReadbackFromRouteReappearance() {
        let (report, writes) = simulateSwitchTrial(acknowledgementDelay: 0.04, missingRouteAfterWrite: true)
        #expect(report.passed)
        #expect(writes == [96_000, 44_100])
        #expect(report.transitions.prefix(2).allSatisfy { ($0.continuityCheckMs ?? 0) > 20 })
    }

    @Test func continuityRejectsAChangedTrackAndRouteDespiteMatchingReadback() {
        let dac = output(uid: "test", id: 17)
        let file = RateConfirmation.canonical(URL(fileURLWithPath: "/tmp/fixture.m4a"))
        let format = Format(rate: 96_000, depth: 24)
        for (trackID, route, expected) in [
            ("new track", [UInt32(17)], "changed track"),
            ("old track", [UInt32(19)], "different or multiple outputs")
        ] {
            let playback = Playback(state: .playing, trackID: trackID, position: nil, file: file, reportedRate: format.rate)
            let result = RateConfirmation.confirmContinuity(
                after: 1, device: dac, format: format, file: file, trackID: "old track",
                observe: { PlaybackSample(outputs: [dac], playback: playback, format: format, route: route, message: "Fixture", at: 1.1) },
                now: { 1.1 }, sleep: { _ in Issue.record("A definite change must not be retried.") }
            )
            guard case let .failed(message) = result else {
                Issue.record("An obsolete switch was confirmed.")
                continue
            }
            #expect(message.contains(expected))
        }
    }

    @Test func continuityDoesNotPublishMatchingSampleIfPreferencesChangedDuringObservation() {
        let dac = output(uid: "test", id: 17)
        let file = RateConfirmation.canonical(URL(fileURLWithPath: "/tmp/fixture.m4a"))
        let format = Format(rate: 96_000, depth: 24)
        var enabled = true
        let result = RateConfirmation.confirmContinuity(
            after: 1, device: dac, format: format, file: file, trackID: "track",
            observe: {
                enabled = false
                let playback = Playback(state: .playing, trackID: "track", position: nil, file: file, reportedRate: format.rate)
                return PlaybackSample(outputs: [dac], playback: playback, format: format, route: [17], message: "Fixture", at: 1.1)
            }, now: { 1.1 }, sleep: { _ in Issue.record("A preference change must end verification.") },
            stillEnabled: { enabled }
        )
        guard case let .failed(message) = result else {
            Issue.record("A switch was confirmed after its settings were invalidated.")
            return
        }
        #expect(message.contains("preferences changed"))
    }

    private func simulateSwitchTrial(
        acknowledgementDelay: TimeInterval, route: [UInt32] = [17], observationDelay: TimeInterval = 0.01,
        missingRouteAfterWrite: Bool = false
    ) -> (SwitchTrial.Report, [Int]) {
        func fixture(_ rate: Int, _ depth: Int) -> SwitchTrial.Fixture {
            SwitchTrial.Fixture(file: URL(fileURLWithPath: "/tmp/fixture-\(rate)-\(depth).m4a")
                .resolvingSymlinksInPath().standardizedFileURL, rate: rate, depth: depth)
        }
        let high = fixture(96_000, 24)
        let baseline = fixture(44_100, 16)
        let sameRate = fixture(44_100, 24)
        var time = 100.0
        var current = high
        var nominalRate = 44_100
        var pending: (rate: Int, at: TimeInterval)?
        var writes: [Int] = []
        var routeReset = false
        func device() -> OutputDevice {
            if let change = pending, time >= change.at {
                nominalRate = change.rate
                pending = nil
            }
            return OutputDevice(objectID: 17, uid: "dac", name: "Test DAC", transport: 0, nominalRate: nominalRate,
                                availableRates: [44_100...44_100, 96_000...96_000], isRateSettable: true)
        }
        let driver = SwitchTrial.Driver(
            now: { time },
            sleep: { time += $0 },
            play: { file, _ in
                current = [high, baseline, sameRate].first { $0.file == file } ?? high
                return time
            },
            observe: { _ in
                time += observationDelay
                let observedRoute = routeReset ? nil : route
                routeReset = false
                let playback = Playback(state: .playing, trackID: current.file.lastPathComponent, position: nil,
                                        file: current.file, reportedRate: current.rate)
                return PlaybackSample(outputs: [device()], playback: playback, format: Format(rate: current.rate, depth: current.depth),
                                      route: observedRoute, message: "Fixture", at: time)
            },
            write: { request, _, _ in
                writes.append(request.rate)
                pending = (request.rate, time + acknowledgementDelay)
                routeReset = missingRouteAfterWrite
                return 0
            },
            readRate: { device().nominalRate }
        )
        let report = SwitchTrial.run(device: device(), high: high, baseline: baseline, sameRate: sameRate, driver: driver)
        return (report, writes)
    }

    private func output(uid: String, id: UInt32) -> OutputDevice {
        OutputDevice(objectID: id, uid: uid, name: "Test DAC", transport: 0, nominalRate: 96_000,
                     availableRates: [96_000...96_000], isRateSettable: true)
    }
}
