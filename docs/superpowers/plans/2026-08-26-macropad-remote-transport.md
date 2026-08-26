# MacroPad Remote Transport Implementation Plan

**Status:** Landed — all 9 tasks committed on the `macropad-remote-transport`
branch. This is the plan as written, not as built; treat
[`2026-08-26-macropad-remote-transport-handover.md`](2026-08-26-macropad-remote-transport-handover.md)
as authoritative for what actually happened, what was verified, and how to
operate it. Known-wrong below, named by symbol and section heading rather
than by line number — this is a long, multi-task planning document, and any
line number cited here would drift on the next edit (including this one).

- The `find_device()` shell function in Task 8, "The bridge script", proved
  unable to match anything against this machine's `ioreg` output.
  `scripts/macropad-bridge.sh`'s own `find_device` is the version that
  actually works.
- The `b115200` socat option — in Task 4 ("`openTCP` and the socket
  options") Step 3's stand-in-bridge verification snippet, and again in
  Task 8's draft bridge loop — is rejected outright by this machine's socat
  1.8.1.3. The shipped script uses `ispeed=115200,ospeed=115200`.
- `device.setEnabled(...)` and `settings.macroPadEnabled`, used throughout
  Tasks 2 through 5, are mechanical mid-refactor scaffolding for a rename
  that landed as `setSource(_:)` / `macroPadSource`. Neither retired symbol
  exists on this branch.
- Task 9 ("Loopback verification, CI floor, and documentation") Step 1, the
  real-hardware loopback, was never run — the only real MacroPad was in
  continuous use by the installed Canopy throughout this branch's work (see
  the handover doc's "What is verified, and what is not").
- The Global Constraints section's bullet claiming pure-value-type coverage
  is "verified by the loopback run in Task 9" is false for the same reason —
  that run never happened. The handover doc's verification table is what
  actually covers that ground.
- Task 6 ("Settings UI — picker and validated address field")'s Picker-
  disabled-row verification tip still says the selection can never be
  `remote` with an unusable address because `commitHost` "moves it to
  `.local`". That became false once this branch's final fix wave changed
  `commitHost`'s empty-address fallback to `.off` (matching the spec's
  argument in §1) — see `Sources/Canopy/SettingsView.swift`'s live
  `commitHost` for the current behaviour.
- `MacroPadController.clearsSleep(movingTo:)`, produced by Task 5 and quoted
  throughout that task's body (including its Global Constraints bullet),
  was renamed to `shouldClearSleep(lastSource:movingTo:)` in a later
  review-fix round, which also gave it a second parameter — the old
  single-parameter signature no longer exists. See that function's doc
  comment on `MacroPadController` for why both conditions are needed.
