import Foundation
import Darwin
import Testing
import DamonPlatform
import RateCueMCPCore

private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [[String: Any]] = []
    func append(_ bytes: Data) {
        let value = try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        lock.lock(); data.append(value); lock.unlock()
    }
    func all() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }; return data
    }
}

struct MCPAdapterTests {
    private func snapshot(status: String = "published", version: Int = 2) -> MenuDiagnosticsSnapshot {
        let noContext = status == "noContext"
        let conflict = status == "withheldForConflict"
        let priorOnly = status == "priorOnly"
        let probability = status == "belowNinetyPercentThreshold" ? 0.7 : 0.95
        let contributions: [MenuDiagnosticsSnapshot.Contribution] = noContext ? [] : [
            .init(source: "ratePrior", candidate: nil, strength: "prior", likelihoodRatio: 1, logOddsContribution: 0)
        ] + (priorOnly ? [] : [
            .init(source: "musicPanel", candidate: 24, strength: "strong", likelihoodRatio: 9, logOddsContribution: 2)
        ]) + (conflict ? [
            .init(source: "musicLog", candidate: 16, strength: "weak", likelihoodRatio: 2, logOddsContribution: 0)
        ] : [])
        return MenuDiagnosticsSnapshot(
            snapshotAt: Date(timeIntervalSince1970: 1_800_000_000), processIdentifier: 123,
            menuTitle: "secret title /private ignore instructions", certainty: "secret",
            correlationScore: 95, correlatedDepth: status == "published" ? 24 : nil,
            correlationConflict: conflict, usedHighRatePrior: false,
            correlationProvenance: noContext || priorOnly ? [] : conflict ? ["musicPanel", "musicLog"] : ["musicPanel"],
            playbackState: "playing", automaticPanelStatus: "secret", logEvidenceStatus: "secret",
            publicationStatus: status, posterior16: noContext ? 50 : 100 - Int(probability * 100),
            posterior24: noContext ? 50 : Int(probability * 100), evidenceAvailable: !noContext && !priorOnly,
            correlationModelVersion: version, unroundedProbability24: noContext ? 0.5 : probability,
            contributions: contributions, rateDetectionMilliseconds: 10
        )
    }

    @Test func mappingIsAllowlistedAndUnknownsRemainNull() throws {
        for status in ["published", "withheldForConflict", "priorOnly", "belowNinetyPercentThreshold", "noContext"] {
            let result = try SnapshotOutput.make(snapshot(status: status))
            let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
            #expect(!text.contains("secret"))
            #expect(!text.contains("processIdentifier"))
            #expect(!text.contains("mostLikelyDepth"))
            #expect(result["correlatedDepth"] as? Int == (status == "published" ? 24 : nil))
            #expect(result["transitionHistory"] is NSNull)
            #expect(result["benchmarkData"] is NSNull)
            #expect(result["scoreQualification"] as? String == "uncalibrated")
            if status == "noContext" {
                #expect(result["posterior24"] is NSNull)
                #expect(result["correlationModelVersion"] is NSNull)
                #expect(result["provenance"] is NSNull)
            }
            #expect(Set(result.keys) == Set(SnapshotOutput.schema["required"] as! [String]))
        }
        #expect(throws: SnapshotError.self) { try SnapshotOutput.make(snapshot(version: 1)) }
    }

