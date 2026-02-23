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
4. Use `processBuffer(_:)` or `process(_:)` from `RNNoise`.

> Note: Input buffers must be mono PCM Float32.

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

## How to build XCFramework manually
1. Build C library first (`Libraries/RNNoise`).
2. Create XCFramework:
```bash
xcodebuild -create-xcframework \
  -library Libraries/RNNoise/.libs/librnnoise.a \
  -headers Libraries/RNNoise/include \
  -output RNNoise.xcframework
```
