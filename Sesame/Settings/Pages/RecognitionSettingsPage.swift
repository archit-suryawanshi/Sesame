//
//  RecognitionSettingsPage.swift
//  Sesame
//

import SwiftUI

struct RecognitionSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable var pocController: POCController
    @Bindable private var settings = SesameSettings.shared

    @State private var isUnlocking = false
    @State private var sessionError: String?

    /// Read from `POCController`, not a local copy — same reasoning as
    /// `PasswordSettingsPage`.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(isSessionUnlocked ? 0 : 1)
                .allowsHitTesting(!isSessionUnlocked)
                .accessibilityHidden(isSessionUnlocked)

            unlockedState
                .opacity(isSessionUnlocked ? 1 : 0)
                .allowsHitTesting(isSessionUnlocked)
                .accessibilityHidden(!isSessionUnlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: isSessionUnlocked)
        .onAppear { pocController.refreshCredentialStatus() }
        // Password/name/enrollment flows run in the notch, outside this
        // window, so nothing else prompts a re-check once one closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    // MARK: - Locked

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Session locked",
            buttonTitle: isUnlocking ? "Authenticating…" : "Unlock session",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup {
                SettingsSteppedSliderRowContent(
                    title: "Match confidence",
                    valueLabel: coordinator.matchStrictness.title,
                    index: matchStrictnessIndex,
                    stopCount: MatchStrictness.allCases.count
                )

                SettingsGroupDivider()

                SettingsSteppedSliderRowContent(
                    title: "Detection distance",
                    valueLabel: detectionDistanceLevel.title,
                    index: detectionDistanceIndex,
                    stopCount: DetectionDistanceLevel.allCases.count
                )
            }

            calibrationCaption

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Attention")
                SettingsGroup {
                    SettingsRowContent(
                        title: "Require attention",
                        info: "Your eyes have to be on the screen, not just your face pointed at it. Looking away won't unlock."
                    ) {
                        SesameToggle(isOn: $settings.requiresAttention)
                    }
                }
                SettingsCaption(text: "macOS has no gaze API, so this is estimated from where each pupil sits in its eye. It reliably rejects a clear glance away; it can't tell exactly where on the screen you're looking. Turning it off means a face pointed at the camera is enough.")
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Liveness")
                SettingsGroup {
                    SettingsRowContent(
                        title: "Liveness detection",
                        info: "Checks that you're a live person, not a photo. May increase unlock time."
                    ) {
                        SesameToggle(isOn: $settings.livenessChecksEnabled)
                    }
                    SettingsGroupDivider()
                    LivenessModePicker(
                        selection: $settings.livenessMode,
                        isEnabled: settings.livenessChecksEnabled
                    )
                }
            }
        }
    }

    // MARK: - Match confidence

    private var matchStrictnessIndex: Binding<Double> {
        Binding(
            get: { coordinator.matchStrictness.sliderIndex },
            set: { coordinator.matchStrictness = MatchStrictness.from(sliderIndex: $0) }
        )
    }

    /// Shows what the slider is actually biasing. The cutoff is measured from each enrollment rather
    /// than typed in, so without this the number gating every unlock would be invisible.
    @ViewBuilder
    private var calibrationCaption: some View {
        let offset = coordinator.matchStrictness.thresholdOffset
        let calibrated = FaceEnrollmentStore.shared.activeIdentities.compactMap { identity -> (String, Float, Float)? in
            guard let calibration = identity.calibration else { return nil }
            let effective = min(max(calibration.threshold + offset, FaceMatchCalibration.floor), 0.65)
            return (identity.name, effective, calibration.worstGenuineScore)
        }

        VStack(alignment: .leading, spacing: 4) {
            if calibrated.isEmpty {
                SettingsCaption(text: "Using the default cutoff of \(format(SesameSettings.defaultMatchThreshold + offset)). Enroll at least four samples to measure one from your own face instead.")
            } else {
                ForEach(calibrated, id: \.0) { name, effective, worst in
                    SettingsCaption(text: "\(name): unlocks at \(format(effective)). The hardest pose in this enrollment scored \(format(worst)).")
                }
            }
        }
        .padding(.horizontal, SettingsMetrics.sectionTitleHorizontalInset)
    }

    private func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Detection distance

    private var detectionDistanceLevel: DetectionDistanceLevel {
        .nearest(to: settings.minimumFaceWidth)
    }

    private var detectionDistanceIndex: Binding<Double> {
        Binding(
            get: { detectionDistanceLevel.sliderIndex },
            set: { settings.minimumFaceWidth = DetectionDistanceLevel.from(sliderIndex: $0).minimumFaceWidth }
        )
    }

    // MARK: - Actions

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }
}

/// The three selectable points on the "Detection distance" slider.
private enum DetectionDistanceLevel: Int, CaseIterable {
    case close, standard, far

    var title: String {
        switch self {
        case .close: return "Close"
        case .standard: return "Default"
        case .far: return "Far"
        }
    }

    var minimumFaceWidth: Float {
        switch self {
        case .close: return 0.24
        case .standard: return 0.2
        case .far: return 0.17
        }
    }

    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    static func nearest(to width: Float) -> Self {
        allCases.min { abs($0.minimumFaceWidth - width) < abs($1.minimumFaceWidth - width) } ?? .standard
    }
}
