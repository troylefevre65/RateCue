import AVFoundation
import DamonPlatform
import DamonPolicy
import Foundation

@MainActor
final class VerificationMonitor {
    private var token = UUID()
    private var deviceUID: String?
    private var camera: HardwareCapture?
    private var microphone: HardwareCapture?
    private var epoch: Epoch?
    private var transition: TransitionVerification?
    private var led: [LEDReading] = []
    private var relayTimes: [TimeInterval] = []
    private var cutoff: TimeInterval = 0
    private var problems: [String] = []
    private(set) var outcome: VerificationState?

    func configure(profile: SensorProfile?, playing: Bool, cameraEnabled: Bool, microphoneEnabled: Bool) {
        guard playing, let profile, cameraEnabled || microphoneEnabled else { stop(); return }
        if deviceUID != profile.deviceUID {
            stop()
            deviceUID = profile.deviceUID
        }
        let token = token
        if !cameraEnabled {
            camera?.stop()
            camera = nil
        } else if camera == nil, let profile = profile.camera, profile.isValid {
            camera = capture(.camera(profile), token: token)
        }
        if !microphoneEnabled {
            microphone?.stop()
            microphone = nil
        } else if microphone == nil, let profile = profile.microphone, profile.isValid {
            microphone = capture(.microphone(profile), token: token)
        }
    }

    func advance(
        epoch: Epoch, target: Int?, state: AlignmentState, write: WriteRequest?,
        trackChanged: Bool, profile: SensorProfile?, now: TimeInterval, confirmedAt: TimeInterval? = nil
    ) {
        if self.epoch != epoch {
            self.epoch = epoch
            transition = nil
            led.removeAll()
            relayTimes.removeAll()
            outcome = nil
        }
        guard camera != nil || microphone != nil, state == .aligned, let target else {
            transition = nil
            outcome = nil
            return
        }
        if transition?.rate != target {
            transition = TransitionVerification(epoch: epoch, rate: target, confirmedAt: confirmedAt ?? now,
                                                trackChanged: trackChanged, writeStarted: write?.requestedAt)
            cutoff = write.map { $0.requestedAt + (profile?.microphone?.maximumLatency ?? 0) } ?? now
        }
        evaluate(now: now)
    }

    var description: String {
        if !problems.isEmpty { return problems.joined(separator: "; ") }
        return outcome?.rawValue ?? "No current hardware verification"
    }

    func stop() {
        guard deviceUID != nil else { return }
        token = UUID()
        camera?.stop()
        microphone?.stop()
        camera = nil
        microphone = nil
        deviceUID = nil
        transition = nil
        led.removeAll()
        relayTimes.removeAll()
        problems.removeAll()
        outcome = nil
    }

    private func capture(_ configuration: HardwareCapture.Configuration, token: UUID) -> HardwareCapture {
        let capture = HardwareCapture(configuration: configuration) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, token == self.token else { return }
                self.receive(event)
            }
        }
        capture.start()
        return capture
    }

    private func receive(_ event: SensorEvent) {
        switch event {
        case let .led(at, rate, score):
            guard let epoch, let transition, at >= transition.confirmedAt, at <= transition.confirmedAt + 2 else { return }
            led.append(LEDReading(epoch: epoch, at: at, rate: rate, lockedAndStable: true, confidence: score))
            // Retain current qualified disagreements for the whole window.
            if led.count > 32 { led.removeFirst() }
        case let .relay(at):
            relayTimes.removeAll { $0 < at - 2 }
            if relayTimes.count == 128 { relayTimes.removeFirst() }
            relayTimes.append(at)
        case let .unavailable(message):
            if !problems.contains(message) { problems.append(message) }
        }
        evaluate(now: ProcessInfo.processInfo.systemUptime)
    }

    private func evaluate(now: TimeInterval) {
        guard let transition else { return }
        let relay = relayTimes.filter { $0 <= cutoff }.map { RelayReading(epoch: transition.epoch, at: $0) }
        outcome = transition.evaluate(led: led, relay: relay, now: now)
    }
}
