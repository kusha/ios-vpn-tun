# VK Turn Proxy — iOS Port

## TL;DR

> **Quick Summary**: Port the Go CLI tool `vk-turn-proxy` (tunnels WireGuard through VK call TURN servers) to an iOS app. Go code compiled as c-archive static lib, Swift foreground app runs proxy on localhost:9000, user connects separate WireGuard app to it.
> 
> **Deliverables**:
> - Go bridge library (c-archive .a for ios/arm64) wrapping vk-turn-proxy client logic
> - Minimal SwiftUI app with connect/disconnect + status display
> - `build.sh` script: one command → unsigned `.ipa` ready for AltStore/Sideloadly
> - GitHub Actions workflow: push to GitHub → CI builds IPA → download from Releases (no local Xcode needed)
> - README with setup + WireGuard configuration instructions
> 
> **Estimated Effort**: Medium
> **Parallel Execution**: YES — 4 waves
> **Critical Path**: Go bridge → build-go.sh → Xcode project → Swift bridge → SwiftUI → build.sh → IPA

---

## Context

### Original Request
Port https://github.com/cacggghp/vk-turn-proxy to run on iOS as a standalone IPA installable via AltStore/Sideloadly. User has zero iOS dev experience — AI writes everything. Single `./build.sh` → `.ipa` pipeline.

### Interview Summary
**Key Discussions**:
- Architecture: Foreground TURN proxy (NOT Network Extension — impossible without $99 Apple Developer Account)
- Complexity: MVP / proof-of-concept — minimal UI, just make it work
- Distribution: AltStore / Sideloadly with free Apple ID (7-day re-signing)
- Providers: VK only (Yandex Telemost shut down permanently)
- Build: User wants IPA without opening Xcode ideally, `./build.sh` is the interface

**Research Findings**:
- wireguard-apple uses exact same c-archive pattern for wireguard-go — proven approach
- Android port runs Go as subprocess (impossible on iOS) — c-archive is the iOS equivalent
- VK credential flow is 4 HTTP POST calls, no browser needed — works from Go on iOS
- Unsigned IPA build: `CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` → manual Payload zip. AltStore signs at install time.
- Full Xcode.app required (not just CLI tools) — iOS SDK only ships with Xcode.app
- Go `GOOS=ios GOARCH=arm64 CGO_ENABLED=1 -buildmode=c-archive` is natively supported

### Metis Review
**Identified Gaps** (addressed):
- Go source must be cloned/vendored at build time — build.sh will clone from GitHub
- `signal.Notify`, `log.Panicf`, `os.Exit` must be replaced with error returns in bridge — Go bridge task covers this
- All Yandex Telemost code stripped (dead service) — reduces bridge surface ~200 lines
- Xcode.app required (not just CLI tools) — build.sh prerequisite check
- WireGuard AllowedIPs must exclude localhost to prevent traffic loop — documented in README
- Go runtime SIGURG conflict possible — start without patches, add if crashes observed
- XcodeGen recommended for reproducible project generation — adopted

---

## Work Objectives

### Core Objective
Produce a working unsigned `.ipa` file containing an iOS app that runs a VK TURN proxy on localhost:9000, installable via AltStore/Sideloadly on iOS 18+.

### Concrete Deliverables
- `go/` — Go bridge module (adapted client/main.go + bridge.go with C exports)
- `Sources/` — Swift app code (bridge, proxy manager, SwiftUI views)
- `project.yml` — XcodeGen project spec
- `build.sh` — Master build script (checks prereqs → builds Go → generates xcodeproj → archives → packages IPA)
- `scripts/build-go.sh` — Go cross-compilation subscript
- `.github/workflows/build-ipa.yml` — GitHub Actions CI: builds IPA on push/tag, uploads as artifact, creates Releases
- `README.md` — Setup, build, install, WireGuard configuration instructions

### Definition of Done
- [ ] `./build.sh` exits 0 on macOS with Xcode + Go installed
- [ ] `build/VKTurnProxy.ipa` exists and is a valid zip containing `Payload/VKTurnProxy.app/VKTurnProxy`
- [ ] IPA contains valid `Info.plist` with correct bundle ID and iOS 18 deployment target
- [ ] Go static library (.a) targets ios/arm64 (verified via `otool`)

### Must Have
- Go TURN proxy compiled as c-archive static library for ios/arm64
- C-exported API: StartProxy(configJSON), StopProxy(), GetStatus(), FreeString()
- VK credential flow (anonymous token → TURN credentials) working from Go
- SwiftUI UI: VK link field, streams count, connect/disconnect button, status/log area
- Unsigned IPA build pipeline (no Apple ID needed at build time)
- Prerequisite checking in build.sh (Xcode, Go, XcodeGen)
- Background audio mode trick for keeping proxy alive when backgrounded
- GitHub Actions workflow: push to GitHub → CI builds IPA → download from artifacts or Releases (no local Xcode needed)

### Must NOT Have (Guardrails)
- ❌ Network Extension or VPN tunnel (impossible without paid account)
- ❌ Yandex Telemost support (service is dead — strip all Yandex code)
- ❌ Built-in WireGuard client (user installs WireGuard from App Store)
- ❌ Settings persistence, multi-profile, onboarding
- ❌ App Store submission (sideload only)
- ❌ gomobile bind (use c-archive directly)
- ❌ `xcodebuild -exportArchive` flow (use manual Payload zip)
- ❌ CI/CD, Fastlane, CocoaPods/SPM
- ❌ XCTest unit tests or UI tests (build verification only)
- ❌ Multi-architecture build (arm64 only — all modern iOS devices)
- ❌ Dark/light theme toggle, animations, localization
- ❌ Go runtime patches (add only if SIGURG crashes observed)
- ❌ Over-abstraction or excessive error handling beyond what the original Go code does

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** — ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: NO (greenfield project)
- **Automated tests**: None — build verification at each wave boundary
- **Framework**: N/A
- **Rationale**: iOS app without device/simulator available. Verification = build succeeds + IPA structure valid.

### QA Policy
Every task includes agent-executed QA scenarios.
Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **Go compilation**: Bash — `file`, `otool`, `grep` on build artifacts
- **Xcode build**: Bash — `xcodebuild` exit code, archive existence
- **IPA packaging**: Bash — `unzip -l`, structure validation
- **Swift compilation**: Bash — `xcodebuild build` exit code

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Foundation — Go bridge + build script, 3 parallel tasks):
├── Task 1: Clone vk-turn-proxy + create Go bridge module [deep]
├── Task 2: Create build-go.sh cross-compilation script [quick]
├── Task 3: Create XcodeGen project.yml + Info.plist + entitlements [quick]

Wave 2 (Swift app — after Go bridge compiles, 3 parallel tasks):
├── Task 4: Swift C bridge + proxy manager (depends: 1, 2) [unspecified-high]
├── Task 5: SwiftUI interface (depends: 3) [visual-engineering]
├── Task 6: Background audio mode manager (depends: 3) [quick]

Wave 3 (Integration + build — after all app code, 2 parallel tasks):
├── Task 7: Master build.sh script (depends: 2, 3, 4, 5, 6) [deep]
├── Task 8: App icon assets + launch screen (depends: 3) [quick]

Wave 4 (Verification + docs + CI — after build works, 3 parallel tasks):
├── Task 9: End-to-end build verification (depends: 7) [unspecified-high]
├── Task 10: README with setup + WireGuard config instructions (depends: 7) [writing]
├── Task 11: GitHub Actions CI workflow + gh release (depends: 7) [quick]

Wave FINAL (Independent review, 4 parallel):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Code quality review (unspecified-high)
├── Task F3: Full build QA — clean build from scratch (unspecified-high)
├── Task F4: Scope fidelity check (deep)