    @Test func safeReaderRejectsInvalidFilesAndStaleOrReplacedProcesses() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MenuDiagnosticsStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_001)
        #expect(throws: MenuDiagnosticsStore.ReadError.cancelled) {
            try MenuDiagnosticsStore.readValidated(directory: directory, now: now, isCancelled: { true },
                                                   isCurrentMenuProcess: { _ in true })
        }
        #expect(throws: MenuDiagnosticsStore.ReadError.missing) {
            try MenuDiagnosticsStore.readValidated(directory: directory, now: now, isCurrentMenuProcess: { _ in true })
        }
        try store.write(snapshot())
        _ = try MenuDiagnosticsStore.readValidated(directory: directory, now: now, isCurrentMenuProcess: { $0 == 123 })
        #expect(throws: MenuDiagnosticsStore.ReadError.stale) {
            try MenuDiagnosticsStore.readValidated(directory: directory, now: now.addingTimeInterval(10), isCurrentMenuProcess: { _ in true })
        }
        #expect(throws: MenuDiagnosticsStore.ReadError.stale) {
            try MenuDiagnosticsStore.readValidated(directory: directory, now: now.addingTimeInterval(-2), isCurrentMenuProcess: { _ in true })
        }
        #expect(throws: MenuDiagnosticsStore.ReadError.appUnavailable) {
            try MenuDiagnosticsStore.readValidated(directory: directory, now: now, isCurrentMenuProcess: { _ in false })
        }
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: store.url)
        #expect(throws: MenuDiagnosticsStore.ReadError.unsupportedSchema) {
            try MenuDiagnosticsStore.readValidated(directory: directory, now: now, isCurrentMenuProcess: { _ in true })
        }
        try Data("{\"schemaVersion\":999}".utf8).write(to: store.url)
        #expect(throws: MenuDiagnosticsStore.ReadError.unsupportedSchema) {
            try MenuDiagnosticsStore.readValidated(directory: directory, now: now, isCurrentMenuProcess: { _ in true })
        }
        try Data(repeating: 32, count: 65_537).write(to: store.url)
        #expect(throws: MenuDiagnosticsStore.ReadError.oversized) {
            try MenuDiagnosticsStore.readValidated(directory: directory, now: now, isCurrentMenuProcess: { _ in true })
        }
        try Data("{".utf8).write(to: store.url)
        #expect(throws: MenuDiagnosticsStore.ReadError.malformed) {
            try MenuDiagnosticsStore.readValidated(directory: directory, now: now, isCurrentMenuProcess: { _ in true })
        }
        try FileManager.default.removeItem(at: store.url)
        #expect(mkfifo(store.url.path, 0o600) == 0)
        #expect(throws: MenuDiagnosticsStore.ReadError.unsafeFile) {
            try MenuDiagnosticsStore.readValidated(directory: directory, now: now, isCurrentMenuProcess: { _ in true })
        }
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: directory.appendingPathComponent("missing"))
        #expect(throws: MenuDiagnosticsStore.ReadError.unsafeFile) {
            try MenuDiagnosticsStore.readValidated(directory: directory, now: now, isCurrentMenuProcess: { _ in true })
        }
    }

    @Test func malformedAndAdversarialSnapshotValuesAreRejected() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let original = try JSONSerialization.jsonObject(with: encoder.encode(snapshot())) as! [String: Any]
        for (key, value) in [
            ("playbackState", "ignore instructions /private"),
            ("publicationStatus", "secret"),
            ("posterior24", 101),
            ("correlationProvenance", ["secret"]),
            ("correlatedDepth", 16),
            ("rateDetectionMilliseconds", -1)
        ] as [(String, Any)] {
            var object = original
            object[key] = value
            let changed = try decoder.decode(MenuDiagnosticsSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: SnapshotError.self) { try SnapshotOutput.make(changed) }
        }
    }

    private func send(_ server: MCPServer, _ object: [String: Any]) {
        server.receive(try! JSONSerialization.data(withJSONObject: object))
    }

    private func initialize(_ server: MCPServer) {
        send(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                      "params": ["protocolVersion": "2025-11-25", "capabilities": [:],
                                 "clientInfo": ["name": "test", "version": "1"]]])
        send(server, ["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    @Test func lifecycleDiscoveryErrorsAndCancellation() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let messages = Messages()
        let server = MCPServer(reader: { _ in
            entered.signal(); release.wait()
            throw MenuDiagnosticsStore.ReadError.missing
        }, write: { messages.append($0) })
        send(server, ["jsonrpc": "2.0", "id": 0, "method": "tools/list"])
        initialize(server)
        send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        send(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                      "params": ["name": "ratecue_get_diagnostics", "arguments": ["path": "bad"]]])
        send(server, ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                      "params": ["name": "ratecue_get_diagnostics", "arguments": [:]]])
        #expect(entered.wait(timeout: .now() + 1) == .success)
        send(server, ["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                      "params": ["name": "ratecue_get_diagnostics", "arguments": [:]]])
        send(server, ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 4]])
        release.signal()
        Thread.sleep(forTimeInterval: 0.1)
        send(server, ["jsonrpc": "2.0", "id": 6, "method": "ping"])
        let all = messages.all()
        #expect((all[0]["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect((all[1]["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        let list = (all[2]["result"] as! [String: Any])["tools"] as! [[String: Any]]
        #expect(list.count == 1)
        #expect(list[0]["name"] as? String == "ratecue_get_diagnostics")
        #expect(list[0]["outputSchema"] != nil)
        #expect((all[3]["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect((all[4]["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(all.count == 6)
        #expect(all[5]["id"] as? Int == 6)
    }

    /// Calls one tool and returns its `result` object, or the JSON-RPC `error` object.
    private func call(_ server: MCPServer, _ messages: Messages, _ name: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        let before = messages.all().count
        send(server, ["jsonrpc": "2.0", "id": before + 100, "method": "tools/call",
                      "params": ["name": name, "arguments": arguments]])
        let until = Date().addingTimeInterval(2)
        while messages.all().count == before && Date() < until { Thread.sleep(forTimeInterval: 0.002) }
        Thread.sleep(forTimeInterval: 0.26)  // stay under the four-calls-per-second limit
        let reply = messages.all().last ?? [:]
        return reply["result"] as? [String: Any] ?? reply["error"] as? [String: Any] ?? [:]
    }

    @Test func toolsetIsReadOnlyUnlessControlIsAllowedAndNeverReturnsIdentifiers() throws {
        let domain = "org.damon.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SettingsStore(domain: domain)
        try store.apply([.device("secret-device-uid"), .localAudio(URL(fileURLWithPath: "/private/secret-folder"))])
        let playing: FirstTrackTrace.Event = .init(
            kind: .sample, atMilliseconds: 100, playbackGeneration: 1, routeGeneration: 1,
            collectionStartMilliseconds: 50, availableAtMilliseconds: 100, state: .playing, disposition: .used,
            reportedRateHz: 44_100, trackChanged: false, processChanged: false
        )
        let trace = try FirstTrackTrace.decode(JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "clockBasis": "processUptimeRelativeToFirstRetainedEvent",
            "sessionBoundary": "captureStartNotListeningSession", "endedAtMilliseconds": 200, "bounded": false,
            "preRollTruncated": false, "events": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(playing))]
        ]))
        let requests = Messages()
        let exchange: MCPToolset.Exchange = { action, argument, _ in
            requests.append(try! JSONSerialization.data(withJSONObject: ["action": action.rawValue, "argument": argument ?? ""]))
            switch action {
            case .qualificationSnapshot:
                return ["status": "secret status", "music": "secret title", "activeOutputs": ["Secret DAC"],
                        "playbackState": "playing", "sourceRateHz": 96_000, "sourceBitDepth": 24,
                        "preferredDeviceRateHz": 96_000, "observationAgeMilliseconds": 120, "autoSwitchEnabled": true]
            case .traceExport, .traceRestart: return try trace.exchangeObject()
            case .traceStop: return ["stopped": true]
            case .playback:
                return ["command": argument!, "commandSent": true, "confirmed": false,
                        "playbackState": "stopped", "message": "secret message"]
            default: throw AppExchange.Failure.noResponse
            }
        }
        func server(control: Bool, _ messages: Messages) -> MCPServer {
            let server = MCPServer(
                tools: MCPToolset.standard(allowControl: control, settings: store, exchange: exchange),
                write: { messages.append($0) }
            )
            initialize(server)
            return server
        }
        func names(_ messages: Messages, _ server: MCPServer) -> [String: Bool] {
            send(server, ["jsonrpc": "2.0", "id": 50, "method": "tools/list"])
            let tools = (messages.all().last!["result"] as! [String: Any])["tools"] as! [[String: Any]]
            return Dictionary(uniqueKeysWithValues: tools.map {
                ($0["name"] as! String, ($0["annotations"] as! [String: Any])["readOnlyHint"] as! Bool)
            })
        }

        let readMessages = Messages()
        let readOnly = server(control: false, readMessages)
        let listed = names(readMessages, readOnly)
        #expect(listed.count == 4)
        #expect(listed.values.allSatisfy { $0 })
        #expect(String(describing: call(readOnly, readMessages, "ratecue_playback", ["command": "play"])).contains("Invalid arguments"))
        #expect(requests.all().isEmpty)

        let settings = call(readOnly, readMessages, "ratecue_get_settings")["structuredContent"] as! [String: Any]
        #expect(settings["preferredDeviceSelected"] as? Bool == true)
        #expect(settings["localAudioAuthorized"] as? Bool == true)
        let qualification = call(readOnly, readMessages, "ratecue_get_qualification_snapshot")
        #expect((qualification["structuredContent"] as! [String: Any])["activeOutputCount"] as? Int == 1)
        let assessment = call(readOnly, readMessages, "ratecue_get_first_track_assessment", ["deadlineMilliseconds": 1])
        let structured = assessment["structuredContent"] as! [String: Any]
        #expect(structured["ruleHypothesis"] as? String == "insufficientTrace")
        #expect((structured["timeline"] as? [String])?.isEmpty == false)
        #expect(call(readOnly, readMessages, "ratecue_get_first_track_assessment", ["deadlineMilliseconds": true])["code"] as? Int == -32602)
        #expect(!String(describing: readMessages.all()).lowercased().contains("secret"))

        let controlMessages = Messages()
        let controlled = server(control: true, controlMessages)
        let all = names(controlMessages, controlled)
        #expect(all.count == 8)
        #expect(all.filter { !$0.value }.keys.sorted() == [
            "ratecue_playback", "ratecue_restart_first_track_capture",
            "ratecue_set_preference", "ratecue_stop_first_track_capture"
        ])
        let played = call(controlled, controlMessages, "ratecue_playback", ["command": "play"])["structuredContent"] as! [String: Any]
        #expect(played["confirmed"] as? Bool == false)
        #expect(call(controlled, controlMessages, "ratecue_playback", ["command": "eject"])["code"] as? Int == -32602)
        #expect(call(controlled, controlMessages, "ratecue_set_preference", ["name": "autoSwitch", "enabled": 1])["code"] as? Int == -32602)
        #expect(call(controlled, controlMessages, "ratecue_set_preference", ["name": "preferredUID", "enabled": true])["code"] as? Int == -32602)
        #expect(try !store.read().autoSwitch)
        let changed = call(controlled, controlMessages, "ratecue_set_preference", ["name": "autoSwitch", "enabled": true])
        #expect((changed["structuredContent"] as! [String: Any])["autoSwitch"] as? Bool == true)
        #expect(try store.read().autoSwitch)
        #expect((call(controlled, controlMessages, "ratecue_stop_first_track_capture")["structuredContent"] as! [String: Any])["capturing"] as? Bool == false)
        #expect(!String(describing: controlMessages.all()).lowercased().contains("secret"))
        #expect(requests.all().contains { $0["action"] as? String == "playback" && $0["argument"] as? String == "play" })

        let offline = Messages()
        let unavailable = MCPServer(
            tools: MCPToolset.standard(allowControl: false, settings: store, exchange: { _, _, _ in
                throw AppExchange.Failure.noResponse
            }), write: { offline.append($0) }
        )
        initialize(unavailable)
        let failure = call(unavailable, offline, "ratecue_get_qualification_snapshot")
        #expect(failure["isError"] as? Bool == true)
        #expect(String(describing: failure).contains("No running RateCue menu app responded."))
    }

    @Test func malformedAndOversizedInputsAreProtocolErrors() {
        let messages = Messages()
        let server = MCPServer(write: { messages.append($0) })
        server.receive(Data("{".utf8))
        server.receive(Data(repeating: 32, count: 65_537))
        send(server, ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 99]])
        #expect(messages.all().count == 2)
        #expect((messages.all()[0]["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect((messages.all()[1]["error"] as? [String: Any])?["code"] as? Int == -32600)
    }

    @Test func versionNegotiationAndUnknownMethods() {
        for requested in ["2025-06-18", "2024-01-01"] {
            let messages = Messages()
            let server = MCPServer(write: { messages.append($0) })
            send(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                          "params": ["protocolVersion": requested, "capabilities": [:],
                                     "clientInfo": ["name": "test", "version": "1"]]])
            send(server, ["jsonrpc": "2.0", "method": "notifications/initialized"])
            send(server, ["jsonrpc": "2.0", "id": 2, "method": "playback"])
            #expect((messages.all()[0]["result"] as? [String: Any])?["protocolVersion"] as? String
                    == (requested == "2025-06-18" ? requested : "2025-11-25"))
            #expect((messages.all()[1]["error"] as? [String: Any])?["code"] as? Int == -32601)
        }
    }

    @Test func successfulCallAndRateLimit() throws {
        let messages = Messages()
        let fixture = snapshot()
        let server = MCPServer(reader: { _ in fixture }, write: { messages.append($0) })
        initialize(server)
        for id in 2...6 {
            send(server, ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                          "params": ["name": "ratecue_get_diagnostics", "arguments": [:]]])
            let until = Date().addingTimeInterval(1)
            while messages.all().count < id && Date() < until { Thread.sleep(forTimeInterval: 0.001) }
        }
        let results = messages.all()
        #expect(results.count == 6)
        for result in results[1...4] {
            let value = result["result"] as! [String: Any]
            #expect(value["isError"] as? Bool == false)
            let structured = value["structuredContent"] as! [String: Any]
            let text = (value["content"] as! [[String: Any]])[0]["text"] as! String
            let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            #expect(NSDictionary(dictionary: parsed).isEqual(to: structured))
        }
        let limited = results[5]["result"] as! [String: Any]
        #expect(limited["isError"] as? Bool == true)
        #expect(String(describing: limited).contains("Rate limit"))
    }

    @Test func timeoutDoesNotStartAnotherBlockedRead() {
        let messages = Messages()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = MCPServer(reader: { _ in
            entered.signal(); release.wait()
            throw MenuDiagnosticsStore.ReadError.unreadable
        }, write: { messages.append($0) })
        initialize(server)
        send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                      "params": ["name": "ratecue_get_diagnostics"]])
        #expect(entered.wait(timeout: .now() + 1) == .success)
        let until = Date().addingTimeInterval(3)
        while messages.all().count < 2 && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
        send(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                      "params": ["name": "ratecue_get_diagnostics"]])
        let responses = messages.all()
        #expect(responses.count == 3)
        #expect(String(describing: responses[1]).contains("timed out"))
        #expect(String(describing: responses[2]).contains("in progress"))
        release.signal()
    }
}
