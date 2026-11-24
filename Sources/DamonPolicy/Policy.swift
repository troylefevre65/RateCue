import Foundation

public struct Epoch: Equatable, Sendable {
    public let playback: UInt64
    public let route: UInt64

    public init(playback: UInt64, route: UInt64) {
        self.playback = playback
        self.route = route
    }
}

public struct Format: Equatable, Sendable {
    public let rate: Int?
    public let depth: Int?

    public init(rate: Int? = nil, depth: Int? = nil) {
        self.rate = rate
        self.depth = depth
    }

    public func label(showRate: Bool, showDepth: Bool) -> String {
        let rateText = rate.map { "\(Decimal($0) / 1000)k" } ?? "—"
        let depthText = depth.map(String.init) ?? "—"
        return [(showRate, rateText), (showDepth, depthText)].compactMap { $0 ? $1 : nil }.joined(separator: " / ")
    }
}

public enum EvidenceSource: Int, Sendable {
    case sourceStream = 1, musicMetadata, dacLED, relay
}

public struct Evidence: Sendable {
    public let epoch: Epoch
    public let source: EvidenceSource
    public let at: TimeInterval
    public let format: Format

    public init(epoch: Epoch, source: EvidenceSource, at: TimeInterval, format: Format) {
        self.epoch = epoch
        self.source = source
        self.at = at
        self.format = format
    }
}

public struct Resolution: Equatable, Sendable {
    public let format: Format
    public let rateConflict: Bool
    public let depthConflict: Bool
    public let lowerTierDisagrees: Bool
}

public enum Confidence {
    public static func resolve(_ observations: [Evidence], epoch: Epoch, since: TimeInterval, now: TimeInterval) -> Resolution {
        let current = observations.filter {
            $0.epoch == epoch && $0.at >= since && $0.at <= now
                && ($0.source == .sourceStream || $0.source == .musicMetadata)
        }
        func decide(_ field: KeyPath<Format, Int?>, using evidence: [Evidence]) -> (Int?, Bool, Bool) {
            let values = evidence.compactMap { item in
                item.format[keyPath: field].flatMap { $0 > 0 ? ($0, item.source.rawValue) : nil }
            }
            guard let rank = values.map(\.1).min() else { return (nil, false, false) }
            let highest = Set(values.filter { $0.1 == rank }.map(\.0))
            guard highest.count == 1, let value = highest.first else { return (nil, true, false) }
            return (value, false, values.contains { $0.1 > rank && $0.0 != value })
        }
        let (rate, rateConflict, rateDisagreement) = decide(\.rate, using: current)
        let applicableDepth = current.filter { item in
            item.format.rate == nil || (!rateConflict && (rate == nil || item.format.rate == rate))
        }
        let (depth, depthConflict, depthDisagreement) = decide(\.depth, using: applicableDepth)
        return Resolution(
            format: Format(rate: rate, depth: depth), rateConflict: rateConflict, depthConflict: depthConflict,
            lowerTierDisagrees: rateDisagreement || depthDisagreement
        )
    }
}

public struct DepthContext: Equatable, Sendable {
    public let epoch: Epoch
    public let trackID: String
    public let routeID: String

    public init(epoch: Epoch, trackID: String, routeID: String) {
        self.epoch = epoch
        self.trackID = trackID
        self.routeID = routeID
    }
}

public enum DepthCandidate: Int, Equatable, Hashable, Sendable, CaseIterable {
    case bit16 = 16
    case bit24 = 24
}

public enum DepthEvidenceSource: String, Equatable, Hashable, Sendable {
    case correlation
    case localHeader
    case musicPanel
    case musicLog
    case decoderLog

    fileprivate var independenceFamily: String {
        switch self {
        case .musicPanel, .musicLog, .decoderLog: "music"
        case .localHeader: "localAsset"
        case .correlation: "correlation"
        }
    }
}

