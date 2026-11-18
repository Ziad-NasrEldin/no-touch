import AVFoundation
import Foundation

/// Mono float PCM decoded for an engine, plus its true duration.
public struct DecodedAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    public var duration: TimeInterval

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
    }
}

/// Decodes any AVAudioFile-readable container (m4a/aac/caf/wav) to mono float
/// PCM at the engine's target rate. Decode is bounded: files longer than
/// `maxSeconds` are rejected before the (potentially large) PCM buffer is
/// allocated, per the spec's fail-visibly rule rather than silent truncation.
public enum AudioChunkDecoder {
    public static func decode(
        fileAt url: URL,
        targetSampleRate: Int = 16_000,
        maxSeconds: TimeInterval = 300
    ) throws -> DecodedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw PhoneAIError.audioDecodingFailed("cannot open \(url.lastPathComponent): \(error.localizedDescription)")
        }

        let sourceFormat = file.processingFormat
        let sourceSeconds = Double(file.length) / sourceFormat.sampleRate
        guard sourceFormat.sampleRate > 0, file.length > 0 else {
            throw PhoneAIError.audioDecodingFailed("\(url.lastPathComponent) is empty or has an invalid format")
        }
        guard sourceSeconds <= maxSeconds else {
            throw PhoneAIError.inputExceedsBound(
                "\(url.lastPathComponent) is \(String(format: "%.1f", sourceSeconds))s, bound is \(maxSeconds)s"
            )
        }

        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(targetSampleRate),
                channels: 1,
                interleaved: false
            )
        else {
            throw PhoneAIError.audioDecodingFailed("could not build target PCM format")
        }

        let framesToRead = AVAudioFrameCount(min(file.length, AVAudioFramePosition(maxSeconds * sourceFormat.sampleRate)))
        guard
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead)
        else {
            throw PhoneAIError.audioDecodingFailed("could not allocate input buffer")
        }
        do {
            try file.read(into: inputBuffer, frameCount: framesToRead)
        } catch {
            throw PhoneAIError.audioDecodingFailed("read failed for \(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard inputBuffer.frameLength > 0 else {
            return DecodedAudio(samples: [], sampleRate: targetSampleRate)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw PhoneAIError.audioDecodingFailed("no converter \(sourceFormat.sampleRate)Hz→\(targetSampleRate)Hz")
        }
        converter.primeMethod = .none
        let ratio = Double(targetSampleRate) / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
        guard
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity)
        else {
            throw PhoneAIError.audioDecodingFailed("could not allocate output buffer")
        }

        var conversionError: NSError?
        var inputConsumed = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if inputConsumed {
                status.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil else {
            throw PhoneAIError.audioDecodingFailed(
                "conversion failed for \(url.lastPathComponent): \(conversionError?.localizedDescription ?? "unknown")"
            )
        }
        guard outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData else {
            return DecodedAudio(samples: [], sampleRate: targetSampleRate)
        }

        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(outputBuffer.frameLength)))
        return DecodedAudio(samples: samples, sampleRate: targetSampleRate)
    }
}
