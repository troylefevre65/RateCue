import AudioToolbox
import Foundation

public enum PCMComparison {
    public enum Verdict: Equatable {
        case identical
        case differentRate
        case differentLength
        case differentSample(frame: Int64, channel: Int)
    }

    public struct Report {
        public let verdict: Verdict
        public let referenceRate: Int
        public let candidateRate: Int
        public let referenceBitDepth: Int
        public let candidateBitDepth: Int
        public let referenceFrames: Int64
        public let candidateFrames: Int64
        public let offset: Int64?

        public var summary: String {
            switch verdict {
            case .identical:
                "Match: \(referenceFrames) stereo frames at \(referenceRate) Hz (candidate start frame \(offset ?? 0))"
            case .differentRate:
                "Mismatch: sample rates differ (\(referenceRate) Hz vs. \(candidateRate) Hz)"
            case .differentLength:
                "Mismatch: reference has \(referenceFrames) frames, candidate has \(candidateFrames) frames (start frame \(offset ?? 0))"
            case let .differentSample(frame, channel):
                "Mismatch: first differing sample at reference frame \(frame), channel \(channel)"
            }
        }
    }

    /// A supplied offset permits extra capture frames before or after the full reference window.
    public static func compare(reference: URL, candidate: URL, offset: Int64? = nil) throws -> Report {
        guard offset.map({ $0 >= 0 }) ?? true else { throw Failure.invalidOffset }
        let expected = try Reader(url: reference)
        let actual = try Reader(url: candidate)
        func report(_ verdict: Verdict) -> Report {
            Report(verdict: verdict, referenceRate: expected.rate, candidateRate: actual.rate,
                   referenceBitDepth: expected.bitDepth, candidateBitDepth: actual.bitDepth,
                   referenceFrames: expected.frames, candidateFrames: actual.frames, offset: offset)
        }
        guard expected.rate == actual.rate else { return report(.differentRate) }
        let start = offset ?? 0
        guard start <= actual.frames, expected.frames <= actual.frames - start,
              offset != nil || expected.frames == actual.frames else {
            return report(.differentLength)
        }
        if start > 0 { try actual.seek(to: start) }

        var expectedSamples = [Int32](repeating: 0, count: 16_384)
        var actualSamples = expectedSamples
        var frame: Int64 = 0
        while frame < expected.frames {
            let count = Int(min(8_192, expected.frames - frame))
            guard try expected.read(frames: count, into: &expectedSamples) == count,
                  try actual.read(frames: count, into: &actualSamples) == count else {
                throw Failure.unexpectedEnd
            }
            for index in 0..<(count * 2) where expectedSamples[index] != actualSamples[index] {
                return report(.differentSample(frame: frame + Int64(index / 2), channel: index % 2 + 1))
            }
            frame += Int64(count)
        }
        return report(.identical)
    }

    static func integerBitDepth(_ format: AudioStreamBasicDescription) -> Int? {
        switch format.mFormatID {
        case kAudioFormatLinearPCM where format.mFormatFlags & kAudioFormatFlagIsFloat == 0:
            let bits = Int(format.mBitsPerChannel)
            return (1...32).contains(bits) ? bits : nil
        case kAudioFormatAppleLossless:
            switch format.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: return 16
            case kAppleLosslessFormatFlag_20BitSourceData: return 20
            case kAppleLosslessFormatFlag_24BitSourceData: return 24
            case kAppleLosslessFormatFlag_32BitSourceData: return 32
            default: return nil
            }
        default:
            return nil
        }
    }

    private enum Failure: LocalizedError {
        case invalidOffset
        case unsupportedFormat(String)
        case audioError(operation: String, file: String, status: OSStatus)
        case unexpectedEnd

        var errorDescription: String? {
            switch self {
            case .invalidOffset: "The capture offset must be nonnegative."
            case let .unsupportedFormat(file): "\(file) must contain nonempty stereo integer PCM or Apple Lossless audio."
            case let .audioError(operation, file, status): "\(operation) failed for \(file) (AudioToolbox status \(status))."
            case .unexpectedEnd: "A file ended before its declared frame count."
            }
        }
    }

    private final class Reader {
        let rate: Int
        let bitDepth: Int
        let frames: Int64
        private let file: ExtAudioFileRef
        private let name: String

        init(url: URL) throws {
            let name = url.lastPathComponent
            var handle: ExtAudioFileRef?
            let openStatus = ExtAudioFileOpenURL(url as CFURL, &handle)
            guard openStatus == noErr, let handle else { throw Failure.audioError(operation: "Open", file: name, status: openStatus) }
            do {
                var source = AudioStreamBasicDescription()
                var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                try Self.check(ExtAudioFileGetProperty(handle, kExtAudioFileProperty_FileDataFormat, &size, &source), "Read format", name)
                var frameCount: Int64 = 0
                size = UInt32(MemoryLayout<Int64>.size)
                try Self.check(ExtAudioFileGetProperty(handle, kExtAudioFileProperty_FileLengthFrames, &size, &frameCount), "Read frame count", name)
                guard source.mChannelsPerFrame == 2, let rate = Int(exactly: source.mSampleRate), rate > 0,
                      let depth = integerBitDepth(source), frameCount > 0 else { throw Failure.unsupportedFormat(name) }
                // Keep the native rate and channels. Integer expansion normalizes container width and endianness.
                var client = AudioStreamBasicDescription(
                    mSampleRate: source.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
                    mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                    mBitsPerChannel: 32, mReserved: 0
                )
                size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                try Self.check(ExtAudioFileSetProperty(handle, kExtAudioFileProperty_ClientDataFormat, size, &client),
                               "Configure integer decoding", name)
                self.file = handle
                self.name = name
                self.rate = rate
                self.bitDepth = depth
                self.frames = frameCount
            } catch {
                ExtAudioFileDispose(handle)
                throw error
            }
        }

        deinit { ExtAudioFileDispose(file) }

        func seek(to frame: Int64) throws {
            try Self.check(ExtAudioFileSeek(file, frame), "Seek", name)
        }

        func read(frames: Int, into samples: inout [Int32]) throws -> Int {
            var count = UInt32(frames)
            let status = samples.withUnsafeMutableBytes { buffer in
                var list = AudioBufferList(mNumberBuffers: 1,
                                           mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: count * 8,
                                                                 mData: buffer.baseAddress))
                return ExtAudioFileRead(file, &count, &list)
            }
            try Self.check(status, "Decode samples", name)
            return Int(count)
        }

        private static func check(_ status: OSStatus, _ operation: String, _ file: String) throws {
            guard status == noErr else { throw Failure.audioError(operation: operation, file: file, status: status) }
        }
    }
}
