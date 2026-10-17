//
//  FaceUnlockCoordinator.swift
//  Sesame
//
//  Connects face recognition to the actual unlock path. Off by default; user opts in after validating accuracy in Face Lab.
//
//  Known limitation: LivenessAnalyzer defeats a photo but not a replayed video (real non-rigid motion looks live) — a successful spoof types the real macOS password.
//

import Foundation
import CoreGraphics
import Observation

@Observable
@MainActor
final class FaceUnlockCoordinator {
    private let pocController: POCController
    let lockMonitor = LockMonitor()
    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()

    /// Persisted via SesameSettings. Setting to false cancels any in-flight scan and disarms the overlay immediately.
    var isEnabled: Bool {
        didSet {
            SesameSettings.shared.isFaceUnlockEnabled = isEnabled
            if !isEnabled { disarmOverlay() }
        }
    }

    /// Kept independent from Face Lab's own `threshold` so tuning the debug tool never silently changes the real unlock gate.
    /// Only consulted for identities `FaceMatchCalibration` couldn't measure; otherwise each identity carries its own.
    var matchThreshold: Float {
        didSet { SesameSettings.shared.matchThreshold = matchThreshold }
    }
    var matchStrictness: MatchStrictness {
        didSet { SesameSettings.shared.matchStrictness = matchStrictness }
    }
    /// Shares its setting with NotchOverlayController's scanning timeout, so the background loop stops in step with the UI collapsing.
    /// Floored by `LivenessMode.minimumScanSeconds`: Heavy needs to actually observe a blink or a head
    /// turn, and the shortest selectable window is under the time either reliably takes.
    private var scanWindowDuration: TimeInterval {
        TimeInterval(SesameSettings.shared.effectiveScanSeconds)
    }
    /// Requires several consecutive below-threshold frames so a single bad-angle read doesn't trigger the failure animation.
    private let wrongFaceStreakThreshold = 6

    private(set) var statusMessage = "Idle"
    private(set) var lastOutcome: String?

    private var hasArmedForCurrentLock = false
    /// One-shot per lock session — an auto-retry that could itself auto-retry would loop the camera for the whole lock session.
    private var hasAutoRetriedForCurrentLock = false
    private var scanTask: Task<Void, Never>?
    /// Bumped by every `startScanCycle()`; a cycle bails once superseded (see `runScanCycle(generation:)`).
    private var scanGeneration = 0
    /// When the last scan cycle was armed — collapses a single wake into a single arm (see `.wake` branch of `evaluateTrigger`).
    private var lastArmedAt: ContinuousClock.Instant?
    /// One lid-open fires several wake signals within a few hundred ms of each other; anything in this window counts as the same wake.
    private let rearmDebounce: Duration = .seconds(2)
    /// Held separately from `scanTask` since it's scheduled from inside the scan task it follows — reusing `scanTask` would self-cancel it.
    private var autoRetryTask: Task<Void, Never>?
    /// Gap between headless auto-retries, just to keep the camera from restarting in a tight loop.
    private let headlessRetryDelay: Duration = .seconds(1)

    /// When off, no notch/pill presence at all — every overlay call in this file is conditioned on this rather than just skipping the video.
    private var showsUI: Bool { SesameSettings.shared.showUnlockAnimation }

    /// Whether the lid was shut at the moment the machine went to sleep. Compared against the lid
    /// state on waking to tell "I lifted the lid" from "something else woke this".
    private var lidWasClosedAtSleep = false

    /// Pending release of a pre-warmed camera, cancelled if a scan claims it first.
    private var prewarmReleaseTask: Task<Void, Never>?

    /// Reads right Shift on the lock screen for the manual trigger; only runs while locked + opted in.
    private let triggerKeyMonitor = ManualTriggerKeyMonitor()