Critical Path: Task 1 → Task 4 → Task 7 → Task 9 → F1-F4
Parallel Speedup: ~50% faster than sequential
Max Concurrent: 3 (Waves 1 & 2)
```

### Dependency Matrix

| Task | Depends On | Blocks |
|------|-----------|--------|
| 1 (Go bridge) | — | 4 |
| 2 (build-go.sh) | — | 4, 7 |
| 3 (XcodeGen) | — | 5, 6, 7, 8 |
| 4 (Swift bridge) | 1, 2 | 7 |
| 5 (SwiftUI) | 3 | 7 |
| 6 (Background audio) | 3 | 7 |
| 7 (build.sh) | 2, 3, 4, 5, 6 | 9, 10, 11 |
| 8 (Assets) | 3 | 7 |
| 9 (E2E verification) | 7 | F1-F4 |
| 10 (README) | 7 | F1-F4 |
| 11 (GitHub Actions CI) | 7 | F1-F4 |
| F1-F4 | 9, 10, 11 | — |

### Agent Dispatch Summary

- **Wave 1**: 3 tasks — T1 → `deep`, T2 → `quick`, T3 → `quick`
- **Wave 2**: 3 tasks — T4 → `unspecified-high`, T5 → `visual-engineering`, T6 → `quick`
- **Wave 3**: 2 tasks — T7 → `deep`, T8 → `quick`
- **Wave 4**: 3 tasks — T9 → `unspecified-high`, T10 → `writing`, T11 → `quick`
- **FINAL**: 4 tasks — F1 → `oracle`, F2 → `unspecified-high`, F3 → `unspecified-high`, F4 → `deep`

---

## TODOs

- [ ] 1. Clone vk-turn-proxy and create Go bridge module

  **What to do**:
  - Clone `https://github.com/cacggghp/vk-turn-proxy` into a temp directory for reference
  - Create `go/` directory in project root with a new Go module (`module vkturnproxy`)
  - Copy and adapt `client/main.go` into the bridge module, splitting into:
    - `go/bridge.go` — C-exported functions (`//export`), `package main`, empty `func main() {}`
    - `go/proxy.go` — Adapted proxy logic (UDP listener, TURN connections, DTLS tunneling). Remove `flag` parsing, `os.Signal` handling, `log.Panicf`/`log.Fatalf`. Accept config via struct. Use `context.WithCancel` for lifecycle.
    - `go/vkcreds.go` — VK credential flow (4 HTTP POST calls). Strip ALL Yandex Telemost code entirely.
  - **C-exported API** (follow wireguard-apple's `api-apple.go` pattern):
    ```go
    //export VKTurnStartProxy
    func VKTurnStartProxy(configJSON *C.char) *C.char  // Returns error or nil
    
    //export VKTurnStopProxy
    func VKTurnStopProxy()
    
    //export VKTurnGetStatus
    func VKTurnGetStatus() *C.char  // JSON: {"running":bool,"connections":int,"error":"..."}
    
    //export VKTurnFreeString
    func VKTurnFreeString(s *C.char)
    
    func main() {}  // Required, empty
    ```
  - Config JSON accepted by StartProxy:
    ```json
    {"peer":"1.2.3.4:56000","vkLink":"https://vk.com/call/join/XXXX","listen":"127.0.0.1:9000","streams":16,"udp":false}
    ```
  - Use handle-based pattern (int32 handle in a global map) for proxy instance — allows clean stop
  - Copy `go.mod` dependencies from upstream, update module name. Run `go mod tidy`.
  - Verify: `GOOS=ios GOARCH=arm64 CGO_ENABLED=1 go build -buildmode=c-archive -o /dev/null .` succeeds

  **Must NOT do**:
  - Do NOT use gomobile bind — this is c-archive
  - Do NOT include Yandex Telemost code (getYandexCreds, yalink flag, any Yandex references)
  - Do NOT keep flag parsing or signal handling from original main.go
  - Do NOT add Go runtime patches (add only if SIGURG crashes observed later)
  - Do NOT over-abstract — keep it close to original code structure

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Core logic port requiring careful Go adaptation — must understand both original code and c-archive constraints
  - **Skills**: []
    - No special skills needed — pure Go code adaptation
  - **Skills Evaluated but Omitted**:
    - `playwright`: No browser interaction
    - `git-master`: Simple initial commit, no complex git ops

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 2, 3)
  - **Blocks**: Task 4 (Swift bridge needs the .h header and .a library)
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - `https://github.com/cacggghp/vk-turn-proxy/blob/main/client/main.go` — FULL source code to adapt. ~540 lines. Key functions: `main()` (UDP listener + TURN setup), `getVkCreds()` (VK auth flow), `oneDtlsConnectionLoop/oneDtlsConnection` (DTLS tunneling), `turnConnectionLoop/turnConnection` (TURN relay)
  - `https://github.com/WireGuard/wireguard-apple` → `Sources/WireGuardKitGo/api-apple.go` — Reference for c-archive bridge pattern: `//export` functions, handle map, C string management, empty main()

  **API/Type References**:
  - `https://github.com/cacggghp/vk-turn-proxy/blob/main/go.mod` — Go dependencies list (pion/turn/v5, pion/dtls/v3, gorilla/websocket, dnsdialer, connutil, google/uuid)

  **External References**:
  - Go c-archive docs: `https://pkg.go.dev/cmd/go#hdr-Build_modes` — `-buildmode=c-archive` specification
  - pion/dtls: `https://github.com/pion/dtls` — DTLS 1.2 implementation used for obfuscation
  - pion/turn: `https://github.com/pion/turn` — TURN client for relaying traffic

  **WHY Each Reference Matters**:
  - `client/main.go` is THE code being ported — executor must read and understand the full file
  - `api-apple.go` shows the exact pattern for iOS c-archive bridges proven in production
  - `go.mod` ensures all dependencies are correctly vendored

  **Acceptance Criteria**:

  - [ ] `go/` directory exists with `bridge.go`, `proxy.go`, `vkcreds.go`, `go.mod`, `go.sum`
  - [ ] `grep -r "Yandex\|yalink\|getYandexCreds\|telemost" go/` returns no matches (all Yandex code stripped)
  - [ ] `grep -r "flag.String\|flag.Int\|flag.Bool\|flag.Parse\|os.Signal\|signal.Notify" go/` returns no matches
  - [ ] `grep "//export VKTurnStartProxy" go/bridge.go` finds the export directive
  - [ ] `grep "//export VKTurnStopProxy" go/bridge.go` finds the export directive
  - [ ] `grep "//export VKTurnGetStatus" go/bridge.go` finds the export directive
  - [ ] `grep "//export VKTurnFreeString" go/bridge.go` finds the export directive
  - [ ] `grep "func main()" go/bridge.go` finds empty main

  **QA Scenarios**:

  ```
  Scenario: Go module compiles for iOS arm64 as c-archive
    Tool: Bash
    Preconditions: Go 1.25+ installed, go/ directory with all source files
    Steps:
      1. cd go/ && GOOS=ios GOARCH=arm64 CGO_ENABLED=1 go build -buildmode=c-archive -o /tmp/test-vkturn.a .
      2. file /tmp/test-vkturn.a
      3. grep "VKTurnStartProxy\|VKTurnStopProxy\|VKTurnGetStatus\|VKTurnFreeString" /tmp/test-vkturn.h
    Expected Result: Step 1 exits 0. Step 2 shows "current ar archive". Step 3 finds all 4 exported functions in header.
    Failure Indicators: Compilation error, missing exports, wrong architecture
    Evidence: .sisyphus/evidence/task-1-go-c-archive-compile.txt

  Scenario: No Yandex code remains in Go bridge
    Tool: Bash
    Preconditions: go/ directory exists
    Steps:
      1. grep -ri "yandex\|yalink\|telemost\|getYandexCreds" go/ || echo "CLEAN"
    Expected Result: Output is "CLEAN" — no Yandex references found
    Failure Indicators: Any grep match means Yandex code was not fully stripped
    Evidence: .sisyphus/evidence/task-1-no-yandex.txt

  Scenario: No CLI/signal handling code remains
    Tool: Bash
    Preconditions: go/ directory exists
    Steps:
      1. grep -r "flag\.String\|flag\.Int\|flag\.Bool\|flag\.Parse\|os\.Signal\|signal\.Notify\|log\.Panicf\|log\.Fatalf\|os\.Exit" go/ || echo "CLEAN"
    Expected Result: Output is "CLEAN"
    Failure Indicators: Any match means CLI code was not fully removed
    Evidence: .sisyphus/evidence/task-1-no-cli-code.txt
  ```

  **Commit**: YES
  - Message: `feat(go): add bridge module wrapping vk-turn-proxy client for iOS c-archive`
  - Files: `go/bridge.go`, `go/proxy.go`, `go/vkcreds.go`, `go/go.mod`, `go/go.sum`
  - Pre-commit: `cd go && GOOS=ios GOARCH=arm64 CGO_ENABLED=1 go build -buildmode=c-archive -o /dev/null .`

