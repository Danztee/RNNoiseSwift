//
//  RNNoise.swift
//
//  Created by Patryk Dajos on 22.10.24.
//

import AVFoundation
import CRNNoise
import Foundation

public enum RNNoiseError: Error {
    case unsupportedSampleFormat
    case unsupportedChannelCount(Int)
    case unsupportedSampleRate(expected: Double, actual: Double)
}

extension RNNoiseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSampleFormat:
            return "RNNoise expects PCM Float32 audio"
        case let .unsupportedChannelCount(channels):
            return "RNNoise expects at least one audio channel (got \(channels))"
        case let .unsupportedSampleRate(expected, actual):
            return "RNNoise expects \(Int(expected)) Hz input (got \(actual) Hz)"
        }
    }
}

public final class RNNoise {
    public static let requiredSampleRate: Double = 48_000

    public let frameSize: Int

    private let denoiseState: OpaquePointer
    private var carryoverSamples: [Float] = []
    private let lock = NSLock()

    /// Creates RNNoise instance with default model.
    public init() {
        denoiseState = rnnoise_create(nil)
        frameSize = Int(rnnoise_get_frame_size())
    }

    deinit {
        rnnoise_destroy(denoiseState)
    }

    /// Legacy in-place denoise. It processes only full RNNoise frames from the supplied buffer.
    ///
    /// For lossless streaming, use `processStream(samples:sampleRate:)`.
    @available(*, deprecated, message: "Use processStream(samples:sampleRate:) to avoid dropping trailing samples.")
    public func process(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return }
        guard abs(buffer.format.sampleRate - Self.requiredSampleRate) < 0.5 else { return }
        guard buffer.format.channelCount == 1, !buffer.format.isInterleaved else { return }
        guard let samples = buffer.floatChannelData?.pointee else { return }

