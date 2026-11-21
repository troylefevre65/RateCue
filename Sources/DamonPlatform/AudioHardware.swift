import CoreAudio
import DamonPolicy
import Foundation

public struct OutputDevice: Sendable, Equatable {
    public let objectID: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: UInt32
    public let nominalRate: Int?
    public let availableRates: [ClosedRange<Double>]
    public let isRateSettable: Bool

    public var endpoint: String { "\(objectID):\(uid)" }

    public var isWiredExternal: Bool {
        transport == kAudioDeviceTransportTypeUSB || transport == kAudioDeviceTransportTypeThunderbolt
    }

    public func supports(_ rate: Int) -> Bool {
        isRateSettable && availableRates.contains { $0.contains(Double(rate)) }
    }
}

public enum AudioHardware {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: UInt32, scope: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(
        _ id: AudioObjectID, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal, into value: inout T
    ) -> Bool {
        var property = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            guard let ptr = buffer.baseAddress else { return OSStatus(kAudioHardwareBadPropertySizeError) }
            return AudioObjectGetPropertyData(id, &property, 0, nil, &size, ptr)
        }
        return status == noErr && size == MemoryLayout<T>.size
    }

    private static func string(_ id: AudioObjectID, _ selector: UInt32) -> String? {
        var result: Unmanaged<CFString>?
        guard read(id, selector, into: &result), let result else { return nil }
        return result.takeRetainedValue() as String
    }

    private static func array<T>(
        _ id: AudioObjectID, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal, zero: T
    ) -> [T]? {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
              size % UInt32(MemoryLayout<T>.stride) == 0 else { return nil }
        if size == 0 { return [] }
        var items = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        let status = items.withUnsafeMutableBytes { buffer in
            guard let ptr = buffer.baseAddress else { return OSStatus(kAudioHardwareBadPropertySizeError) }
            return AudioObjectGetPropertyData(id, &property, 0, nil, &size, ptr)
        }
        let count = Int(size) / MemoryLayout<T>.stride
        guard status == noErr, size % UInt32(MemoryLayout<T>.stride) == 0, count <= items.count else { return nil }
        return Array(items.prefix(count))
    }

    private static func nominalRate(_ id: AudioObjectID) -> Int? {
        var rate = 0.0
        guard read(id, kAudioDevicePropertyNominalSampleRate, into: &rate), rate.isFinite, rate > 0 else { return nil }
        return Int(exactly: rate)
    }

    static func readRate(on device: OutputDevice) -> Int? {
        guard string(device.objectID, kAudioDevicePropertyDeviceUID) == device.uid else { return nil }
        return nominalRate(device.objectID)
    }

    public static func outputs() -> [OutputDevice]? {
        array(system, kAudioHardwarePropertyDevices, zero: AudioObjectID(0))?.compactMap { id in
            guard let streams = array(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput,
                                      zero: AudioObjectID(0)), !streams.isEmpty,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            var alive: UInt32 = 0
            guard read(id, kAudioDevicePropertyDeviceIsAlive, into: &alive), alive != 0 else { return nil }
            var transport: UInt32 = 0
            _ = read(id, kAudioDevicePropertyTransportType, into: &transport)
            var property = address(kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)
            var writable: DarwinBoolean = false
            let settable = AudioObjectIsPropertySettable(id, &property, &writable) == noErr && writable.boolValue
            let ranges = array(id, kAudioDevicePropertyAvailableNominalSampleRates, zero: AudioValueRange())?
                .compactMap { range -> ClosedRange<Double>? in
                    guard range.mMinimum.isFinite, range.mMaximum.isFinite, range.mMinimum > 0,
                          range.mMinimum <= range.mMaximum else { return nil }
                    return range.mMinimum...range.mMaximum
                } ?? []
            return OutputDevice(objectID: id, uid: uid, name: name, transport: transport, nominalRate: nominalRate(id),
                                availableRates: ranges, isRateSettable: settable)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func confirmedMusicOutputs(pid: pid_t) -> [AudioObjectID]? {
        guard let processes = array(system, kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0)) else { return nil }
        var matches: [AudioObjectID] = []
        for process in processes {
            var processPID: pid_t = 0
            guard read(process, kAudioProcessPropertyPID, into: &processPID), pid == processPID,
                  string(process, kAudioProcessPropertyBundleID) == "com.apple.Music" else { continue }
            var running: UInt32 = 0
            guard read(process, kAudioProcessPropertyIsRunningOutput, into: &running), running != 0 else { continue }
            guard let outputs = array(process, kAudioProcessPropertyDevices, scope: kAudioDevicePropertyScopeOutput,
                                      zero: AudioObjectID(0)) else { return nil }
            matches.append(contentsOf: outputs)
        }
        return matches.isEmpty ? nil : Array(Set(matches)).sorted()
    }

    static func musicHasExclusiveOutput(pid: pid_t, deviceID: AudioObjectID) -> Bool {
        guard confirmedMusicOutputs(pid: pid) == [deviceID],
              let processes = array(system, kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0)) else { return false }
        for process in processes {
            var running: UInt32 = 0
            guard read(process, kAudioProcessPropertyIsRunningOutput, into: &running) else { return false }
            guard running != 0 else { continue }
            var processPID: pid_t = 0
            guard read(process, kAudioProcessPropertyPID, into: &processPID) else { return false }
            guard processPID != pid else { continue }
            guard let outputs = array(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput,
                                      zero: AudioObjectID(0)), !outputs.contains(deviceID) else { return false }
        }
        return true
    }

    public static func setRate(_ rate: Int, device: OutputDevice, musicPID: pid_t, deadline: TimeInterval) -> OSStatus {
        guard musicHasExclusiveOutput(pid: musicPID, deviceID: device.objectID),
              string(device.objectID, kAudioDevicePropertyDeviceUID) == device.uid,
              device.isWiredExternal, device.supports(rate) else { return kAudioHardwareIllegalOperationError }
        guard let current = nominalRate(device.objectID), current == device.nominalRate,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return kAudioHardwareBadDeviceError
        }
        if current == rate { return kAudioHardwareUnsupportedOperationError }
        var property = address(kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)
        var target = Double(rate)
        return AudioObjectSetPropertyData(device.objectID, &property, 0, nil, UInt32(MemoryLayout<Double>.size), &target)
    }

    public static func writeDisposition(_ status: OSStatus) -> WriteDisposition {
        switch status {
        case noErr: .submitted
        case kAudioHardwareNotReadyError: .transientFailure
        default: .failed
        }
    }
}
