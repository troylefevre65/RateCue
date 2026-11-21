import AVFoundation
import CoreMedia
import Foundation

public struct SensorProfile: Decodable, Sendable {
    public struct Region: Decodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var isValid: Bool {
            x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1
        }
    }

    public struct Camera: Decodable, Sendable {
        public struct Indicator: Decodable, Sendable {
            let rate: Int
            let region: Region
            let confidence: Double
        }

        let deviceID: String
        let lock: Region
        let indicators: [Indicator]
        let minimumBrightness: Double
        let minimumMargin: Double

        public var isValid: Bool {
            !deviceID.isEmpty && lock.isValid && indicators.count >= 2 && indicators.count <= 16
                && Set(indicators.map(\.rate)).count == indicators.count
                && indicators.allSatisfy { $0.rate > 0 && $0.region.isValid && (0...1).contains($0.confidence) }
                && (0...1).contains(minimumBrightness) && minimumMargin > 0 && minimumMargin <= 1
        }

        func classify(lockBrightness: Double, levels: [Double]) -> Indicator? {
            guard lockBrightness >= minimumBrightness, levels.count == indicators.count else { return nil }
            let best = levels.indices.sorted { levels[$0] > levels[$1] }
            guard best.count >= 2, levels[best[0]] >= minimumBrightness,
                  levels[best[0]] - levels[best[1]] >= minimumMargin else { return nil }
            return indicators[best[0]]
        }
    }

    public struct Microphone: Decodable, Sendable {
        let deviceID: String
        let minimumPeak: Double
        let minimumCrestFactor: Double
        public let maximumLatency: TimeInterval

        public var isValid: Bool {
            !deviceID.isEmpty && minimumPeak > 0 && minimumPeak <= 1
                && minimumCrestFactor.isFinite && minimumCrestFactor > 1
                && maximumLatency > 0 && maximumLatency <= 2
        }
    }

    public let deviceUID: String
    public let camera: Camera?
    public let microphone: Microphone?
}

public enum SensorEvent: Sendable {
    case led(at: TimeInterval, rate: Int, confidence: Double)
    case relay(at: TimeInterval)
    case unavailable(String)
}

public final class HardwareCapture: NSObject, @unchecked Sendable {
    public enum Configuration: Sendable {
        case camera(SensorProfile.Camera)
        case microphone(SensorProfile.Microphone)

        var mediaType: AVMediaType {
            switch self { case .camera: .video; case .microphone: .audio }
        }

        var deviceID: String {
            switch self { case let .camera(profile): profile.deviceID; case let .microphone(profile): profile.deviceID }
        }
    }

    private let configuration: Configuration
    private let receive: @Sendable (SensorEvent) -> Void
    private let queue = DispatchQueue(label: "org.damon.verification", qos: .utility)
    // All capture and classifier state is owned by queue, including sample callbacks.
    private var session: AVCaptureSession?
    private var failureObserver: NSObjectProtocol?
    private var lastRate: Int?
    private var stableSince: TimeInterval = 0
    private var lastFrame: TimeInterval = 0

    public init(configuration: Configuration, receive: @escaping @Sendable (SensorEvent) -> Void) {
        self.configuration = configuration
        self.receive = receive
    }

    public func start() {
        queue.async { self.startCapture() }
    }

    public func stop() {
        queue.async {
            if let observer = self.failureObserver { NotificationCenter.default.removeObserver(observer) }
            self.failureObserver = nil
            self.session?.stopRunning()
            self.session = nil
            self.lastRate = nil
        }
    }