- [ ] 2. Create build-go.sh cross-compilation script

  **What to do**:
  - Create `scripts/build-go.sh` — builds Go bridge as c-archive for ios/arm64
  - Script must:
    1. Set environment: `GOOS=ios GOARCH=arm64 CGO_ENABLED=1`
    2. Set CC to Xcode's clang with iOS SDK: `CC=$(xcrun --sdk iphoneos --find clang)` with appropriate `-isysroot` and `-arch arm64` flags
    3. Run `go build -buildmode=c-archive -o build/go/libvkturn.a .` from `go/` directory
    4. Verify output: check `libvkturn.a` exists and `libvkturn.h` was generated
    5. Print summary: library size, header exports count
  - Output goes to `build/go/libvkturn.a` and `build/go/libvkturn.h`
  - Must be idempotent (re-running overwrites previous build)
  - Must handle errors gracefully with clear messages

  **Must NOT do**:
  - Do NOT use gomobile
  - Do NOT build for simulator (x86_64) — arm64 device only
  - Do NOT build fat/universal binary — single architecture

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Single shell script, straightforward cross-compilation setup
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - All — this is a simple bash script

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 3)
  - **Blocks**: Tasks 4, 7
  - **Blocked By**: None (can start immediately — but needs Task 1's Go source to actually run)

  **References**:

  **Pattern References**:
  - wireguard-apple Makefile: `https://github.com/WireGuard/wireguard-apple` → `Sources/WireGuardKitGo/Makefile` — Shows exact clang flags for iOS c-archive compilation: `CC`, `CGO_CFLAGS`, `CGO_LDFLAGS`, SDK path resolution

  **External References**:
  - `xcrun --sdk iphoneos --show-sdk-path` — Resolves iOS SDK root
  - `xcrun --sdk iphoneos --find clang` — Resolves iOS clang path
  - Go cross-compilation: `https://pkg.go.dev/cmd/go#hdr-Build_modes`

  **WHY Each Reference Matters**:
  - wireguard-apple Makefile is the production-proven reference for iOS Go cross-compilation flags — copy their approach

  **Acceptance Criteria**:

  - [ ] `scripts/build-go.sh` exists and is executable (`chmod +x`)
  - [ ] Running `scripts/build-go.sh` from project root produces `build/go/libvkturn.a` and `build/go/libvkturn.h`

  **QA Scenarios**:

  ```
  Scenario: build-go.sh produces valid iOS arm64 static library
    Tool: Bash
    Preconditions: Go 1.25+ installed, Xcode.app installed, Task 1 complete (go/ dir exists)
    Steps:
      1. ./scripts/build-go.sh
      2. test -f build/go/libvkturn.a && echo "LIB EXISTS"
      3. test -f build/go/libvkturn.h && echo "HEADER EXISTS"
      4. otool -l build/go/libvkturn.a | grep -A5 LC_BUILD_VERSION | head -10
      5. grep "VKTurnStartProxy" build/go/libvkturn.h
    Expected Result: Step 1 exits 0. Steps 2-3 print EXISTS. Step 4 shows platform 2 (iOS). Step 5 finds export.
    Failure Indicators: Non-zero exit, missing files, wrong platform, missing exports
    Evidence: .sisyphus/evidence/task-2-build-go-output.txt

  Scenario: build-go.sh fails gracefully without Go installed
    Tool: Bash
    Preconditions: Temporarily rename go binary or test error path
    Steps:
      1. PATH=/usr/bin ./scripts/build-go.sh 2>&1 || true
      2. Check output contains error message about missing Go
    Expected Result: Script exits non-zero with clear error message mentioning Go installation
    Failure Indicators: Silent failure, cryptic error, or zero exit code
    Evidence: .sisyphus/evidence/task-2-build-go-error.txt
  ```

  **Commit**: YES
  - Message: `feat(build): add build-go.sh for iOS arm64 c-archive cross-compilation`
  - Files: `scripts/build-go.sh`
  - Pre-commit: `test -x scripts/build-go.sh`

- [ ] 3. Create XcodeGen project.yml, Info.plist, and entitlements

  **What to do**:
  - Create `project.yml` — XcodeGen project specification for iOS app:
    - Target: `VKTurnProxy` (iOS app, deployment target 18.0, arm64 only)
    - Sources: `Sources/`
    - Resources: `Resources/`
    - Link `build/go/libvkturn.a` as a static library
    - Set bridging header to `Sources/Bridge/VKTurnProxy-Bridging-Header.h`
    - Build settings: `SWIFT_VERSION: "5.10"`, `IPHONEOS_DEPLOYMENT_TARGET: "18.0"`, `TARGETED_DEVICE_FAMILY: "1,2"` (iPhone + iPad)
    - Add `libresolv.tbd` to linked frameworks (Go's `net` package needs it on iOS)
    - Add `Security.framework` (for TLS/cert operations)
    - Add background mode `audio` to capabilities (for background keepalive trick)
  - Create `Info.plist`:
    - `CFBundleIdentifier`: `com.vkturnproxy.app` (placeholder — AltStore may override)
    - `CFBundleDisplayName`: `VK Turn`
    - `CFBundleVersion`: `1.0`
    - `MinimumOSVersion`: `18.0`
    - `UIBackgroundModes`: `[audio]`
    - `UILaunchScreen`: `{}` (empty — system default)
    - `NSAppTransportSecurity` → `NSAllowsArbitraryLoads: true` (VK API endpoints)
  - Create `VKTurnProxy.entitlements`:
    - Minimal: just `com.apple.security.application-groups` (empty array, placeholder for AltStore)
    - NO network extension entitlement

  **Must NOT do**:
  - Do NOT create .xcodeproj manually — XcodeGen generates it
  - Do NOT add Network Extension target or entitlement
  - Do NOT add unnecessary capabilities

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Configuration files with known structure — YAML + plist
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `frontend-ui-ux`: Not UI work — project configuration

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 2)
  - **Blocks**: Tasks 5, 6, 7, 8
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - XcodeGen docs: `https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md` — Full project.yml specification
  - wireguard-apple project structure — Reference for how an iOS app integrating Go c-archive organizes its Xcode project

  **External References**:
  - Apple Info.plist reference: `https://developer.apple.com/documentation/bundleresources/information_property_list`
  - Background modes: `https://developer.apple.com/documentation/bundleresources/information_property_list/uibackgroundmodes`

  **WHY Each Reference Matters**:
  - XcodeGen spec is the authoritative reference for project.yml syntax — executor must consult it for linking static libraries and setting bridging headers
  - Info.plist needs exact keys for background audio mode to work

  **Acceptance Criteria**:

  - [ ] `project.yml` exists with correct target configuration
  - [ ] `Info.plist` exists with UIBackgroundModes containing "audio"
  - [ ] `VKTurnProxy.entitlements` exists without NE entitlement
  - [ ] `brew install xcodegen && xcodegen generate` succeeds (if XcodeGen installed)

  **QA Scenarios**:

  ```
  Scenario: XcodeGen generates valid Xcode project from project.yml
    Tool: Bash
    Preconditions: XcodeGen installed (brew install xcodegen), project.yml exists
    Steps:
      1. xcodegen generate 2>&1
      2. test -f VKTurnProxy.xcodeproj/project.pbxproj && echo "XCODEPROJ EXISTS"
      3. grep "libvkturn.a" VKTurnProxy.xcodeproj/project.pbxproj
      4. grep "VKTurnProxy-Bridging-Header.h" VKTurnProxy.xcodeproj/project.pbxproj
    Expected Result: Step 1 exits 0. Step 2 confirms project exists. Steps 3-4 find library and bridging header references.
    Failure Indicators: XcodeGen error, missing project file, missing references
    Evidence: .sisyphus/evidence/task-3-xcodegen-output.txt

  Scenario: Info.plist contains required keys
    Tool: Bash
    Preconditions: Info.plist exists
    Steps:
      1. grep "UIBackgroundModes" Info.plist
      2. grep "audio" Info.plist
      3. grep "NSAllowsArbitraryLoads" Info.plist
    Expected Result: All three greps find matches
    Failure Indicators: Missing background mode or ATS override
    Evidence: .sisyphus/evidence/task-3-info-plist-check.txt
  ```

  **Commit**: YES
  - Message: `feat(xcode): add XcodeGen project.yml, Info.plist, and entitlements`
  - Files: `project.yml`, `Info.plist`, `VKTurnProxy.entitlements`
  - Pre-commit: `test -f project.yml && test -f Info.plist`

- [ ] 4. Swift C bridge and proxy manager

  **What to do**:
  - Create `Sources/Bridge/VKTurnProxy-Bridging-Header.h`:
    - `#include "libvkturn.h"` (the header generated by Go c-archive build)
    - This exposes `VKTurnStartProxy`, `VKTurnStopProxy`, `VKTurnGetStatus`, `VKTurnFreeString` to Swift
  - Create `Sources/Bridge/VKTurnBridge.swift` — Swift-friendly wrapper around C functions:
    ```swift
    class VKTurnBridge {
        static func startProxy(config: ProxyConfig) throws  // Encodes config to JSON, calls VKTurnStartProxy
        static func stopProxy()                               // Calls VKTurnStopProxy
        static func getStatus() -> ProxyStatus               // Calls VKTurnGetStatus, parses JSON
    }
    ```
    - Handle C string memory: call `VKTurnFreeString` on returned strings
    - Define `ProxyConfig` struct (Codable): peer, vkLink, listen, streams, udp
    - Define `ProxyStatus` struct (Codable): running, connections, error
  - Create `Sources/App/ProxyManager.swift` — ObservableObject for SwiftUI:
    - Published properties: `isRunning`, `statusText`, `logMessages: [String]`
    - `connect()` — calls VKTurnBridge.startProxy, starts status polling timer
    - `disconnect()` — calls VKTurnBridge.stopProxy, stops timer
    - Status polling: Timer every 1 second calls `VKTurnBridge.getStatus()`, updates published state
    - Log messages: append timestamped status changes
    - Run proxy start on background DispatchQueue (Go runtime initializes on first call, may take a moment)

  **Must NOT do**:
  - Do NOT persist settings (no UserDefaults, no Core Data)
  - Do NOT add error recovery/retry logic beyond what Go code does
  - Do NOT add networking permission prompts (UDP localhost doesn't need them)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Swift + C interop requires careful memory management and understanding of bridging patterns
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `frontend-ui-ux`: This is bridge/logic code, not UI

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 5, 6 in Wave 2)
  - **Parallel Group**: Wave 2
  - **Blocks**: Task 7
  - **Blocked By**: Task 1 (needs Go C API defined), Task 2 (needs .h header path)

  **References**:

  **Pattern References**:
  - wireguard-apple Swift bridge: `https://github.com/WireGuard/wireguard-apple` → `Sources/WireGuardKit/WireGuardAdapter.swift` — Shows how they call C-exported Go functions from Swift, manage C string lifecycle
  - Go c-archive header pattern — The generated `libvkturn.h` will declare `extern` C functions that Swift sees via bridging header

  **API/Type References**:
  - Task 1's bridge.go defines the exact C API: `VKTurnStartProxy(configJSON *C.char) *C.char`, etc.
  - Config JSON schema: `{"peer":"...","vkLink":"...","listen":"127.0.0.1:9000","streams":16,"udp":false}`

  **External References**:
  - Swift C interop: `https://developer.apple.com/documentation/swift/importing-c-based-apis-into-swift`

  **WHY Each Reference Matters**:
  - wireguard-apple's Swift adapter is the closest production reference for calling Go c-archive from Swift
  - The C API from Task 1 is the contract this bridge implements against

  **Acceptance Criteria**:

  - [ ] `Sources/Bridge/VKTurnProxy-Bridging-Header.h` exists with `#include "libvkturn.h"`
  - [ ] `Sources/Bridge/VKTurnBridge.swift` exists with startProxy/stopProxy/getStatus methods
  - [ ] `Sources/App/ProxyManager.swift` exists as ObservableObject with Published properties
  - [ ] No `UserDefaults`, `CoreData`, `SwiftData` references in any Swift file

  **QA Scenarios**:

  ```
  Scenario: Swift bridge file structure is correct
    Tool: Bash
    Preconditions: Sources/ directory created by this task
    Steps:
      1. test -f Sources/Bridge/VKTurnProxy-Bridging-Header.h && echo "HEADER OK"
      2. test -f Sources/Bridge/VKTurnBridge.swift && echo "BRIDGE OK"
      3. test -f Sources/App/ProxyManager.swift && echo "MANAGER OK"
      4. grep "libvkturn.h" Sources/Bridge/VKTurnProxy-Bridging-Header.h
      5. grep "VKTurnStartProxy\|VKTurnStopProxy\|VKTurnGetStatus" Sources/Bridge/VKTurnBridge.swift
      6. grep "ObservableObject" Sources/App/ProxyManager.swift
    Expected Result: All files exist, all greps find matches
    Failure Indicators: Missing files, missing C function calls, missing ObservableObject conformance
    Evidence: .sisyphus/evidence/task-4-swift-bridge-structure.txt

  Scenario: No forbidden persistence APIs used
    Tool: Bash
    Preconditions: Sources/ directory exists
    Steps:
      1. grep -r "UserDefaults\|CoreData\|SwiftData\|NSKeyedArchiver" Sources/ || echo "CLEAN"
    Expected Result: Output is "CLEAN"
    Failure Indicators: Any match means persistence was added against spec
    Evidence: .sisyphus/evidence/task-4-no-persistence.txt
  ```

  **Commit**: YES
  - Message: `feat(swift): add C bridge and proxy manager for Go library lifecycle`
  - Files: `Sources/Bridge/VKTurnProxy-Bridging-Header.h`, `Sources/Bridge/VKTurnBridge.swift`, `Sources/App/ProxyManager.swift`
  - Pre-commit: `test -f Sources/Bridge/VKTurnBridge.swift`

- [ ] 5. Minimal SwiftUI interface

  **What to do**:
  - Create `Sources/App/VKTurnProxyApp.swift` — App entry point (`@main`), creates ContentView
  - Create `Sources/App/ContentView.swift` — Single-screen SwiftUI view:
    - **VK Link field**: TextField for VK call join link (e.g., `https://vk.com/call/join/...`)
    - **Peer field**: TextField for server address (e.g., `1.2.3.4:56000`)
    - **Streams stepper**: Stepper or picker for number of streams (default 16, range 1-64)
    - **Connect/Disconnect button**: Large button, toggles between Connect (green) and Disconnect (red) based on `proxyManager.isRunning`
    - **Status indicator**: Text showing current status (Disconnected / Connecting / Connected — N streams)
    - **Log area**: ScrollView with Text showing recent log messages from ProxyManager (last ~50 lines)
    - Uses `@StateObject var proxyManager = ProxyManager()`
    - Simple VStack layout, no fancy styling
  - Keep it minimal — one screen, no navigation, no settings

  **Must NOT do**:
  - Do NOT add NavigationView/NavigationStack (single screen)
  - Do NOT add TabView, settings, about screen
  - Do NOT add animations beyond system defaults
  - Do NOT add custom colors, themes, or design system
  - Do NOT localize strings

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
    - Reason: SwiftUI view construction — needs to look decent even if minimal
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `playwright`: iOS app, not web
    - `frontend-ui-ux`: This is intentionally minimal, not a design task

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 4, 6 in Wave 2)
  - **Parallel Group**: Wave 2
  - **Blocks**: Task 7
  - **Blocked By**: Task 3 (needs XcodeGen project structure)

  **References**:

  **Pattern References**:
  - SwiftUI basics: `https://developer.apple.com/tutorials/swiftui` — TextField, Button, ScrollView, @StateObject patterns

  **API/Type References**:
  - Task 4's `ProxyManager` — the ObservableObject this view binds to
  - `ProxyConfig` struct fields determine what input fields are needed

  **WHY Each Reference Matters**:
  - ProxyManager is the data source — view must bind to its Published properties correctly

  **Acceptance Criteria**:

  - [ ] `Sources/App/VKTurnProxyApp.swift` exists with `@main` attribute
  - [ ] `Sources/App/ContentView.swift` exists with TextField for VK link, peer, connect button
  - [ ] `grep "@StateObject" Sources/App/ContentView.swift` finds ProxyManager binding
  - [ ] `grep -r "NavigationView\|NavigationStack\|TabView" Sources/App/` returns no matches

  **QA Scenarios**:

  ```
  Scenario: SwiftUI views have correct structure
    Tool: Bash
    Preconditions: Sources/App/ directory exists
    Steps:
      1. grep "@main" Sources/App/VKTurnProxyApp.swift
      2. grep "struct ContentView" Sources/App/ContentView.swift
      3. grep "@StateObject.*ProxyManager\|@State.*ProxyManager" Sources/App/ContentView.swift
      4. grep "TextField" Sources/App/ContentView.swift
      5. grep "Button" Sources/App/ContentView.swift
      6. grep -r "NavigationView\|NavigationStack\|TabView" Sources/App/ || echo "NO NAV - CORRECT"
    Expected Result: Steps 1-5 find matches. Step 6 outputs "NO NAV - CORRECT".
    Failure Indicators: Missing @main, missing ContentView struct, missing ProxyManager binding, navigation added
    Evidence: .sisyphus/evidence/task-5-swiftui-structure.txt
  ```

  **Commit**: YES
  - Message: `feat(ui): add minimal SwiftUI interface with connect/disconnect and log`
  - Files: `Sources/App/VKTurnProxyApp.swift`, `Sources/App/ContentView.swift`
  - Pre-commit: `grep "@main" Sources/App/VKTurnProxyApp.swift`

