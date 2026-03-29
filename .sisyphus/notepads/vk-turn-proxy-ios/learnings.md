# Learnings — vk-turn-proxy iOS Port

Track conventions, patterns, and discovered insights here. Append only (never overwrite).

## Task 3: XcodeGen Configuration (2026-03-30)

### XcodeGen Project Spec Patterns
- **YAML structure**: Simple declarative format matching Xcode project structure
- **Platform**: Use `platform: iOS` (singular, not "iOS target")
- **Deployment Target**: Set both at project level (`options.deploymentTarget`) and target level (`targets.<name>.deploymentTarget`)
- **Dependencies**: Use `sdk:` prefix for system frameworks and static libs (e.g., `sdk: libvkturn.a`)

### Swift + Objective-C Bridging
- **Bridging header path**: Set `SWIFT_OBJC_BRIDGING_HEADER: Sources/Bridge/VKTurnProxy-Bridging-Header.h`
- **Search paths**: Need both `HEADER_SEARCH_PATHS` and `LIBRARY_SEARCH_PATHS` pointing to Go build output
- **Pattern**: `$(PROJECT_DIR)/build/go` for relative paths (automatically resolved)

### Static Library Linking (Go)
- Go generates `libvkturn.a` static library
- Link via `sdk: libvkturn.a` in dependencies
- **System frameworks required**: 
  - `libresolv.tbd` — Go's `net` package uses DNS resolution
  - `Security.framework` — TLS/SSL operations for DTLS
- **No Network Extension**: Verified entitlements are minimal (no NEProvider capability)

### iOS 18.0 Minimum
- Set `IPHONEOS_DEPLOYMENT_TARGET: "18.0"`
- `deploymentTarget: "18.0"` in project options
- Info.plist: `<string>18.0</string>` for `LSMinimumSystemVersion`

### Background Audio Mode
- **iOS plist format**: `UIBackgroundModes` array with string value `"audio"`
- **Why audio**: TURN server proxying needs background execution; audio mode is lightweight, not an extension
- **ATS exception**: `NSAppTransportSecurity.NSAllowsArbitraryLoads: true` needed for VK API endpoints (not HTTPS)

### Architecture Targeting
- **arm64 only**: Set `VALID_ARCHS: arm64` and `ARCHS: arm64`
- **No simulator support**: x86_64/arm64e excluded
- **Device only build**: Matches Apple Silicon Macs requirement

### Info.plist Auto-Generation
- XcodeGen can generate minimal plist, but explicit is better for:
  - `CFBundleDisplayName: VK Turn`
  - `UIBackgroundModes` configuration
  - `NSAppTransportSecurity` exemptions
- Values like `CFBundleIdentifier`, `CFBundleExecutable` can use `$(PRODUCT_BUNDLE_IDENTIFIER)` and `$(EXECUTABLE_NAME)`

### Device Family Support
- `TARGETED_DEVICE_FAMILY: "1,2"` = iPhone (1) + iPad (2)
- Useful for TURN proxy (can run on both form factors)

## Build System Patterns

### iOS C-Archive Build Script (scripts/build-go.sh)

**Key Insights:**
- WireGuard iOS uses exactly same pattern: `GOOS=ios GOARCH=arm64 CGO_ENABLED=1 CC=$(xcrun --sdk iphoneos --find clang) go build -buildmode=c-archive`
- iOS SDK path must be resolved via `xcrun --sdk iphoneos --show-sdk-path` (not hardcoded)
- Both CGO_CFLAGS and CGO_LDFLAGS must include `-arch arm64 -isysroot $SDK_PATH`
- go build with c-archive automatically produces both .a and .h files

**Script Features:**
- Idempotent: Can run multiple times safely (mkdir -p, build overwrites)
- Prerequisite checks: Go, Xcode CLI Tools, iOS SDK availability
- Color-coded logging: [INFO] green, [WARN] yellow, ERROR red
- Graceful error handling: set -e + detailed error messages
- Modular: Detects go.mod in go/ or root directory
- Output verification: Checks both .a and .h exist before claiming success

**Error Paths Covered:**
1. Go not installed → Clear message to install
2. Xcode not installed → Clear message to install
3. xcode-select not configured → Suggest reset
4. iOS SDK unavailable → Troubleshooting hint
5. Go module not found → Check paths
6. Build failure → Captured by set -e
7. Missing artifacts → Explicit verification checks

**File Size Reporting:**
- Uses `numfmt --to=iec-i` for human-readable sizes (fallback to bytes)
- Counts exported symbols via grep "^extern" in header
- Verifies iOS platform via otool (if available)

## Task 1: vk-turn-proxy Go Bridge Foundation (2026-03-30)

