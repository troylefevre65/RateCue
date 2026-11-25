import Foundation

public struct MenuDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public struct Contribution: Codable, Equatable, Sendable {
        public let source: String
        public let candidate: Int?
        public let strength: String
        public let likelihoodRatio: Double?
        public let logOddsContribution: Double

        public init(
            source: String, candidate: Int?, strength: String,
            likelihoodRatio: Double?, logOddsContribution: Double
        ) {
            self.source = source
            self.candidate = candidate
            self.strength = strength
            self.likelihoodRatio = likelihoodRatio
            self.logOddsContribution = logOddsContribution
        }
    }

    public let schemaVersion: Int
    public let correlationModelVersion: Int
    public let snapshotAt: Date
    public let processIdentifier: Int32
    public let menuTitle: String
    public let certainty: String
    public let correlationScore: Int
    public let posterior16: Int
    public let posterior24: Int
    public let evidenceAvailable: Bool
    public let prior16: Int
    public let prior24: Int
    public let unroundedProbability24: Double
    public let contributions: [Contribution]
    public let correlatedDepth: Int?
    public let mostLikelyDepth: Int
    public let publicationStatus: String
    public let correlationConflict: Bool
    public let usedHighRatePrior: Bool
    public let correlationProvenance: [String]
    public let playbackState: String?
    public let automaticPanelStatus: String?
    public let logEvidenceStatus: String
    public let rateDetectionMilliseconds: Int?
    public let depthDetectionMilliseconds: Int?

    public init(
        snapshotAt: Date, processIdentifier: Int32, menuTitle: String, certainty: String,
        correlationScore: Int, correlatedDepth: Int?, correlationConflict: Bool,
        usedHighRatePrior: Bool, correlationProvenance: [String], playbackState: String?,
        automaticPanelStatus: String?, logEvidenceStatus: String = "Not attempted", mostLikelyDepth: Int = 16,
        publicationStatus: String = "priorOnly", posterior16: Int = 50, posterior24: Int = 50,
        evidenceAvailable: Bool = false, correlationModelVersion: Int = 1,
        prior16: Int = 50, prior24: Int = 50, unroundedProbability24: Double = 0.5,
        contributions: [Contribution] = [], rateDetectionMilliseconds: Int? = nil,
        depthDetectionMilliseconds: Int? = nil
    ) {
        self.schemaVersion = 2
        self.correlationModelVersion = correlationModelVersion
        self.snapshotAt = snapshotAt
        self.processIdentifier = processIdentifier
        self.menuTitle = menuTitle
        self.certainty = certainty
        self.correlationScore = correlationScore
        self.posterior16 = posterior16
        self.posterior24 = posterior24
        self.evidenceAvailable = evidenceAvailable
        self.prior16 = prior16
        self.prior24 = prior24
        self.unroundedProbability24 = unroundedProbability24
        self.contributions = contributions
        self.correlatedDepth = correlatedDepth
        self.mostLikelyDepth = mostLikelyDepth
        self.publicationStatus = publicationStatus
        self.correlationConflict = correlationConflict
        self.usedHighRatePrior = usedHighRatePrior
        self.correlationProvenance = correlationProvenance
        self.playbackState = playbackState
        self.automaticPanelStatus = automaticPanelStatus
        self.logEvidenceStatus = logEvidenceStatus
        self.rateDetectionMilliseconds = rateDetectionMilliseconds
        self.depthDetectionMilliseconds = depthDetectionMilliseconds
    }
}

public struct MenuDiagnosticsStore: Sendable {
    private let directory: URL

    public init(
        directory: URL? = nil
    ) {
        if let directory {
            self.directory = directory
        } else if let override = ProcessInfo.processInfo.environment["RATECUE_DIAGNOSTICS_DIR"],
                  !override.isEmpty {
            self.directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.directory = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("RateCue", isDirectory: true)
        }
    }

    public var url: URL { directory.appendingPathComponent("menu-status.json") }

    public func write(_ snapshot: MenuDiagnosticsSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public func read() throws -> MenuDiagnosticsSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MenuDiagnosticsSnapshot.self, from: Data(contentsOf: url))
    }
}
