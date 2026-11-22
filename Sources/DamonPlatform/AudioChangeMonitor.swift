import CoreAudio
import Foundation

struct AudioListenerKey: Hashable {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope

    init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        self.object = object
        self.selector = selector
        self.scope = scope
    }

    var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

@MainActor
public final class AudioChangeMonitor {
    struct Driver {
        let musicProcesses: (pid_t) -> [AudioObjectID]?
        let add: (AudioListenerKey, @escaping AudioObjectPropertyListenerBlock) -> OSStatus
        let remove: (AudioListenerKey, @escaping AudioObjectPropertyListenerBlock) -> OSStatus

        @MainActor static let system = Driver(
            musicProcesses: AudioHardware.musicProcessObjects,
            add: { key, block in
                var address = key.address
                return AudioObjectAddPropertyListenerBlock(key.object, &address, .main, block)
            },
            remove: { key, block in
                var address = key.address
                return AudioObjectRemovePropertyListenerBlock(key.object, &address, .main, block)
            }
        )
    }

    private let driver: Driver
    private let onChange: @MainActor () -> Void
    private let onError: @MainActor (String) -> Void
    private var listeners: [AudioListenerKey: AudioObjectPropertyListenerBlock] = [:]
    private var failures: [AudioListenerKey: OSStatus] = [:]
    private var processEnumerationFailed = false
    private var started = false

    public convenience init(onChange: @escaping @MainActor () -> Void, onError: @escaping @MainActor (String) -> Void) {
        self.init(driver: .system, onChange: onChange, onError: onError)
    }

    init(driver: Driver, onChange: @escaping @MainActor () -> Void, onError: @escaping @MainActor (String) -> Void) {
        self.driver = driver
        self.onChange = onChange
        self.onError = onError
    }

    public func start() {
        guard !started else { return }
        started = true
        update(preferred: nil, musicPID: nil)
    }

    public func update(preferred: OutputDevice?, musicPID: pid_t?) {
        guard started else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var desired: Set<AudioListenerKey> = [
            AudioListenerKey(system, kAudioHardwarePropertyDevices),
            AudioListenerKey(system, kAudioHardwarePropertyDefaultOutputDevice),
            AudioListenerKey(system, kAudioHardwarePropertyProcessObjectList)
        ]
        if let preferred {
            desired.insert(AudioListenerKey(preferred.objectID, kAudioDevicePropertyNominalSampleRate))
            desired.insert(AudioListenerKey(preferred.objectID, kAudioDevicePropertyDeviceIsAlive))
            desired.insert(AudioListenerKey(preferred.objectID, kAudioDevicePropertyAvailableNominalSampleRates))
        }
        if let musicPID {
            if let processes = driver.musicProcesses(musicPID) {
                processEnumerationFailed = false
                for process in processes {
                    desired.insert(AudioListenerKey(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput))
                    desired.insert(AudioListenerKey(process, kAudioProcessPropertyIsRunningOutput))
                }
            } else {
                if !processEnumerationFailed {
                    onError("Unable to observe Music output changes; periodic monitoring continues.")
                    processEnumerationFailed = true
                }
                // Keep existing process listeners until enumeration succeeds or Music exits.
                desired.formUnion(listeners.keys.filter {
                    $0.selector == kAudioProcessPropertyDevices || $0.selector == kAudioProcessPropertyIsRunningOutput
                })
            }
        }
        reconcile(desired)
    }

    public func stop() {
        guard started else { return }
        started = false
        reconcile([])
        failures.removeAll()
        processEnumerationFailed = false
    }

    private func reconcile(_ desired: Set<AudioListenerKey>) {
        for key in listeners.keys.filter({ !desired.contains($0) }) {
            guard let block = listeners.removeValue(forKey: key) else { continue }
            let status = driver.remove(key, block)
            if status != noErr && status != kAudioHardwareBadObjectError {
                onError("Could not remove a Core Audio listener (status \(status)).")
            }
        }
        failures = failures.filter { desired.contains($0.key) }
        for key in desired where listeners[key] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.started, self.listeners[key] != nil else { return }
                    self.onChange()
                }
            }
            let status = driver.add(key, block)
            if status == noErr {
                listeners[key] = block
                failures.removeValue(forKey: key)
            } else {
                if failures[key] != status {
                    onError("Core Audio change listener unavailable (status \(status)); periodic monitoring continues.")
                }
                failures[key] = status
            }
        }
    }
}

@MainActor
public final class AudioRefreshGate {
    public private(set) var version: UInt64 = 0
    private var sleeper: Task<Void, Never>?

    public init() {}

    public func signal() {
        version &+= 1
        sleeper?.cancel()
    }

    public func wait(since version: UInt64, milliseconds: Int) async {
        guard version == self.version, !Task.isCancelled else { return }
        let task = Task { _ = try? await Task.sleep(for: .milliseconds(milliseconds)) }
        sleeper = task
        await task.value
        sleeper = nil
    }

    public func stop() {
        sleeper?.cancel()
    }
}
