import DamonPolicy
import Foundation

enum SwitchTrial {
    struct Fixture {
        let file: URL
        let rate: Int
        let depth: Int
    }

    struct Driver {
        let now: () -> TimeInterval
        let sleep: (TimeInterval) -> Void
        let play: (URL, URL?) throws -> TimeInterval
        let observe: (URL) -> PlaybackSample
        let write: (WriteRequest, OutputDevice, URL) throws -> Int32
        let readRate: () -> Int?
    }

    struct Leg: Encodable {
        let sourceRateHz: Int
        let bitDepth: Int
        var outcome = "failed"
        var detail: String?
        var sourceDetectionMs: Double?
        var alignmentReadbackMs: Double?
        var requestToReadbackMs: Double?
        var lastObservedRateHz: Int?
        var writeStatuses: [Int32] = []
        var submissionMs: Double?
        var observedSubmittedRate = false
        var continuityCheckMs: Double?

        var passed: Bool { outcome != "failed" }
    }

    struct Report: Encodable {
        let passed: Bool
        let device: String
        let initialRateHz: Int
        let finalRateHz: Int?
        let restored: Bool
        let transitions: [Leg]
        let recovery: Leg?
    }

    static func run(
        device: OutputDevice, high: Fixture, baseline: Fixture, sameRate: Fixture, driver: Driver
    ) -> Report {
        var transitions: [Leg] = []
        var previous: URL?
        for (fixture, startingRate) in [(high, baseline.rate), (baseline, high.rate), (sameRate, baseline.rate)] {
            let leg = runLeg(fixture, device: device, previous: &previous, startingRate: startingRate, driver: driver)
            transitions.append(leg)
            if !leg.passed { break }
        }

        // A write can settle after its deadline. Only recover once its effect is observable,
        // on the same endpoint and using the authorized baseline fixture, not a blind rollback.
        var recovery: Leg?
        let submittedHigh = transitions.first?.writeStatuses.contains(0) == true
        let submittedBaseline = transitions.dropFirst().last(where: { $0.writeStatuses.contains(0) })
        if submittedHigh, submittedBaseline == nil, driver.readRate() == high.rate {
            recovery = runLeg(baseline, device: device, previous: &previous, startingRate: high.rate, driver: driver)
        }
        let final = driver.readRate()
        let returnedToBaseline = submittedBaseline ?? recovery
        let restored = final == baseline.rate && (!submittedHigh || returnedToBaseline?.observedSubmittedRate == true)
        return Report(passed: transitions.count == 3 && transitions.allSatisfy(\.passed) && restored,
                      device: device.name, initialRateHz: baseline.rate, finalRateHz: final,
                      restored: restored, transitions: transitions, recovery: recovery)
    }

