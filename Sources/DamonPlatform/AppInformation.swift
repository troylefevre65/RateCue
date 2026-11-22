import Foundation

public struct AppInformation {
    public enum Error: LocalizedError, Equatable {
        case missingMetadata(String)
        case missingCredits
        case emptyCredits

        public var errorDescription: String? {
            switch self {
            case let .missingMetadata(key): "The app bundle is missing \(key)."
            case .missingCredits: "The credits file is missing from the app bundle."
            case .emptyCredits: "The credits file in the app bundle is empty."
            }
        }
    }

    public let name: String
    public let version: String
    public let build: String

    public init(bundle: Bundle = .main) throws {
        try self.init(info: bundle.infoDictionary ?? [:])
    }

    init(info: [String: Any]) throws {
        func field(_ key: String) throws -> String {
            guard let value = info[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.missingMetadata(key)
            }
            return value
        }
        name = try field("CFBundleName")
        version = try field("CFBundleShortVersionString")
        build = try field("CFBundleVersion")
    }

    public var versionDescription: String { "\(name) \(version) (build \(build))" }

    public static func credits(bundle: Bundle = .main) throws -> String {
        guard let url = bundle.url(forResource: "NOTICE", withExtension: nil) else { throw Error.missingCredits }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Error.emptyCredits }
        return text
    }
}
