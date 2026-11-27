import Foundation

/// Explicit request and response between a client (CLI, MCP helper, test harness) and the running menu app.
/// A request is a local distributed notification naming an allowlisted action; the response is one
/// owner-only JSON file that the client consumes. Nothing is retained after the client reads it.
public enum AppExchange {
    public static let notification = Notification.Name("org.damon.BitStreamManager.appRequest")
    public static let maximumBytes = 256 * 1_024

    public enum Action: String, Sendable, CaseIterable {
        case traceExport, traceRestart, traceStop
        case logs, diagnostics, qualificationSnapshot, loginItem, playback, quit

        /// The only arguments an action accepts; `nil` means it takes none.
        public var arguments: [String]? {
            switch self {
            case .loginItem: ["status", "on", "off"]
            case .playback: ["play", "pause", "next"]
            default: nil
            }
        }
    }

    /// Fixed failure codes; the app never returns free-form error text.
    public enum Failure: String, Error, Sendable {
        case noResponse, invalidResponse, traceDisabled, traceStopped, musicUnavailable, failed
    }

    public struct Request: Sendable {
        public let action: Action
        public let argument: String?
        public let identifier: UUID

        public var userInfo: [String: String] {
            var values = ["action": action.rawValue, "request": identifier.uuidString]
            values["argument"] = argument
            return values
        }
    }

    /// Accepts only a known action, an allowlisted argument and a UUID, so a request can never name a file.
    public static func request(from userInfo: [AnyHashable: Any]?) -> Request? {
        guard let action = (userInfo?["action"] as? String).flatMap(Action.init(rawValue:)),
              let identifier = (userInfo?["request"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        let argument = userInfo?["argument"] as? String
        if let allowed = action.arguments {
            guard let argument, allowed.contains(argument) else { return nil }
        } else if argument != nil { return nil }
        return Request(action: action, argument: argument, identifier: identifier)
    }

    private static func url(_ identifier: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("app-response-\(identifier.uuidString).json")
    }

    /// App side. Expired responses are removed without disturbing other clients' active requests.
    public static func respond(
        _ result: Result<Any, Failure>, to identifier: UUID, in directory: URL = MenuDiagnosticsStore.standardDirectory
    ) throws {
        let envelope: [String: Any] = switch result {
        case let .success(value): ["ok": true, "result": value]
        case let .failure(code): ["ok": false, "error": code.rawValue]
        }
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard data.count <= maximumBytes else { throw Failure.failed }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let expiry = Date().addingTimeInterval(-60)
        for name in try files.contentsOfDirectory(atPath: directory.path) {
            let prefix = name.hasPrefix(".") ? ".app-response-" : "app-response-"
            let suffix = name.hasPrefix(".") ? ".tmp" : ".json"
            guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                  UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil else { continue }
            let item = directory.appendingPathComponent(name)
            do {
                let attributes = try files.attributesOfItem(atPath: item.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                guard let modified = attributes[.modificationDate] as? Date else { throw Failure.failed }
                if modified < expiry { try files.removeItem(at: item) }
            } catch {
                let error = error as NSError
                // A different client may have consumed its response while this directory was listed.
                if error.domain == NSCocoaErrorDomain
                    && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { continue }
                throw error
            }
        }
        let staged = directory.appendingPathComponent(".app-response-\(identifier.uuidString).tmp")
        guard files.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.failed
        }
        try files.moveItem(at: staged, to: url(identifier, in: directory))
    }

    /// Client side. Posts one request and consumes its response; the response file is deleted once read.
    public static func send(
        _ action: Action, argument: String? = nil, in directory: URL = MenuDiagnosticsStore.standardDirectory,
        timeout: TimeInterval = 3,
        post: (Request) -> Void = { request in
            DistributedNotificationCenter.default().postNotificationName(
                notification, object: nil, userInfo: request.userInfo, deliverImmediately: true
            )
        }
    ) throws -> Any {
        let request = Request(action: action, argument: argument, identifier: UUID())
        let response = url(request.identifier, in: directory)
        post(request)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: response.path) {
                defer { try? FileManager.default.removeItem(at: response) }
                let values = try? response.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                      let handle = try? FileHandle(forReadingFrom: response) else { throw Failure.invalidResponse }
                defer { try? handle.close() }
                guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
                      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ok = envelope["ok"] as? Bool else { throw Failure.invalidResponse }
                guard ok, let value = envelope["result"] else {
                    throw (envelope["error"] as? String).flatMap(Failure.init(rawValue:)) ?? .invalidResponse
                }
                return value
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw Failure.noResponse
    }
}

extension FirstTrackTrace {
    /// Asks a trace-enabled menu app for its current capture, optionally restarting it first.
    public static func request(
        restart: Bool = false, send: (AppExchange.Action) throws -> Any = { try AppExchange.send($0) }
    ) throws -> FirstTrackTrace {
        let value = try send(restart ? .traceRestart : .traceExport)
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            throw AppExchange.Failure.invalidResponse
        }
        return try decode(data)
    }

    /// The same capture as a JSON object, for an `AppExchange` response.
    public func exchangeObject() throws -> Any {
        try JSONSerialization.jsonObject(with: encoded())
    }

    /// True once the capture covers the deadline after the first accepted playing sample, or can no longer grow.
    public func covers(deadlineMilliseconds: Int, marginMilliseconds: Int = 1_000) -> Bool {
        guard let first = events.first(where: \.isUsedPlayingSample) else { return false }
        return bounded || endedAtMilliseconds - first.atMilliseconds >= deadlineMilliseconds + marginMilliseconds
    }
}

extension MusicObserver {
    /// Typed outcome of one transport command; no free-form message.
    public struct TransportOutcome: Sendable {
        public let command: String
        public let commandSent: Bool
        public let confirmed: Bool
        public let playbackState: String

        public var object: [String: Any] {
            ["command": command, "commandSent": commandSent, "confirmed": confirmed, "playbackState": playbackState]
        }
    }

    /// One transport command; never prompts for Automation access. Nil when Music cannot be controlled.
    public static func transport(_ command: String, pid: pid_t) -> TransportOutcome? {
        guard let action = TransportAction(rawValue: command),
              requestPermission(pid: pid, askIfNeeded: false) == 0,
              let result = try? control(action, pid: pid) else { return nil }
        return TransportOutcome(command: command, commandSent: result.commandSent, confirmed: result.confirmed,
                                playbackState: result.playbackState)
    }
}