    init(pocController: POCController) {
        self.pocController = pocController
        self.isEnabled = SesameSettings.shared.isFaceUnlockEnabled
        self.matchThreshold = SesameSettings.shared.matchThreshold
        self.matchStrictness = SesameSettings.shared.matchStrictness
        triggerKeyMonitor.onTriggerKeyDown = { [weak self] in self?.handleTriggerKeyPress() }
        observeLockAndWakeEvents()
    }

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeLockAndWakeEvents() {
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
            _ = lockMonitor.wakeEventCount
            _ = lockMonitor.isSleeping
            // Also tracked so screensaver-stop and display-only wakes still wake this up.
            _ = lockMonitor.eventCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeLockAndWakeEvents()
                // Kicked off before the settle delay, not after it: AVCaptureSession start-up
                // dominates time-to-unlock, and every millisecond of it that overlaps the delays
                // below is a millisecond the user does not wait. Safe to call speculatively — it is
                // idempotent, and the scan's own `camera.start()` finds the session already running.
                // Someone got in another way — Touch ID, the password typed by hand, an Apple Watch.
                // Handled before the settle delay rather than after it, because this is the one
                // transition where waiting is wrong: the Mac is already open and the camera is still
                // looking at its owner. The delay exists to let CGSession settle after a *wake*, and
                // an unlock needs no such benefit of the doubt.
                if self?.standDownIfUnlocked() == true { return }

                self?.prewarmCameraIfArmed()
                // Brief settle delay: CGSession's reported state can lag the true state right after wake.
                try? await Task.sleep(nanoseconds: 120_000_000)
                // Re-checked after the sleep: an unlock can land inside those 120ms.
                if self?.standDownIfUnlocked() == true { return }
                self?.evaluateTrigger()
            }
        }
    }

    /// Cuts the scan and releases the camera the moment the Mac is open, whoever opened it.
    ///
    /// Sesame is not the only way in. If a finger reaches the Touch ID sensor first, or the password
    /// is typed by hand, the unlock happens without Sesame being consulted — and a camera that keeps
    /// filming its owner after the machine is already unlocked is doing nothing useful and looks
    /// like it is doing something worse. Returns whether it stood down, so callers can stop.
    @discardableResult
    private func standDownIfUnlocked() -> Bool {
        guard !LockMonitor.isScreenActuallyLocked() else { return false }
        let wasLooking = scanTask != nil || camera.isRunning
        hasArmedForCurrentLock = false
        hasAutoRetriedForCurrentLock = false
        disarmOverlay()
        if wasLooking {
            UnlockLog.event("Mac was unlocked another way; camera released and scan stood down")
        }
        return true
    }

    /// Starts the capture session ahead of the scan, but only when this lock really is going to
    /// scan — the same gates `evaluateTrigger` applies, so the camera never lights up for a lock
    /// that was going to be declined anyway.
    private func prewarmCameraIfArmed() {
        prewarmReleaseTask?.cancel()
        prewarmReleaseTask = nil
        guard isEnabled,
              LockMonitor.isScreenActuallyLocked(),
              !lockMonitor.isSleeping,
              SecureCredentialManager.isSessionUnlocked,
              SecureCredentialManager.hasStoredPassword()
        else { return }
        Task { await camera.start() }
    }

    /// Logs why no scan is happening and releases anything `prewarmCameraIfArmed` may have started.
    /// Only for declines that come *after* the pre-warm gates have already passed; the earlier ones
    /// cannot have started the camera.
    private func declineAfterPrewarm(_ reason: String) {
        UnlockLog.blocked(reason)
        guard NotchOverlayController.shared.phase != .scanning, scanTask == nil else { return }

        // Not stopped immediately. Waking a Mac emits `screenLocked` and then `wake` a beat later,
        // and only the second of those arms a scan — so releasing the camera on the first threw away
        // the warm-up that had just been paid for and made the scan start from cold. Measured 1660ms
        // to recognition on that path against 670ms on an already-warm camera.
        prewarmReleaseTask?.cancel()
        prewarmReleaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            guard scanTask == nil, NotchOverlayController.shared.phase != .scanning else { return }
            camera.stop()
        }
    }

    private func evaluateTrigger() {
        // One line per evaluation, with the whole gate state, because every `return` below used to be
        // invisible. Without this, "it just didn't scan" is indistinguishable from "it never even
        // heard the screen lock", and those have completely different fixes.
        UnlockLog.event(
            "trigger: event=\(lockMonitor.lastEvent.map(String.init(describing:)) ?? "none") "
            + "locked=\(LockMonitor.isScreenActuallyLocked()) sleeping=\(lockMonitor.isSleeping) "
            + "enabled=\(isEnabled) armed=\(hasArmedForCurrentLock) "
            + "session=\(SecureCredentialManager.isSessionUnlocked ? "unlocked" : "LOCKED") "
            + "password=\(SecureCredentialManager.hasStoredPassword()) "
            + "accessibility=\(KeystrokeInjector.isAccessibilityTrusted()) "
            + "lid=\(LidMonitor.isLidClosed.map { $0 ? "shut" : "open" } ?? "n/a") "
            + "lidOpenWake=\(isLidOpenWake) wakeReason=\(LidMonitor.lastWakeReason ?? "unknown")"
        )

        guard LockMonitor.isScreenActuallyLocked() else {
            hasArmedForCurrentLock = false
            hasAutoRetriedForCurrentLock = false
            disarmOverlay()
            return
        }
        guard !lockMonitor.isSleeping else {
            // Captured here rather than on waking, when it is already too late to know.
            lidWasClosedAtSleep = LidMonitor.isLidClosed == true
            UnlockLog.blocked("still going to sleep (lid \(lidWasClosedAtSleep ? "shut" : "open")); waiting for the wake signal instead")
            return
        }

        // `.wake` (sleep, display sleep, or screensaver stopping) is an explicit "let me back in," so clear the one-shot guard.
        // `isWithinRecentArmBurst` keeps the several wake signals from one lid-open from each re-arming and fighting over the camera.
        if lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }

        // Runs before the hasArmedForCurrentLock guard — the space monitor's lifetime is tied to "locked + opted in," not to whether a scan already ran.
        updateSpaceMonitor()

        guard isEnabled else {
            UnlockLog.blocked("face unlock is switched off")
            return
        }
        guard !hasArmedForCurrentLock else {
            declineAfterPrewarm("already armed for this lock; waiting for the next wake or lock")
            return
        }
        guard let signal = requiredTrigger(for: lockMonitor.lastEvent) else {
            declineAfterPrewarm("event \(lockMonitor.lastEvent.map(String.init(describing:)) ?? "none") does not arm a scan")
            return
        }
        // A pinned display that isn't connected bails entirely rather than showing up elsewhere; "Main display" (nil) always resolves.
        guard NotchGeometry.preferredScreen() != nil else {
            declineAfterPrewarm("the display pinned in Settings is not connected")
            return
        }

        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Face unlock is on, but the session is locked — authenticate once from Password settings first."
            UnlockLog.blocked("Touch ID session is locked; open Settings > Password and authenticate once")
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "Face unlock is on, but no password is stored yet."
            UnlockLog.blocked("no password stored")
            return
        }

        // A deselected trigger means "don't auto-scan for this signal," not "do nothing" — the user can still opt in by hand.
        let shouldAutoScan = SesameSettings.shared.unlockTriggers.contains(signal)

        // Headless has nothing to arm/hover, so if this signal isn't selected there's nothing to do — and hasArmedForCurrentLock
        // must stay false, or a later selected signal could never fire (nothing else calls arm() to reset it).
        guard showsUI || shouldAutoScan else {
            declineAfterPrewarm("trigger \(signal.rawValue) is not selected, and animations are off so there is nothing to hover")
            return
        }

        hasArmedForCurrentLock = true
        lastArmedAt = .now
        Task { [weak self] in
            // arm() only shows a small closed notch silhouette, so this only needs a brief buffer
            // past the login window's entrance. Trimmed from 250ms: it sits directly on the
            // time-to-unlock path and the window is already up by the time a scan can see anything.
            try? await Task.sleep(nanoseconds: 60_000_000)
            await self?.arm(autoScan: shouldAutoScan)
        }
    }

    /// Whether the last arm was recent enough to be part of the same wake burst rather than a new one.
    private var isWithinRecentArmBurst: Bool {
        guard let lastArmedAt else { return false }
        return ContinuousClock.now - lastArmedAt < rearmDebounce
    }

    /// nil for signals that shouldn't arm anything — including a nil `lastEvent`, or the first observation would fire regardless of user selection.
    ///
    /// Only a lid-open wake arms a scan by itself. Every other lock, including a wake that was not
    /// the lid, is the manual case and waits for right Shift.
    private func requiredTrigger(for event: LockEventKind?) -> UnlockTrigger? {
        switch event {
        case .wake: return isLidOpenWake ? .onLidOpen : nil
        case .screenLocked, .screenUnlocked, .willSleep, nil: return nil
        }
    }

    /// True when this wake looks like the lid being lifted: it was shut when the Mac went to sleep
    /// and is open now. The firmware's wake reason is accepted as corroboration, since on some Macs
    /// the clamshell property has already been updated by the time `willSleep` is observed.
    private var isLidOpenWake: Bool {
        let lidIsOpenNow = LidMonitor.isLidClosed == false
        guard lidIsOpenNow else { return false }
        return lidWasClosedAtSleep || LidMonitor.wakeReasonNamesLid
    }

    private func disarmOverlay() {
        prewarmReleaseTask?.cancel()
        prewarmReleaseTask = nil
        scanTask?.cancel()
        scanTask = nil
        // Bumping makes any cycle still suspended at `await camera.start()` inert, rather than resuming and re-showing the overlay.
        scanGeneration &+= 1
        autoRetryTask?.cancel()
        autoRetryTask = nil
        camera.stop()
        NotchOverlayController.shared.disarm()
        // Covers isEnabled being switched off directly, keeping "disarmed" and "not listening for space" in lockstep.
        triggerKeyMonitor.stop()
    }

    /// Idempotent and safe to call on every lock/wake event. Deliberately does not prompt for Input Monitoring — a missing grant just means "don't listen."
    private func updateSpaceMonitor() {
        let shouldListen = isEnabled
            && SesameSettings.shared.unlockTriggers.contains(.onRightShift)
            && LockMonitor.isScreenActuallyLocked()
            && ManualTriggerKeyMonitor.hasInputMonitoringAccess()
        if shouldListen {
            triggerKeyMonitor.start()
        } else {
            triggerKeyMonitor.stop()
        }
    }

    /// Runs the same gate chain as `evaluateTrigger`, then starts a scan. Independent of `LockMonitor` events, so doesn't touch `hasArmedForCurrentLock`.
    private func handleTriggerKeyPress() {
        guard isEnabled,
              SesameSettings.shared.unlockTriggers.contains(.onRightShift),
              LockMonitor.isScreenActuallyLocked(),
              NotchGeometry.preferredScreen() != nil,
              SecureCredentialManager.isSessionUnlocked,
              SecureCredentialManager.hasStoredPassword()
        else { return }

        // Already looking — swallows auto-repeat/double-presses and lets "On wake"/"On lock" override "On space" with no special-casing.
        guard NotchOverlayController.shared.phase != .scanning else { return }

        guard showsUI else {
            // Headless: no overlay, just scan.
            startScanCycle()
            return
        }
        if NotchOverlayController.shared.isArmed {
            // Closed pill/notch already up — expand and scan, like a hover retry.
            startScanCycle()
        } else {
            Task { [weak self] in await self?.arm(autoScan: true) }
        }
    }

    /// Either way the overlay still arms — a deselected trigger only skips the automatic scan, leaving hover-to-start available.
    private func arm(autoScan: Bool) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }
        guard showsUI else {
            // Headless: evaluateTrigger() already guaranteed autoScan is true here, so this is just "start scanning."
            startScanCycle()
            return
        }
        NotchOverlayController.shared.arm { [weak self] in
            self?.startScanCycle()
        }
        if autoScan {
            startScanCycle()
        }
    }

    /// Called on arm, and again whenever the overlay hover-activates.
    private func startScanCycle() {
        prewarmReleaseTask?.cancel()
        prewarmReleaseTask = nil
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.runScanCycle(generation: generation)
        }
    }

    /// `generation` is what makes overlapping cycles safe: `Task.cancel()` is cooperative, so a superseded cycle still runs to the
    /// end of this function, and its global side effects (`camera.stop()` etc.) could otherwise land on the newer cycle instead
    /// of itself. This was a real bug — a superseded `camera.stop()` queued behind the newer cycle's `startRunning()` made the
    /// camera visibly switch on then die mid-warm-up, leaving the surviving cycle polling a dead session and never unlocking.
    private func runScanCycle(generation: Int) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }

        await camera.start()
        guard generation == scanGeneration else { return }

        if let error = camera.errorMessage {
            statusMessage = error
            UnlockLog.failure("camera unavailable: \(error)")
            camera.stop()
            return
        }
        UnlockLog.event("scan started, window \(Int(scanWindowDuration))s, liveness \(SesameSettings.shared.livenessChecksEnabled ? SesameSettings.shared.livenessMode.rawValue : "off")")

        // Concurrent with recognition, not after it. Bringing the lock screen's password field up
        // costs a beat of settling, and doing it here means that beat is spent while the camera is
        // still warming rather than added on once a face has already been recognized.
        Task.detached(priority: .userInitiated) {
            KeystrokeInjector.wakeLockScreenField()
        }

        let scanBegan = ContinuousClock.now
        let showsUI = self.showsUI
        if showsUI {
            NotchOverlayController.shared.beginScanning()
        }
        statusMessage = "Looking for your face…"

        let outcome = await observeScanWindow(
            deadline: Date().addingTimeInterval(scanWindowDuration),
            requireOverlayScanning: showsUI,
            scanBegan: scanBegan
        )

        // A newer cycle now owns the camera and overlay — leave both alone, and leave the auto-retry one-shot unspent.
        guard generation == scanGeneration else { return }

        camera.stop()

        switch outcome {
        case .matched:
            // The overlay already went to its success state the moment the face was accepted, inside
            // observeScanWindow. Nothing to show here.
            break
        case .notLookingAtScreen(let detail):
            statusMessage = "Look at the screen to unlock."
            UnlockLog.outcome("face matched but attention was never confirmed — \(detail)")
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .unlockDidNotTake:
            statusMessage = "Recognized you, but the Mac didn't unlock."
            UnlockLog.outcome("recognized but the unlock did not take, see the preceding line for why")
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "Recognized you, but the Mac didn't unlock — check permissions in Settings."
            }
            // Deliberately no auto-retry: a refused injection or a wrong stored password fails
            // identically every time, and retrying only types the wrong password at the lock screen
            // a second time.
        case .consistentlyWrongFace:
            statusMessage = "Face not recognized."
            UnlockLog.outcome("face seen but did not match — \(lastOutcome ?? "no score recorded")")
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "Face not recognized — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .spoofSuspected:
            statusMessage = "Couldn't confirm a live face."
            UnlockLog.outcome("rejected as a spoof — \(lastOutcome ?? "no reason recorded")")
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "Couldn't confirm a live face — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .supersededByOtherUnlock:
            // No failure animation and no retry. The Mac is open; there is nothing left to tell the
            // user and nothing left to try. Reporting this as "no face detected" would be a lie
            // about a scan that was simply overtaken.
            statusMessage = "Unlocked another way."
            UnlockLog.outcome("superseded — the Mac was unlocked by Touch ID, a typed password or a paired device")
        case .noResolution:
            statusMessage = "No face detected."
            UnlockLog.outcome("window expired without a decision — \(lastOutcome ?? "no face ever scored")")
            if showsUI {
                // No explicit collapse call: NotchOverlayController's own scanning timeout fires on the same mark and collapses itself.
                statusMessage = "No face detected — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.collapseAnimationDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        }
    }

    /// How long to give the login window to accept the typed password before calling it a failure.
    /// Generous: the lock screen animates out over roughly a second, and a slow disk can add more.
    private static let unlockConfirmationTimeout: TimeInterval = 4

    /// Polls CGSession until the screen reports unlocked, or the timeout expires.
    ///
    /// `CGEvent.post` returns nothing and cannot fail visibly, so without this the app has no way to
    /// tell a real unlock from keystrokes that went nowhere — which is exactly the state a user sees
    /// as "it scanned my face and then nothing happened."
    nonisolated static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    private static func waitForScreenToUnlock() async -> Bool {
        let deadline = Date().addingTimeInterval(unlockConfirmationTimeout)
        while Date() < deadline {
            if !LockMonitor.isScreenActuallyLocked() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// `delay` waits out whatever the overlay is still showing so the retry doesn't start underneath the previous outcome.
    private func scheduleAutoRetryIfEnabled(after delay: Duration) {
        guard SesameSettings.shared.autoRetryOnce, !hasAutoRetriedForCurrentLock else { return }
        hasAutoRetriedForCurrentLock = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Re-check rather than trust the delay: the user may have unlocked by password or retried manually while this waited.
            guard LockMonitor.isScreenActuallyLocked(), self.isEnabled else { return }
            if self.showsUI {
                guard NotchOverlayController.shared.phase == .closed else { return }
            }
            self.startScanCycle()
        }
    }

    private enum ScanOutcome {
        case matched
        /// The Mac was opened by something else mid-scan. Not a failure of any kind: nothing was
        /// rejected, the question simply stopped being asked.
        case supersededByOtherUnlock
        /// Face matched, but the eyes were never on the screen. Kept distinct from every other
        /// failure because the user did nothing wrong and the remedy is simply to look at the Mac.
        case notLookingAtScreen(String)
        /// Recognized and liveness-confirmed, but the Mac did not actually unlock. Kept distinct
        /// from `.consistentlyWrongFace` because the fix is completely different: nothing is wrong
        /// with the face, the credential or the permission is.
        case unlockDidNotTake
        case consistentlyWrongFace
        /// A deny cue (glare, device rectangle) fired — actively rejected as a spoof regardless of match. Same failure path as `.consistentlyWrongFace`.
        case spoofSuspected
        case noResolution
    }

    /// Recognition and liveness run concurrently and each latches when it succeeds, so unlock fires the moment the second lands;
    /// liveness never fails the scan by staying undecided, it just keeps scanning until `deadline`.
    /// `requireOverlayScanning` bails early once the overlay's own timeout collapses the UI — only applied when there is an
    /// overlay, since headlessly `phase` never becomes `.scanning` at all.
    private func observeScanWindow(deadline: Date, requireOverlayScanning: Bool, scanBegan: ContinuousClock.Instant = .now) async -> ScanOutcome {
        let livenessEnabled = SesameSettings.shared.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { SesameSettings.shared.livenessMode }
        var consecutiveWrongFaceFrames = 0

        /// Cleared the moment a detected face fails to match, so a latched match can't be handed to whoever steps in next.
        var readyMatch: ScoredIdentity?
        /// Turning liveness off in Settings makes this half permanently ready.
        var livenessConfirmed = !livenessEnabled
        let attentionRequired = SesameSettings.shared.requiresAttention
        /// The last few attention readings. A majority of them must be attentive, rather than an
        /// unbroken run: pupil landmarks jitter frame to frame, and demanding three consecutive
        /// clean reads meant one noisy frame threw away the two before it. Measured at 1529ms spent
        /// here after the face had already matched, against 45ms to recognise the face at all.
        ///
        /// Still not something a glance can pass. The window is short enough that it only ever holds
        /// the last sixth of a second, so a majority of it is genuinely "looking right now".
        var attentionWindow: [Bool] = []
        /// Counted only for the log, to tell "rejected a lot" from "saw very few frames".
        var attentionFramesSeen = 0
        /// When recognition first had a match in hand. The gap between this and the unlock is time
        /// spent waiting on liveness or attention rather than on recognising anyone, and the two are
        /// worth telling apart: one is the model's speed, the other is a setting's price.
        var matchReadyAt: ContinuousClock.Instant?
        /// Last reason attention was refused, reported if the window expires without it.
        var attentionRefusal: String?
        /// Last frame's selected face, passed back so `selectDominantFace` stays on the same person instead of flip-flopping.
        var lastFaceBoundingBox: CGRect?
        /// Cheap way to detect "no new camera frame yet" vs. "fresh frame" — without it a repeat frame would corrupt the liveness motion signal.
        var lastProcessedFrameID: UInt64?

        while Date() < deadline, !Task.isCancelled,
              !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning {
            guard LockMonitor.isScreenActuallyLocked() else { return .supersededByOtherUnlock }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                // 8ms, not 20ms. The camera delivers at ~33ms, so a 20ms poll could sit out most of
                // a frame interval before noticing a frame had arrived; this costs nothing and
                // removes that from the critical path.
                try? await Task.sleep(nanoseconds: 8_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                // No capture-quality pass: nothing on this path reads it, and it is measurable work.
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox, includeQuality: false) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard let (result, livenessFrame) = outcome else {
                consecutiveWrongFaceFrames = 0
                lastFaceBoundingBox = nil
                try? await Task.sleep(nanoseconds: 8_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            if attentionRequired {
                attentionFramesSeen += 1
                let reading = AttentionDetector.read(result.face)
                if let reading {
                    if !reading.isAttentive { attentionRefusal = reading.reason }
                } else {
                    // Pupils not resolvable. Not the same as looking away, and reported differently:
                    // "look at the screen" is useless advice when the real problem is the light.
                    attentionRefusal = "couldn't see your eyes clearly"
                }
                attentionWindow.append(reading?.isAttentive ?? false)
                if attentionWindow.count > AttentionDetector.windowFrames {
                    attentionWindow.removeFirst()
                }
            }

            // Fed regardless of match, so liveness stays a genuinely independent gate rather than one starved by recognition confidence.
            var confirmingCue: LivenessCue?
            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    // Overrides everything, including a match and any confirmation that already happened.
                    lastOutcome = snapshot.decision.denialReason
                    let measured = livenessFrame.glare.map {
                        String(format: "specular=%.4f cluster=%.3f cropPx=%.0f",
                               $0.specularFraction, $0.specularClusterRatio, $0.cropPixelWidth)
                    } ?? "no glare sample"
                    UnlockLog.failure("liveness denied: \(snapshot.decision.denialReason ?? "unspecified") [\(measured)]")
                    return .spoofSuspected
                case .confirmed(let cue):
                    livenessConfirmed = true
                    confirmingCue = cue
                case .pending:
                    break
                }
            }

            // `activeIdentities`, not `identities`: someone switched off on the Your Face page stays enrolled but must not unlock.
            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            let matched = pipeline.bestMatch(
                in: scored,
                fallbackThreshold: matchThreshold,
                offset: matchStrictness.thresholdOffset
            )

            if let best = scored.first {
                let gate = best.threshold(fallback: matchThreshold, offset: matchStrictness.thresholdOffset)
                lastOutcome = "\(best.identity.name) scored \(String(format: "%.3f", best.matchScore)) against \(String(format: "%.3f", gate)) (centroid \(String(format: "%.3f", best.centroidSimilarity)))"
                UnlockLog.frame("\(lastOutcome ?? "") liveness=\(livenessConfirmed ? "confirmed" : "pending") attention=\(attentionRequired ? "\(attentionWindow.filter { $0 }.count)/\(AttentionDetector.requiredFrames)\(attentionRefusal.map { " (\($0))" } ?? "")" : "off")")
            }

            if let matched {
                consecutiveWrongFaceFrames = 0
                if readyMatch == nil, matchReadyAt == nil { matchReadyAt = .now }
                readyMatch = matched
            } else {
                readyMatch = nil
                consecutiveWrongFaceFrames += 1
                if consecutiveWrongFaceFrames >= wrongFaceStreakThreshold {
                    return .consistentlyWrongFace
                }
            }

            let attentiveCount = attentionWindow.filter { $0 }.count
            let attentionConfirmed = !attentionRequired || attentiveCount >= AttentionDetector.requiredFrames
            if let readyMatch, livenessConfirmed, attentionConfirmed {
                statusMessage = "Recognized — unlocking…"
                let livenessNote = livenessEnabled
                    ? (confirmingCue.map { "live via \($0.title)" } ?? "liveness clear")
                    : "liveness off"
                let gate = readyMatch.threshold(fallback: matchThreshold, offset: matchStrictness.thresholdOffset)
                lastOutcome = "Matched \(readyMatch.identity.name) at \(String(format: "%.3f", readyMatch.matchScore)) against \(String(format: "%.3f", gate)), \(livenessNote)."
                let heldUp = matchReadyAt.map { Self.elapsedMilliseconds(since: $0) } ?? 0
                if attentionRequired, heldUp > 60 {
                    UnlockLog.event("attention: \(attentiveCount)/\(attentionWindow.count) of the last window attentive over \(attentionFramesSeen) frames\(attentionRefusal.map { "; last refusal: \($0)" } ?? "")")
                }
                UnlockLog.event(
                    "recognized \(readyMatch.identity.name) \(Self.elapsedMilliseconds(since: scanBegan))ms after the scan began"
                    + (heldUp > 60 ? ", of which \(heldUp)ms was spent waiting on liveness/attention after the face already matched" : "")
                    + "; typing"
                )

                // Shown here, at the moment the face is accepted, rather than after the unlock has
                // been confirmed. It used to run after `waitForScreenToUnlock`, so the Mac was
                // already on the desktop before "accepted" appeared — the confirmation arriving
                // after the thing it was confirming. The claim is also true at this point and not
                // before: the face *was* accepted. If the unlock then fails to take, the
                // `.unlockDidNotTake` branch corrects the overlay to its failure state.
                if requireOverlayScanning {
                    NotchOverlayController.shared.finish(success: true)
                }

                guard await pocController.injectStoredPassword(requireAuthoritativeLock: true) else {
                    // The reason is already logged by injectStoredPassword.
                    return .unlockDidNotTake
                }
                guard await Self.waitForScreenToUnlock() else {
                    // Keystrokes were posted but the Mac is still locked. CGEvent.post reports
                    // nothing back, so this is the only place the difference is observable: either
                    // the stored password is wrong and the lock screen rejected it, or the events
                    // never reached the login window at all.
                    UnlockLog.failure("typed the password but the screen is still locked after \(Int(Self.unlockConfirmationTimeout))s — either the stored password is wrong, or synthetic keystrokes are not reaching the lock screen")
                    return .unlockDidNotTake
                }
                return .matched
            }

            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        // A window that expired holding a match, with attention the only thing missing, is not "no
        // face detected" — the user was there the whole time and is owed the actual reason.
        if readyMatch != nil, attentionRequired, attentionWindow.filter({ $0 }).count < AttentionDetector.requiredFrames {
            let seen = attentionFramesSeen
            return .notLookingAtScreen("\(attentionRefusal ?? "eyes were not on the screen") (over \(seen) frames)")
        }
        return .noResolution
    }
}
