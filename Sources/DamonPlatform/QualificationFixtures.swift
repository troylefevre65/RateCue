import Foundation

public enum QualificationFixtures {
    public static let formats = [(44_100, 16), (44_100, 24), (48_000, 24), (88_200, 24),
                                 (96_000, 24), (176_400, 24), (192_000, 24)]

    static let trialRate = 96_000
    static let trialDepth = 24

    private struct Manifest: Encodable {
        struct Fixture: Encodable {
            let alac: String
            let reference: String
            let sampleRateHz: Int
            let bitDepth: Int
            let frames: Int
        }

        let schemaVersion = 1
        let fixtures: [Fixture]
    }

    public static func generate(at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for (rate, depth) in formats {
            try writePair(to: folder, rate: rate, depth: depth, frames: rate * 12)
        }
    }

    public static func generateKit(at folder: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: folder.path) else { throw CocoaError(.fileWriteFileExists) }
        let alacFolder = folder.appendingPathComponent("ALAC", isDirectory: true)
        let referenceFolder = folder.appendingPathComponent("PCM", isDirectory: true)
        for directory in [folder, alacFolder, referenceFolder] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let fixtures = try formats.map { rate, depth in
            let frames = rate * (rate == 44_100 || rate == 96_000 ? 60 : 12)
            let name = "Damon-\(rate)Hz-\(depth)bit"
            let alac = alacFolder.appendingPathComponent(name + ".m4a")
            let reference = referenceFolder.appendingPathComponent(name + ".wav")
            try writePair(reference: reference, encoded: alac, rate: rate, depth: depth, frames: frames)
            let result = try PCMComparison.compare(reference: reference, candidate: alac)
            guard result.verdict == .identical, result.referenceRate == rate, result.referenceFrames == frames,
                  result.referenceBitDepth == depth, result.candidateBitDepth == depth else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "Fixture validation failed for \(name): \(result.summary)"
                ])
            }
            return Manifest.Fixture(alac: "ALAC/\(alac.lastPathComponent)", reference: "PCM/\(reference.lastPathComponent)",
                                    sampleRateHz: rate, bitDepth: depth, frames: frames)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifest = try encoder.encode(Manifest(fixtures: fixtures))
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    }

    static func prepareTrial(in folder: URL, rate: Int = trialRate, depth: Int = trialDepth) throws -> URL {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        if !FileManager.default.fileExists(atPath: root.path) {
            try generateKit(at: root)
        }
        let basename = "Damon-\(rate)Hz-\(depth)bit"
        let alac = root.appendingPathComponent("ALAC/\(basename).m4a")
        let reference = root.appendingPathComponent("PCM/\(basename).wav")
        guard alac.resolvingSymlinksInPath() == alac, reference.resolvingSymlinksInPath() == reference else {
            throw CocoaError(.fileReadInvalidFileName, userInfo: [NSLocalizedDescriptionKey: "The trial files must not be symlinks."])
        }
        let result = try PCMComparison.compare(reference: reference, candidate: alac)
        guard result.verdict == .identical, result.referenceRate == rate, result.referenceBitDepth == depth,
              result.candidateBitDepth == depth, result.referenceFrames == rate * 60 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "The live trial needs the validated 60-second \(rate) Hz / \(depth)-bit ALAC and PCM pair."])
        }
        return alac
    }

    @discardableResult
    static func writePair(to folder: URL, rate: Int, depth: Int, frames: Int) throws -> URL {
        let name = "Damon-\(rate)Hz-\(depth)bit"
        let source = folder.appendingPathComponent(name + ".wav")
        let encoded = folder.appendingPathComponent(name + ".m4a")
        try writePair(reference: source, encoded: encoded, rate: rate, depth: depth, frames: frames)
        return encoded
    }

    private static func writePair(reference: URL, encoded: URL, rate: Int, depth: Int, frames: Int) throws {
        guard formats.contains(where: { $0 == (rate, depth) }), (1...(rate * 60)).contains(frames) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Invalid fixture format or frame count"])
        }
        guard !FileManager.default.fileExists(atPath: encoded.path) else { throw CocoaError(.fileWriteFileExists) }
        try referenceWave(rate: rate, depth: depth, frames: frames).write(to: reference, options: .withoutOverwriting)
        let conversion = Process()
        conversion.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        conversion.arguments = ["-f", "m4af", "-d", "alac", reference.path, encoded.path]
        try conversion.run()
        conversion.waitUntilExit()
        guard conversion.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "afconvert failed for \(encoded.lastPathComponent) (status \(conversion.terminationStatus))"
            ])
        }
    }

    private static func referenceWave(rate: Int, depth: Int, frames: Int) -> Data {
        let bytesPerSample = depth / 8
        let bytesPerFrame = 2 * bytesPerSample
        let length = frames * bytesPerFrame
        var bytes = Data("RIFF".utf8)
        bytes.reserveCapacity(44 + length)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        append(UInt32(36 + length))
        bytes.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(2))
        append(UInt32(rate))
        append(UInt32(rate * bytesPerFrame))
        append(UInt16(bytesPerFrame))
        append(UInt16(depth))
        bytes.append(contentsOf: "data".utf8)
        append(UInt32(length))
        let scale = Double(1 << (depth - 1)) / 64
        for index in 0..<frames {
            let time = Double(index) / Double(rate)
            let fade = min(1, Double(min(index, frames - 1 - index)) / (Double(rate) / 40))
            for frequency in [371.0, 593.0] {
                // Distinct, quiet channels make swaps and sample offsets detectable in a reference capture.
                let amplitude = sin(time * 2 * .pi * frequency) * fade * scale
                var sample = Int32(amplitude.rounded()).littleEndian
                withUnsafeBytes(of: &sample) { bytes.append(contentsOf: $0.prefix(bytesPerSample)) }
            }
        }
        return bytes
    }
}
