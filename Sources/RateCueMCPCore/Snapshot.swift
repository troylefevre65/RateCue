import Foundation
import DamonPlatform

public enum SnapshotError: Error { case invalid, unsupportedModel }

public enum SnapshotOutput {
    private static let sources = Set(["correlation", "localHeader", "musicPanel", "musicLog", "decoderLog"])
    private static let strengths = Set(["weak", "moderate", "strong", "direct"])
    private static let null = NSNull()

    public static func make(_ s: MenuDiagnosticsSnapshot) throws -> [String: Any] {
        guard s.schemaVersion == 2,
              s.playbackState.map({ ["playing", "paused", "stopped"].contains($0) }) ?? true,
              s.rateDetectionMilliseconds.map({ $0 >= 0 }) ?? true,
              s.depthDetectionMilliseconds.map({ $0 >= 0 }) ?? true,
              ["noContext", "published", "withheldForConflict", "priorOnly",
               "belowNinetyPercentThreshold"].contains(s.publicationStatus),
              s.contributions.count <= 16, s.correlationProvenance.count <= 5,
              Set(s.correlationProvenance).count == s.correlationProvenance.count,
              s.correlationProvenance.allSatisfy({ sources.contains($0) })
        else { throw SnapshotError.invalid }

        let context = s.publicationStatus != "noContext"
        if context && s.correlationModelVersion != 2 { throw SnapshotError.unsupportedModel }
        guard (0...100).contains(s.prior16), (0...100).contains(s.prior24),
              s.prior16 + s.prior24 == 100,
              (0...100).contains(s.posterior16), (0...100).contains(s.posterior24),
              s.posterior16 + s.posterior24 == 100,
              s.unroundedProbability24.isFinite, (0...1).contains(s.unroundedProbability24),
              s.posterior24 == Int((s.unroundedProbability24 * 100).rounded()),
              s.correlatedDepth.map({ [16, 24].contains($0) }) ?? true else { throw SnapshotError.invalid }
        for c in s.contributions {
            guard c.logOddsContribution.isFinite,
                  c.likelihoodRatio.map({ $0.isFinite && $0 > 0 }) ?? true,
                  c.candidate.map({ [16, 24].contains($0) }) ?? true,
                  (c.source == "ratePrior" && c.strength == "prior")
                    || (sources.contains(c.source) && strengths.contains(c.strength) && c.candidate != nil)
            else { throw SnapshotError.invalid }
        }
        switch s.publicationStatus {
        case "noContext":
            guard s.correlatedDepth == nil, !s.evidenceAvailable, !s.correlationConflict,
                  !s.usedHighRatePrior, s.contributions.isEmpty, s.correlationProvenance.isEmpty
            else { throw SnapshotError.invalid }
        case "published":
            guard let depth = s.correlatedDepth, s.evidenceAvailable, !s.correlationConflict,
                  (depth == 24 ? s.unroundedProbability24 : 1 - s.unroundedProbability24) >= 0.9
            else { throw SnapshotError.invalid }
        case "withheldForConflict":
            guard s.correlatedDepth == nil, s.evidenceAvailable, s.correlationConflict else { throw SnapshotError.invalid }
        case "priorOnly":
            guard s.correlatedDepth == nil, !s.evidenceAvailable, !s.correlationConflict else { throw SnapshotError.invalid }
        default:
            guard s.correlatedDepth == nil, s.evidenceAvailable, !s.correlationConflict,
                  max(s.unroundedProbability24, 1 - s.unroundedProbability24) < 0.9
            else { throw SnapshotError.invalid }
        }
        if context {
            let candidates = Set(s.contributions.dropFirst().compactMap(\.candidate))
            guard s.contributions.first?.source == "ratePrior",
                  s.contributions.filter({ $0.source == "ratePrior" }).count == 1,
                  Set(s.contributions.dropFirst().map(\.source)) == Set(s.correlationProvenance),
                  s.evidenceAvailable == !s.correlationProvenance.isEmpty,
                  s.correlationConflict == (candidates.contains(16) && candidates.contains(24)),
                  s.contributions.first?.candidate == (s.prior16 == 50 ? nil : s.prior16 > 50 ? 16 : 24),
                  s.usedHighRatePrior == (s.prior16 < 50)
            else { throw SnapshotError.invalid }
        }
        let formatter = ISO8601DateFormatter()
        let contributions: [[String: Any]] = s.contributions.map {
            ["source": $0.source, "candidate": $0.candidate as Any? ?? null,
             "strength": $0.strength, "likelihoodRatio": $0.likelihoodRatio as Any? ?? null,
             "logOddsContribution": $0.logOddsContribution]
        }
        return [
            "adapterSchemaVersion": 1, "sourceSchemaVersion": 2,
            "correlationModelVersion": context ? s.correlationModelVersion as Any : null,
            "snapshotAt": formatter.string(from: s.snapshotAt),
            "playbackState": s.playbackState as Any? ?? null,
            "publicationStatus": s.publicationStatus,
            "correlatedDepth": s.correlatedDepth as Any? ?? null,
            "estimateQualification": "unverified", "scoreQualification": "uncalibrated",
            "evidenceAvailable": s.evidenceAvailable, "correlationConflict": s.correlationConflict,
            "usedHighRatePrior": context ? s.usedHighRatePrior as Any : null,
            "prior16": context ? s.prior16 as Any : null, "prior24": context ? s.prior24 as Any : null,
            "posterior16": context ? s.posterior16 as Any : null, "posterior24": context ? s.posterior24 as Any : null,
            "unroundedProbability24": context ? s.unroundedProbability24 as Any : null,
            "contributions": contributions, "provenance": context ? s.correlationProvenance as Any : null,
            "rateDetectionMilliseconds": s.rateDetectionMilliseconds as Any? ?? null,
            "depthDetectionMilliseconds": s.depthDetectionMilliseconds as Any? ?? null,
            "transitionHistory": null, "benchmarkData": null
        ]
    }