public enum DepthEvidenceStrength: Int, Sendable {
    case weak = 2
    case moderate = 4
    case strong = 9
    case direct = 36
}

public struct DepthContribution: Equatable, Sendable {
    public let source: String
    public let candidate: DepthCandidate?
    public let strength: String
    public let likelihoodRatio: Double?
    public let logOddsContribution: Double

    public init(
        source: String, candidate: DepthCandidate?, strength: String,
        likelihoodRatio: Double?, logOddsContribution: Double
    ) {
        self.source = source
        self.candidate = candidate
        self.strength = strength
        self.likelihoodRatio = likelihoodRatio
        self.logOddsContribution = logOddsContribution
    }
}

public struct DepthObservation: Sendable {
    public let context: DepthContext
    public let at: TimeInterval
    public let source: DepthEvidenceSource
    public let candidate: DepthCandidate
    public let strength: DepthEvidenceStrength
    public let persistsForContext: Bool

    public init(
        context: DepthContext, at: TimeInterval, source: DepthEvidenceSource,
        candidate: DepthCandidate, strength: DepthEvidenceStrength, persistsForContext: Bool = false
    ) {
        self.context = context
        self.at = at
        self.source = source
        self.candidate = candidate
        self.strength = strength
        self.persistsForContext = persistsForContext
    }
}

public struct DepthResolution: Equatable, Sendable {
    public let candidate: DepthCandidate?
    public let score: Int
    public let posterior16: Int
    public let posterior24: Int
    public let evidenceAvailable: Bool
    public let conflict: Bool
    public let usedHighRatePrior: Bool
    public let provenance: [DepthEvidenceSource]
    public let modelVersion: Int
    public let prior16: Int
    public let prior24: Int
    public let unroundedProbability24: Double
    public let contributions: [DepthContribution]

    public init(
        candidate: DepthCandidate?, score: Int, conflict: Bool,
        usedHighRatePrior: Bool, provenance: [DepthEvidenceSource],
        posterior16: Int = 50, posterior24: Int = 50, evidenceAvailable: Bool = false,
        modelVersion: Int = 1, prior16: Int = 50, prior24: Int = 50,
        unroundedProbability24: Double = 0.5, contributions: [DepthContribution] = []
    ) {
        self.candidate = candidate
        self.score = score
        self.posterior16 = posterior16
        self.posterior24 = posterior24
        self.evidenceAvailable = evidenceAvailable
        self.conflict = conflict
        self.usedHighRatePrior = usedHighRatePrior
        self.provenance = provenance
        self.modelVersion = modelVersion
        self.prior16 = prior16
        self.prior24 = prior24
        self.unroundedProbability24 = unroundedProbability24
        self.contributions = contributions
    }
}

public struct BitDepthCorrelationEngine: Sendable {
    public let capacity: Int
    public let freshness: TimeInterval
    private var observations: [DepthObservation] = []

    public init(capacity: Int = 16, freshness: TimeInterval = 2) {
        self.capacity = max(1, capacity)
        self.freshness = max(0.1, freshness)
    }

    public mutating func observe(_ observation: DepthObservation) {
        guard !observation.context.trackID.isEmpty,
              !observation.context.routeID.isEmpty,
              observation.at.isFinite else { return }
        if let latest = observations.filter({
            $0.context == observation.context && $0.source == observation.source
        }).map(\.at).max(), latest > observation.at {
            return
        }
        if observation.persistsForContext {
            observations.removeAll { $0.context != observation.context }
        }
        observations.removeAll { $0.context == observation.context && $0.source == observation.source }
        observations.append(observation)
        if observations.count > capacity {
            var excess = observations.count - capacity
            observations = observations.filter { item in
                guard excess > 0, !item.persistsForContext else { return true }
                excess -= 1
                return false
            }
        }
    }