        let totalSamples = Int(buffer.frameLength)
        lock.withLock {
            processFullFramesInPlace(samples, totalSamples: totalSamples)
        }
    }

    /// Legacy in-place denoise. It processes only full RNNoise frames from the supplied buffer.
    ///
    /// For lossless streaming, use `processStream(samples:sampleRate:)`.
    @available(*, deprecated, message: "Use processStream(samples:sampleRate:) to avoid dropping trailing samples.")
    public func processBuffer(_ bufferPointer: UnsafeMutableBufferPointer<Float>) {
        guard let samplesPointer = bufferPointer.baseAddress else { return }

        lock.withLock {
            processFullFramesInPlace(samplesPointer, totalSamples: bufferPointer.count)
        }
    }

    /// Clears buffered carryover samples. By default this also resets RNNoise's recurrent denoise state.
    public func reset(resetDenoiseState: Bool = true) {
        lock.withLock {
            carryoverSamples.removeAll(keepingCapacity: true)
            if resetDenoiseState {
                _ = rnnoise_init(denoiseState, nil)
            }
        }
    }

    /// Stateful streaming API for 48 kHz Float32 mono samples.
    ///
    /// This method never drops trailing samples. It buffers incomplete RNNoise frames
    /// and emits output only for complete frames.
    /// Returns a tuple of (denoisedSamples, speechProbability).
    public func processStream(samples: [Float], sampleRate: Double) throws -> ([Float], Float) {
        if samples.isEmpty {
            return ([], 0.0)
        }

        try validateSampleRate(sampleRate)

        return lock.withLock {
            processStreamLocked(newSamples: samples)
        }
    }

    /// Stateful streaming API for 48 kHz Float32 mono samples.
    /// Returns a tuple of (denoisedSamples, speechProbability).
    public func processStream(samples: UnsafeBufferPointer<Float>, sampleRate: Double) throws -> ([Float], Float) {
        guard let baseAddress = samples.baseAddress, samples.count > 0 else {
            return ([], 0.0)
        }

        try validateSampleRate(sampleRate)

        return lock.withLock {
            let copied = Array(UnsafeBufferPointer(start: baseAddress, count: samples.count))
            return processStreamLocked(newSamples: copied)
        }
    }

    /// Stateful streaming API for `AVAudioPCMBuffer` input.
    ///
    /// Requirements:
    /// - `buffer.format.commonFormat == .pcmFormatFloat32`
    /// - `buffer.format.sampleRate == 48_000`
    ///
    /// Multi-channel input is averaged to mono before denoising.
    /// Returns a tuple of (denoisedSamples, speechProbability).
    public func processStream(_ buffer: AVAudioPCMBuffer) throws -> ([Float], Float) {
        try Self.validateFormat(buffer.format)

        let mono = try Self.extractMonoFloat32(from: buffer)
        if mono.isEmpty {
            return ([], 0.0)
        }

        return try processStream(samples: mono, sampleRate: buffer.format.sampleRate)
    }

    /// Flushes pending carryover samples.
    ///
    /// - `processPartialFrame == false` returns pending samples unchanged.
    /// - `processPartialFrame == true` zero-pads to one RNNoise frame, denoises, and returns
    ///   only the original pending sample count.
    /// Returns a tuple of (flushedSamples, speechProbability).
    public func flush(processPartialFrame: Bool = false) -> ([Float], Float) {
        lock.withLock {
            guard !carryoverSamples.isEmpty else { return ([], 0.0) }

            let pending = carryoverSamples
            carryoverSamples.removeAll(keepingCapacity: true)

            guard processPartialFrame else {
                return (pending, 0.0)
            }

            var padded = pending
            if padded.count < frameSize {
                padded.append(contentsOf: repeatElement(0.0, count: frameSize - padded.count))
            }

            let probability = denoiseFramesInPlace(&padded, frameCount: 1)
            return (Array(padded.prefix(pending.count)), probability)
        }
    }

    public static func validateFormat(_ format: AVAudioFormat) throws {
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw RNNoiseError.unsupportedSampleFormat
        }

        let channels = Int(format.channelCount)
        guard channels > 0 else {
            throw RNNoiseError.unsupportedChannelCount(channels)
        }

        if abs(format.sampleRate - requiredSampleRate) >= 0.5 {
            throw RNNoiseError.unsupportedSampleRate(expected: requiredSampleRate, actual: format.sampleRate)
        }
    }

    private func validateSampleRate(_ sampleRate: Double) throws {
        if abs(sampleRate - Self.requiredSampleRate) >= 0.5 {
            throw RNNoiseError.unsupportedSampleRate(expected: Self.requiredSampleRate, actual: sampleRate)
        }
    }

    private func processStreamLocked(newSamples: [Float]) -> ([Float], Float) {
        var combined: [Float]
        if carryoverSamples.isEmpty {
            combined = newSamples
        } else {
            combined = carryoverSamples
            combined.reserveCapacity(carryoverSamples.count + newSamples.count)
            combined.append(contentsOf: newSamples)
        }

        let frameCount = combined.count / frameSize
        guard frameCount > 0 else {
            carryoverSamples = combined
            return ([], 0.0)
        }

        let processedSampleCount = frameCount * frameSize
        let probability = denoiseFramesInPlace(&combined, frameCount: frameCount)

        let output = Array(combined.prefix(processedSampleCount))
        carryoverSamples = Array(combined.dropFirst(processedSampleCount))
        return (output, probability)
    }

    @discardableResult
    private func denoiseFramesInPlace(_ samples: inout [Float], frameCount: Int) -> Float {
        guard frameCount > 0 else { return 0.0 }

        var totalProbability: Float = 0
        samples.withUnsafeMutableBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }

            for frame in 0 ..< frameCount {
                let frameStart = baseAddress.advanced(by: frame * frameSize)
                totalProbability += rnnoise_process_frame(denoiseState, frameStart, frameStart)
            }
        }
        return totalProbability / Float(frameCount)
    }

    @discardableResult
    private func processFullFramesInPlace(_ samples: UnsafeMutablePointer<Float>, totalSamples: Int) -> Float {
        let frameCount = totalSamples / frameSize
        guard frameCount > 0 else { return 0.0 }

        var totalProbability: Float = 0
        for frame in 0 ..< frameCount {
            let frameStart = samples.advanced(by: frame * frameSize)
            totalProbability += rnnoise_process_frame(denoiseState, frameStart, frameStart)
        }
        return totalProbability / Float(frameCount)
    }

    private static func extractMonoFloat32(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else {
            throw RNNoiseError.unsupportedSampleFormat
        }

        let frameCount = Int(buffer.frameLength)
        if frameCount == 0 {
            return []
        }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else {
            throw RNNoiseError.unsupportedChannelCount(channelCount)
        }

        if !buffer.format.isInterleaved {
            guard let channels = buffer.floatChannelData else {
                throw RNNoiseError.unsupportedSampleFormat
            }

            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
            }

            var mono = [Float](repeating: 0, count: frameCount)
            let scale = 1.0 / Float(channelCount)
            for channel in 0 ..< channelCount {
                let source = channels[channel]
                for index in 0 ..< frameCount {
                    mono[index] += source[index] * scale
                }
            }
            return mono
        }

        guard let rawData = buffer.audioBufferList.pointee.mBuffers.mData else {
            throw RNNoiseError.unsupportedSampleFormat
        }

        let interleaved = rawData.assumingMemoryBound(to: Float.self)
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: interleaved, count: frameCount))
        }

        var mono = [Float](repeating: 0, count: frameCount)
        let scale = 1.0 / Float(channelCount)

        for frame in 0 ..< frameCount {
            let baseIndex = frame * channelCount
            var sum: Float = 0
            for channel in 0 ..< channelCount {
                sum += interleaved[baseIndex + channel]
            }
            mono[frame] = sum * scale
        }

        return mono
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