- WireGuard Apple c-archive export pattern is strict: `import "C"` plus `//export` directives directly above exported functions and an empty `func main() {}` in package `main`.
- For iOS bridge integration, replacing CLI flags with JSON config (`peer`, `vkLink`, `listen`, `streams`, `udp`) keeps the API stable and simple for Swift callers.
- Handle-based lifecycle (`map[int32]*proxyInstance`) with `context.WithCancel` cleanly replaces signal-based process lifecycle and supports multiple concurrent proxy instances.
- Removing Yandex code is safest when done at the type/function level (no partial stubs): eliminate Telemost credential flow entirely and keep only VK credential acquisition.
- `go mod tidy` on this module upgraded `go` directive to `1.25.0` and resolved full transitive graph needed for `GOOS=ios GOARCH=arm64 CGO_ENABLED=1` c-archive builds.

## 2026-03-30 (Task 5: Minimal SwiftUI Interface)
- Implemented `VKTurnProxyApp` with a single entry point to `ContentView`
- Designed `ContentView` as a single-screen `VStack` adhering to minimal design requirements (no navs, no custom styles).
- Connected a mocked/expected `ProxyManager` using `@StateObject` directly in the view.
- Ensured strict compliance with the directive: avoided any NavigationStack, NavigationView, or TabView components. Used standard system colors (red/green) and `.monospaced` system font for logs to maintain simplicity.

## Task 4: Swift C Bridge and Proxy Manager (2026-03-30)

### Swift-C Interop Patterns

**Bridging Header Minimalism:**
- Single `#include "libvkturn.h"` line is sufficient
- XcodeGen config handles path resolution via `SWIFT_OBJC_BRIDGING_HEADER` and `HEADER_SEARCH_PATHS`
- No need for additional guards or imports

**C String Memory Management:**
- CRITICAL: Every `C.char*` returned from Go must be freed via `VKTurnFreeString`
- Pattern: `defer { VKTurnFreeString(cString) }` immediately after receiving C string
- Swift's `String(cString:)` copies the C string, so deferred free is safe
- Memory leak if `VKTurnFreeString` not called (Go allocates via `C.CString`)

**C Function Calls from Swift:**
- Use `.withCString { ptr in }` to pass Swift strings to C
- C functions directly callable from Swift after bridging header import
- Return values: `int32` maps directly, `*C.char` requires explicit `String(cString:)` conversion

### Swift Wrapper Architecture

**Three-Layer Structure:**
1. **Bridging Header** (`VKTurnProxy-Bridging-Header.h`): Exposes C API to Swift
2. **Bridge Layer** (`VKTurnBridge.swift`): Static methods wrapping C calls, handles JSON encoding/decoding
3. **Manager Layer** (`ProxyManager.swift`): ObservableObject with SwiftUI lifecycle, async/await, status polling

**ProxyConfig and ProxyStatus:**
- Define as `Codable` structs matching JSON schema from Go
- JSONEncoder/JSONDecoder handle serialization for C API
- ProxyConfig: `peer`, `vkLink`, `listen`, `streams` (Int), `udp` (Bool)
- ProxyStatus: `state` (String), `error` (String)

### ObservableObject Pattern

**@MainActor Isolation:**
- Mark class with `@MainActor` to ensure all property updates on main thread
- SwiftUI requires `@Published` updates on main thread
- Simplifies synchronization vs manual `DispatchQueue.main.async`

**Published Properties:**
- `@Published private(set)` for read-only external access, internal mutation
- `isRunning`: Connection state (Bool)
- `statusText`: Human-readable status (String)
- `logMessages`: Array of timestamped log entries with bounded size (max 100)

**Background Execution:**
- Use `Task.detached` for C function calls (blocks thread, not async)
- Wrap blocking C calls to avoid blocking main thread
- Return to `MainActor.run` to update `@Published` properties

### Status Polling Implementation

**Timer-Based Polling:**
- `Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true)` for 1-second polling
- Store timer in `statusTimer` property, invalidate in `stopStatusPolling()`
- Timer fires on RunLoop, callback must be `@MainActor` or dispatch to main

**Graceful Error Handling:**
- Parse status JSON state: `running`, `stopped`, `error`, `not_found`
- Auto-disconnect on unexpected states (`stopped`, `error`, `not_found`) when `isRunning == true`
- Prevents zombie proxies after Go-side failures

### Lifecycle Management

**Connect Flow:**
1. Check not already running
2. Call `VKTurnBridge.startProxy` on `Task.detached` (background)
3. If handle >= 0: Store handle, set `isRunning = true`, start polling
4. If handle == -1: Log error, set status to "Connection Failed"

**Disconnect Flow:**
1. Check currently running
2. Stop status polling timer
3. Call `VKTurnBridge.stopProxy` on `Task.detached` (background)
4. Set `isRunning = false`, clear handle, update status

**Deinit Safety:**
- Check `isRunning` in `deinit`, call `disconnect()` if needed
- Prevents resource leaks if ProxyManager deallocated while connected

### Swift Concurrency with C

**Task.detached for Blocking C Calls:**
- C functions from Go are synchronous/blocking, not async
- Wrap in `Task.detached` to avoid blocking main thread
- Use `await MainActor.run` to update UI from detached task

**Async/Await in ObservableObject:**
- Methods can be `async` even though C calls aren't
- `Task { await self.method() }` from timer callback to bridge sync/async