    public func resolve(context: DepthContext, rateHz: Int?, now: TimeInterval) -> DepthResolution {
        guard now.isFinite else {
            return DepthResolution(
                candidate: nil, score: 50, conflict: false, usedHighRatePrior: false, provenance: []
            )
        }
        let current = observations.filter {
            $0.context == context && $0.at <= now
                && ($0.persistsForContext || $0.at >= now - freshness)
        }
        let prior = switch rateHz {
        case 44_100: 70
        case 88_200, 96_000, 176_400: 30
        case 192_000: 5
        default: 50
        }
        let usedHighRatePrior = prior < 50
        var logOdds24 = log(Double(100 - prior) / Double(prior))
        var contributions = [DepthContribution(
            source: "ratePrior",
            candidate: prior == 50 ? nil : prior == 70 ? .bit16 : .bit24,
            strength: "prior",
            likelihoodRatio: Double(100 - prior) / Double(prior),
            logOddsContribution: logOdds24
        )]
        var sources: [DepthCandidate: [DepthEvidenceSource: DepthEvidenceStrength]] = [.bit16: [:], .bit24: [:]]
        for observation in current {
            var candidateSources = sources[observation.candidate] ?? [:]
            if let existing = candidateSources[observation.source] {
                candidateSources[observation.source] = DepthEvidenceStrength(
                    rawValue: max(existing.rawValue, observation.strength.rawValue)
                )
            } else {
                candidateSources[observation.source] = observation.strength
            }
            sources[observation.candidate] = candidateSources
        }
        let flattenedSources = DepthCandidate.allCases.flatMap { candidate in
            (sources[candidate] ?? [:]).map { (candidate, $0.key, $0.value) }
        }
        let strongestByFamily = Dictionary(grouping: flattenedSources, by: { $0.1.independenceFamily })
            .compactMapValues {
                $0.max { lhs, rhs in
                    if lhs.2.rawValue == rhs.2.rawValue {
                        return lhs.1.rawValue > rhs.1.rawValue
                    }
                    return lhs.2.rawValue < rhs.2.rawValue
                }
            }
        for candidate in DepthCandidate.allCases {
            let candidateSources = (sources[candidate] ?? [:]).sorted(by: { $0.key.rawValue < $1.key.rawValue })
            for (source, strength) in candidateSources {
                let ratio = Double(strength.rawValue)
                let strongest = strongestByFamily[source.independenceFamily]
                let selected = strongest?.0 == candidate && strongest?.1 == source
                let contribution = selected ? log(ratio) * (candidate == .bit24 ? 1 : -1) : 0
                if selected {
                    logOdds24 += contribution
                }
                contributions.append(DepthContribution(
                    source: source.rawValue, candidate: candidate, strength: String(describing: strength),
                    likelihoodRatio: ratio, logOddsContribution: contribution
                ))
            }
        }
        let probability24 = 1 / (1 + exp(-logOdds24))
        let posterior24 = max(0, min(100, Int((probability24 * 100).rounded())))
        let posterior16 = 100 - posterior24
        let evidenceAvailable = !current.isEmpty
        let conflict = (sources[.bit16]?.isEmpty == false) && (sources[.bit24]?.isEmpty == false)
        let canPublish = evidenceAvailable && !conflict
        let candidate: DepthCandidate? = if canPublish, probability24 >= 0.9 {
            .bit24
        } else if canPublish, (1 - probability24) >= 0.9 {
            .bit16
        } else {
            nil
        }
        let provenance = Array(Set(
            DepthCandidate.allCases.flatMap { candidate in
                sources[candidate]?.keys.map { $0 } ?? []
            }
        )).sorted { $0.rawValue < $1.rawValue }
        return DepthResolution(
            candidate: candidate,
            score: candidate == .bit16 ? posterior16 : candidate == .bit24 ? posterior24 : max(posterior16, posterior24),
            conflict: conflict, usedHighRatePrior: usedHighRatePrior, provenance: provenance,
            posterior16: posterior16, posterior24: posterior24, evidenceAvailable: evidenceAvailable,
            modelVersion: 2, prior16: prior, prior24: 100 - prior,
            unroundedProbability24: probability24, contributions: contributions
        )
    }
}