- [ ] 6. Background audio mode manager

  **What to do**:
  - Create `Sources/App/BackgroundAudioManager.swift`:
    - Uses AVAudioSession + AVAudioPlayer to play silent audio in a loop
    - `startBackgroundAudio()` — configures audio session (`.playback` category), starts playing silence
    - `stopBackgroundAudio()` — stops playback, deactivates audio session
    - Audio file: generate silence programmatically using AVAudioPCMBuffer (no external .wav file needed)
    - Or alternatively: embed a tiny 1-second silent .caf file in Resources/
  - Integrate with ProxyManager: start background audio when proxy starts, stop when proxy stops
  - This keeps the app alive when user switches to WireGuard or other apps
  - Add `AVFoundation` import

  **Must NOT do**:
  - Do NOT make this mandatory — proxy should work without it
  - Do NOT add UI controls for background mode (always-on when proxy is running)
  - Do NOT use `BGTaskScheduler` or background fetch

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Small utility class with well-known iOS pattern
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 4, 5 in Wave 2)
  - **Parallel Group**: Wave 2
  - **Blocks**: Task 7
  - **Blocked By**: Task 3 (needs background audio capability in project.yml)

  **References**:

  **External References**:
  - AVAudioSession: `https://developer.apple.com/documentation/avfaudio/avaudiosession`
  - Background audio trick: widely documented iOS pattern for keeping apps alive

  **WHY Each Reference Matters**:
  - AVAudioSession setup must be correct or iOS will kill the app despite background mode capability

  **Acceptance Criteria**:

  - [ ] `Sources/App/BackgroundAudioManager.swift` exists
  - [ ] `grep "AVAudioSession\|AVAudioPlayer" Sources/App/BackgroundAudioManager.swift` finds matches
  - [ ] `grep "BGTaskScheduler" Sources/App/` returns no matches

  **QA Scenarios**:

  ```
  Scenario: BackgroundAudioManager has correct API
    Tool: Bash
    Preconditions: Sources/App/ directory exists
    Steps:
      1. grep "startBackgroundAudio\|stopBackgroundAudio" Sources/App/BackgroundAudioManager.swift
      2. grep "AVAudioSession" Sources/App/BackgroundAudioManager.swift
      3. grep -r "BGTaskScheduler\|BackgroundTask" Sources/App/ || echo "NO BG TASKS - CORRECT"
    Expected Result: Steps 1-2 find matches. Step 3 outputs "NO BG TASKS - CORRECT".
    Failure Indicators: Missing methods, missing AVAudioSession, forbidden BGTaskScheduler present
    Evidence: .sisyphus/evidence/task-6-background-audio.txt
  ```

  **Commit**: YES
  - Message: `feat(background): add background audio mode for proxy keepalive`
  - Files: `Sources/App/BackgroundAudioManager.swift`
  - Pre-commit: `test -f Sources/App/BackgroundAudioManager.swift`

