import CoreFoundation
import Foundation

public struct DamonSettings: Encodable, Equatable, Sendable {
    public var preferredOutputUID: String?
    public var authorizedAudioPath: String?
    public var monitorMusic = false
    public var autoSwitch = false
    public var autoReadMusicPanel = false
    public var showSampleRate = true
    public var showBitDepth = true
    public var cameraVerification = false
    public var relayVerification = false

    public var authorizedAudio: URL? { authorizedAudioPath.map { URL(fileURLWithPath: $0) } }

    public init() {}

    public func invalidatesAutomaticPanelRead(comparedTo previous: DamonSettings) -> Bool {
        monitorMusic != previous.monitorMusic || autoReadMusicPanel != previous.autoReadMusicPanel
    }
}

public enum SettingEdit: Sendable {
    case device(String?)
    case localAudio(URL?)
    case monitorMusic(Bool)
    case autoSwitch(Bool)
    case autoReadMusicPanel(Bool)
    case showSampleRate(Bool)
    case showBitDepth(Bool)
    case cameraVerification(Bool)
    case relayVerification(Bool)
}

public struct SettingsStore: Sendable {
    private let domain: String

    public init(domain: String = "org.damon.BitStreamManager") {
        self.domain = domain
    }

    public struct SyncError: LocalizedError {
        public var errorDescription: String? { "Unable to synchronize RateCue preferences." }
    }

    public func read() throws -> DamonSettings {
        guard CFPreferencesAppSynchronize(domain as CFString) else { throw SyncError() }
        let keys = ["preferredUID", "approvedAudioPath", "approvedFolder", "observeMusic", "automatic",
                    "autoReadMusicPanel", "showRate", "showDepth", "cameraVerification", "relayVerification"]
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
        settings.autoReadMusicPanel = values["autoReadMusicPanel"] as? Bool ?? false
        settings.showSampleRate = values["showRate"] as? Bool ?? true
        settings.showBitDepth = values["showDepth"] as? Bool ?? true
        settings.cameraVerification = values["cameraVerification"] as? Bool ?? false
        settings.relayVerification = values["relayVerification"] as? Bool ?? false
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
            case let .autoReadMusicPanel(on): set("autoReadMusicPanel", on)
            case let .showSampleRate(on): set("showRate", on)
            case let .showBitDepth(on): set("showDepth", on)
            case let .cameraVerification(on): set("cameraVerification", on)
            case let .relayVerification(on): set("relayVerification", on)
            }
        }
        guard CFPreferencesAppSynchronize(domain as CFString) else { throw SyncError() }
        CFPreferencesSetMultiple(changes as CFDictionary, Array(removals) as CFArray, domain as CFString,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesAppSynchronize(domain as CFString) else { throw SyncError() }
    }
}
