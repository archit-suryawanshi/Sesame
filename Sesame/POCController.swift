//
//  POCController.swift
//  Sesame
//
//  Orchestration for credential storage: wires SecureCredentialManager to
//  KeystrokeInjector and exposes session/password status for Settings.
//

import Foundation
import Observation

@Observable
@MainActor
final class POCController {
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var sessionError: String? = nil

    /// Bound to the setup SecureField. Cleared immediately after a successful save.
    var passwordInput: String = ""

    var statusMessage: String = "Idle"

    func refreshAccessibilityStatus() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    func refreshCredentialStatus() {
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
    }

    // MARK: - Session (Touch ID gate)

    /// Must succeed before `savePassword()` or `injectStoredPassword()` will do anything.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "Authenticate to set up or use Sesame")
            }.value
            isSessionUnlocked = true
        } catch {
            isSessionUnlocked = false
            sessionError = error.localizedDescription
        }
    }

    /// Prompts for Touch ID once at launch, so face unlock is armed without the user having to know
    /// it needs arming.
    ///
    /// The session key is held only in `SecureCredentialManager`'s memory and is unwrapped once per
    /// launch, so every start of the app — including the automatic one at login — begins with the
    /// session locked, and `FaceUnlockCoordinator.evaluateTrigger` silently declines to scan until
    /// something unlocks it. Upstream's menu bar item showed "Session Locked" and let you fix it
    /// there. With no menu bar item, nothing surfaced it at all: the Mac simply stopped face
    /// unlocking after every restart, with no visible reason and nowhere obvious to look.
    ///
    /// Prompting here is not a weakening of the gate. Touch ID is still required, still once per
    /// launch, and a cancelled prompt still leaves the session locked — it just asks at the moment
    /// the answer is needed rather than waiting to be found.
    func armSessionAtLaunch() async {
        guard SesameSettings.shared.isFaceUnlockEnabled else { return }
        guard SecureCredentialManager.hasStoredPassword() else { return }
        guard !SecureCredentialManager.isSessionUnlocked else { return }

        UnlockLog.event("session is locked at launch; asking for Touch ID to arm face unlock")
        await unlockSession()
        if isSessionUnlocked {
            UnlockLog.event("session armed, face unlock is live")
        } else {
            UnlockLog.failure("session not armed (\(sessionError ?? "cancelled")) — face unlock will not run until you authenticate in Settings > Password")
        }
    }

    func lockSession() {
        SecureCredentialManager.lockSession()
        isSessionUnlocked = false
    }

    // MARK: - Setup flow

    /// Encrypts and stores `passwordInput`. Requires the session to already
    /// be unlocked (Touch ID happens in `unlockSession()`, not here).
    func savePassword() async {
        guard !passwordInput.isEmpty else {
            statusMessage = "Enter a password first."
            return
        }
        let plaintext = passwordInput
        passwordInput = ""

        do {
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = plaintext.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            statusMessage = "Password saved and encrypted."
            hasStoredPassword = true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Injection

    /// Reads + decrypts + injects the stored password, zeroing the plaintext
    /// buffer before returning. When `requireAuthoritativeLock` is true (the
    /// auto-trigger path), refuses to inject unless the CGSession dictionary
    /// confirms the screen is actually locked.
    ///
    /// Returns whether the keystrokes were actually posted. Every refusal below used to return
    /// `Void` after writing to `statusMessage`, which at the lock screen is written to nobody: the
    /// caller then reported a successful unlock regardless, so a face could be recognized, the
    /// success animation could play, and the Mac would stay locked with nothing typed.
    @discardableResult
    func injectStoredPassword(requireAuthoritativeLock: Bool = false) async -> Bool {
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "Accessibility not granted — open System Settings and enable Sesame."
            UnlockLog.failure("inject refused: Accessibility permission not granted")
            return false
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Session locked — authenticate with Touch ID first."
            UnlockLog.failure("inject refused: Touch ID session is locked")
            return false
        }

        if requireAuthoritativeLock {
            guard LockMonitor.isScreenActuallyLocked() else {
                statusMessage = "Skipped: CGSession reports screen is not actually locked."
                UnlockLog.failure("inject refused: CGSession says the screen is not locked")
                return false
            }
        }

        statusMessage = "Injecting…"
        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try KeystrokeInjector.typeAndReturn(bytes)
            }.value
            statusMessage = "Injected stored password + Return at \(Date().formatted(date: .omitted, time: .standard))"
            UnlockLog.event("typed stored password and Return")
            return true
        } catch {
            statusMessage = "Injection failed: \(error.localizedDescription)"
            UnlockLog.failure("inject failed: \(error.localizedDescription)")
            return false
        }
    }
}
