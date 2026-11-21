import CoreFoundation
import Foundation

public struct DamonSettings: Encodable, Equatable, Sendable {
    public var preferredOutputUID: String?
    public var authorizedAudioPath: String?
    public var monitorMusic = false
    public var autoSwitch = false
    public var showSampleRate = true
    public var showBitDepth = true

    public var authorizedAudio: URL? { authorizedAudioPath.map { URL(fileURLWithPath: $0) } }

    public init() {}
}

public enum SettingEdit: Sendable {
    case device(String?)
    case localAudio(URL?)
    case monitorMusic(Bool)
    case autoSwitch(Bool)
    case showSampleRate(Bool)
    case showBitDepth(Bool)
}

public struct SettingsStore {
    private let domain: String

    public init(domain: String = "org.damon.BitStreamManager") {
        self.domain = domain
    }

    public struct SyncError: LocalizedError {
        public var errorDescription: String? { "Unable to synchronize Damon's preferences." }
    }

    public func read() throws -> DamonSettings {
        guard CFPreferencesAppSynchronize(domain as CFString) else { throw SyncError() }
        let keys = ["preferredUID", "approvedAudioPath", "approvedFolder", "observeMusic", "automatic", "showRate", "showDepth"]
        let values = CFPreferencesCopyMultiple(keys as CFArray, domain as CFString,
                                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
        var settings = DamonSettings()
        settings.preferredOutputUID = values["preferredUID"] as? String
        settings.authorizedAudioPath = values["approvedAudioPath"] as? String
        if settings.authorizedAudioPath == nil, values["approvedFolder"] != nil {
            let defaults = domain == Bundle.main.bundleIdentifier ? UserDefaults.standard : UserDefaults(suiteName: domain)
            settings.authorizedAudioPath = defaults?.url(forKey: "approvedFolder")?.path
        }
        settings.monitorMusic = values["observeMusic"] as? Bool ?? false
        settings.autoSwitch = values["automatic"] as? Bool ?? false
        settings.showSampleRate = values["showRate"] as? Bool ?? true
        settings.showBitDepth = values["showDepth"] as? Bool ?? true
        return settings
    }

    public func apply(_ edits: [SettingEdit]) throws {
        var changes: [String: Any] = [:]
        var removals: Set<String> = []
        func set(_ key: String, _ value: Any?) {
            if let value {
                changes[key] = value
                removals.remove(key)
            } else {
                changes.removeValue(forKey: key)
                removals.insert(key)
            }
        }
        for edit in edits {
            switch edit {
            case let .device(uid): set("preferredUID", uid)
            case let .localAudio(url):
                set("approvedAudioPath", url?.resolvingSymlinksInPath().standardizedFileURL.path)
                set("approvedFolder", nil)
            case let .monitorMusic(on): set("observeMusic", on)
            case let .autoSwitch(on): set("automatic", on)
            case let .showSampleRate(on): set("showRate", on)
            case let .showBitDepth(on): set("showDepth", on)
            }
        }
        guard CFPreferencesAppSynchronize(domain as CFString) else { throw SyncError() }
        CFPreferencesSetMultiple(changes as CFDictionary, Array(removals) as CFArray, domain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesAppSynchronize(domain as CFString) else { throw SyncError() }
    }
}
