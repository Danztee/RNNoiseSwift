import XCTest
@testable import RNNoiseSwift

final class RNNoiseSwiftTests: XCTestCase {
    func testProcessStreamPreservesAllSamplesAcrossChunks() throws {
        let rnnoise = RNNoise()
        let input = (0 ..< 1024).map { _ in Float.random(in: -1 ... 1) }

        let first = try rnnoise.processStream(samples: Array(input[0 ..< 500]), sampleRate: RNNoise.requiredSampleRate)
        let second = try rnnoise.processStream(samples: Array(input[500 ..< input.count]), sampleRate: RNNoise.requiredSampleRate)
        let tail = rnnoise.flush()

        XCTAssertEqual(first.count + second.count + tail.count, input.count)
        XCTAssertEqual(tail.count, input.count % rnnoise.frameSize)
    }

    func testFlushPartialFrameReturnsOnlyPendingLength() throws {
        let rnnoise = RNNoise()
        let input = (0 ..< 100).map { _ in Float.random(in: -1 ... 1) }

        let output = try rnnoise.processStream(samples: input, sampleRate: RNNoise.requiredSampleRate)
        XCTAssertTrue(output.isEmpty)

        let flushed = rnnoise.flush(processPartialFrame: true)
        XCTAssertEqual(flushed.count, input.count)
    }

    func testUnsupportedSampleRateThrows() {
        let rnnoise = RNNoise()

        XCTAssertThrowsError(
            try rnnoise.processStream(samples: [0, 0, 0, 0], sampleRate: 16_000)
        ) { error in
            guard case let RNNoiseError.unsupportedSampleRate(expected, actual) = error else {
                return XCTFail("Expected unsupportedSampleRate, got \(error)")
            }
            XCTAssertEqual(expected, RNNoise.requiredSampleRate)
            XCTAssertEqual(actual, 16_000)
        }
    }
}
