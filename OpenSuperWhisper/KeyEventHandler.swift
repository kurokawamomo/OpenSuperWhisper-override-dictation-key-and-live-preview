import AppKit
import Carbon
import Foundation

/// The single key `KeyEventHandler` watches, selected by
/// `AppPreferences.tapHoldTriggerKey`. Kept separate from `ModifierKey`:
/// `.f5Dictation` needs `keyDown`/`keyUp`, not `flagsChanged`, so folding it
/// into `ModifierKey`'s modifier-only concept would misrepresent it.
enum TapHoldTriggerKey: String, CaseIterable, Identifiable {
    case f5Dictation
    case rightOption
    case fn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .f5Dictation: return "F5 / Dictation Key"
        case .rightOption: return "Right ⌥ Option"
        case .fn: return "Fn"
        }
    }

    var isModifier: Bool { self != .f5Dictation }

    /// The set of raw keycodes this trigger matches. `.f5Dictation` accepts
    /// both 96 (F5's standard keycode) and 176 — observed on real hardware
    /// to replace 96 after the first successful keyDown/keyUp pair, once
    /// macOS stops treating the key as bound to its own Dictation action
    /// (exact mechanism unconfirmed; this is a pragmatic two-value match).
    var keyCodes: Set<UInt16> {
        switch self {
        case .f5Dictation: return [96, 176]
        case .rightOption: return [61]
        case .fn: return [63]
        }
    }

    /// Only meaningful for modifier keys; matched against `CGEvent.flags` on
    /// `.flagsChanged`. `.f5Dictation` arrives as `.keyDown`/`.keyUp` instead.
    var physicalEventFlag: CGEventFlags {
        switch self {
        case .rightOption: return CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))
        case .fn: return .maskSecondaryFn
        case .f5Dictation: return []
        }
    }
}

/// Distinguishes a short tap of the configured trigger key (runs
/// `SystemActionHandler.performTapAction()`, never starts a recording) from
/// a hold (drives the same record -> transcribe -> paste flow as
/// ShortcutManager's hold-to-record hotkeys). Runs as an independent
/// trigger alongside ShortcutManager's three existing modes;
/// RecordingSessionController's own exclusivity is what keeps two triggers
/// from double-starting a recording if a key is ever bound in both places.
///
/// `@MainActor` because the recording bridge below calls MainActor-isolated
/// APIs (`IndicatorWindowManager`, `IndicatorViewModel`) directly, the same
/// way `ShortcutManager` does. The CGEventTap callback itself runs outside
/// actor isolation, so the two entry points it calls (`handleEvent`,
/// `reenableTap`) are `nonisolated` and hop back to the main actor via
/// `Task { @MainActor in ... }` before touching the state machine.
@MainActor
final class KeyEventHandler {
    static let shared = KeyEventHandler()

    private enum State {
        case idle
        case pressing
        case holding
    }

    private var state: State = .idle
    private var holdWorkItem: DispatchWorkItem?
    private var isTriggerKeyPressed = false

    /// Guards against a keyUp immediately followed by a spurious keyDown
    /// (seen on real hardware while holding the trigger key: a crash report
    /// showed keyUp -> keyDown pairs firing a few ms apart during a single
    /// physical hold, re-triggering `beginRecording()` before the previous
    /// session's teardown had finished). A new keyDown within this window
    /// of the last keyUp is treated as noise, not a new press.
    private var lastKeyUpAt: DispatchTime?
    private static let minimumIntervalAfterKeyUp: TimeInterval = 0.15

    /// Written only from `reconfigure()` (main actor); read only from
    /// `handleEvent`/`reenableTap` (the tap's callback, non-isolated). Both
    /// sides run on the same underlying thread (the main runloop the tap is
    /// registered on), so actor isolation would only get in the
    /// non-isolated callback's way without buying any real safety.
    nonisolated(unsafe) private var triggerKey: TapHoldTriggerKey = .f5Dictation
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?