- Task 9's closing arithmetic ("the tasks above add 31 … Task 1 measured
  578, which is exactly 551 + 27") is stale twice over: a later commit on
  this branch removed one probe assertion, landing the floor at 581, and a
  subsequent review-fix round (T1/T2/T3 in that round's report) added 6 more
  — 2 for `parsePort`'s ASCII-digit guard, 1 net for extracting
  `MacroPadController.shouldClearSleep`, 1 for `displayLabel`'s IPv6
  bracketing, and 2 for `MacroPadDevice.Endpoint.label` — measured at 587.
  `.github/workflows/ci.yml`'s `EXPECTED_ASSERTIONS` is the live number; this
  bullet is a historical note about why the body's arithmetic no longer
  matches it, not a second place that number is tracked.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Canopy drive its MacroPad over TCP from a bridge on another Mac, switchable live between `Off` / `Local USB` / `Remote`, so a pad plugged into the MBP can run the Studio's Canopy over Tailscale.

**Architecture:** Everything in `MacroPadDevice` from `adopt` onward already works on any file descriptor — the `DispatchSourceRead`, `writeBytes`, and `MacroPadLineDecoder` are transport-agnostic. Only discovery and `open`+`configureTTY` are serial-specific, so an `Endpoint` enum forks exactly those two points and the `HELLO`/`PONG` probe stays shared. One transport is live at a time, chosen by `CanopySettings.macroPadSource`, which replaces the old `macroPadEnabled` boolean.

**Tech Stack:** Swift 6 (Xcode 26 toolchain required), SwiftUI, BSD sockets + IOKit, `socat` + launchd on the bridge side.

**Spec:** `docs/superpowers/specs/2026-08-26-macropad-remote-transport-design.md`

## Global Constraints

- **Xcode 26 toolchain is required.** Under Xcode 16.4 this project does not compile at all. `project.yml` sets `SWIFT_VERSION: "6.0"` (language mode, not compiler).
- **Build with `./scripts/build_debug_stable.sh`.** Never `CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO` — that re-triggers the TCC dialog every launch. The Debug bundle id is `sh.saqoo.Canopy.debug`.
- **Tests are the DEBUG logic probe, not XCTest.** There is no XCTest target. Assertions are `record(name, ok, detail)` calls inside `SidebarLogicProbe.runAllTests()` in `Sources/Canopy/_SidebarLogicProbe.swift`. Run with:
  `CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`
  It prints `--- N passed, M failed ---` to stderr and exits on the failure counter (~3 s).
- **Only pure value types are probe-reachable.** Anything needing a live socket, a real `/dev/cu.*`, or AppKit is verified by the loopback run in Task 9, not by the probe.
- **Version control is `jj`** (this repo is jj-colocated). Bookmark for this work: `macropad-remote-transport`. Commit messages are English, imperative summary, bullet details, and end with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **Japanese Markdown headings use 体言止め.** Does not apply to this plan or to any file it touches (all English), but applies if you write Japanese docs.
- **Never log a secret or a full filesystem path without `privacy: .private`.** Host names in this feature are not secret and use `privacy: .public`.

---

### Task 1: `MacroPadRemoteEndpoint` and `MacroPadSource`

The two pure value types the whole feature rests on. Parsing happens here and nowhere else — no runtime path re-parses an address string.

**Files:**
- Create: `Sources/Canopy/MacroPad/MacroPadRemoteEndpoint.swift`
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift` (append a new section after the existing `// MARK: - MacroPad wire protocol / SessionActivity / unread tracker` block, which starts at line 3490)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct MacroPadRemoteEndpoint: Equatable, Sendable` with `let host: String`, `let port: UInt16`, `var displayLabel: String`, `static let defaultPort: UInt16 = 8765`, `static func parse(_ raw: String) -> MacroPadRemoteEndpoint?`
  - `enum MacroPadSource: Equatable, Sendable` with cases `off`, `local`, `remote(MacroPadRemoteEndpoint)`, plus `var isOff: Bool`, `var rawValue: String`, `static func resolve(rawValue: String, host: String) -> MacroPadSource?`, `static func migrated(storedRaw: String?, storedHost: String, legacyEnabled: Bool?) -> MacroPadSource`

- [ ] **Step 1: Write the failing assertions**

Open `Sources/Canopy/_SidebarLogicProbe.swift`. Find the end of the MacroPad section — search for the last `record("macropad ` line before `// MARK: - Session restore snapshot`. Insert this block immediately before that `// MARK:` line:

```swift
        // MARK: - MacroPad remote endpoint parsing (remote transport)
        //
        // Parsing happens once, at the settings boundary. Every assertion
        // here is a shape that must NOT reach the socket layer as a guess.

        record("macropad endpoint: bare host takes the default port",
               MacroPadRemoteEndpoint.parse("mbp") == MacroPadRemoteEndpoint(host: "mbp", port: 8765),
               "got \(String(describing: MacroPadRemoteEndpoint.parse("mbp")))")
        record("macropad endpoint: host:port",
               MacroPadRemoteEndpoint.parse("mbp:9000") == MacroPadRemoteEndpoint(host: "mbp", port: 9000),
               "got \(String(describing: MacroPadRemoteEndpoint.parse("mbp:9000")))")
        record("macropad endpoint: surrounding whitespace is trimmed",
               MacroPadRemoteEndpoint.parse("  mbp:9000  ") == MacroPadRemoteEndpoint(host: "mbp", port: 9000),
               "got \(String(describing: MacroPadRemoteEndpoint.parse("  mbp:9000  ")))")
        record("macropad endpoint: bracketed IPv6 with a port",
               MacroPadRemoteEndpoint.parse("[fd7a::1]:8765") == MacroPadRemoteEndpoint(host: "fd7a::1", port: 8765),
               "got \(String(describing: MacroPadRemoteEndpoint.parse("[fd7a::1]:8765")))")
        record("macropad endpoint: bracketed IPv6 without a port",
               MacroPadRemoteEndpoint.parse("[fd7a::1]") == MacroPadRemoteEndpoint(host: "fd7a::1", port: 8765),
               "got \(String(describing: MacroPadRemoteEndpoint.parse("[fd7a::1]")))")
        // A bare v6 literal is ambiguous with host:port. Rejected, never guessed.
        record("macropad endpoint: unbracketed IPv6 is rejected",
               MacroPadRemoteEndpoint.parse("fd7a::1") == nil,
               "got \(String(describing: MacroPadRemoteEndpoint.parse("fd7a::1")))")
        record("macropad endpoint: empty is nil",
               MacroPadRemoteEndpoint.parse("") == nil, "expected nil")
        record("macropad endpoint: whitespace only is nil",
               MacroPadRemoteEndpoint.parse("   ") == nil, "expected nil")
        record("macropad endpoint: empty host with a port is nil",
               MacroPadRemoteEndpoint.parse(":8765") == nil, "expected nil")
        record("macropad endpoint: port 0 is nil",
               MacroPadRemoteEndpoint.parse("mbp:0") == nil, "expected nil")
        record("macropad endpoint: port 65536 is nil",
               MacroPadRemoteEndpoint.parse("mbp:65536") == nil, "expected nil")
        record("macropad endpoint: non-numeric port is nil",
               MacroPadRemoteEndpoint.parse("mbp:abc") == nil, "expected nil")
        record("macropad endpoint: missing port after the colon is nil",
               MacroPadRemoteEndpoint.parse("mbp:") == nil, "expected nil")
        record("macropad endpoint: displayLabel round-trips",
               MacroPadRemoteEndpoint.parse("mbp")?.displayLabel == "mbp:8765",
               "got \(String(describing: MacroPadRemoteEndpoint.parse("mbp")?.displayLabel))")

        // --- MacroPadSource resolution and migration
        record("macropad source: off resolves",
               MacroPadSource.resolve(rawValue: "off", host: "") == .off, "expected .off")
        record("macropad source: local resolves",
               MacroPadSource.resolve(rawValue: "local", host: "") == .local, "expected .local")
        record("macropad source: remote resolves with a valid host",
               MacroPadSource.resolve(rawValue: "remote", host: "mbp:9000")
                   == .remote(MacroPadRemoteEndpoint(host: "mbp", port: 9000)),
               "got \(String(describing: MacroPadSource.resolve(rawValue: "remote", host: "mbp:9000")))")
        // Degrading to .local here would silently drive a DIFFERENT pad than
        // the one configured, which is the worst outcome available.
        record("macropad source: remote with an empty host degrades to off, not local",
               MacroPadSource.resolve(rawValue: "remote", host: "") == .off,
               "got \(String(describing: MacroPadSource.resolve(rawValue: "remote", host: "")))")
        record("macropad source: remote with an unparseable host degrades to off",
               MacroPadSource.resolve(rawValue: "remote", host: "mbp:abc") == .off,
               "got \(String(describing: MacroPadSource.resolve(rawValue: "remote", host: "mbp:abc")))")
        record("macropad source: an unknown selector does not resolve",
               MacroPadSource.resolve(rawValue: "banana", host: "") == nil, "expected nil")
        record("macropad source: isOff only for off",
               MacroPadSource.off.isOff && !MacroPadSource.local.isOff, "isOff is wrong")
        record("macropad source: rawValue spellings",
               MacroPadSource.off.rawValue == "off"
                   && MacroPadSource.local.rawValue == "local"
                   && MacroPadSource.remote(MacroPadRemoteEndpoint(host: "m", port: 1)).rawValue == "remote",
               "rawValue spelling changed")

        record("macropad source migration: legacy enabled=true becomes local",
               MacroPadSource.migrated(storedRaw: nil, storedHost: "", legacyEnabled: true) == .local,
               "expected .local")
        record("macropad source migration: legacy enabled=false becomes off",
               MacroPadSource.migrated(storedRaw: nil, storedHost: "", legacyEnabled: false) == .off,
               "expected .off")
        record("macropad source migration: a fresh install defaults to local",
               MacroPadSource.migrated(storedRaw: nil, storedHost: "", legacyEnabled: nil) == .local,
               "expected .local")
        // The stored selector outranks the legacy key once it exists.
        record("macropad source migration: a stored selector wins over the legacy key",
               MacroPadSource.migrated(storedRaw: "off", storedHost: "", legacyEnabled: true) == .off,
               "expected .off")
        // A garbage SELECTOR falls through to the legacy/default path. That is
        // different from a garbage ADDRESS, which degrades to .off above.
        record("macropad source migration: a garbage selector falls through to the legacy key",
               MacroPadSource.migrated(storedRaw: "banana", storedHost: "", legacyEnabled: false) == .off,
               "expected .off")

```

- [ ] **Step 2: Run the probe and verify it fails to build**

```bash
./scripts/build_debug_stable.sh
```

Expected: FAIL. Compiler errors along the lines of `cannot find 'MacroPadRemoteEndpoint' in scope` and `cannot find 'MacroPadSource' in scope`. That the build breaks *is* the failing test here — the probe cannot run until the types exist.

- [ ] **Step 3: Write the implementation**

Create `Sources/Canopy/MacroPad/MacroPadRemoteEndpoint.swift`:

```swift
import Foundation

/// Where a remote MacroPad bridge lives.
///
/// Parsed once, at the settings boundary, and stored as a value from then on.
/// Nothing downstream re-parses an address string, so no runtime path has to
/// decide what a malformed one means.
struct MacroPadRemoteEndpoint: Equatable, Sendable {
    /// Matches the port `scripts/macropad-bridge.sh` listens on. Changing one
    /// without the other silently produces a pad that never connects.
    static let defaultPort: UInt16 = 8765

    let host: String
    let port: UInt16

    /// What logs and the menu show. Always carries the port, including when
    /// the user typed a bare host, so a log line is unambiguous about which
    /// port was actually tried.
    var displayLabel: String { "\(host):\(port)" }

    /// Accepts `host`, `host:port`, `[v6]`, and `[v6]:port`.
    ///
    /// Returns nil for anything that would otherwise have to be guessed at:
    /// an empty host, a port outside 1...65535, a non-numeric port, or a bare
    /// IPv6 literal — the last because `fd7a::1` is indistinguishable from a
    /// `host:port` with a strange host, and picking either reading silently
    /// dials somewhere the user did not ask for.
    static func parse(_ raw: String) -> MacroPadRemoteEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty { return MacroPadRemoteEndpoint(host: host, port: defaultPort) }
            guard rest.hasPrefix(":"), let port = parsePort(String(rest.dropFirst())) else { return nil }
            return MacroPadRemoteEndpoint(host: host, port: port)
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return MacroPadRemoteEndpoint(host: String(parts[0]), port: defaultPort)
        case 2:
            let host = String(parts[0])
            guard !host.isEmpty, let port = parsePort(String(parts[1])) else { return nil }
            return MacroPadRemoteEndpoint(host: host, port: port)
        default:
            // Three or more colons: an unbracketed IPv6 literal. See the doc.
            return nil
        }
    }

    private static func parsePort(_ raw: String) -> UInt16? {
        // `UInt16(raw)` alone would accept "+1" and Unicode digits; both would
        // then be handed to `getaddrinfo` as a service name.
        guard !raw.isEmpty,
              raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt16(raw),
              value > 0
        else { return nil }
        return value
    }
}

/// Which pad this Canopy is driving.
///
/// Replaces `CanopySettings.macroPadEnabled`. Carrying both a boolean and a
/// selector would give two spellings of "off" that could disagree.
///
/// Only one case is ever live at a time, which is the whole design: the
/// firmware blanks itself when its host disconnects, so switching away leaves
/// the abandoned pad dark for free, and `canopy.macroPadAsleep` can stay a
/// single boolean instead of a per-device map.
enum MacroPadSource: Equatable, Sendable {
    case off
    case local
    case remote(MacroPadRemoteEndpoint)

    var isOff: Bool {
        if case .off = self { return true }
        return false
    }

    /// The persisted spelling of the selector only. The address lives in its
    /// own settings key so the menu can switch without re-typing it.
    var rawValue: String {
        switch self {
        case .off: return "off"
        case .local: return "local"
        case .remote: return "remote"
        }
    }

    /// Resolves a stored selector against a stored address.
    ///
    /// Returns nil when the selector itself is unrecognised, so the caller can
    /// fall through to migration rather than inventing a state.
    ///
    /// A `remote` selector whose ADDRESS is unusable degrades to `.off`, never
    /// to `.local`. The settings file is hand-editable, and quietly driving a
    /// different pad than the one configured is worse than driving none.
    static func resolve(rawValue: String, host: String) -> MacroPadSource? {
        switch rawValue {
        case "off": return .off
        case "local": return .local
        case "remote": return MacroPadRemoteEndpoint.parse(host).map(MacroPadSource.remote) ?? .off
        default: return nil
        }
    }

    /// The load-time ladder: a stored selector wins; failing that the retired
    /// `canopy.macroPadEnabled` boolean is mapped once; failing that, `.local`,
    /// which is what a fresh install used to get from `macroPadEnabled = true`.
    ///
    /// Note the asymmetry with `resolve`: an unrecognised SELECTOR falls
    /// through to the legacy key, because it says nothing about intent. An
    /// unusable ADDRESS under a `remote` selector does not — that one is a
    /// specific request that cannot be honoured, so it lands on `.off`.
    static func migrated(storedRaw: String?, storedHost: String, legacyEnabled: Bool?) -> MacroPadSource {
        if let storedRaw, let resolved = resolve(rawValue: storedRaw, host: storedHost) {
            return resolved
        }
        if let legacyEnabled { return legacyEnabled ? .local : .off }
        return .local
    }
}
```

- [ ] **Step 4: Build and run the probe**

```bash
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```

Expected: PASS for all 26 new `macropad endpoint:` / `macropad source:` / `macropad source migration:` lines, and the summary's failure count is 0.

- [ ] **Step 5: Commit**

```bash
jj describe -m "Add MacroPadRemoteEndpoint and MacroPadSource value types

- Parse bridge addresses once at the settings boundary
- Reject unbracketed IPv6 rather than guessing host:port
- Degrade a remote selector with a bad address to off, never to local
- Cover parsing, resolution and legacy migration in the logic probe

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
jj new
jj bookmark set macropad-remote-transport -r @-
```

---

### Task 2: Settings keys and migration

**Files:**
- Modify: `Sources/Canopy/CanopySettings.swift` (the `macroPadEnabled` property around line 37, the `load()` line reading `canopy.macroPadEnabled` around line 97, and `save()` around line 127)
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: `MacroPadSource`, `MacroPadRemoteEndpoint` from Task 1.
- Produces: `CanopySettings.macroPadSource: MacroPadSource` and `CanopySettings.macroPadRemoteHost: String`. `CanopySettings.macroPadEnabled` **no longer exists** — Tasks 5, 6 and 7 must not reference it.

- [ ] **Step 1: Write the failing assertion**

The `load()`/`save()` pair touches the real settings file, so it is not probe-reachable. What *is* reachable is that the settings object exposes the new surface. Append to the block added in Task 1, immediately after the last `macropad source migration:` line:

```swift
        // The load/save pair reads the real settings file and is not
        // probe-reachable; this pins only that the new surface exists and
        // that the retired boolean is gone from the type.
        record("macropad settings: the live source is one of the three spellings",
               ["off", "local", "remote"].contains(CanopySettings.shared.macroPadSource.rawValue),
               "got \(CanopySettings.shared.macroPadSource.rawValue)")

```

- [ ] **Step 2: Build and verify it fails**

```bash
./scripts/build_debug_stable.sh
```

Expected: FAIL with `value of type 'CanopySettings' has no member 'macroPadRemoteHost'`.

- [ ] **Step 3: Write the implementation**

In `Sources/Canopy/CanopySettings.swift`, **replace** the `macroPadEnabled` property:

```swift
    /// Whether the USB MacroPad is adopted when plugged in. Off leaves the
    /// pad alone (and blanks it if it was already connected).
    var macroPadEnabled: Bool = true {
        didSet { save() }
    }
```

with:

```swift
    /// Which pad this Canopy drives: none, the local USB one, or a bridge on
    /// another Mac. Replaces the old `macroPadEnabled` boolean, which is read
    /// once at load for migration and then never written again.
    ///
    /// Only one is ever live. Switching away releases the port, and the
    /// firmware blanks itself on host disconnect, so the pad left behind goes
    /// dark with no code and no user action.
    var macroPadSource: MacroPadSource = .local {
        didSet { save() }
    }

    /// Address of the remote bridge, as the user typed it (`mbp`, `mbp:8765`).
    /// Kept separate from `macroPadSource` so the menu can switch to remote
    /// and back without the address having to be re-entered.
    ///
    /// Stored raw rather than as a parsed endpoint because this is also what
    /// the Settings field shows; it is validated on commit there, and
    /// re-validated at load in case the JSON was edited by hand.
    var macroPadRemoteHost: String = "" {
        didSet { save() }
    }
```

In `load()`, **replace**:

```swift
        if let enabled = dict["canopy.macroPadEnabled"] as? Bool { macroPadEnabled = enabled }
```

with:

```swift
        macroPadRemoteHost = (dict["canopy.macroPadRemoteHost"] as? String) ?? ""
        macroPadSource = MacroPadSource.migrated(
            storedRaw: dict["canopy.macroPadSource"] as? String,
            storedHost: macroPadRemoteHost,
            legacyEnabled: dict["canopy.macroPadEnabled"] as? Bool
        )
```

(The host must be assigned first — `migrated` resolves the selector against it.)

In `save()`, **replace**:

```swift
        dict["canopy.macroPadEnabled"] = macroPadEnabled
```

with:

```swift
        dict["canopy.macroPadSource"] = macroPadSource.rawValue
        dict["canopy.macroPadRemoteHost"] = macroPadRemoteHost
        // Retire the pre-source key on the first save after migration.
        // Assigning nil removes it, so a downgrade sees a fresh install
        // rather than a stale boolean fighting the selector.
        dict["canopy.macroPadEnabled"] = nil
```

- [ ] **Step 4: Build and run the probe**

```bash
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```

Expected: the build fails in `MacroPadController.swift`, `SettingsView.swift` (both reference `macroPadEnabled`). That is expected at this point — fix them by mechanically substituting for now:
- `Sources/Canopy/MacroPad/MacroPadController.swift`: `settings.macroPadEnabled` → `!settings.macroPadSource.isOff` at every site (there are three: `start()`, `refresh()`, `publishStatus()`), and `device.setEnabled(settings.macroPadEnabled)` → `device.setEnabled(!settings.macroPadSource.isOff)`.
- `Sources/Canopy/SettingsView.swift`: `Toggle("Enable MacroPad", isOn: $settings.macroPadEnabled)` → `Toggle("Enable MacroPad", isOn: Binding(get: { !settings.macroPadSource.isOff }, set: { settings.macroPadSource = $0 ? .local : .off }))`, and `.disabled(!settings.macroPadEnabled)` → `.disabled(settings.macroPadSource.isOff)`.

Tasks 5 and 6 replace both of those properly. Then re-run: PASS, failure count 0.

- [ ] **Step 5: Commit**

```bash
jj describe -m "Replace macroPadEnabled with a macroPadSource selector

- Add canopy.macroPadSource and canopy.macroPadRemoteHost settings keys
- Migrate the retired boolean once at load and drop it on the next save
- Bridge existing call sites through isOff until later tasks replace them

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
jj new
jj bookmark set macropad-remote-transport -r @-
```

---

### Task 3: `Endpoint` split in `MacroPadDevice` (serial only)

Refactor the device's two serial-specific entry points behind an enum, and swap `setEnabled` for `setSource`, **without adding TCP yet**. Local USB must behave exactly as before at the end of this task — that is what makes it independently reviewable.

**Files:**
- Modify: `Sources/Canopy/MacroPad/MacroPadDevice.swift`

**Interfaces:**
- Consumes: `MacroPadSource` from Task 1.
- Produces: `MacroPadDevice.setSource(_ source: MacroPadSource)`. `MacroPadDevice.setEnabled(_:)` **no longer exists**. Internal `MacroPadDevice.Endpoint` with `.serial(path:interfaceNumber:)` and `.tcp(MacroPadRemoteEndpoint)` and `var label: String`.

- [ ] **Step 1: Add the `Endpoint` type and swap the stored state**

Inside `final class MacroPadDevice`, immediately after the existing `enum Output`, add:

```swift
    /// Where a probe-ready file descriptor comes from. The two cases are the
    /// only transport-specific part of this class: everything from `adopt`
    /// onward — the read source, `writeBytes`, the decoder — works on any fd.
    enum Endpoint: Equatable {
        case serial(path: String, interfaceNumber: Int)
        case tcp(MacroPadRemoteEndpoint)

        /// What logs say. `adopt` takes this rather than a path so a TCP link
        /// reads as `mbp:8765` instead of an empty or fabricated device path.
        var label: String {
            switch self {
            case .serial(let path, _): return path
            case .tcp(let endpoint): return endpoint.displayLabel
            }
        }
    }
```

Replace the stored property `private var isEnabled = true` with:

```swift
    /// The active selection. Owned by `queue` like the rest of the state.
    /// Starts at `.off` so nothing is opened before `setSource` has run —
    /// `MacroPadController.start()` supplies the real value.
    private var source: MacroPadSource = .off
```

- [ ] **Step 2: Replace `setEnabled` with `setSource`**

Replace the whole `setEnabled(_:)` function with:

```swift
    /// Settings selector. Switching closes the current port (blanking the pad
    /// first) so a pad that is being switched away from is not left showing
    /// stale colours — the firmware also blanks on host disconnect, so this is
    /// belt-and-braces for the case where the close is clean.
    ///
    /// Arms hot-plug only in `.local`. In `.remote` the IOKit matching
    /// notification would never fire, so `hasHotplug` stays false and the
    /// `scheduleRetry` chain is what keeps discovery alive — the same fallback
    /// that already exists for a failed arm.
    func setSource(_ newSource: MacroPadSource) {
        queue.async { [self] in
            guard source != newSource else { return }
            source = newSource
            if fd >= 0 {
                if !writeBytes(MacroPadCommand.reset.wireBytes) {
                    logger.error("MacroPad: reset write failed while switching source; the device blanks itself on disconnect")
                }
                closePort(notifying: true)
            }
            applySourceArming()
            retryDelay = 1
            attemptConnect()
        }
    }

    /// Must run on `queue`. Hot-plug is a local-USB concept only.
    private func applySourceArming() {
        if case .local = source {
            armMatchingNotification()
        } else {
            disarmMatchingNotification()
        }
    }
```

- [ ] **Step 3: Route `start()` through the same arming**

In `start()`, replace the body of the `queue.async` block:

```swift
        queue.async { [self] in
            isStopped = false
            armMatchingNotification()
            attemptConnect()
        }
```

with:

```swift
        queue.async { [self] in
            isStopped = false
            applySourceArming()
            attemptConnect()
        }
```

- [ ] **Step 4: Replace discovery and the connect loop**

Rename `rankedCandidates()`'s consumers. Leave `rankedCandidates()` and its `Candidate` struct exactly as they are — they still do the IOKit scan — and add below them:

```swift
    /// The single list `attemptConnect` walks, whichever mode is active.
    private func rankedEndpoints() -> [Endpoint] {
        switch source {
        case .off:
            return []
        case .remote(let endpoint):
            return [.tcp(endpoint)]
        case .local:
            return rankedCandidates().map { .serial(path: $0.path, interfaceNumber: $0.interfaceNumber) }
        }
    }
```

Replace `attemptConnect()` with:

```swift
    private func attemptConnect() {
        guard !isStopped, !source.isOff, fd < 0 else { return }
        let endpoints = rankedEndpoints()
        guard !endpoints.isEmpty else {
            // Nothing enumerated. With hot-plug armed the matching callback is
            // the wake-up and a timer would be redundant — but when arming
            // failed, this is the only thread back, and returning here would
            // end discovery for the lifetime of the process while the log
            // claimed a fallback existed.
            if !hasHotplug { scheduleRetry() }
            return
        }

        // Not `for … where`: `openAndProbe` opens a port, writes to it, and
        // can block for `probeTimeout`. That does not belong in a filter.
        for endpoint in endpoints {
            if openAndProbe(endpoint) { return }
        }
        // Every candidate stayed silent. Common during bring-up (wrong port,
        // firmware not running) and after a reset that is still booting.
        scheduleRetry()
    }
```

Replace `scheduleRetry()`'s guard line `guard !isStopped, isEnabled else { return }` with:

```swift
        guard !isStopped, !source.isOff else { return }
```

- [ ] **Step 5: Fork `openAndProbe` on the endpoint**

Change the signature and the opening block. Replace:

```swift
    private func openAndProbe(_ candidate: Candidate) -> Bool {
        let handle = open(candidate.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            logger.notice("""
                MacroPad: open(\(candidate.path, privacy: .public)) failed: \
                \(String(cString: strerror(errno)), privacy: .public)
                """)
            return false
        }
        guard configureTTY(handle) else {
            close(handle)
            return false
        }
```

with:

```swift
    private func openAndProbe(_ endpoint: Endpoint) -> Bool {
        let handle: Int32
        switch endpoint {
        case .serial(let path, _):
            let opened = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard opened >= 0 else {
                // `EBUSY` here is the single most common bring-up state — a
                // `screen` session, a CircuitPython IDE, or (with the remote
                // transport) the bridge on this same machine holding the port
                // — and it is unactionable unless it is said out loud.
                logger.notice("""
                    MacroPad: open(\(path, privacy: .public)) failed: \
                    \(String(cString: strerror(errno)), privacy: .public)
                    """)
                return false
            }
            guard configureTTY(opened) else {
                close(opened)
                return false
            }
            handle = opened
        case .tcp:
            // Task 4 fills this in.
            return false
        }
```

Then in the same function, replace the two remaining `candidate.path` references with `endpoint.label`:
- the ping-write failure line: `logger.notice("MacroPad: ping write failed on \(endpoint.label, privacy: .public); skipping candidate")`
- the success call: `adopt(handle: handle, label: endpoint.label, pending: pending)`

And change `adopt`'s signature from `private func adopt(handle: Int32, path: String, pending: [MacroPadEvent])` to `private func adopt(handle: Int32, label: String, pending: [MacroPadEvent])`, with its log line becoming `logger.info("MacroPad connected on \(label, privacy: .public)")` and its emit becoming `emit(.connected(path: label))`.

- [ ] **Step 6: Point the controller at the new API**

In `Sources/Canopy/MacroPad/MacroPadController.swift`, replace both `device.setEnabled(...)` call sites (in `start()` and in `refresh()`) with `device.setSource(settings.macroPadSource)`.

- [ ] **Step 7: Build and verify local USB is unchanged**

```bash
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```

Expected: build succeeds, probe failure count 0.

Then, with the pad plugged into this Mac:

```bash
open build/Build/Products/Debug/Canopy.app
/usr/bin/log show --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "MacroPad"' --last 2m --style compact --info
```

Expected: a `MacroPad connected on /dev/cu.usbmodem…` line, and the pad lights. Unplug it: a disconnect line. Re-plug: it reconnects. Note `/usr/bin/log` with the absolute path — a bare `log` is eaten by the shell builtin.

- [ ] **Step 8: Commit**

```bash
jj describe -m "Fork MacroPadDevice discovery behind an Endpoint enum

- Add Endpoint with serial and tcp cases plus a log label
- Replace setEnabled with setSource and arm hot-plug only in local mode
- Route attemptConnect through rankedEndpoints; tcp returns false for now
- Rename adopt's path parameter to label so a TCP link logs its address

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
jj new
jj bookmark set macropad-remote-transport -r @-
```

---

### Task 4: `openTCP` and the socket options

**Files:**
- Modify: `Sources/Canopy/MacroPad/MacroPadDevice.swift`

**Interfaces:**
- Consumes: `MacroPadDevice.Endpoint`, `MacroPadRemoteEndpoint`.
- Produces: `private func openTCP(_ endpoint: MacroPadRemoteEndpoint) -> Int32?` and `private func connectSocket(_ info: addrinfo, label: String) -> Int32?`.

- [ ] **Step 1: Write the implementation**

In `Sources/Canopy/MacroPad/MacroPadDevice.swift`, replace the placeholder from Task 3:

```swift
        case .tcp:
            // Task 4 fills this in.
            return false
```

with:

```swift
        case .tcp(let remote):
            guard let opened = openTCP(remote) else { return false }
            handle = opened
```

Add these two functions immediately after `configureTTY`:

```swift
    /// Connects to a bridge over TCP and returns a probe-ready descriptor.
    ///
    /// The result is deliberately indistinguishable from a serial fd to
    /// everything downstream: the same `HELLO`/`PONG` probe adopts it, the
    /// same read source drives it, the same `writeBytes` feeds it. No
    /// `configureTTY` — there is no line discipline on a socket.
    ///
    /// Known bound: `getaddrinfo` blocks, and it runs on `queue`, which
    /// `stop()` waits on with `queue.sync`. A hung DNS lookup therefore
    /// lengthens Cmd+Q. Tailscale MagicDNS resolves locally and fails fast, so
    /// this is accepted; if it is ever observed the fix is to move resolution
    /// off the synchronous path, not to shorten a timeout.
    private func openTCP(_ endpoint: MacroPadRemoteEndpoint) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        // The port is already a number; without this the resolver would also
        // consult /etc/services for it.
        hints.ai_flags = AI_NUMERICSERV

        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(endpoint.host, String(endpoint.port), &hints, &list)
        guard status == 0, let head = list else {
            // Distinguishable from a refused connection, which is the whole
            // point: a typo'd host and a bridge that isn't running are
            // different problems with different fixes.
            logger.notice("""
                MacroPad: getaddrinfo(\(endpoint.displayLabel, privacy: .public)) failed: \
                \(String(cString: gai_strerror(status)), privacy: .public)
                """)
            return nil
        }
        defer { freeaddrinfo(head) }

        var node: UnsafeMutablePointer<addrinfo>? = head
        while let info = node {
            // A quit issued mid-connect would otherwise wait out the full
            // timeout for every address the resolver returned.
            if stopRequested.withLock({ $0 }) { return nil }
            if let handle = connectSocket(info.pointee, label: endpoint.displayLabel) { return handle }
            node = info.pointee.ai_next
        }
        return nil
    }

    /// One address, one attempt. Returns a connected non-blocking descriptor
    /// or nil, having closed anything it opened.
    private func connectSocket(_ info: addrinfo, label: String) -> Int32? {
        let handle = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard handle >= 0 else { return nil }

        var enable: Int32 = 1
        // NOT optional. A write to a hung-up tty returns EIO; a write to a
        // closed socket raises SIGPIPE, which has no handler here and takes
        // the whole app down. Stopping the bridge would crash Canopy.
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size))
        // Commands are ~10 bytes. Nagle would hold a colour change behind the
        // previous ACK.
        setsockopt(handle, IPPROTO_TCP, TCP_NODELAY, &enable, socklen_t(MemoryLayout<Int32>.size))
        // Closing the bridge Mac's lid leaves the connection half-open, and
        // writes keep succeeding into the send buffer — so neither the read
        // side nor the controller's watchdog ping can notice. 15s idle, 15s
        // between probes, 3 probes: ~45s, the same budget SSH remote uses
        // (ServerAliveInterval=15, ServerAliveCountMax=3).
        setsockopt(handle, SOL_SOCKET, SO_KEEPALIVE, &enable, socklen_t(MemoryLayout<Int32>.size))
        var idle: Int32 = 15
        setsockopt(handle, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
        var interval: Int32 = 15
        setsockopt(handle, IPPROTO_TCP, TCP_KEEPINTVL, &interval, socklen_t(MemoryLayout<Int32>.size))
        var probes: Int32 = 3
        setsockopt(handle, IPPROTO_TCP, TCP_KEEPCNT, &probes, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking for the same reason the serial path opens O_NONBLOCK:
        // it is what lets `writeBytes`'s EAGAIN loop and the read source work
        // unchanged on this descriptor.
        let flags = fcntl(handle, F_GETFL, 0)
        guard flags >= 0, fcntl(handle, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            close(handle)
            return nil
        }

        if connect(handle, info.ai_addr, info.ai_addrlen) == 0 { return handle }
        guard errno == EINPROGRESS else {
            logger.notice("""
                MacroPad: connect(\(label, privacy: .public)) failed: \
                \(String(cString: strerror(errno)), privacy: .public)
                """)
            close(handle)
            return nil
        }

        let deadline = Date().addingTimeInterval(Self.probeTimeout)
        while Date() < deadline {
            if stopRequested.withLock({ $0 }) { break }
            var poller = pollfd(fd: handle, events: Int16(POLLOUT), revents: 0)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let ready = poll(&poller, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }

            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(handle, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { break }
            if socketError == 0 { return handle }
            logger.notice("""
                MacroPad: connect(\(label, privacy: .public)) failed: \
                \(String(cString: strerror(socketError)), privacy: .public)
                """)
            close(handle)
            return nil
        }

        logger.notice("MacroPad: connect(\(label, privacy: .public)) timed out")
        close(handle)
        return nil
    }
```

- [ ] **Step 2: Build**

```bash
./scripts/build_debug_stable.sh
```

Expected: succeeds. If `SO_NOSIGPIPE`, `TCP_KEEPALIVE`, `TCP_KEEPINTVL` or `TCP_KEEPCNT` are not in scope, add `import Darwin` at the top of the file (`Foundation` normally re-exports them).

- [ ] **Step 3: Verify against a stand-in bridge**

There is no bridge script yet, so fake one with `socat` against the real pad. In one terminal:

```bash
DEV=$(ls /dev/cu.usbmodem* | tail -1)
socat TCP-LISTEN:8765,bind=127.0.0.1,reuseaddr FILE:$DEV,raw,b115200,nonblock
```

Then point the Debug build at it. The Debug build has its own defaults domain:

```bash
/usr/libexec/PlistBuddy -c "Print" ~/Library/Application\ Support/Canopy/settings.json 2>/dev/null
```

Settings UI does not exist yet (Task 6), so set it by hand — edit `~/Library/Application Support/Canopy/settings.json` and set `"canopy.macroPadSource": "remote"` and `"canopy.macroPadRemoteHost": "127.0.0.1:8765"`, with Canopy not running. Make sure this Mac's *other* Canopy (the installed Release build) has the pad released, or `socat` gets `EBUSY`.

```bash
open build/Build/Products/Debug/Canopy.app
/usr/bin/log show --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "MacroPad"' --last 2m --style compact --info
```

Expected: `MacroPad connected on 127.0.0.1:8765`, and the pad lights with the current panes.

Then the crash test that matters: **Ctrl-C the `socat`** while the link is up. Expected: Canopy logs a disconnect and keeps running. If Canopy dies instead, `SO_NOSIGPIPE` is not taking effect.

- [ ] **Step 4: Commit**

```bash
jj describe -m "Connect the MacroPad over TCP

- Add openTCP/connectSocket with a non-blocking connect and SO_ERROR check
- Set SO_NOSIGPIPE so a closed bridge socket cannot kill the app
- Set TCP_NODELAY and a 15s/15s/3 keepalive budget matching SSH remote
- Walk every getaddrinfo result and honour stopRequested between attempts

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
jj new
jj bookmark set macropad-remote-transport -r @-
```

---

### Task 5: Controller — observe the source, clear sleep on switch

**Files:**
- Modify: `Sources/Canopy/MacroPad/MacroPadController.swift` (`refresh()` around line 456, `publishStatus()` at line 528, and the `lastEnabled` stored property)
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: `MacroPadSource`, `CanopySettings.macroPadSource`, `MacroPadDevice.setSource(_:)`.
- Produces: `static func clearsSleep(movingTo source: MacroPadSource) -> Bool` on `MacroPadController`.

- [ ] **Step 1: Write the failing assertion**

Append to the probe block from Task 1, after the `macropad settings:` line:

```swift
        // Switching source is an explicit "I am using this pad now"; the chord
        // means "go dark". The newer, more specific verb wins — otherwise
        // every transition costs a swallowed keypress to wake the new pad.
        record("macropad sleep: switching to local clears sleep",
               MacroPadController.clearsSleep(movingTo: .local), "expected true")
        record("macropad sleep: switching to remote clears sleep",
               MacroPadController.clearsSleep(movingTo: .remote(MacroPadRemoteEndpoint(host: "mbp", port: 8765))),
               "expected true")
        // Off disconnects, and the firmware blanks itself. Clearing the flag
        // there would silently un-sleep the pad you get back later.
        record("macropad sleep: switching to off does not clear sleep",
               !MacroPadController.clearsSleep(movingTo: .off), "expected false")

```

- [ ] **Step 2: Build and verify it fails**

```bash
./scripts/build_debug_stable.sh
```

Expected: FAIL with `type 'MacroPadController' has no member 'clearsSleep'`.

- [ ] **Step 3: Write the implementation**

In `Sources/Canopy/MacroPad/MacroPadController.swift`, add next to `effectiveBrightness`:

```swift
    /// Whether moving to `source` should clear manual sleep.
    ///
    /// Pure and static so the probe can reach it — `setAsleep` is private and
    /// needs a live controller. See the assertions for the reasoning.
    static func clearsSleep(movingTo source: MacroPadSource) -> Bool { !source.isOff }
```

Rename the stored property `private var lastEnabled: Bool?` (search for `lastEnabled`) to:

```swift
    private var lastSource: MacroPadSource?
```

In `refresh()`, replace:

```swift
        let enabled = settings.macroPadEnabled
```

with:

```swift
        let source = settings.macroPadSource
```

and replace the change-detection block:

```swift
        if lastEnabled != enabled {
            // A toggle Canopy performed will produce a `HELLO` that is not a
            // firmware reboot.
            if enabled { expectHostInitiatedHello() }
            lastEnabled = enabled
        }
        device.setEnabled(enabled)
```

with:

```swift
        if lastSource != source {
            // A switch Canopy performed will produce a `HELLO` that is not a
            // firmware reboot.
            if !source.isOff { expectHostInitiatedHello() }
            // Only on an actual change, and only once `lastSource` is
            // non-nil: at launch this runs before the user has touched
            // anything, and clearing there would discard a sleep the user set
            // before quitting.
            if lastSource != nil, Self.clearsSleep(movingTo: source) { setAsleep(false) }
            lastSource = source
        }
        device.setSource(source)
```

In `publishStatus()`, replace:

```swift
        guard settings.macroPadEnabled else {
```

with:

```swift
        guard !settings.macroPadSource.isOff else {
```

In `start()`, the `device.setSource(settings.macroPadSource)` line from Task 3 stays as-is.

- [ ] **Step 4: Build and run the probe**

```bash
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy
```

Expected: the three `macropad sleep:` assertions PASS, failure count 0.

- [ ] **Step 5: Verify sleep is preserved across a relaunch**

With the pad connected locally, hold the two outermost keys until the pad goes dark, then quit and relaunch Canopy. Expected: the pad comes back dark (the `lastSource != nil` guard is what protects this). Press any key: it lights.

- [ ] **Step 6: Commit**

```bash
jj describe -m "Drive the MacroPad controller from macroPadSource

- Observe the selector instead of the retired enabled boolean
- Clear manual sleep when the user switches to a live source
- Keep sleep across launch by only clearing on an observed change
- Add the probe-reachable clearsSleep rule

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
jj new
jj bookmark set macropad-remote-transport -r @-
```

---

### Task 6: Settings UI — picker and validated address field

**Files:**
- Modify: `Sources/Canopy/SettingsView.swift` (the MacroPad `Section` starting at line 65)

**Interfaces:**
- Consumes: `CanopySettings.macroPadSource`, `CanopySettings.macroPadRemoteHost`, `MacroPadRemoteEndpoint.parse`.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Write the implementation**

Replace the whole MacroPad `Section { … } footer: { … }` block with:

```swift
            Section {
                Picker("MacroPad", selection: Binding(
                    get: { settings.macroPadSource.rawValue },
                    set: { raw in
                        switch raw {
                        case "off":
                            settings.macroPadSource = .off
                        case "remote":
                            // Unreachable while the row is disabled, but the
                            // Picker's setter is not the place to trust that.
                            if let endpoint = MacroPadRemoteEndpoint.parse(settings.macroPadRemoteHost) {
                                settings.macroPadSource = .remote(endpoint)
                            }
                        default:
                            settings.macroPadSource = .local
                        }
                    }
                )) {
                    Text("Off").tag("off")
                    Text("Local USB").tag("local")
                    Text("Remote bridge").tag("remote")
                        .disabled(MacroPadRemoteEndpoint.parse(settings.macroPadRemoteHost) == nil)
                }

                LabeledContent("Bridge address") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $hostDraft, prompt: Text("mbp or mbp:8765"))
                            .textFieldStyle(.roundedBorder)
                            .focused($hostFieldFocused)
                            .onSubmit { commitHost() }
                            .onChange(of: hostFieldFocused) { _, focused in
                                // Committing per keystroke would try to
                                // connect to "m", then "mb", then "mbp",
                                // tearing down the link each time.
                                if !focused { commitHost() }
                            }
                        if let hostError {
                            Text(hostError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                LabeledContent("LED brightness") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { Double(settings.macroPadBrightness) },
                                              set: { settings.macroPadBrightness = Int($0.rounded()) }),
                               in: 0...100, step: 5)
                        Text("\(settings.macroPadBrightness)%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(settings.macroPadSource.isOff)
            } footer: {
                SettingsFooter(text: "Lights each pane's activity on the pad's keys, and switches panes when a key is pressed. Local USB connects automatically when the pad is plugged in; Remote bridge reaches a pad on another Mac running scripts/macropad-bridge.sh. A small indicator at the bottom of the sidebar shows the link state; Off hides it.")
            }
            .onAppear { hostDraft = settings.macroPadRemoteHost }
```

Add these three members to the same `View` struct (alongside its existing `@Bindable private var settings`):

```swift
    @State private var hostDraft: String = ""
    @State private var hostError: String?
    @FocusState private var hostFieldFocused: Bool

    /// Validates at the boundary so nothing downstream ever re-parses. An
    /// unparseable value is refused rather than stored — the settings file is
    /// the only other way in, and `CanopySettings.load` re-validates that.
    private func commitHost() {
        let trimmed = hostDraft.trimmingCharacters(in: .whitespaces)
        hostDraft = trimmed

        guard !trimmed.isEmpty else {
            hostError = nil
            settings.macroPadRemoteHost = ""
            // The selector cannot stay on a source with no address.
            if case .remote = settings.macroPadSource { settings.macroPadSource = .local }
            return
        }
        guard let endpoint = MacroPadRemoteEndpoint.parse(trimmed) else {
            hostError = "Use host or host:port, e.g. mbp:8765."
            return
        }
        hostError = nil
        settings.macroPadRemoteHost = trimmed
        // Re-resolve a live remote selection so an edited port takes effect
        // without a second trip through the Picker.
        if case .remote = settings.macroPadSource { settings.macroPadSource = .remote(endpoint) }
    }
```

- [ ] **Step 2: Build and verify by hand**

```bash
./scripts/build_debug_stable.sh
open build/Build/Products/Debug/Canopy.app
```

In Settings, verify:
1. With an empty address, "Remote bridge" is greyed out. **If it is selectable but inert instead**, `.disabled` is not taking effect for this Picker style — replace the row with a conditional one (`if MacroPadRemoteEndpoint.parse(settings.macroPadRemoteHost) != nil { Text("Remote bridge").tag("remote") }`). That is safe because the selection can never *be* `remote` with an unusable address: `CanopySettings.load` degrades that to `.off` and `commitHost` moves it to `.local`.
2. Typing `mbp:abc` and pressing Return shows the red hint and does not store.
3. Typing `127.0.0.1:8765` and pressing Return enables "Remote bridge".
4. Selecting "Remote bridge" with the stand-in `socat` from Task 4 running connects the pad within a second or two.
5. Selecting "Local USB" reconnects over USB; selecting "Off" darkens the pad and the sidebar indicator.

- [ ] **Step 3: Commit**

```bash
jj describe -m "Add the MacroPad source picker and bridge address field

- Replace the Enable toggle with an Off/Local USB/Remote bridge picker
- Validate the address on commit and refuse to store an unparseable one
- Disable the remote row until a usable address exists
- Re-resolve a live remote selection when the address is edited

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
jj new
jj bookmark set macropad-remote-transport -r @-
```

---

### Task 7: MacroPad menu

**Files:**
- Create: `Sources/Canopy/MacroPad/MacroPadCommands.swift`
- Modify: `Sources/Canopy/CanopyApp.swift` (inside `.commands { … }`, after the existing `CommandMenu("Panes")` block at line 113)

**Interfaces:**
- Consumes: `CanopySettings.macroPadSource`, `MacroPadRemoteEndpoint.parse`.
- Produces: `struct MacroPadCommands: View`.

- [ ] **Step 1: Write the implementation**

Create `Sources/Canopy/MacroPad/MacroPadCommands.swift`:

```swift
import SwiftUI

/// The one-click switch the whole remote transport is built around: the user
/// changes source where they are sitting, not where the pad is.
///
/// A `View` in its own file rather than inline in `CanopyApp` so `@Bindable`
/// can track `CanopySettings` — a `Commands` body is not a tracked scope, so
/// checkmarks written there would not update when the source changes from
/// Settings.
///
/// No key equivalents. Nothing here is urgent enough to spend shortcut space
/// that Panes and Sessions already crowd.
struct MacroPadCommands: View {
    @Bindable private var settings = CanopySettings.shared

    var body: some View {
        Button { settings.macroPadSource = .off } label: {
            Label("Off", systemImage: settings.macroPadSource.isOff ? "checkmark" : "")
        }
        Button { settings.macroPadSource = .local } label: {
            Label("Use Local", systemImage: isLocal ? "checkmark" : "")
        }
        Button { selectRemote() } label: {
            Label(remoteTitle, systemImage: isRemote ? "checkmark" : "")
        }
        .disabled(remoteEndpoint == nil)
    }

    private var remoteEndpoint: MacroPadRemoteEndpoint? {
        MacroPadRemoteEndpoint.parse(settings.macroPadRemoteHost)
    }

    private var isLocal: Bool { settings.macroPadSource == .local }

    private var isRemote: Bool {
        if case .remote = settings.macroPadSource { return true }
        return false
    }

    /// Names the host so the menu says which machine, not just "remote" —
    /// the whole point of the switch is knowing which pad you are about to
    /// drive. Falls back to a hint when no address is configured, because a
    /// disabled item with no explanation reads as a bug.
    private var remoteTitle: String {
        guard let remoteEndpoint else { return "Use Remote (set an address in Settings)" }
        return "Use \(remoteEndpoint.host)"
    }

    private func selectRemote() {
        guard let remoteEndpoint else { return }
        settings.macroPadSource = .remote(remoteEndpoint)
    }
}
```

In `Sources/Canopy/CanopyApp.swift`, add after the closing brace of the `CommandMenu("Panes")` block:

```swift
            CommandMenu("MacroPad") {
                MacroPadCommands()
            }
```

- [ ] **Step 2: Build and verify by hand**

```bash
./scripts/build_debug_stable.sh
open build/Build/Products/Debug/Canopy.app
```

Expected: a `MacroPad` menu with three items. The current source carries a checkmark. With no address configured, the third item is greyed out and reads `Use Remote (set an address in Settings)`. With `127.0.0.1:8765` configured it reads `Use 127.0.0.1` and is enabled. Changing the source in Settings updates the checkmark in the menu without a relaunch.

- [ ] **Step 3: Commit**

```bash
jj describe -m "Add a MacroPad menu for switching source

- Add MacroPadCommands with checkmarked Off/Local/Remote items
- Name the configured host in the remote item so the target is explicit
- Disable the remote item with a reason when no address is set

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
jj new
jj bookmark set macropad-remote-transport -r @-
```

---

### Task 8: The bridge script

**Files:**
- Create: `scripts/macropad-bridge.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks (it is a standalone shell script).
- Produces: a TCP listener on the Tailscale address, port 8765 by default, speaking the raw MacroPad line protocol.

- [ ] **Step 1: Write the script**

Create `scripts/macropad-bridge.sh`:

```bash
#!/bin/bash
# Bridge a locally-attached Canopy MacroPad onto TCP so a Canopy on another
# Mac can drive it (see MacroPadDevice's remote transport).
#
# Usage:
#   ./scripts/macropad-bridge.sh              run in the foreground
#   ./scripts/macropad-bridge.sh --install    install + start a launchd agent
#   ./scripts/macropad-bridge.sh --uninstall  stop + remove the agent
#
# The Canopy running on THIS machine must have MacroPad set to Off, or it
# holds the serial port and socat gets EBUSY.
set -euo pipefail

PORT="${CANOPY_MACROPAD_BRIDGE_PORT:-8765}"
LABEL="sh.saqoo.canopy-macropad-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/canopy-macropad-bridge.log"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PRODUCT="Canopy MacroPad"

die() { echo "macropad-bridge: $*" >&2; exit 1; }

require_socat() {
  command -v socat >/dev/null 2>&1 || die "socat not found. Install it with: brew install socat"
}

# The Tailscale address, and only that. Binding 0.0.0.0 would expose a device
# that can switch panes to every network this Mac joins.
tailscale_ip() {
  local ts ip
  for ts in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale \
            /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    [ -x "$ts" ] || continue
    ip="$("$ts" ip -4 2>/dev/null | head -1)" || true
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  done
  if command -v tailscale >/dev/null 2>&1; then
    ip="$(tailscale ip -4 2>/dev/null | head -1)" || true
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  fi
  return 1
}

# Same ranking rule MacroPadDevice.rankedCandidates uses: match the product
# string (the one identifier this project controls, set by boot.py), then take
# the highest bInterfaceNumber, which on CircuitPython is the data port rather
# than the REPL console. Never hardcode /dev/cu.usbmodemNNNN — the suffix moves
# with the port and across reboots, which is also why this is re-run per
# connection rather than resolved once.
find_device() {
  # The script goes in -c, NOT `python3 -`: ioreg output is already on
  # stdin, and `-` would make python read its own source from there
  # instead. The product string is argv, never interpolated into the -c
  # source (an apostrophe in it would be a SyntaxError, which is what
  # issue #127 records).
  ioreg -a -r -c IOSerialBSDClient -l 2>/dev/null | python3 -c '
import plistlib, sys
product = sys.argv[1]
try:
    entries = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(1)
best = None
for entry in entries or []:
    if entry.get("USB Product Name") != product:
        continue
    path = entry.get("IOCalloutDevice")
    if not path:
        continue
    interface = entry.get("bInterfaceNumber", 0)
    if best is None or interface > best[0]:
        best = (interface, path)
if best is None:
    sys.exit(1)
print(best[1])
' "$PRODUCT"
}

run_bridge() {
  require_socat
  local ip
  ip="$(tailscale_ip)" || die "no Tailscale IPv4 address. Start Tailscale, or fix the bridge before exposing it more widely — this script will not bind 0.0.0.0."
  echo "macropad-bridge: listening on $ip:$PORT"

  while true; do
    local dev
    if ! dev="$(find_device)"; then
      # Deliberately do not listen at all with no pad present: Canopy then
      # gets ECONNREFUSED and retries cleanly, instead of seeing a connection
      # that dies before HELLO.
      sleep 2
      continue
    fi
    echo "macropad-bridge: $dev ready, waiting for a client"
    # No `fork`: the device path must be re-resolved after a re-plug, and a
    # forking socat holds its argv for the life of the process. socat opens
    # address 1 (accept) before address 2, so the serial port still stays free
    # until a client actually connects.
    if ! socat "TCP-LISTEN:$PORT,bind=$ip,reuseaddr" "FILE:$dev,raw,b115200,nonblock"; then
      # EBUSY is the common one: the local Canopy still has MacroPad on.
      echo "macropad-bridge: socat exited non-zero (is this Mac's Canopy holding the pad?)"
      sleep 2
    fi
  done
}

install_agent() {
  require_socat
  tailscale_ip >/dev/null || die "no Tailscale IPv4 address; refusing to install an agent that cannot bind."
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST_EOF
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$PLIST"
  echo "macropad-bridge: installed. Logs: $LOG"
}

uninstall_agent() {
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "macropad-bridge: uninstalled."
}

case "${1:-}" in
  --install)   install_agent ;;
  --uninstall) uninstall_agent ;;
  "")          run_bridge ;;
  *)           die "unknown argument: $1" ;;
