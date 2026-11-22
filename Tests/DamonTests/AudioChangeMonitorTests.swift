@testable import DamonPlatform
import CoreAudio
import AppKit
import Foundation
import Testing

@MainActor
private final class FakeAudioListeners {
    var blocks: [AudioListenerKey: AudioObjectPropertyListenerBlock] = [:]
    var additions: [AudioListenerKey] = []
    var removals: [AudioListenerKey] = []
    var failed: Set<AudioListenerKey> = []
    var processes: [AudioObjectID]? = [101]

    var driver: AudioChangeMonitor.Driver {
        AudioChangeMonitor.Driver(
            musicProcesses: { _ in self.processes },
            add: { key, block in
                self.additions.append(key)
                guard !self.failed.contains(key) else { return kAudioHardwareUnspecifiedError }
                self.blocks[key] = block
                return noErr
            },
            remove: { key, _ in
                self.removals.append(key)
                self.blocks.removeValue(forKey: key)
                return noErr
            }
        )
    }
}

@MainActor
struct AudioChangeMonitorTests {
    private func device(_ id: AudioObjectID) -> OutputDevice {
        OutputDevice(objectID: id, uid: "device-\(id)", name: "Test", transport: 0,
                     nominalRate: 44_100, availableRates: [44_100...44_100], isRateSettable: true)
    }

    @Test func subscribesAndReconcilesDevicesAndMusicProcesses() async throws {
        let backend = FakeAudioListeners()
        var wakes = 0
        var errors: [String] = []
        let observer = AudioChangeMonitor(driver: backend.driver, onChange: { wakes += 1 }, onError: { errors.append($0) })
        observer.start()
        observer.update(preferred: device(21), musicPID: 42)
        let rate = AudioListenerKey(21, kAudioDevicePropertyNominalSampleRate)
        let route = AudioListenerKey(101, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
        #expect(backend.blocks[rate] != nil)
        #expect(backend.blocks[route] != nil)
        let callback = try #require(backend.blocks[rate])
        var address = rate.address
        withUnsafePointer(to: &address) { callback(1, $0) }
        await Task.yield()
        #expect(wakes == 1)

        let originalCount = backend.additions.count
        observer.update(preferred: device(21), musicPID: 42)
        #expect(backend.additions.count == originalCount)
        backend.processes = [102]
        observer.update(preferred: device(22), musicPID: 42)
        #expect(backend.blocks[rate] == nil)
        #expect(backend.blocks[route] == nil)
        #expect(backend.blocks[AudioListenerKey(22, kAudioDevicePropertyNominalSampleRate)] != nil)
        #expect(backend.blocks[AudioListenerKey(102, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)] != nil)
        withUnsafePointer(to: &address) { callback(1, $0) }
        await Task.yield()
        #expect(wakes == 1)
        observer.stop()
        #expect(backend.blocks.isEmpty)
        #expect(errors.isEmpty)
    }

    @Test func reportsFailedListenersOnceAndRetriesOnNextRefresh() {
        let backend = FakeAudioListeners()
        let key = AudioListenerKey(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        backend.failed = [key]
        var errors: [String] = []
        let observer = AudioChangeMonitor(driver: backend.driver, onChange: {}, onError: { errors.append($0) })
        observer.start()
        observer.update(preferred: nil, musicPID: nil)
        #expect(errors.count == 1)
        #expect(backend.blocks[key] == nil)
        backend.failed.remove(key)
        observer.update(preferred: nil, musicPID: nil)
        #expect(backend.blocks[key] != nil)
        observer.stop()
        #expect(backend.blocks.isEmpty)
    }

    @Test func processEnumerationFailurePreservesExistingListenersUntilRecovery() {
        let backend = FakeAudioListeners()
        var errors: [String] = []
        let observer = AudioChangeMonitor(driver: backend.driver, onChange: {}, onError: { errors.append($0) })
        let route = AudioListenerKey(101, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
        observer.start()
        observer.update(preferred: nil, musicPID: 42)
        backend.processes = nil
        observer.update(preferred: nil, musicPID: 42)
        observer.update(preferred: nil, musicPID: 42)
        #expect(backend.blocks[route] != nil)
        #expect(errors.count == 1)
        backend.processes = []
        observer.update(preferred: nil, musicPID: 42)
        #expect(backend.blocks[route] == nil)
        observer.stop()
    }

    @Test func registersAndRemovesSystemListenersWithoutChangingAudio() {
        var errors: [String] = []
        let observer = AudioChangeMonitor(onChange: {}, onError: { errors.append($0) })
        observer.start()
        if let preferred = AudioHardware.outputs()?.first {
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: PlaybackSample.musicBundleID).first?.processIdentifier
            observer.update(preferred: preferred, musicPID: pid)
        }
        observer.stop()
        #expect(errors.isEmpty)
    }

    @Test func refreshGateDoesNotLoseChangesDuringSampling() async {
        let gate = AudioRefreshGate()
        let version = gate.version
        gate.signal()
        let start = ContinuousClock.now
        await gate.wait(since: version, milliseconds: 3_000)
        #expect(start.duration(to: .now) < .seconds(1))

        let waiter = Task { @MainActor in
            let start = ContinuousClock.now
            await gate.wait(since: gate.version, milliseconds: 3_000)
            return start.duration(to: .now)
        }
        await Task.yield()
        gate.signal()
        let duration = await waiter.value
        #expect(duration < .seconds(1))
        gate.stop()
    }
}