public struct AlignmentInput: Sendable {
    public let epoch: Epoch
    public let playbackBoundary: TimeInterval
    public let playing: Bool
    public let enabled: Bool
    public let devicePresent: Bool
    public let preferredIsConfirmedRoute: Bool
    public let qualified: Bool
    public let supportsTarget: Bool
    public let target: Int?
    public let readback: Int?
    public let endpoint: String?
    public let observedEndpoints: [String: Int?]?

    public init(
        epoch: Epoch, playbackBoundary: TimeInterval, playing: Bool, enabled: Bool, devicePresent: Bool,
        preferredIsConfirmedRoute: Bool, qualified: Bool, supportsTarget: Bool, target: Int?, readback: Int?,
        endpoint: String?, observedEndpoints: [String: Int?]?
    ) {
        self.epoch = epoch
        self.playbackBoundary = playbackBoundary
        self.playing = playing
        self.enabled = enabled
        self.devicePresent = devicePresent
        self.preferredIsConfirmedRoute = preferredIsConfirmedRoute
        self.qualified = qualified
        self.supportsTarget = supportsTarget
        self.target = target
        self.readback = readback
        self.endpoint = endpoint
        self.observedEndpoints = observedEndpoints
    }
}

public struct WriteRequest: Equatable, Sendable {
    public let epoch: Epoch
    public let rate: Int
    public let requestedAt: TimeInterval
    public let deadline: TimeInterval
    public let attempt: Int
    public let endpoint: String
}

public enum WriteDisposition: Sendable {
    case submitted, transientFailure, failed
}

public enum AlignmentState: String, Equatable, Sendable {
    case idle = "Waiting for Music"
    case unavailable = "Preferred device unavailable"
    case unknown = "Unknown Format"
    case unsupportedRoute = "Music output route not confirmed"
    case monitorOnly = "Monitor only — configuration not qualified"
    case unsupportedRate = "Exact rate unavailable or read-only"
    case unavailableReadback = "Unable to read device configuration"
    case off = "Auto Switch is off"
    case aligning = "Aligning device"
    case aligned = "Device aligned"
    case failed = "Alignment failed"
    case drift = "Device rate changed externally"
}

public struct AlignmentMachine: Sendable {
    public private(set) var state: AlignmentState = .idle
    public private(set) var confirmedWrite: WriteRequest?
    private var epoch: Epoch?
    private var target: Int?
    private var flight: WriteRequest?
    private var result: WriteDisposition?
    private var attempts = 0
    private var deadline: TimeInterval?
    private var wasAligned = false
    private var exhausted = false

    public init() {}

    public mutating func receive(_ disposition: WriteDisposition, for request: WriteRequest) {
        guard request == flight, result == nil else { return }
        result = disposition
    }

