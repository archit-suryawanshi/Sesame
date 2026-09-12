//
//  SesameSettings.swift
//  Sesame
//
//  Backed directly by `UserDefaults.standard` — each property's `didSet`
//  writes through immediately, so there's no explicit "save" step.
//

import Foundation
import Observation

/// How long the Touch-ID-unlocked session may sit idle before it re-locks.
enum AutoLockInterval: Int, CaseIterable, Identifiable {
    case oneDay = 1
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    var id: Int { rawValue }

    var title: String { rawValue == 1 ? "1 day" : "\(rawValue) days" }

    var duration: TimeInterval { TimeInterval(rawValue) * 24 * 60 * 60 }

    /// Position in `allCases`, used to drive the discrete 4-stop slider.
    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> AutoLockInterval {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .sevenDays
    }
}

/// How far the user wants to nudge the measured threshold. This is a bias on top of each
/// identity's own calibration rather than an absolute cutoff — upstream exposed raw cosine values
/// on a slider, which only works if you know what scale the model reports on.
enum MatchStrictness: String, CaseIterable, Identifiable {
    case lessStrict
    case standard
    case moreStrict

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lessStrict: return "Less strict"
        case .standard: return "Default"
        case .moreStrict: return "More strict"
        }
    }

    /// Added to the calibrated threshold. Deliberately small: calibration already measured where
    /// this face sits, so these are nudges for edge cases (poor light, glasses) rather than a way
    /// to paper over a bad enrollment.
    var thresholdOffset: Float {
        switch self {
        case .lessStrict: return -0.04
        case .standard: return 0
        case .moreStrict: return 0.05
        }
    }

    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }
}

/// Unlock success/failure animation style shown in the notch overlay.
enum UnlockAnimationStyle: String, CaseIterable, Identifiable {
    case none
    case minimal
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .original: return "Original"
        }
    }

    /// The styles the picker offers; `.none` is still a valid stored value but is now produced by the "Show animation" toggle, not a tile.
    static let selectableCases: [UnlockAnimationStyle] = [.minimal, .original]
}

/// What can prompt a scan.
///
/// Two states, not a free-for-all, because the two situations genuinely differ:
///
/// - **Lid opened.** An unambiguous "I am coming back to this machine". Worth scanning for on its
///   own, and the case where waiting to be asked would be irritating.
/// - **Locked with the lid open.** A manual lock, a sleep from the Apple menu, a display timeout.
///   The Mac may be sitting in front of someone who deliberately locked it, possibly with the owner
///   still in frame. A camera that starts hunting for a face every time here is both wrong and
///   unnerving, so this one waits to be asked, with right Shift.
enum UnlockTrigger: String, CaseIterable, Identifiable {
    /// Waking because the lid was opened. Scans automatically.
    case onLidOpen
    /// Right Shift at the lock screen. The lock screen's Secure Event Input blocks normal event
    /// taps, so this is read via IOKit HID instead (see `ManualTriggerKeyMonitor`).
    case onRightShift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onLidOpen: return "When the lid opens"
        case .onRightShift: return "On right Shift"
        }
    }

    var detail: String {
        switch self {
        case .onLidOpen: return "Scans as soon as you lift the lid."
        case .onRightShift: return "Any other lock waits until you press right Shift."
        }
    }

    var iconName: String {
        switch self {
        case .onLidOpen: return "macbook"
        case .onRightShift: return "shift"
        }
    }
}

@Observable
@MainActor
final class SesameSettings {
    static let shared = SesameSettings()

    private enum Key {
        static let isFaceUnlockEnabled = "Sesame.isFaceUnlockEnabled"
        static let matchThreshold = "Sesame.matchThreshold"
        static let matchStrictness = "Sesame.matchStrictness"
        static let livenessChecksEnabled = "Sesame.livenessChecksEnabled"
        static let livenessMode = "Sesame.livenessMode"
        static let minimumFaceWidth = "Sesame.minimumFaceWidth"
        static let unlockAnimationStyle = "Sesame.unlockAnimationStyle"
        static let showUnlockAnimation = "Sesame.showUnlockAnimation"
        /// Legacy bool key — read once during migration, then ignored.
        static let playUnlockAnimation = "Sesame.playUnlockAnimation"
        static let unlockTriggers = "Sesame.unlockTriggers"
        static let requiresAttention = "Sesame.requiresAttention"
        static let retryOnHover = "Sesame.retryOnHover"
        static let faceDetectionSeconds = "Sesame.faceDetectionSeconds"
        static let autoRetryOnce = "Sesame.autoRetryOnce"
        static let hapticFeedbackEnabled = "Sesame.hapticFeedbackEnabled"
        static let preferredDisplayID = "Sesame.preferredDisplayID"
        static let preferredDisplayName = "Sesame.preferredDisplayName"
        static let autoLockIntervalDays = "Sesame.autoLockIntervalDays"
        static let defaultCameraID = "Sesame.defaultCameraID"
        static let builtInDisplayCameraID = "Sesame.builtInDisplayCameraID"
        static let externalDisplayCameraID = "Sesame.externalDisplayCameraID"
        static let hasCompletedOnboarding = "Sesame.hasCompletedOnboarding"
        static let onboardingResumeStep = "Sesame.onboardingResumeStep"
        static let hasAcknowledgedSecurityNotice = "Sesame.hasAcknowledgedSecurityNotice"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Used when an identity has too few samples for `FaceMatchCalibration` to measure one.
    static let defaultMatchThreshold: Float = 0.42