- [ ] 7. Master build.sh script

  **What to do**:
  - Create `build.sh` at project root — THE primary user interface for building the IPA
  - Script flow:
    1. **Prerequisite checks** (fail fast with clear messages):
       - `xcodebuild -version` → must find Xcode (NOT just CLI tools — check for `Xcode.app`)
       - `go version` → must find Go 1.25+ (parse version, compare)
       - `xcodegen --version` → must find XcodeGen (suggest `brew install xcodegen` if missing)
       - Detect Apple Silicon vs Intel Mac (informational)
    2. **Build Go library**:
       - Call `scripts/build-go.sh`
       - Verify `build/go/libvkturn.a` and `build/go/libvkturn.h` exist
    3. **Copy Go header to bridging header location**:
       - Copy `build/go/libvkturn.h` to where the bridging header can find it
       - Set `HEADER_SEARCH_PATHS` or copy alongside bridging header
    4. **Generate Xcode project**:
       - `xcodegen generate`
       - Verify `VKTurnProxy.xcodeproj/project.pbxproj` exists
    5. **Build archive (unsigned)**:
       ```bash
       xcodebuild archive \
         -project VKTurnProxy.xcodeproj \
         -scheme VKTurnProxy \
         -archivePath build/VKTurnProxy.xcarchive \
         -configuration Release \
         -sdk iphoneos \
         CODE_SIGN_IDENTITY="" \
         CODE_SIGNING_REQUIRED=NO \
         CODE_SIGNING_ALLOWED=NO \
         HEADER_SEARCH_PATHS="$(pwd)/build/go" \
         LIBRARY_SEARCH_PATHS="$(pwd)/build/go"
       ```
    6. **Package IPA** (manual Payload zip — NOT exportArchive):
       ```bash
       mkdir -p build/Payload
       cp -r build/VKTurnProxy.xcarchive/Products/Applications/VKTurnProxy.app build/Payload/
       cd build && zip -r VKTurnProxy.ipa Payload
       ```
    7. **Verify IPA**:
       - Check `build/VKTurnProxy.ipa` exists
       - Check it contains `Payload/VKTurnProxy.app/VKTurnProxy` (binary)
       - Check it contains `Payload/VKTurnProxy.app/Info.plist`
       - Print IPA size
    8. **Print success message** with next steps (AltStore install instructions)
  - Must be `chmod +x`
  - Clean previous build artifacts at start (`rm -rf build/`)
  - Use color output for errors/success (with fallback for non-color terminals)
  - Total expected build time: 2-5 minutes

  **Must NOT do**:
  - Do NOT use `xcodebuild -exportArchive` or `ExportOptions.plist`
  - Do NOT require any Apple ID or signing identity at build time
  - Do NOT build for simulator
  - Do NOT use Fastlane or other build tools

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Complex multi-step shell script that orchestrates the entire build pipeline — must handle errors gracefully, prerequisite detection, multiple tools
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `git-master`: No git operations in build script

  **Parallelization**:
  - **Can Run In Parallel**: NO (depends on all previous tasks)
  - **Parallel Group**: Wave 3 (with Task 8)
  - **Blocks**: Tasks 9, 10
  - **Blocked By**: Tasks 2, 3, 4, 5, 6 (needs all source code and build scripts)

  **References**:

  **Pattern References**:
  - Unsigned IPA pattern (dev.to/oivoodoo): archive → extract .app → zip as Payload → .ipa
  - wireguard-apple Makefile: `https://github.com/WireGuard/wireguard-apple` → build flags reference

  **External References**:
  - `xcodebuild` man page: archive and CODE_SIGNING flags
  - XcodeGen CLI: `xcodegen generate` command

  **WHY Each Reference Matters**:
  - The unsigned IPA pattern is non-obvious — most guides assume signing. The Payload zip approach is the correct one for AltStore/Sideloadly.
  - xcodebuild flags must be exact — wrong signing flags cause build failures

  **Acceptance Criteria**:

  - [ ] `build.sh` exists at project root and is executable
  - [ ] `build.sh` checks for Xcode, Go, XcodeGen before proceeding
  - [ ] `grep "exportArchive\|ExportOptions" build.sh` returns no matches
  - [ ] `grep "CODE_SIGNING_ALLOWED=NO" build.sh` finds the unsigned build flag
  - [ ] `grep "Payload" build.sh` finds the manual IPA packaging step

  **QA Scenarios**:

  ```
  Scenario: Full build pipeline produces valid IPA
    Tool: Bash
    Preconditions: All Tasks 1-6 complete, Xcode + Go + XcodeGen installed
    Steps:
      1. ./build.sh 2>&1
      2. test -f build/VKTurnProxy.ipa && echo "IPA EXISTS"
      3. unzip -l build/VKTurnProxy.ipa | grep "Payload/VKTurnProxy.app/VKTurnProxy"
      4. unzip -l build/VKTurnProxy.ipa | grep "Payload/VKTurnProxy.app/Info.plist"
      5. du -h build/VKTurnProxy.ipa
    Expected Result: Step 1 exits 0. Step 2 prints "IPA EXISTS". Steps 3-4 find binary and plist. Step 5 shows reasonable size (10-30MB).
    Failure Indicators: Non-zero exit, missing IPA, missing files in IPA, unreasonable size
    Evidence: .sisyphus/evidence/task-7-full-build.txt

  Scenario: build.sh detects missing prerequisites
    Tool: Bash
    Preconditions: Valid system (testing error messages)
    Steps:
      1. Check that build.sh contains prerequisite checks (grep for "xcodebuild", "go version", "xcodegen")
      2. Verify error messages are user-friendly (grep for help text / install instructions)
    Expected Result: Script contains checks for all 3 tools with helpful error messages
    Failure Indicators: Missing checks, cryptic errors
    Evidence: .sisyphus/evidence/task-7-prereq-checks.txt

  Scenario: build.sh does not use signing or exportArchive
    Tool: Bash
    Preconditions: build.sh exists
    Steps:
      1. grep -i "exportArchive\|ExportOptions\|DEVELOPMENT_TEAM\|CODE_SIGN_IDENTITY=\"Apple\|CODE_SIGN_IDENTITY=\"iPhone" build.sh || echo "NO SIGNING - CORRECT"
    Expected Result: "NO SIGNING - CORRECT"
    Failure Indicators: Any signing-related flags found
    Evidence: .sisyphus/evidence/task-7-no-signing.txt
  ```

  **Commit**: YES (grouped with Task 8)
  - Message: `feat(build): add master build.sh script and app assets for IPA packaging`
  - Files: `build.sh`, `Resources/Assets.xcassets/`
  - Pre-commit: `test -x build.sh`