esac
```

- [ ] **Step 2: Make it executable and check device discovery**

```bash
chmod +x scripts/macropad-bridge.sh
ioreg -a -r -c IOSerialBSDClient -l | python3 -c 'import plistlib,sys; [print(e.get("USB Product Name"), e.get("bInterfaceNumber"), e.get("IOCalloutDevice")) for e in plistlib.loads(sys.stdin.buffer.read()) or []]'
```

Expected: two rows for `Canopy MacroPad`, with different `bInterfaceNumber` values. The script must pick the higher one.

- [ ] **Step 3: Run it in the foreground**

With this Mac's Canopy set to `Off`:

```bash
./scripts/macropad-bridge.sh
```

Expected: `listening on 100.x.y.z:8765` then `… ready, waiting for a client`.

Verify the "serial stays free until a client connects" claim — the one thing in the spec taken on reasoning rather than measurement. In another terminal, while the bridge is waiting:

```bash
lsof /dev/cu.usbmodem* 2>/dev/null || echo "no holder — the port is free"
```

Expected: no holder. If `socat` already appears here, the claim is wrong and the script must move to an accept-then-exec shape; record the finding before changing anything.

- [ ] **Step 4: Install and verify the agent**

```bash
./scripts/macropad-bridge.sh --install
launchctl print "gui/$UID/sh.saqoo.canopy-macropad-bridge" | head -20
tail -5 ~/Library/Logs/canopy-macropad-bridge.log
```

Expected: the agent is loaded and the log shows the listening line.

- [ ] **Step 5: Commit**

```bash
jj describe -m "Add the MacroPad TCP bridge script