    var isFaceUnlockEnabled: Bool {
        didSet { defaults.set(isFaceUnlockEnabled, forKey: Key.isFaceUnlockEnabled) }
    }
    /// Only used for identities with no measured calibration — see `FaceMatchCalibration`.
    var matchThreshold: Float {
        didSet { defaults.set(matchThreshold, forKey: Key.matchThreshold) }
    }
    var matchStrictness: MatchStrictness {
        didSet { defaults.set(matchStrictness.rawValue, forKey: Key.matchStrictness) }
    }
    /// Master switch for liveness checking. Off means face recognition
    /// alone decides an unlock — a photo of the enrolled user would pass.
    var livenessChecksEnabled: Bool {
        didSet { defaults.set(livenessChecksEnabled, forKey: Key.livenessChecksEnabled) }
    }
    /// Face ID's "Require Attention": your eyes have to be on the screen, not just your face
    /// pointed at it. On by default, because off is the weaker of the two and should be chosen.
    var requiresAttention: Bool {
        didSet { defaults.set(requiresAttention, forKey: Key.requiresAttention) }
    }
    /// Light (deny-only) vs Heavy (deny plus a required proof of life) —
    /// see `LivenessMode`.
    var livenessMode: LivenessMode {
        didSet { defaults.set(livenessMode.rawValue, forKey: Key.livenessMode) }
    }
    /// Mirrored into `FaceRecognitionPipeline.minimumProminentFaceWidth` on
    /// every change, since that's read from a background `nonisolated` context.
    var minimumFaceWidth: Float {
        didSet {
            defaults.set(minimumFaceWidth, forKey: Key.minimumFaceWidth)
            FaceRecognitionPipeline.minimumProminentFaceWidth = minimumFaceWidth
        }
    }
    /// The remembered choice (`.minimal`/`.original` only); `showUnlockAnimation`
    /// tracks on/off separately so toggling back on restores the prior pick.
    /// Read `effectiveUnlockAnimationStyle`, not this, to decide what to show.
    var unlockAnimationStyle: UnlockAnimationStyle {
        didSet { defaults.set(unlockAnimationStyle.rawValue, forKey: Key.unlockAnimationStyle) }
    }
    var showUnlockAnimation: Bool {
        didSet { defaults.set(showUnlockAnimation, forKey: Key.showUnlockAnimation) }
    }

    /// What the overlay should actually render — the pick, or `.none` when
    /// animations are switched off entirely.
    var effectiveUnlockAnimationStyle: UnlockAnimationStyle {
        showUnlockAnimation ? unlockAnimationStyle : .none
    }

    /// Which signals arm Face Unlock. Persisted as raw-value strings; the
    /// setter refuses to store an empty set (see `UnlockTrigger`).
    var unlockTriggers: Set<UnlockTrigger> {
        didSet {
            // Belt-and-braces behind the picker's own min-one rule. This
            // reassignment re-enters didSet once, then terminates since the
            // corrected value is never itself empty.
            if unlockTriggers.isEmpty {
                unlockTriggers = oldValue.isEmpty ? Set(UnlockTrigger.allCases) : oldValue
            }
            defaults.set(unlockTriggers.map(\.rawValue), forKey: Key.unlockTriggers)
        }
    }
    var retryOnHover: Bool {
        didSet { defaults.set(retryOnHover, forKey: Key.retryOnHover) }
    }
    /// How long each scan cycle looks for a face before giving up. Must stay
    /// equal to `FaceUnlockCoordinator.scanWindowDuration` and
    /// `NotchOverlayController.scanTimeoutDuration`.
    var faceDetectionSeconds: Int {
        didSet {
            // Only reassign when clamping actually changes the value —
            // unconditional reassignment would recurse infinitely, since the
            // slider only ever produces already-in-range values.
            let clamped = min(max(faceDetectionSeconds, Self.faceDetectionRange.lowerBound),
                               Self.faceDetectionRange.upperBound)
            guard clamped == faceDetectionSeconds else {
                faceDetectionSeconds = clamped
                return
            }
            defaults.set(faceDetectionSeconds, forKey: Key.faceDetectionSeconds)
        }
    }
    var autoRetryOnce: Bool {
        didSet { defaults.set(autoRetryOnce, forKey: Key.autoRetryOnce) }
    }
    /// Trackpad haptic on hovering the notch/pill and on a successful unlock —
    /// see `NotchOverlayView`'s hover handler and `.onChange(of: controller.phase)`.
    var hapticFeedbackEnabled: Bool {
        didSet { defaults.set(hapticFeedbackEnabled, forKey: Key.hapticFeedbackEnabled) }
    }

