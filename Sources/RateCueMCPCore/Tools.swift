import Foundation
import DamonPlatform

/// The MCP tool surface. Every tool returns typed values only: no device names, paths, titles or free text.
public enum MCPToolset {
    public typealias Exchange = @Sendable (AppExchange.Action, String?, TimeInterval) throws -> Any

    private static let null = NSNull()
    private static let states = ["playing", "paused", "stopped"]
    private static let preferences = ["monitorMusic", "autoSwitch", "showSampleRate", "showBitDepth"]
    private static let commands = AppExchange.Action.playback.arguments!

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "required": properties.keys.sorted(), "properties": properties]
    }

    /// JSON true/false only; JSON numbers also bridge to Bool, so the type is checked explicitly.
    private static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func whole(_ value: Any?, _ range: ClosedRange<Int>) -> Int? {
        guard flag(value) == nil, let number = value as? Int, range.contains(number) else { return nil }
        return number
    }

    private static func settingsObject(_ settings: SettingsStore) throws -> [String: Any] {
        let value = try settings.read()
        return [
            "monitorMusic": value.monitorMusic, "autoSwitch": value.autoSwitch,
            "showSampleRate": value.showSampleRate, "showBitDepth": value.showBitDepth,
            "autoReadMusicPanel": value.autoReadMusicPanel, "cameraVerification": value.cameraVerification,
            "relayVerification": value.relayVerification,
            "preferredDeviceSelected": value.preferredOutputUID != nil,
            "localAudioAuthorized": value.authorizedAudioPath != nil
        ]
    }

    public static func diagnostics(reader: @escaping MCPServer.Reader) -> MCPTool {
        MCPTool(
            name: "ratecue_get_diagnostics",
            description: "Read the current redacted menu snapshot. Scores are uncalibrated; correlated depth is unverified. History and benchmarks are unavailable.",
            outputSchema: SnapshotOutput.schema
        ) { _, cancelled in try SnapshotOutput.make(reader(cancelled)) }
    }

    /// Read-only tools, plus control tools when the user has explicitly allowed them for this helper.
    /// Nothing here writes audio hardware; rate switching stays with RateCue's deterministic engine.
    public static func standard(
        allowControl: Bool,
        reader: @escaping MCPServer.Reader = { try MenuDiagnosticsStore.readValidated(isCancelled: $0) },
        settings: SettingsStore = SettingsStore(),
        exchange: @escaping Exchange = { try AppExchange.send($0, argument: $1, timeout: $2) }
    ) -> [MCPTool] {
        let boolean: [String: Any] = ["type": "boolean"]
        let integer: [String: Any] = ["type": ["integer", "null"], "minimum": 0]
        let outcome: [String: Any] = ["enum": ["observedByDeadline", "observedAfterDeadline", "notObservedByDeadline", "inconclusive"]]
        let settingsOutput = object(Dictionary(uniqueKeysWithValues: (preferences + [
            "autoReadMusicPanel", "cameraVerification", "relayVerification", "preferredDeviceSelected", "localAudioAuthorized"
        ]).map { ($0, boolean as Any) }))
        var tools = [
            diagnostics(reader: reader),
            MCPTool(
                name: "ratecue_get_settings",
                description: "Read RateCue's on/off preferences. Device identity and local paths are reported only as present or absent.",
                outputSchema: settingsOutput
            ) { _, _ in try settingsObject(settings) },
            MCPTool(
                name: "ratecue_get_qualification_snapshot",
                description: "Read the menu app's current observation: playback state, source rate and depth as displayed, preferred device rate and whether automatic switching is on. Unverified.",
                outputSchema: object([
                    "playbackState": ["enum": states + [null] as [Any]], "observationAgeMilliseconds": integer,
                    "sourceRateHz": integer, "sourceBitDepth": integer, "preferredDeviceRateHz": integer,
                    "autoSwitchEnabled": boolean, "activeOutputCount": ["type": "integer", "minimum": 0]
                ])
            ) { _, _ in
                guard let value = try exchange(.qualificationSnapshot, nil, 2) as? [String: Any],
                      let automatic = flag(value["autoSwitchEnabled"]) else { throw AppExchange.Failure.invalidResponse }
                let state = value["playbackState"] as? String
                return [
                    "playbackState": state.flatMap { states.contains($0) ? $0 : nil } ?? null as Any,
                    "observationAgeMilliseconds": whole(value["observationAgeMilliseconds"], 0...86_400_000) ?? null as Any,
                    "sourceRateHz": whole(value["sourceRateHz"], 1...768_000) ?? null as Any,
                    "sourceBitDepth": whole(value["sourceBitDepth"], 1...32) ?? null as Any,
                    "preferredDeviceRateHz": whole(value["preferredDeviceRateHz"], 1...768_000) ?? null as Any,
                    "autoSwitchEnabled": automatic,
                    "activeOutputCount": min((value["activeOutputs"] as? [Any])?.count ?? 0, 64)
                ]
            },
            MCPTool(
                name: "ratecue_get_first_track_assessment",
                description: "Assess the first track captured by a trace-enabled menu app: delays for reported rate, displayed depth and device alignment, observed facts, a rule-based hypothesis and a timeline. The hypothesis is consistent with the trace, not a proven cause.",
                inputSchema: [
                    "type": "object", "additionalProperties": false,
                    "properties": ["deadlineMilliseconds": ["type": "integer", "minimum": 1, "maximum": 120_000]]
                ],
                outputSchema: object([
                    "diagnosticVersion": ["const": 2], "deadlineMilliseconds": ["type": "integer"],
                    "firstPlayingEventIndex": integer, "boundaryUncertaintyMilliseconds": integer,
                    "rate": outcome, "rateDelayMilliseconds": integer,
                    "displayedDepth": outcome, "displayedDepthDelayMilliseconds": integer,
                    "deviceAligned": outcome, "deviceAlignedDelayMilliseconds": integer,
                    "findings": ["type": "array", "items": object([
                        "fact": ["type": "string"], "eventIndices": ["type": "array", "items": ["type": "integer"]]
                    ])],
                    "ruleHypothesis": ["enum": FirstTrackAssessment.Mechanism.allCases.map(\.rawValue)],
                    "timeline": ["type": "array", "maxItems": FirstTrackTimeline.maximumRows, "items": ["type": "string"]],
                    "rootCause": ["type": "null"], "independentPlaybackBoundary": ["type": "null"],
                    "logVisibilityTime": ["type": "null"]
                ]),
                timeout: 4,
                accepts: { $0.isEmpty || ($0.count == 1 && whole($0["deadlineMilliseconds"], 1...120_000) != nil) }
            ) { arguments, _ in
                let trace = try FirstTrackTrace.request(send: { try exchange($0, nil, 2) })
                let assessment = try FirstTrackAssessment.assess(
                    trace, deadlineMilliseconds: whole(arguments["deadlineMilliseconds"], 1...120_000) ?? 10_000,
                    includeTimeline: true
                )
                guard let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(assessment)) as? [String: Any]
                else { throw AppExchange.Failure.invalidResponse }
                return value
            }
        ]
        guard allowControl else { return tools }

        let capture = object(["capturing": boolean])
        tools += [
            MCPTool(
                name: "ratecue_restart_first_track_capture",
                description: "Drop the buffered first-track trace and wait for the next playback start. Affects only the diagnostic buffer.",
                outputSchema: capture, readOnly: false
            ) { _, _ in
                _ = try FirstTrackTrace.request(restart: true, send: { try exchange($0, nil, 2) })
                return ["capturing": true]
            },
            MCPTool(
                name: "ratecue_stop_first_track_capture",
                description: "Stop first-track capture and drop its buffer.",
                outputSchema: capture, readOnly: false
            ) { _, _ in
                _ = try exchange(.traceStop, nil, 2)
                return ["capturing": false]
            },
            MCPTool(
                name: "ratecue_playback",
                description: "Send one transport command to Music through the menu app. It cannot choose what plays.",
                inputSchema: [
                    "type": "object", "additionalProperties": false, "required": ["command"],
                    "properties": ["command": ["enum": commands]]
                ],
                outputSchema: object([
                    "command": ["enum": commands], "commandSent": boolean, "confirmed": boolean,
                    "playbackState": ["enum": states + ["unknown"]]
                ]),
                readOnly: false, timeout: 10,
                accepts: { $0.count == 1 && ($0["command"] as? String).map(commands.contains) == true }
            ) { arguments, _ in
                let command = arguments["command"] as! String
                guard let value = try exchange(.playback, command, 8) as? [String: Any],
                      let sent = flag(value["commandSent"]), let confirmed = flag(value["confirmed"])
                else { throw AppExchange.Failure.invalidResponse }
                let state = value["playbackState"] as? String
                return ["command": command, "commandSent": sent, "confirmed": confirmed,
                        "playbackState": state.flatMap { states.contains($0) ? $0 : nil } ?? "unknown"]
            },
            MCPTool(
                name: "ratecue_set_preference",
                description: "Turn one RateCue on/off preference on or off. Turning autoSwitch on lets RateCue's own qualified engine change the device rate; this tool never writes hardware itself.",
                inputSchema: [
                    "type": "object", "additionalProperties": false, "required": ["name", "enabled"],
                    "properties": ["name": ["enum": preferences], "enabled": boolean]
                ],
                outputSchema: settingsOutput, readOnly: false,
                accepts: {
                    $0.count == 2 && ($0["name"] as? String).map(preferences.contains) == true
                        && flag($0["enabled"]) != nil
                }
            ) { arguments, _ in
                let on = flag(arguments["enabled"])!
                let edit: SettingEdit = switch arguments["name"] as! String {
                case "monitorMusic": .monitorMusic(on)
                case "autoSwitch": .autoSwitch(on)
                case "showSampleRate": .showSampleRate(on)
                default: .showBitDepth(on)
                }
                try settings.apply([edit])
                return try settingsObject(settings)
            }
        ]
        return tools
    }
}