- [ ] 8. App icon assets and launch screen

  **What to do**:
  - Create `Resources/Assets.xcassets/AppIcon.appiconset/`:
    - Generate a simple app icon programmatically or use a minimal placeholder
    - Create `Contents.json` with required iOS icon sizes (1024x1024 for App Store, 60x60@2x, 60x60@3x, etc.)
    - Icon concept: simple "VK" text or arrow/tunnel icon on solid background — keep it dead simple
    - If programmatic generation is too complex, use a single 1024x1024 PNG and let Xcode resize
  - Create `Resources/Assets.xcassets/Contents.json` (top-level asset catalog descriptor)
  - No custom launch screen — use the default (UILaunchScreen = {} in Info.plist already handles this)

  **Must NOT do**:
  - Do NOT spend time on elaborate icon design — placeholder is fine for MVP
  - Do NOT add launch screen storyboard
  - Do NOT add image assets beyond app icon

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple asset catalog creation with placeholder icon
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 7 in Wave 3)
  - **Parallel Group**: Wave 3
  - **Blocks**: Task 7 (build needs assets)
  - **Blocked By**: Task 3 (needs project.yml to know asset paths)

  **References**:

  **External References**:
  - Apple icon sizes: `https://developer.apple.com/design/human-interface-guidelines/app-icons`
  - Asset catalog format: `https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/`

  **Acceptance Criteria**:

  - [ ] `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` exists
  - [ ] `Resources/Assets.xcassets/Contents.json` exists
  - [ ] At least one PNG icon file exists in AppIcon.appiconset

  **QA Scenarios**:

  ```
  Scenario: Asset catalog has valid structure
    Tool: Bash
    Preconditions: Resources/ directory exists
    Steps:
      1. test -f Resources/Assets.xcassets/Contents.json && echo "CATALOG OK"
      2. test -f Resources/Assets.xcassets/AppIcon.appiconset/Contents.json && echo "ICON SET OK"
      3. ls Resources/Assets.xcassets/AppIcon.appiconset/*.png 2>/dev/null | wc -l
    Expected Result: Steps 1-2 confirm files exist. Step 3 shows at least 1 PNG.
    Failure Indicators: Missing Contents.json, no PNG files
    Evidence: .sisyphus/evidence/task-8-assets.txt
  ```

  **Commit**: YES (grouped with Task 7)
  - Message: (grouped with Task 7's commit)
  - Files: `Resources/Assets.xcassets/`

- [ ] 9. End-to-end build verification

  **What to do**:
  - Run `./build.sh` from completely clean state (delete build/, generated xcodeproj, etc.)
  - Capture full terminal output as evidence
  - Verify all build artifacts:
    - `build/go/libvkturn.a` — Go static library exists, correct platform
    - `build/go/libvkturn.h` — Header with all 4 exports
    - `VKTurnProxy.xcodeproj/` — Generated Xcode project
    - `build/VKTurnProxy.xcarchive/` — Xcode archive
    - `build/VKTurnProxy.ipa` — Final IPA
  - Verify IPA internal structure:
    - Contains `Payload/VKTurnProxy.app/VKTurnProxy` (arm64 Mach-O executable)
    - Contains `Payload/VKTurnProxy.app/Info.plist` with correct bundle ID and version
    - No code signature present (unsigned)
  - Check binary architecture: `lipo -info` on extracted binary should show arm64
  - Record IPA file size
  - If any step fails: document the failure clearly for fixing

  **Must NOT do**:
  - Do NOT attempt to install on device (no signing at this stage)
  - Do NOT attempt to run on simulator (arm64 only, no sim support)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Comprehensive verification requiring multiple tools and careful checking
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 10 in Wave 4)
  - **Parallel Group**: Wave 4
  - **Blocks**: F1-F4
  - **Blocked By**: Task 7

  **References**:

  **WHY**: This is the integration test — verifies all pieces work together

  **Acceptance Criteria**:

  - [ ] `./build.sh` exits 0 from clean state
  - [ ] All build artifacts listed above exist
  - [ ] IPA contains correct structure
  - [ ] Evidence file saved with full build log

  **QA Scenarios**:

  ```
  Scenario: Clean build from scratch succeeds
    Tool: Bash
    Preconditions: All source files from Tasks 1-8 present
    Steps:
      1. rm -rf build/ VKTurnProxy.xcodeproj/
      2. ./build.sh 2>&1 | tee .sisyphus/evidence/task-9-full-build-log.txt
      3. echo "EXIT CODE: $?"
      4. test -f build/VKTurnProxy.ipa && echo "IPA EXISTS"
      5. otool -l build/go/libvkturn.a | grep -A5 LC_BUILD_VERSION | head -10
      6. unzip -p build/VKTurnProxy.ipa Payload/VKTurnProxy.app/Info.plist | head -20
    Expected Result: Step 2 completes without errors. Step 3 shows "EXIT CODE: 0". Step 4 confirms IPA. Step 5 shows platform 2. Step 6 shows valid plist XML.
    Failure Indicators: Non-zero exit code, missing artifacts, wrong platform
    Evidence: .sisyphus/evidence/task-9-full-build-log.txt

  Scenario: IPA binary is arm64 Mach-O
    Tool: Bash
    Preconditions: build/VKTurnProxy.ipa exists from previous scenario
    Steps:
      1. mkdir -p /tmp/ipa-check && cd /tmp/ipa-check && unzip -o $(pwd)/build/VKTurnProxy.ipa
      2. file Payload/VKTurnProxy.app/VKTurnProxy
      3. lipo -info Payload/VKTurnProxy.app/VKTurnProxy
      4. rm -rf /tmp/ipa-check
    Expected Result: Step 2 shows "Mach-O 64-bit executable arm64". Step 3 shows "arm64".
    Failure Indicators: Wrong architecture, not Mach-O
    Evidence: .sisyphus/evidence/task-9-binary-check.txt
  ```

  **Commit**: NO (verification only, no new files)