    static let faceDetectionRange = 3...10

    /// The window the scan loop and the notch overlay must both use. They are driven from one place
    /// because they used to read `faceDetectionSeconds` separately: the overlay collapsing first ends
    /// the scan early, since `observeScanWindow` bails as soon as the overlay leaves `.scanning`.
    var effectiveScanSeconds: Int {
        guard livenessChecksEnabled else { return faceDetectionSeconds }
        return max(faceDetectionSeconds, livenessMode.minimumScanSeconds)
    }

    /// Which display Face Unlock shows on. `nil` means `NotchGeometry.preferredScreen()`'s
    /// default, re-evaluated live; a pinned display has deliberately no
    /// fallback if disconnected (see `FaceUnlockCoordinator.evaluateTrigger()`).
    var preferredDisplayID: String? {
        didSet { defaults.set(preferredDisplayID, forKey: Key.preferredDisplayID) }
    }
    /// The chosen display's name at pick time — cosmetic only, so the row can
    /// show something recognizable when that display is disconnected.
    var preferredDisplayName: String? {
        didSet { defaults.set(preferredDisplayName, forKey: Key.preferredDisplayName) }
    }
    /// Enforced by `SessionAutoLocker`, not here — this is only the stored
    /// preference.
    var autoLockInterval: AutoLockInterval {
        didSet { defaults.set(autoLockInterval.rawValue, forKey: Key.autoLockIntervalDays) }
    }
    /// Device `uniqueID`s, not device objects — devices can disconnect/
    /// reconnect between launches, but their unique ID is stable.
    var defaultCameraID: String? {
        didSet { defaults.set(defaultCameraID, forKey: Key.defaultCameraID) }
    }
    var builtInDisplayCameraID: String? {
        didSet { defaults.set(builtInDisplayCameraID, forKey: Key.builtInDisplayCameraID) }
    }
    var externalDisplayCameraID: String? {
        didSet { defaults.set(externalDisplayCameraID, forKey: Key.externalDisplayCameraID) }
    }

    /// Gates first-run onboarding — `AppDelegate` shows it instead of the
    /// Settings window until this is `true`. Set once, by `OnboardingController`
    /// on the true first-run flow reaching `.complete`.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }
    /// Where to resume first-run onboarding if the app quit mid-flow; `nil`
    /// starts fresh at `.intro`. Steps depending on in-memory capture state
    /// collapse to `.preSetup` before storing, since that state doesn't
    /// survive a relaunch — see `OnboardingStep.resumeTarget`.
    var onboardingResumeStep: OnboardingStep? {
        didSet { defaults.set(onboardingResumeStep?.rawValue, forKey: Key.onboardingResumeStep) }
    }
    /// Gates the one-time post-update notice for users who completed onboarding before the
    /// security-disclaimer step existed. Set alongside `hasCompletedOnboarding` for anyone
    /// finishing normal onboarding (which now includes that step), and separately by
    /// `OnboardingController.startPostUpdateNotice()` once the standalone catch-up notice is
    /// acknowledged. Defaults `false`, so an upgrading 1.0 install (where this key has never
    /// been written) correctly triggers the catch-up flow once.
    var hasAcknowledgedSecurityNotice: Bool {
        didSet { defaults.set(hasAcknowledgedSecurityNotice, forKey: Key.hasAcknowledgedSecurityNotice) }
    }