### Log Management

**Bounded Log Array:**
- `maxLogEntries = 100` constant to limit memory growth
- `logMessages.removeFirst(count - max)` when exceeding limit
- Each entry: `LogEntry` struct with `id: UUID`, `timestamp: Date`, `message: String`
- `Identifiable` conformance for SwiftUI `List` rendering

### JSON Schema Compliance

**ProxyConfig matches Go bridge.go expectations:**
```swift
struct ProxyConfig: Codable {
    let peer: String         // "1.2.3.4:56000"
    let vkLink: String       // "https://vk.com/call/join/XXXX"
    let listen: String       // "127.0.0.1:9000"
    let streams: Int         // 16
    let udp: Bool            // false
}
```

**ProxyStatus matches Go statusJSON() output:**
```swift
struct ProxyStatus: Codable {
    let state: String   // "running|stopped|error|not_found"
    let error: String   // Error message or empty string
}
```

### Verification Results

**All QA Scenarios Passed:**
1. ✅ Bridging header exists with `#include "libvkturn.h"`
2. ✅ VKTurnBridge.swift calls `VKTurnStartProxy`, `VKTurnStopProxy`, `VKTurnGetStatus`
3. ✅ ProxyManager.swift conforms to `ObservableObject`
4. ✅ No forbidden persistence APIs (`UserDefaults`, `CoreData`, `SwiftData`)
5. ✅ `VKTurnFreeString` called with `defer` for memory safety
6. ✅ `connect()` and `disconnect()` methods implemented
7. ✅ Status polling timer with 1-second interval
8. ✅ Published properties: `isRunning`, `statusText`, `logMessages`

**Code Metrics:**
- VKTurnBridge.swift: 67 lines (compact wrapper, JSON handling)
- ProxyManager.swift: 191 lines (lifecycle, polling, logging, error handling)
- VKTurnProxy-Bridging-Header.h: 1 line (minimal bridge)

### Key Patterns for iOS + Go c-archive

1. **Memory discipline**: Always pair C string allocation with `VKTurnFreeString` via `defer`
2. **Thread safety**: Background queue for C calls, main actor for UI updates
3. **Handle lifecycle**: Store handle (int32), use for all subsequent C calls, clean up on disconnect
4. **Status polling**: Timer-based (not push), 1-second interval, graceful on errors
5. **No persistence**: In-memory state only, no UserDefaults/CoreData (per plan requirement)

### WireGuard Pattern Alignment

This implementation follows the same architecture as `wireguard-apple`:
- Bridging header includes Go-generated `.h` file
- Swift wrapper class with static methods calling C functions
- ObservableObject manager for SwiftUI integration
- Background queues for blocking C operations
- Handle-based lifecycle (WireGuard uses tunnel handle, we use proxy handle)

## Task 6: Background Audio Mode Manager (2026-03-30)

### AVAudioSession Configuration Pattern
- **Playback category**: Use `.playback` mode to allow background audio
- **Session activation**: `setActive(true, options: .notifyOthersOnDeactivation)` ensures proper audio session lifecycle
- **Mixing**: Include `.mixWithOthers` option so app doesn't silence other audio (e.g., music, calls)
- **Ducking**: `.duckOthers` option reduces volume of other apps' audio automatically

### Infinite Audio Loop for Background Keepalive
- **numberOfLoops = -1**: AVAudioPlayer infinite loop constant (-1, not 0 or nil)
- **Volume = 0.0**: Silent audio (0 volume, no audible sound)
- **Playback guarantee**: Playing any audio (even silent) with .playback category lets iOS background thread run longer
- **Limitation**: iOS still kills app eventually (few minutes to hours), but significantly extends lifetime vs. no background mode

### Programmatic Silence Generation
- **AVAudioPCMBuffer approach**: Create 1-second buffer at 44.1kHz mono, already zeroed (silence by default)
- **WAV export**: Convert float32 PCM buffer to WAV format manually (simple format suitable for AVAudioPlayer)
- **WAV header structure**: RIFF chunk, fmt subchunk (PCM format spec), data subchunk (audio samples)
- **Float to int16 conversion**: `Int16(float32 * 32767.0)` for proper PCM range

### Integration with ProxyManager
- **Optional feature**: Proxy works without background audio (successful connection in foreground)
- **Start/Stop pattern**: Call `startBackgroundAudio()` when proxy starts, `stopBackgroundAudio()` when proxy stops
- **Thread-safe**: BackgroundAudioManager uses internal state tracking (`isRunning` flag), safe to call methods multiple times

### Error Handling Philosophy
- **Graceful degradation**: Audio session errors don't crash app or prevent proxy from working
- **Logging only**: Use print() for debug info, no error propagation to caller
- **Safe guards**: No-op on multiple start/stop calls prevents state corruption

### AVFoundation Framework Requirements
- Minimal imports: only `AVFoundation` + `Foundation`
- No additional frameworks needed for playback
- Audio session is singleton: `AVAudioSession.sharedInstance()`