    private func startCapture() {
        guard session == nil, AVCaptureDevice.authorizationStatus(for: configuration.mediaType) == .authorized else {
            receive(.unavailable("Permission not granted"))
            return
        }
        let session = AVCaptureSession()
        let deviceTypes: [AVCaptureDevice.DeviceType] = configuration.mediaType == .video ? [.external] : [.microphone]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: configuration.mediaType, position: .unspecified)
        guard let device = devices.devices.first(where: { $0.uniqueID == configuration.deviceID }) else {
            receive(.unavailable("Calibrated capture device not found"))
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { receive(.unavailable("Cannot open calibrated capture input")); return }
            session.addInput(input)
        } catch {
            receive(.unavailable(error.localizedDescription))
            return
        }
        let output: AVCaptureOutput
        switch configuration {
        case .camera:
            if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
            let video = AVCaptureVideoDataOutput()
            video.alwaysDiscardsLateVideoFrames = true
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            video.setSampleBufferDelegate(self, queue: queue)
            output = video
        case .microphone:
            let audio = AVCaptureAudioDataOutput()
            audio.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                                   AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                   AVLinearPCMIsNonInterleaved: false]
            audio.setSampleBufferDelegate(self, queue: queue)
            output = audio
        }
        guard session.canAddOutput(output) else { receive(.unavailable("Cannot configure capture output")); return }
        session.addOutput(output)
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.receive(.unavailable("Capture session interrupted or disconnected"))
        }
        self.session = session
        session.startRunning()
        if !session.isRunning { receive(.unavailable("Capture session did not start")) }
    }

    private func observeFrame(_ buffer: CMSampleBuffer, at: TimeInterval, profile: SensorProfile.Camera) {
        guard at - lastFrame >= 0.08, let pixels = CMSampleBufferGetImageBuffer(buffer),
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        if at - lastFrame > 0.25 { lastRate = nil }
        lastFrame = at
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let strideBytes = CVPixelBufferGetBytesPerRow(pixels)
        func brightness(_ region: SensorProfile.Region) -> Double {
            let left = Int(region.x * Double(width))
            let right = min(width, max(left + 1, Int((region.x + region.width) * Double(width))))
            let top = Int(region.y * Double(height))
            let bottom = min(height, max(top + 1, Int((region.y + region.height) * Double(height))))
            let stepX = max(1, (right - left) / 12)
            let stepY = max(1, (bottom - top) / 12)
            var sum = 0
            var count = 0
            for y in stride(from: top, to: bottom, by: stepY) {
                for x in stride(from: left, to: right, by: stepX) {
                    let p = base + y * strideBytes + x * 4
                    sum += Int(max(p[0], p[1], p[2]))
                    count += 1
                }
            }
            return count == 0 ? 0 : Double(sum) / (255 * Double(count))
        }
        guard let match = profile.classify(lockBrightness: brightness(profile.lock), levels: profile.indicators.map({ brightness($0.region) })) else {
            lastRate = nil
            return
        }
        if lastRate != match.rate {
            lastRate = match.rate
            stableSince = at
        } else if at - stableSince >= 0.16 {
            receive(.led(at: at, rate: match.rate, confidence: match.confidence))
        }
    }

    private func observeAudio(_ buffer: CMSampleBuffer, at: TimeInterval, profile: SensorProfile.Microphone) {
        guard let data = CMSampleBufferGetDataBuffer(buffer),
              let format = CMSampleBufferGetFormatDescription(buffer),
              let pcm = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              pcm.mFormatID == kAudioFormatLinearPCM, pcm.mBitsPerChannel == 16,
              pcm.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian) == 0,
              pcm.mSampleRate > 0, pcm.mChannelsPerFrame > 0 else { return }
        var length = 0
        var total = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: &length,
                                          totalLengthOut: &total, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              length == total, total >= 2, let pointer else { return }
        let bytes = UnsafeRawPointer(pointer)
        var peak = 0.0
        var peakIndex = 0
        var energy = 0.0
        for offset in stride(from: 0, to: total - 1, by: 2) {
            let value = abs(Double(bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
            if value > peak {
                peak = value
                peakIndex = offset / 2
            }
            energy += value * value
        }
        let rms = sqrt(energy / Double(total / 2))
        if peak >= profile.minimumPeak, rms > 0, peak / rms >= profile.minimumCrestFactor {
            let position = Double(peakIndex / Int(pcm.mChannelsPerFrame)) / pcm.mSampleRate
            receive(.relay(at: at + position))
        }
    }
}

extension HardwareCapture: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let host = CMClockGetHostTimeClock()
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard let clock = session?.synchronizationClock else { return }
        let hostTime = CMSyncConvertTime(pts, from: clock, to: host)
        let age = CMTimeSubtract(CMClockGetTime(host), hostTime).seconds
        guard age.isFinite, (-0.02...0.5).contains(age) else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime - age
        switch configuration {
        case let .camera(profile): observeFrame(buffer, at: timestamp, profile: profile)
        case let .microphone(profile): observeAudio(buffer, at: timestamp, profile: profile)
        }
    }
}
