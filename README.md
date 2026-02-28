# Swift Implementation - RNNoise

Swift wrapper for the [RNNoise](https://github.com/xiph/rnnoise) C library.

## Platform support
- iOS 15+
- macOS 13+

## Quick start (local package)
1. Clone this repository.
2. Build:
   ```bash
   swift build -c debug
   ```
3. Add `RNNoiseSwift` as a local package in Xcode.
4. Use the stateful streaming API:
   ```swift
   let rnnoise = RNNoise()
   let denoised = try rnnoise.processStream(samples: samples48k, sampleRate: 48_000)
   let tail = rnnoise.flush(processPartialFrame: false)
   ```

## Input requirements
- RNNoise expects 48 kHz audio.
- Use PCM Float32 samples.
- Multi-channel `AVAudioPCMBuffer` input is averaged to mono.

## API notes
- `processStream(samples:sampleRate:)` and `processStream(_ buffer:)` are the recommended APIs.
- Incomplete frames are buffered internally; samples are not dropped between calls.
- `flush(processPartialFrame:)` lets you retrieve pending samples at end-of-stream.
- Legacy in-place methods `process(_:)` and `processBuffer(_:)` are kept for compatibility and only process full frames from each call.

## Production-ready source layout
This fork vendors RNNoise C sources directly under `Libraries/RNNoise`, including
required model source files (`src/rnnoise_data.c` and `src/rnnoise_data.h`).
That keeps CI/SPM builds reproducible without runtime/bootstrap downloads.

## Optional model refresh
If you need to refresh model source files from upstream:
```bash
./scripts/bootstrap-rnnoise-model.sh
```

## Build
```bash
swift build -c debug
```

## Test
```bash
swift test
```

## How to build XCFramework manually
1. Build C library first (`Libraries/RNNoise`).
2. Create XCFramework:
```bash
xcodebuild -create-xcframework \
  -library Libraries/RNNoise/.libs/librnnoise.a \
  -headers Libraries/RNNoise/include \
  -output RNNoise.xcframework
```