- [ ] 10. README with setup, build, install, and WireGuard configuration instructions

  **What to do**:
  - Create `README.md` at project root covering:
    1. **What this is**: iOS port of vk-turn-proxy — tunnels WireGuard through VK call TURN servers
    2. **Prerequisites**:
       - macOS with Xcode installed (full Xcode.app, not just CLI tools)
       - Go 1.25+ (`brew install go` or download from go.dev)
       - XcodeGen (`brew install xcodegen`)
       - AltStore or Sideloadly installed on Mac
       - iPhone/iPad running iOS 18+
    3. **Building** (two options):
       - **Option A — GitHub CI (no local tools needed)**:
         Push code to GitHub → Actions builds IPA automatically → download from Releases or workflow artifacts
         For releases: `git tag v1.0.0 && git push --tags`
       - **Option B — Local build**:
         ```bash
         git clone <repo>
         cd ios-vpn-tun
         ./build.sh
         ```
         Requires: macOS + Xcode + Go 1.25+ + XcodeGen
       - Output: `build/VKTurnProxy.ipa`
    4. **Installing**:
       - Open AltStore on Mac
       - Connect iPhone via USB
       - Install `build/VKTurnProxy.ipa` through AltStore
       - NOTE: Must re-sign every 7 days with free Apple ID
    5. **Using**:
       - You need a VK Turn Proxy SERVER running on a VPS (see original project)
       - Open VK Turn app on iPhone
       - Enter server address (peer) and VK call join link
       - Tap Connect
       - Open WireGuard app → configure endpoint as `127.0.0.1:9000`
       - **CRITICAL**: In WireGuard config, set AllowedIPs to exclude localhost:
         `AllowedIPs = 0.0.0.0/1, 128.0.0.0/1` (this already excludes 127.0.0.0/8)
         OR use the "Exclude Private IPs" toggle if available
       - **IMPORTANT**: VK Turn app must stay in foreground (or recent apps) for proxy to work. Background audio mode helps but is not guaranteed.
    6. **Limitations**:
       - Proxy stops when app is killed/force-closed
       - 7-day re-signing with free AltStore
       - No Yandex Telemost support (service shut down)
       - VK may change their API at any time
    7. **Credits**: Link to original vk-turn-proxy project

  **Must NOT do**:
  - Do NOT write in Russian (keep README in English for wider audience, original project is also multilingual)
  - Do NOT include server setup instructions (out of scope)
  - Do NOT over-document — keep it concise

  **Recommended Agent Profile**:
  - **Category**: `writing`
    - Reason: Documentation writing task
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 9 in Wave 4)
  - **Parallel Group**: Wave 4
  - **Blocks**: F1-F4
  - **Blocked By**: Task 7 (needs to know exact build steps)

  **References**:

  **Pattern References**:
  - Original vk-turn-proxy README: `https://github.com/cacggghp/vk-turn-proxy` — for understanding what the tool does and server-side setup link
  - Android port README: `https://github.com/MYSOREZ/vk-turn-proxy-android` — for usage pattern reference

  **WHY Each Reference Matters**:
  - Original README explains what the tool does — our README should be consistent
  - Android README shows the usage pattern we're replicating (separate WG + proxy app)

  **Acceptance Criteria**:

  - [ ] `README.md` exists at project root
  - [ ] Contains both build options (GitHub CI + local build.sh)
  - [ ] Contains WireGuard configuration instructions with `127.0.0.1:9000`
  - [ ] Contains AllowedIPs configuration to exclude localhost
  - [ ] Contains AltStore installation instructions
  - [ ] Contains 7-day re-signing note

  **QA Scenarios**:

  ```
  Scenario: README contains all required sections
    Tool: Bash
    Preconditions: README.md exists
    Steps:
      1. grep -i "prerequisite\|requirements" README.md
      2. grep "build.sh" README.md
      3. grep "127.0.0.1:9000" README.md
      4. grep -i "AllowedIPs\|allowedips" README.md
      5. grep -i "AltStore\|Sideloadly" README.md
      6. grep -i "7.day\|seven.day\|re-sign" README.md
      7. grep -i "GitHub Actions\|github.actions\|CI" README.md
    Expected Result: All greps find at least one match
    Failure Indicators: Missing critical section
    Evidence: .sisyphus/evidence/task-10-readme-check.txt
  ```

  **Commit**: YES
  - Message: `docs: add README with build, install, and WireGuard config instructions`
  - Files: `README.md`
  - Pre-commit: `test -f README.md`

