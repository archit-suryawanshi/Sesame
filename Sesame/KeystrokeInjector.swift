//
//  KeystrokeInjector.swift
//  Sesame
//
//  Synthesizes keystrokes via CGEvent, posted at the HID tap so they reach the lock screen's secure text field.
//

import Foundation
import ApplicationServices
import CoreGraphics
// IsSecureEventInputEnabled.
import Carbon.HIToolbox

enum KeystrokeError: LocalizedError {
    case accessibilityNotGranted
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission required. Open System Settings → Privacy & Security → Accessibility and enable Sesame."
        case .eventCreationFailed:
            return "Couldn't create CGEvent for keystroke."
        }
    }
}

enum KeystrokeInjector {
    /// Returns true if the app has Accessibility permission (no prompt).
    nonisolated static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Triggers the system prompt to grant Accessibility (deep links to System Settings).
    @discardableResult
    nonisolated static func promptForAccessibility() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Types the UTF-8 bytes into whatever has keyboard focus, then presses Return. Takes `Data` rather than `String` so the
    /// caller can hold the plaintext as a zero-able buffer; the brief internal `String` decode is scoped to this call. Blocking.
    nonisolated static func typeAndReturn(_ passwordBytes: Data) throws {
        guard isAccessibilityTrusted() else {
            throw KeystrokeError.accessibilityNotGranted
        }
        guard let text = String(data: passwordBytes, encoding: .utf8) else {
            throw KeystrokeError.eventCreationFailed
        }

        // `CGEvent.post` returns nothing and cannot report being dropped, so these two facts are the
        // only way to tell the two remaining failures apart when the password is typed and the Mac
        // stays locked. Secure Event Input is the system-wide switch that makes the OS discard
        // synthetic keystrokes; if it is on at the lock screen, no user-space app can type there and
        // the approach itself is dead rather than misconfigured.
        //
        // Deliberately not logging the password's length or any part of its content.
        UnlockLog.event(
            "about to type: secure event input is \(IsSecureEventInputEnabled() ? "ON, synthetic keystrokes are discarded by the OS" : "off"), "
            + "stored password is \(passwordBytes.isEmpty ? "EMPTY" : "non-empty")"
        )
        let source = CGEventSource(stateID: .hidSystemState)
        wakeLockScreenField(source: source)
        for char in text {
            try postUnicode(String(char), source: source)
        }
        // Lets the field settle on the last character before submitting; a Return that races the
        // final keystroke submits a password one character short, which reads as a wrong password.
        Thread.sleep(forTimeInterval: 0.15)
        try postReturn(source: source)
    }

    /// Presses and releases Shift, then waits for the lock screen to present its password field.
    ///
    /// The macOS lock screen does not always start with that field focused and accepting input: it
    /// can be showing the clock, and the first keystroke dismisses that rather than typing into
    /// anything. A password burst posted straight into it loses its leading characters, or all of
    /// them, and the Mac stays locked with nothing visibly rejected.
    ///
    /// Shift is used because it produces no character, so this is harmless when the field already
    /// had focus.
    private nonisolated static func wakeLockScreenField(source: CGEventSource?) {
        let shiftKey: CGKeyCode = 0x38
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: false) else { return }
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        keyUp.post(tap: .cghidEventTap)
        // Generous: the field animates in, and typing before it exists is the whole failure above.
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// Per-character Unicode injection — bypasses keyboard layout issues.
    private nonisolated static func postUnicode(_ unicode: String, source: CGEventSource?) throws {
        let utf16 = Array(unicode.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        utf16.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
            }
        }
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
    }

    /// Physical Return key (virtual key 0x24).
    private nonisolated static func postReturn(source: CGEventSource?) throws {
        let returnKey: CGKeyCode = 0x24
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        keyUp.post(tap: .cghidEventTap)
    }
}