    private init() {
        // Enabled by default — onboarding already enrolled a face and set a
        // password specifically to use Face Unlock.
        isFaceUnlockEnabled = defaults.object(forKey: Key.isFaceUnlockEnabled) as? Bool ?? true
        // Fallback for identities with no calibration. Measured genuine scores run 0.61-0.79 and
        // impostors -0.06 to 0.10 (tools/embedding_bench.swift), so 0.42 sits in the middle of that
        // gap where both margins are wide, rather than at the top edge of it like upstream's 0.66.
        //
        // Any stored value at or above 0.56 is from that old scale — the whole new range tops out
        // below it — so it is discarded rather than migrated, or an existing install would carry the
        // broken cutoff forward forever.
        let storedThreshold = defaults.object(forKey: Key.matchThreshold) as? Float
        matchThreshold = (storedThreshold.map { $0 >= 0.56 ? Self.defaultMatchThreshold : $0 })
            ?? Self.defaultMatchThreshold
        matchStrictness = defaults.string(forKey: Key.matchStrictness)
            .flatMap(MatchStrictness.init(rawValue:)) ?? .standard
        livenessChecksEnabled = defaults.object(forKey: Key.livenessChecksEnabled) as? Bool ?? true
        requiresAttention = defaults.object(forKey: Key.requiresAttention) as? Bool ?? true
        // Light by default — Heavy requires a blink/pose/depth signal a
        // still, non-blinking user may never produce, while Light still
        // catches the main attack (a photo on a phone screen).
        livenessMode = defaults.string(forKey: Key.livenessMode)
            .flatMap(LivenessMode.init(rawValue:)) ?? .light
        // Matches `DetectionDistanceLevel.standard` — see RecognitionSettingsPage.swift.
        minimumFaceWidth = defaults.object(forKey: Key.minimumFaceWidth) as? Float ?? 0.21

        // Resolve the stored style first, `.none` included, then split it
        // into the pick + the on/off flag the UI now works in.
        let storedStyle: UnlockAnimationStyle
        if let raw = defaults.string(forKey: Key.unlockAnimationStyle),
           let style = UnlockAnimationStyle(rawValue: raw) {
            storedStyle = style
        } else if let legacy = defaults.object(forKey: Key.playUnlockAnimation) as? Bool {
            // Migrate the oldest on/off toggle: off → none, on → original.
            storedStyle = legacy ? .original : .none
        } else {
            storedStyle = .original
        }
        // A stored `.none` becomes "off, remembering .original" so
        // switching back on has something to restore.
        unlockAnimationStyle = storedStyle == .none ? .original : storedStyle
        showUnlockAnimation = defaults.object(forKey: Key.showUnlockAnimation) as? Bool
            ?? (storedStyle != .none)

        // Both on by default: together they cover every way a Mac gets locked, one automatically
        // and one on request. Old installs stored onWake/onLock/onSpace/onActivity, none of which
        // exist any more, so anything unrecognised falls through to the default pair.
        let storedTriggers = (defaults.array(forKey: Key.unlockTriggers) as? [String])?
            .compactMap(UnlockTrigger.init(rawValue:))
        unlockTriggers = storedTriggers.map(Set.init).flatMap { $0.isEmpty ? nil : $0 }
            ?? [.onLidOpen, .onRightShift]
        retryOnHover = defaults.object(forKey: Key.retryOnHover) as? Bool ?? true
        faceDetectionSeconds = (defaults.object(forKey: Key.faceDetectionSeconds) as? Int)
            .map { min(max($0, Self.faceDetectionRange.lowerBound), Self.faceDetectionRange.upperBound) }
            ?? 5
        autoRetryOnce = defaults.object(forKey: Key.autoRetryOnce) as? Bool ?? false
        hapticFeedbackEnabled = defaults.object(forKey: Key.hapticFeedbackEnabled) as? Bool ?? true
        preferredDisplayID = defaults.string(forKey: Key.preferredDisplayID)
        preferredDisplayName = defaults.string(forKey: Key.preferredDisplayName)

        // Defaults to 7 days — long enough not to nag daily users, short
        // enough not to leave an abandoned session live indefinitely.
        autoLockInterval = (defaults.object(forKey: Key.autoLockIntervalDays) as? Int)
            .flatMap(AutoLockInterval.init(rawValue:)) ?? .sevenDays
        defaultCameraID = defaults.string(forKey: Key.defaultCameraID)
        builtInDisplayCameraID = defaults.string(forKey: Key.builtInDisplayCameraID)
        externalDisplayCameraID = defaults.string(forKey: Key.externalDisplayCameraID)

        hasCompletedOnboarding = defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool ?? false
        onboardingResumeStep = defaults.string(forKey: Key.onboardingResumeStep)
            .flatMap(OnboardingStep.init(rawValue:))
        hasAcknowledgedSecurityNotice = defaults.object(forKey: Key.hasAcknowledgedSecurityNotice) as? Bool ?? false

        // Push into the nonisolated mirror immediately, or FaceRecognitionPipeline
        // would keep its own default until the slider is first touched.
        FaceRecognitionPipeline.minimumProminentFaceWidth = minimumFaceWidth
    }
}