- [ ] 11. GitHub Actions CI workflow for building IPA without local Xcode

  **What to do**:
  - Create `.github/workflows/build-ipa.yml` — GitHub Actions workflow that builds the unsigned IPA entirely in CI
  - **Trigger**: on push to `main` branch + on tag push (`v*`) for releases + manual `workflow_dispatch`
  - **Runner**: `macos-15` (has Xcode 16.4 with iOS 18 SDK pre-installed, M1 arm64 native)
  - **Workflow steps**:
    1. `actions/checkout@v4`
    2. `actions/setup-go@v5` with `go-version: '1.25'` and `cache: true`
    3. Install XcodeGen: `brew install xcodegen`
    4. Select Xcode: `sudo xcode-select -s /Applications/Xcode_16.4.app`
    5. Run `./build.sh` (reuse the same script that works locally)
    6. Upload IPA as workflow artifact: `actions/upload-artifact@v4` with `build/VKTurnProxy.ipa`
    7. **On tag push only**: Create GitHub Release with IPA attached via `gh release create`
  - **Release step** (conditional on tag):
    ```yaml
    - name: Create Release
      if: startsWith(github.ref, 'refs/tags/')
      run: |
        gh release create ${{ github.ref_name }} \
          build/VKTurnProxy.ipa \
          --title "VK Turn Proxy ${{ github.ref_name }}" \
          --notes "Unsigned IPA for sideloading via AltStore/Sideloadly"
      env:
        GH_TOKEN: ${{ github.token }}
    ```
  - **User workflow**: Push code to GitHub → CI builds IPA → download from Actions artifacts or GitHub Releases
  - This means user does NOT need Xcode, Go, or XcodeGen installed locally at all
  - For releases: `git tag v1.0.0 && git push --tags` → IPA appears in GitHub Releases

  **Must NOT do**:
  - Do NOT add code signing or Apple ID secrets — build is unsigned
  - Do NOT use `macos-latest` (use explicit `macos-15` for reproducibility)
  - Do NOT add complex matrix builds or multi-platform support
  - Do NOT add Fastlane or other CI wrappers

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Single YAML file with well-documented GitHub Actions patterns. Runner capabilities are verified.
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `git-master`: No complex git operations — just a workflow file

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 9, 10 in Wave 4)
  - **Parallel Group**: Wave 4
  - **Blocks**: F1-F4
  - **Blocked By**: Task 7 (workflow calls build.sh, so build.sh must exist first)

  **References**:

  **Pattern References**:
  - GopeedLab/gopeed `.github/workflows/build.yml` — Real example: Go mobile bindings + Flutter iOS + unsigned IPA + `gh release create` in one workflow
  - diasurgical/DevilutionX `.github/workflows/iOS.yml` — Real example: CMake iOS unsigned build → manual Payload zip → IPA on GitHub Actions
  - aiyakuaile/easy_tv_live `.github/workflows/main.yml` — Real example: Flutter iOS `--no-codesign` → Payload zip → IPA

  **API/Type References**:
  - `macos-15` runner specs: Xcode 16.4 (default), Go 1.25.7 pre-installed, 3-core M1, 7GB RAM, `gh` CLI 2.87+
  - `actions/setup-go@v5` — Go version management with caching
  - `actions/upload-artifact@v4` — Workflow artifact upload

  **External References**:
  - GitHub Actions macOS runners: `https://github.com/actions/runner-images`
  - `gh release create` docs: `https://cli.github.com/manual/gh_release_create`

  **WHY Each Reference Matters**:
  - GopeedLab workflow is the closest real-world example: Go compilation + iOS unsigned IPA + GitHub Release in one pipeline
  - Runner image specs confirm all tools are pre-installed — no guessing

  **Acceptance Criteria**:

  - [ ] `.github/workflows/build-ipa.yml` exists
  - [ ] Workflow runs on `macos-15` runner
  - [ ] Workflow installs Go 1.25 and XcodeGen
  - [ ] Workflow calls `./build.sh` to build the IPA
  - [ ] Workflow uploads IPA as artifact (`actions/upload-artifact`)
  - [ ] Workflow creates GitHub Release with IPA on tag push (`gh release create`)
  - [ ] No signing secrets or Apple ID references in workflow

  **QA Scenarios**:

  ```
  Scenario: Workflow file has correct structure and triggers
    Tool: Bash
    Preconditions: .github/workflows/build-ipa.yml exists
    Steps:
      1. grep "macos-15" .github/workflows/build-ipa.yml
      2. grep "setup-go@v5\|setup-go@v4" .github/workflows/build-ipa.yml
      3. grep "xcodegen" .github/workflows/build-ipa.yml
      4. grep "build.sh" .github/workflows/build-ipa.yml
      5. grep "upload-artifact" .github/workflows/build-ipa.yml
      6. grep "gh release create" .github/workflows/build-ipa.yml
      7. grep "workflow_dispatch" .github/workflows/build-ipa.yml
    Expected Result: All greps find matches — workflow has all required components
    Failure Indicators: Missing runner, missing Go setup, missing build step, missing artifact upload, missing release creation
    Evidence: .sisyphus/evidence/task-11-workflow-structure.txt

  Scenario: Workflow does not contain signing secrets
    Tool: Bash
    Preconditions: .github/workflows/build-ipa.yml exists
    Steps:
      1. grep -i "APPLE_ID\|TEAM_ID\|CERTIFICATE\|PROVISIONING\|P12\|KEYCHAIN\|CODE_SIGN_IDENTITY=\"Apple\|CODE_SIGN_IDENTITY=\"iPhone" .github/workflows/build-ipa.yml || echo "NO SIGNING SECRETS - CORRECT"
    Expected Result: "NO SIGNING SECRETS - CORRECT"
    Failure Indicators: Any signing-related secrets found
    Evidence: .sisyphus/evidence/task-11-no-signing.txt

  Scenario: Workflow YAML is valid
    Tool: Bash
    Preconditions: .github/workflows/build-ipa.yml exists
    Steps:
      1. python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-ipa.yml'))" && echo "VALID YAML"
    Expected Result: "VALID YAML"
    Failure Indicators: YAML parse error
    Evidence: .sisyphus/evidence/task-11-yaml-valid.txt
  ```

  **Commit**: YES
  - Message: `ci: add GitHub Actions workflow for building unsigned IPA and creating releases`
  - Files: `.github/workflows/build-ipa.yml`
  - Pre-commit: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-ipa.yml'))"`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Rejection → fix → re-run.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists (read file, run command). For each "Must NOT Have": search codebase for forbidden patterns — reject with file:line if found. Check evidence files exist in `.sisyphus/evidence/`. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `./build.sh` from clean state. Review all Go and Swift files for: `as any`/`@ts-ignore` equivalents, empty catches, print statements in prod code, commented-out code, unused imports. Check for AI slop: excessive comments, over-abstraction, generic variable names.
  Output: `Build [PASS/FAIL] | Files [N clean/N issues] | VERDICT`

- [ ] F3. **Full Build QA — Clean Build from Scratch** — `unspecified-high`
  Delete `build/` directory. Run `./build.sh` from clean state. Verify IPA exists, verify IPA structure (Payload/VKTurnProxy.app/VKTurnProxy binary, Info.plist). Verify Go .a was rebuilt. Verify no signing identity was used. Save terminal output as evidence.
  Output: `Clean Build [PASS/FAIL] | IPA Valid [YES/NO] | Structure [N/N checks] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual files created. Verify 1:1 — everything in spec was built, nothing beyond spec was built. Check "Must NOT Have" compliance: no NE code, no Yandex code, no gomobile, no exportArchive. Flag any unaccounted files.
  Output: `Tasks [N/N compliant] | Must NOT Have [N/N clean] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

- **Commit 1** (after Task 1): `feat(go): add bridge module wrapping vk-turn-proxy client for iOS c-archive` — go/bridge.go, go/proxy.go, go/vkcreds.go, go/go.mod, go/go.sum
- **Commit 2** (after Task 2): `feat(build): add build-go.sh for iOS arm64 c-archive cross-compilation` — scripts/build-go.sh
- **Commit 3** (after Task 3): `feat(xcode): add XcodeGen project.yml, Info.plist, and entitlements` — project.yml, Info.plist, VKTurnProxy.entitlements
- **Commit 4** (after Task 4): `feat(swift): add C bridge and proxy manager for Go library lifecycle` — Sources/Bridge/
- **Commit 5** (after Task 5): `feat(ui): add minimal SwiftUI interface with connect/disconnect and log` — Sources/App/
- **Commit 6** (after Task 6): `feat(background): add background audio mode for proxy keepalive` — Sources/App/BackgroundAudioManager.swift
- **Commit 7** (after Tasks 7, 8): `feat(build): add master build.sh script and app assets for IPA packaging` — build.sh, Resources/
- **Commit 8** (after Task 10): `docs: add README with build, install, and WireGuard config instructions` — README.md
- **Commit 9** (after Task 11): `ci: add GitHub Actions workflow for building unsigned IPA and creating releases` — .github/workflows/build-ipa.yml

---

## Success Criteria

### Verification Commands
```bash
./build.sh                                                    # Expected: exits 0
test -f build/VKTurnProxy.ipa && echo "IPA EXISTS"           # Expected: IPA EXISTS
unzip -l build/VKTurnProxy.ipa | grep "Payload/VKTurnProxy.app/VKTurnProxy"  # Expected: match found
unzip -l build/VKTurnProxy.ipa | grep "Payload/VKTurnProxy.app/Info.plist"   # Expected: match found
otool -l build/go/libvkturn.a | grep -A5 LC_BUILD_VERSION | grep "platform 2"  # Expected: platform 2 (iOS)
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] `./build.sh` exits 0 from clean state
- [ ] IPA file valid and contains correct app structure
- [ ] README exists with setup instructions