    static func runLeg(
        _ fixture: Fixture, device: OutputDevice, previous: inout URL?, startingRate: Int, driver: Driver
    ) -> Leg {
        var report = Leg(sourceRateHz: fixture.rate, bitDepth: fixture.depth)
        let mustWrite = fixture.rate != startingRate
        let start: TimeInterval
        do {
            start = try driver.play(fixture.file, previous)
            previous = fixture.file
        } catch {
            report.detail = error.localizedDescription
            return report
        }
        let limit = start + 2
        let epoch = Epoch(playback: 1, route: 1)
        var machine = AlignmentMachine()
        var firstWriteAt: TimeInterval?
        var writeDeadline: TimeInterval?
        var trackID: String?
        repeat {
            let sample = driver.observe(fixture.file)
            let now = driver.now()
            if let current = sample.preferredOutput(uid: device.uid), current.endpoint == device.endpoint {
                report.lastObservedRateHz = current.nominalRate
                if let trackID, let playback = sample.playback, playback.trackID != trackID {
                    report.detail = "Playback changed before the switch was verified."
                    break
                }
                if let rendition = sample.format, rendition.rate == fixture.rate, rendition.depth == fixture.depth,
                   sample.at >= start, sample.playback?.state == .playing,
                   sample.playback?.file?.resolvingSymlinksInPath().standardizedFileURL == fixture.file,
                   let currentTrackID = sample.playback?.trackID {
                    trackID = currentTrackID
                    if report.sourceDetectionMs == nil { report.sourceDetectionMs = milliseconds(now - start) }
                    let routeConfirmed = sample.route == [current.objectID]
                    if routeConfirmed && firstWriteAt == nil && current.nominalRate != startingRate {
                        report.detail = "The selected device no longer starts this leg at \(startingRate) Hz."
                        break
                    }
                    func input(rate: Int?) -> AlignmentInput {
                        AlignmentInput(epoch: epoch, playbackBoundary: start, playing: true, enabled: true, devicePresent: true,
                                       preferredIsConfirmedRoute: routeConfirmed, qualified: true, supportsTarget: current.supports(fixture.rate),
                                       target: fixture.rate, readback: rate, endpoint: current.endpoint,
                                       observedEndpoints: [current.endpoint: rate])
                    }
                    let request = machine.step(input(rate: current.nominalRate), now: now)
                    if let request, mustWrite {
                        firstWriteAt = firstWriteAt ?? request.requestedAt
                        writeDeadline = request.deadline
                        do {
                            let status = try driver.write(request, current, fixture.file)
                            report.submissionMs = milliseconds(driver.now() - request.requestedAt)
                            report.writeStatuses.append(status)
                            machine.receive(AudioHardware.writeDisposition(status), for: request)
                            if status == 0 {
                                let readback = RateConfirmation.poll(request, read: driver.readRate, now: driver.now, sleep: driver.sleep)
                                report.lastObservedRateHz = readback.rate
                                guard readback.rate == request.rate else {
                                    report.detail = "The pending write did not receive matching readback in time."
                                    return report
                                }
                                report.observedSubmittedRate = true
                                _ = machine.step(input(rate: readback.rate), now: readback.at)
                                report.alignmentReadbackMs = milliseconds(readback.at - (firstWriteAt ?? request.requestedAt))
                                report.requestToReadbackMs = milliseconds(readback.at - start)
                                guard machine.confirmedWrite != nil else {
                                    report.detail = "The device rate was confirmed only after the alignment deadline."
                                    return report
                                }
                                let continuity = RateConfirmation.confirmContinuity(
                                    after: readback.at, device: current, format: rendition, file: fixture.file,
                                    trackID: currentTrackID, observe: { driver.observe(fixture.file) }, now: driver.now, sleep: driver.sleep
                                )
                                report.continuityCheckMs = milliseconds(driver.now() - readback.at)
                                switch continuity {
                                case .confirmed: report.outcome = "switched"
                                case let .failed(warning): report.detail = warning
                                }
                                return report
                            }
                        } catch {
                            report.detail = error.localizedDescription
                            break
                        }
                    } else if machine.state == .aligned, now <= limit {
                        if !mustWrite && firstWriteAt == nil {
                            report.outcome = "alreadyMatched"
                        }
                        if report.passed {
                            report.requestToReadbackMs = milliseconds(now - start)
                            return report
                        }
                    } else if machine.state == .failed || machine.state == .drift || machine.state == .unsupportedRate {
                        report.detail = machine.state.rawValue
                        break
                    }
                }
            } else {
                report.detail = "The selected endpoint disconnected or changed identity."
                break
            }
            let remaining = min(limit, writeDeadline ?? limit) - driver.now()
            if remaining <= 0 { break }
            driver.sleep(min(0.02, remaining))
        } while true
        if report.detail == nil {
            report.detail = firstWriteAt == nil
                ? "The exact playing fixture and route were not confirmed in time."
                : "The pending write did not receive matching readback in time."
        }
        return report
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Double {
        (seconds * 1_000_000).rounded() / 1_000
    }
}