    public static var schema: [String: Any] {
        let integer: [String: Any] = ["type": ["integer", "null"], "minimum": 0]
        let percent: [String: Any] = ["type": ["integer", "null"], "minimum": 0, "maximum": 100]
        let depth: [String: Any] = ["enum": [16, 24, null]]
        let source = ["correlation", "localHeader", "musicPanel", "musicLog", "decoderLog"]
        let contribution: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["source", "candidate", "strength", "likelihoodRatio", "logOddsContribution"],
            "properties": [
                "source": ["enum": source + ["ratePrior"]], "candidate": depth,
                "strength": ["enum": ["prior", "weak", "moderate", "strong", "direct"]],
                "likelihoodRatio": ["type": ["number", "null"], "exclusiveMinimum": 0],
                "logOddsContribution": ["type": "number"]
            ]
        ]
        let properties: [String: Any] = [
            "adapterSchemaVersion": ["const": 1], "sourceSchemaVersion": ["const": 2],
            "correlationModelVersion": ["enum": [2, null]], "snapshotAt": ["type": "string", "format": "date-time"],
            "playbackState": ["enum": ["playing", "paused", "stopped", null]],
            "publicationStatus": ["enum": ["noContext", "published", "withheldForConflict", "priorOnly", "belowNinetyPercentThreshold"]],
            "correlatedDepth": depth, "estimateQualification": ["const": "unverified"],
            "scoreQualification": ["const": "uncalibrated"],
            "evidenceAvailable": ["type": "boolean"], "correlationConflict": ["type": "boolean"],
            "usedHighRatePrior": ["type": ["boolean", "null"]],
            "prior16": percent, "prior24": percent, "posterior16": percent, "posterior24": percent,
            "unroundedProbability24": ["type": ["number", "null"], "minimum": 0, "maximum": 1],
            "contributions": ["type": "array", "maxItems": 16, "items": contribution],
            "provenance": ["type": ["array", "null"], "maxItems": 5, "uniqueItems": true, "items": ["enum": source]],
            "rateDetectionMilliseconds": integer, "depthDetectionMilliseconds": integer,
            "transitionHistory": ["type": "null"], "benchmarkData": ["type": "null"]
        ]
        return ["type": "object", "additionalProperties": false,
                "required": properties.keys.sorted(), "properties": properties]
    }
}