    private weak var activeVm: IndicatorViewModel?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indicatorWindowDidHide),
            name: .indicatorWindowDidHide,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeySettingsChanged,
            object: nil
        )
    }

    @objc private func indicatorWindowDidHide() {
        activeVm = nil
    }

    @objc private func hotkeySettingsChanged() {
        reconfigure()
    }

    func start() {
        reconfigure()
    }

    private func reconfigure() {
        stop()

        guard AppPreferences.shared.tapHoldModeEnabled else {
            print("KeyEventHandler: Tap-hold mode disabled")
            return
        }
        guard AXIsProcessTrusted() else {
            print("KeyEventHandler: Accessibility permission not granted, skipping tap creation")
            return
        }

        triggerKey = TapHoldTriggerKey(rawValue: AppPreferences.shared.tapHoldTriggerKey) ?? .f5Dictation

        let eventMask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let handler = Unmanaged<KeyEventHandler>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    handler.reenableTap()
                    return Unmanaged.passUnretained(event)
                }

                if handler.handleEvent(type: type, event: event) {
                    // Swallow the trigger key at the HID level, before macOS's
                    // own Dictation/Siri binding on that key can fire.
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("KeyEventHandler: Failed to create event tap. Check accessibility permissions.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("KeyEventHandler: Started monitoring \(triggerKey)")
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isTriggerKeyPressed = false
        holdWorkItem?.cancel()
        holdWorkItem = nil
        state = .idle
        lastKeyUpAt = nil
    }

    /// Runs on the CGEventTap's callback thread, outside actor isolation.
    nonisolated fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            print("KeyEventHandler: Re-enabled tap after timeout")
        }
    }

    /// Runs on the CGEventTap's callback thread, outside actor isolation;
    /// hops to the main actor before touching the state machine. Returns
    /// whether the event should be swallowed instead of passed through:
    /// only `.f5Dictation`'s own keyDown/keyUp is swallowed — that's the
    /// case where macOS has its own binding (Dictation/Siri) on the same
    /// physical key that would otherwise fire alongside ours. Modifier-only
    /// triggers (`.rightOption`/`.fn`) are never swallowed — `flagsChanged`
    /// carries no down/up pairing of its own to safely drop, and dropping
    /// it risks desyncing the system's modifier state.
    @discardableResult
    nonisolated fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard triggerKey.keyCodes.contains(keyCode) else { return false }

        print("KeyEventHandler [diag]: matched triggerKey=\(triggerKey) type=\(type.rawValue) keyCode=\(keyCode)")

        switch type {
        case .keyDown where !triggerKey.isModifier:
            Task { @MainActor [weak self] in self?.keyDown() }
            return true

        case .keyUp where !triggerKey.isModifier:
            Task { @MainActor [weak self] in self?.keyUp() }
            return true

        case .flagsChanged where triggerKey.isModifier:
            let isPressed = event.flags.contains(triggerKey.physicalEventFlag)
            Task { @MainActor [weak self] in self?.modifierChanged(isPressed: isPressed) }
            return false

        default:
            return false
        }
    }

    private func modifierChanged(isPressed: Bool) {
        guard isPressed != isTriggerKeyPressed else { return }
        isTriggerKeyPressed = isPressed
        if isPressed {
            keyDown()
        } else {
            keyUp()
        }
    }

    // MARK: - State machine

    private func keyDown() {
        print("KeyEventHandler[diag]: keyDown() state=\(state)")
        guard case .idle = state else { return }

        if let lastKeyUpAt {
            let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - lastKeyUpAt.uptimeNanoseconds) / 1_000_000_000
            guard elapsedSeconds >= Self.minimumIntervalAfterKeyUp else {
                print("KeyEventHandler[diag]: keyDown debounced, only \(elapsedSeconds)s since last keyUp")
                return
            }
        }

        state = .pressing
        let thresholdSeconds = AppPreferences.shared.tapHoldThresholdMs / 1000.0
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.promoteToHolding() }
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + thresholdSeconds, execute: workItem)
    }

    private func promoteToHolding() {
        print("KeyEventHandler[diag]: promoteToHolding() state=\(state)")
        guard case .pressing = state else { return }
        state = .holding
        beginRecording()
    }

    private func keyUp() {
        print("KeyEventHandler[diag]: keyUp() state=\(state)")
        lastKeyUpAt = .now()
        switch state {
        case .pressing:
            holdWorkItem?.cancel()
            holdWorkItem = nil
            state = .idle
            SystemActionHandler.shared.performTapAction()

        case .holding:
            state = .idle
            endRecording()

        case .idle:
            break
        }
    }

    // MARK: - Recording bridge (mirrors ShortcutManager's hold-to-record flow)

    private func beginRecording() {
        let session = RecordingSessionController.shared
        guard !session.hasSession, activeVm == nil else {
            print("KeyEventHandler[diag]: beginRecording skipped, hasSession=\(session.hasSession) activeVm!=nil=\(activeVm != nil)")
            return
        }

        print("KeyEventHandler[diag]: beginRecording -> prepare()+startRecording()")
        let vm = IndicatorWindowManager.shared.prepare()
        activeVm = vm
        vm.startRecording()

        let cursorPosition = FocusUtils.getCurrentCursorPosition()
        Task { @MainActor in
            let anchorPoint = await Self.resolveAnchorPoint(timeoutNanoseconds: 150_000_000)
            let point = FocusUtils.chooseIndicatorPoint(resolvedInputAnchor: anchorPoint, cursorPosition: cursorPosition)
            IndicatorWindowManager.shared.presentWindow(for: vm, nearPoint: point)
        }
    }

    private func endRecording() {
        guard activeVm != nil else { return }
        IndicatorWindowManager.shared.stopRecording()
    }

    private static func resolveAnchorPoint(timeoutNanoseconds: UInt64) async -> NSPoint? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSPoint?, Never>) in
            let gate = AnchorGate(continuation)
            Task.detached {
                let point = FocusUtils.getInputAnchorPoint()
                await gate.resume(point)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await gate.resume(nil)
            }
        }
    }

    private actor AnchorGate {
        private var continuation: CheckedContinuation<NSPoint?, Never>?

        init(_ continuation: CheckedContinuation<NSPoint?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: NSPoint?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