    public mutating func step(_ input: AlignmentInput, now: TimeInterval) -> WriteRequest? {
        confirmedWrite = nil
        if epoch != input.epoch || target != input.target {
            epoch = input.epoch
            target = input.target
            attempts = 0
            deadline = nil
            wasAligned = false
            exhausted = false
        }
        if let request = flight {
            let latestRate = input.observedEndpoints?[request.endpoint] ?? nil
            let deviceGone = input.observedEndpoints.map { !$0.keys.contains(request.endpoint) } ?? false
            let settled = result.map { $0 != .submitted } == true
                || (result == .submitted && (deviceGone || latestRate == request.rate))
            // A timeout is not a HAL acknowledgement. Do not race a possibly late write.
            guard settled else {
                state = !input.devicePresent ? .unavailable : now >= request.deadline ? .failed : .aligning
                return nil
            }
            let outcome = result
            flight = nil
            result = nil
            if request.epoch == input.epoch, request.rate == input.target, request.endpoint == input.endpoint {
                if outcome == .submitted, input.playing, input.enabled, input.preferredIsConfirmedRoute,
                   input.readback == request.rate, now <= request.deadline {
                    confirmedWrite = request
                } else if outcome != .transientFailure {
                    exhausted = true
                }
            }
        }
        guard input.devicePresent else { state = .unavailable; return nil }
        guard input.playing else { state = .idle; return nil }
        guard let rate = input.target else { state = .unknown; return nil }
        guard input.preferredIsConfirmedRoute else { state = .unsupportedRoute; return nil }
        guard let readback = input.readback, let endpoint = input.endpoint else { state = .unavailableReadback; return nil }
        if rate == readback { state = .aligned; wasAligned = true; return nil }
        guard !wasAligned else { state = .drift; return nil }
        guard input.enabled else { state = .off; return nil }
        guard input.qualified else { state = .monitorOnly; return nil }
        guard input.supportsTarget else { state = .unsupportedRate; return nil }
        let limit = deadline ?? min(now + 0.5, input.playbackBoundary + 2)
        guard !exhausted, attempts < 2, now < limit else { state = .failed; return nil }
        deadline = limit
        attempts += 1
        let request = WriteRequest(epoch: input.epoch, rate: rate, requestedAt: now, deadline: limit, attempt: attempts,
                                   endpoint: endpoint)
        flight = request
        state = .aligning
        return request
    }
}

public struct LEDReading: Sendable {
    public let epoch: Epoch
    public let at: TimeInterval
    public let rate: Int
    public let lockedAndStable: Bool
    public let confidence: Double

    public init(epoch: Epoch, at: TimeInterval, rate: Int, lockedAndStable: Bool, confidence: Double) {
        self.epoch = epoch
        self.at = at
        self.rate = rate
        self.lockedAndStable = lockedAndStable
        self.confidence = confidence
    }
}

public struct RelayReading: Sendable {
    public let epoch: Epoch
    public let at: TimeInterval

    public init(epoch: Epoch, at: TimeInterval) {
        self.epoch = epoch
        self.at = at
    }
}

public enum VerificationState: String, Equatable, Sendable {
    case pending = "Awaiting hardware evidence"
    case incomplete = "Verification incomplete"
    case failed = "Verification failed"
    case dacRateConfirmed = "DAC rate confirmed"
    case transitionVerified = "Transition verified"
}

public struct TransitionVerification: Sendable {
    public let epoch: Epoch
    public let rate: Int
    public let confirmedAt: TimeInterval
    public let trackChanged: Bool
    public let writeStarted: TimeInterval?

    public init(epoch: Epoch, rate: Int, confirmedAt: TimeInterval, trackChanged: Bool, writeStarted: TimeInterval?) {
        self.epoch = epoch
        self.rate = rate
        self.confirmedAt = confirmedAt
        self.trackChanged = trackChanged
        self.writeStarted = writeStarted
    }

    public func evaluate(led: [LEDReading], relay: [RelayReading], now: TimeInterval) -> VerificationState {
        let deadline = confirmedAt + 2
        let end = min(deadline, now)
        guard end >= confirmedAt else { return .pending }
        let validLED = led.filter {
            $0.epoch == epoch && (confirmedAt...end).contains($0.at) && $0.lockedAndStable
                && $0.confidence > 0.95 && $0.confidence <= 1
        }
        if validLED.contains(where: { $0.rate != rate }) { return .failed }
        if validLED.contains(where: { $0.rate == rate }) {
            if trackChanged, let writeStarted, relay.contains(where: {
                $0.epoch == epoch && $0.at >= writeStarted && $0.at <= end
            }) { return .transitionVerified }
            return .dacRateConfirmed
        }
        return now < deadline ? .pending : .incomplete
    }
}