- Resolve the data port by USB product string and highest interface number
- Bind only the Tailscale address and refuse to fall back to 0.0.0.0
- Re-resolve the device per connection instead of forking socat
- Add --install/--uninstall for a KeepAlive launchd agent

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
jj new
jj bookmark set macropad-remote-transport -r @-
```

---

### Task 9: Loopback verification, CI floor, and documentation

**Files:**
- Modify: `.github/workflows/ci.yml` (`EXPECTED_ASSERTIONS`, line 442)
- Modify: `CLAUDE.md` (the MacroPad architecture bullets and the `MacroPad/` file list)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Run the full loopback end-to-end**

One machine, no Studio needed. Bridge running from Task 8, Debug Canopy pointed at `127.0.0.1:8765`… except the bridge binds the Tailscale address, so use this Mac's own Tailscale IP as the address in Settings.

Walk all five:

1. **Connect.** Set the address, pick `Remote bridge`. Expected: `MacroPad connected on <ts-ip>:8765` in the log and the pad lights with the current panes.
2. **`SO_NOSIGPIPE`.** Kill the bridge's `socat` child while the link is up (`pkill -f 'TCP-LISTEN:8765'` — verify the PID with `ps -p <pid> -o pid,command=` first). Expected: Canopy logs a disconnect and keeps running.
3. **Reconnect.** Let the bridge's loop come back. Expected: Canopy reconnects within its 8 s backoff cap and re-pushes every colour.
4. **Device path re-resolution.** Unplug the pad, wait five seconds, plug it back in. Expected: the bridge re-resolves and Canopy reconnects, even if `/dev/cu.usbmodemNNNN` changed.
5. **Sleep clears on switch.** Sleep the pad with the chord, then switch source via the MacroPad menu. Expected: the pad arrives lit, with no keypress needed.

```bash
/usr/bin/log show --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "MacroPad"' --last 10m --style compact --info
```

Filter by `Canopy[<pid>` if the installed Release build is also running — `process == "Canopy"` matches both.

- [ ] **Step 2: Measure the assertion count and raise the CI floor**

```bash
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | tail -3
```

Read the `--- N passed` line and set `EXPECTED_ASSERTIONS` in `.github/workflows/ci.yml` (line 442) to exactly `N`. It is 551 before this branch; the tasks above add 31 (27 in Task 1, 1 in Task 2, 3 in Task 5) — Task 1 measured 578, which is exactly 551 + 27. Do not guess the number — use the measured one, because CI builds the merge ref and main may have moved.

- [ ] **Step 3: Update CLAUDE.md**

In the `MacroPad/` file list, add after the `MacroPadProtocol.swift` bullet:

```markdown
- `MacroPad/MacroPadRemoteEndpoint.swift` — `MacroPadRemoteEndpoint` (bridge address, parsed once at the settings boundary) and `MacroPadSource` (`off` / `local` / `remote`), which **replaced** `CanopySettings.macroPadEnabled`. Two decisions are load-bearing. A bare IPv6 literal is **rejected** rather than read as `host:port` — either reading silently dials somewhere the user did not ask for. And a `remote` selector whose address is unusable degrades to `.off`, never to `.local`: the settings file is hand-editable, and quietly driving a different pad than the one configured is worse than driving none. An unrecognised *selector* is different and does fall through to the retired boolean, because it says nothing about intent
- `MacroPad/MacroPadCommands.swift` — the `MacroPad` menu (Off / Use Local / Use `<host>`). A `View` in its own file, not inline in `CanopyApp`, because a `Commands` body is not a tracked scope and checkmarks written there would not follow a source change made in Settings
```

In the `MacroPadDevice.swift` bullet, append:

```markdown
  Since the remote transport landed it opens **either** a `/dev/cu.*` or a TCP socket, forked on `Endpoint`; everything from `adopt` onward was already transport-agnostic and is shared verbatim, the `HELLO`/`PONG` probe included. `SO_NOSIGPIPE` is not optional on the socket path — a write to a hung-up tty returns `EIO`, but a write to a closed socket raises SIGPIPE and takes the app down, so stopping the bridge would crash Canopy. Keepalive is 15 s / 15 s / 3, the same ~45 s budget SSH remote uses, because a closed lid leaves the connection half-open and writes keep succeeding into the send buffer where neither the read side nor the watchdog ping can see them
```

Add to the MacroPad learnings section:

```markdown
- **One transport at a time is what keeps `canopy.macroPadAsleep` a single boolean.** Fan-out across a local pad and a remote one was designed and rejected: it saves exactly one click on one daily transition, costs untangling the per-device state (diff cache, version gate, reset-loop detector) from the global state (unread tracker) inside one 1000-line file, and makes a dark pad ambiguous between "asleep" and "disconnected, blanked by its own firmware" — doubling issue #147's surface. Single-active also gets the abandoned pad blanked for free, since the firmware blanks on host disconnect. The reasoning and the click-count table are in `docs/superpowers/specs/2026-08-26-macropad-remote-transport-design.md`
- **Switching source clears manual sleep; the sleep chord still exists and covers a different window.** Automatic blanking happens *after* the switch, which is made at the destination; the chord covers the hours *before* it, when the pad is still lit on a desk nobody is at. `MacroPadController.clearsSleep(movingTo:)` only fires on an observed change, so a sleep set before quitting survives the next launch
```

- [ ] **Step 4: Commit**

```bash
jj describe -m "Raise the probe floor and document the remote transport

- Set EXPECTED_ASSERTIONS to the measured count for the new assertions
- Document MacroPadRemoteEndpoint, MacroPadCommands and the socket options
- Record why fan-out was rejected and how sleep composes with switching

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
jj new
jj bookmark set macropad-remote-transport -r @-
```

- [ ] **Step 5: Verify on real hardware**

Studio over Tailscale to the MBP's bridge. Walk the four transitions from the spec's behaviour table:

1. Studio → `Use Local` at the office.
2. Leave; confirm pad #1 blanks itself once the Studio switches away.
3. From home through Parsec, Studio → `Use mbp`; confirm pad #2 lights with the Studio's panes.
4. Studio → `Off` and MBP → `Use Local`, in either order; confirm the MBP's Canopy picks pad #2 up within 8 s.
