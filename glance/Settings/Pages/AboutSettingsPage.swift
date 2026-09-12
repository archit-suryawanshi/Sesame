//
//  AboutSettingsPage.swift
//  glance
//

import SwiftUI
import AppKit

struct AboutSettingsPage: View {
    let environment: AppEnvironment

    /// Secret-tap state for revealing the Debug/Face Lab sidebar section —
    /// see `AppEnvironment.isDebugSectionRevealed`. A pause over a second
    /// resets the count, so this requires 5 *consecutive* taps.
    @State private var iconTapCount = 0
    @State private var lastTapDate: Date?
    private let requiredTapCount = 5
    private let tapResetInterval: TimeInterval = 1.0

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 2) {
            // Plain imageset, not an app-icon catalog entry — those live in
            // a restricted namespace `Image(_:)` can't resolve.
            Image("appicon")
                .resizable()
                .frame(width: 80, height: 80)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .onTapGesture(perform: handleIconTap)

            Text("Sesame")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SettingsMetrics.textPrimary)

            Text(versionString)
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)

        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Reopening this window")
            SettingsGroup {
                SettingsRowContent(
                    title: "Keyboard shortcut",
                    info: "Works from anywhere, including over full-screen apps."
                ) {
                    Text(GlobalHotKey.settingsShortcutDescription)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                }

                SettingsGroupDivider()

                SettingsRowContent(
                    title: "Open Sesame again",
                    info: "From Spotlight, Finder or Launchpad. Launching it while it is already running brings this window back."
                ) { EmptyView() }

                SettingsGroupDivider()

                SettingsRowContent(
                    title: "URL scheme",
                    info: "For Shortcuts, Raycast or a shell alias."
                ) {
                    Text("sesame://settings")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                        .textSelection(.enabled)
                }
            }

            // Sesame deliberately has no menu bar item and no Dock tile, so this is the whole list.
            SettingsCaption(text: "Sesame stays out of the menu bar and the Dock. Quitting it turns face unlock off until you open it again, so leave it running and use one of the above when you need Settings.")
        }
    }

    private func handleIconTap() {
        let now = Date()
        if let lastTapDate, now.timeIntervalSince(lastTapDate) > tapResetInterval {
            iconTapCount = 0
        }
        lastTapDate = now
        iconTapCount += 1
        guard iconTapCount >= requiredTapCount else { return }
        iconTapCount = 0
        environment.isDebugSectionRevealed = true
    }
}
