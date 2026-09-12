//
//  SesameApp.swift
//  Sesame
//
//  Created by Jonathan Zhou on 2026-07-21.
//

import SwiftUI

@main
struct SesameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Only reliable way to reopen a `Window` scene once its `NSWindow` has fully closed.
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        settingsWindow
    }

    /// Suppressed so Settings doesn't appear on launch/restore. `openWindow` is captured here, not in `onAppear`, since the
    /// window may never have appeared before the menu bar needs to open it.
    private var settingsWindow: some Scene {
        let open = openWindow
        let delegate = appDelegate
        DispatchQueue.main.async {
            delegate.bindOpenWindowAction { open(id: "settings") }
        }
        return Window("Sesame Settings", id: "settings") {
            SettingsWindowView(environment: appDelegate.environment)
                .onAppear {
                    delegate.bindOpenWindowAction { open(id: "settings") }
                }
        }
        // Deliberately no `.windowResizability(.contentSize)`: it kept re-deriving the window size from the titlebar band,
        // growing the window whenever that band's height changed. Size is set once by WindowConfiguringView instead.
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owns the long-lived controllers so every Settings page and the menu bar's session row share the same instances instead of
    /// each spinning up its own camera/lock-monitor (see AppEnvironment.swift). Lives here rather than as `@State` because
    /// `@NSApplicationDelegateAdaptor` constructs this delegate before the scene body runs, so it's always safe to read.
    let environment = AppEnvironment()

    /// Kept alive for the app's lifetime — releasing it unregisters the shortcut.
    private var settingsHotKey: GlobalHotKey?
    /// Bridges SwiftUI's `openWindow(\.settings)` action in from `SesameApp.body`, since this plain `NSObject` has no
    /// `@Environment` of its own. Bound from the scene body (not `onAppear`) so it's ready before Settings has ever shown —
    /// `NSApp.windows` stops containing the window once fully closed, so only `openWindow(id:)` can reliably re-create it.
    var openSettingsWindowAction: (() -> Void)?

    /// Reassigned on every scene rebuild so the (cheap) action never goes stale.
    func bindOpenWindowAction(_ action: @escaping () -> Void) {
        openSettingsWindowAction = action
    }

    /// Guards `environment.updater.start()` against running twice — reachable from two call sites, and Sparkle doesn't promise
    /// starting an already-started `SPUUpdater` is a safe no-op.
    private var hasStartedUpdater = false

    /// Accessory before the Dock binds this launch to a persistent tile — starting `.regular` made the pinned icon bounce and
    /// get replaced by a Recents tile the moment the Dock icon was later hidden/shown.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No NSStatusItem. The app is deliberately invisible while it runs: nothing in the menu bar,
        // and `.accessory` keeps it out of the Dock too. Three ways back into Settings replace it,
        // none of which need a permanent slot in anyone's menu bar:
        //
        //   1. Open the app again (Spotlight, Finder, Launchpad). Handled in
        //      `applicationShouldHandleReopen`, which is what a second launch of a running app
        //      becomes.
        //   2. The global shortcut below.
        //   3. `open sesame://settings`, for Shortcuts, Raycast or a shell alias.
        registerSettingsHotKey()

        // SwiftUI can flip the app back to `.regular` while installing scenes even with `.suppressed`; re-assert accessory.
        NSApp.setActivationPolicy(.accessory)

        // `object: nil` deliberately — the Settings window may not exist yet (SwiftUI creates scene content lazily), and this
        // still matches it by identity in the handler below once it does close.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )

        // Deferred until onboarding is done — Sparkle's own "Check for updates automatically?" consent alert fires the moment
        // it starts on a fresh install, and starting unconditionally here used to pop it mid-onboarding.
        if SesameSettings.shared.hasCompletedOnboarding {
            if SesameSettings.shared.hasAcknowledgedSecurityNotice {
                startUpdaterIfNeeded()
                // Without this the Mac stops face unlocking after every restart: the Touch ID
                // session key lives only in memory, so a fresh launch always starts locked.
                Task { [environment] in await environment.pocController.armSessionAtLaunch() }
            } else {
                // Upgraded from a version before the notice existed — show it once, standalone.
                presentPostUpdateSecurityNotice()
            }
        } else {
            presentOnboardingGate()
        }
    }

    /// First-run gate: onboarding lives entirely in the notch, so this stays accessory. Called once at launch if onboarding
    /// isn't done, and again from `revealSettingsWindow()` if the user reaches Settings mid-flow. Closing any main window here
    /// is defense in depth against SwiftUI's `.suppressed` scene timing not being guaranteed.
    private func presentOnboardingGate() {
        for window in NSApp.windows where window.canBecomeMain {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
        OnboardingController.startFlow(
            resumingAt: SesameSettings.shared.onboardingResumeStep,
            onFirstRunComplete: { [weak self] in
                // First time Settings should appear, which also brings the Dock icon back.
                self?.revealSettingsWindow()
                self?.startUpdaterIfNeeded()
            }
        )
    }

    /// One-time catch-up for users who completed onboarding before the security-notice step
    /// existed — same accessory/window-closing treatment as `presentOnboardingGate()`, but
    /// resumes straight into the updater afterward instead of revealing Settings, since setup
    /// itself is already done.
    private func presentPostUpdateSecurityNotice() {
        for window in NSApp.windows where window.canBecomeMain {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
        // Reachable repeatedly — every gated menu action re-enters here while unacknowledged.
        // A fresh `startPostUpdateNotice()` would just replace the one already on screen.
        guard NotchOverlayController.shared.phase != .onboarding else { return }
        OnboardingController.startPostUpdateNotice { [weak self] in
            self?.startUpdaterIfNeeded()
        }
    }

    /// Reachable from launch (onboarding already done) or from first-run completion — `hasStartedUpdater` collapses both into "exactly once."
    private func startUpdaterIfNeeded() {
        guard !hasStartedUpdater else { return }
        hasStartedUpdater = true
        environment.updater.start()
    }

    /// Hides the Dock icon once no `canBecomeMain` window is left (`revealSettingsWindow()` brings it back) — excludes non-main
    /// windows like the lock-screen notch overlay, and backs off while Sparkle's update window is showing.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow.canBecomeMain else { return }
        guard !environment.updater.isPresentingUpdateUI else { return }
        let stillOpen = NSApp.windows.contains { $0 !== closingWindow && $0.canBecomeMain && $0.isVisible }
        guard !stillOpen else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Keeps the process alive after the window closes so it can still react to the screen locking (e.g. for face unlock).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Launching the app while it is already running lands here, and is now the main way back into
    /// Settings: with no menu bar item and no Dock tile, opening it from Spotlight or Finder is the
    /// gesture people reach for. Upstream returned `flag`, which did nothing at all when no window
    /// was open — correct when a menu bar item existed, a dead end once it doesn't.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    /// `sesame://settings`, so Shortcuts, Raycast or a shell alias can open it too.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "sesame" }) else { return }
        openSettingsWindow()
    }

    private func registerSettingsHotKey() {
        settingsHotKey = GlobalHotKey(
            keyCode: GlobalHotKey.settingsKeyCode,
            modifiers: GlobalHotKey.settingsModifiers
        ) { [weak self] in
            self?.openSettingsWindow()
        }
        if settingsHotKey == nil {
            // Another app already owns the combination. Not fatal, since reopening the app and the
            // URL scheme both still work, but it must not fail silently.
            UnlockLog.failure("could not register \(GlobalHotKey.settingsShortcutDescription) — another app owns it. Open the app again, or run: open sesame://settings")
        }
    }

    @objc private func openSettingsWindow() {
        revealSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// True whenever an updated user hasn't acknowledged the post-update security notice yet.
    /// Checked before anything that would otherwise let them into Settings.
    private var isBlockedByPostUpdateNotice: Bool {
        SesameSettings.shared.hasCompletedOnboarding && !SesameSettings.shared.hasAcknowledgedSecurityNotice
    }

    /// Restores the Dock icon before bringing the window forward — doing it after the window is already key can leave the icon
    /// out of sync. During onboarding this only ensures the notch flow is up; it doesn't open Settings or show a Dock icon.
    private func revealSettingsWindow() {
        if isBlockedByPostUpdateNotice {
            presentPostUpdateSecurityNotice()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard SesameSettings.shared.hasCompletedOnboarding else {
            // Re-present rather than restart: a fresh startFlow() would throw away the in-session step already navigated to,
            // since it only knows the last step written to disk.
            if NotchOverlayController.shared.phase != .onboarding {
                presentOnboardingGate()
            }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)
        if let openSettingsWindowAction {
            openSettingsWindowAction()
        } else {
            // `body` hasn't run yet somehow — falls back to a direct walk, which only works if a window instance still exists.
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        // Coming from `.accessory` there's no user gesture to activate the app, so without this Settings appears inactive and
        // won't take focus until the user Cmd-Tabs away and back.
        makeSettingsKeyAndActive()
    }

    /// Two runloop hops: `openWindow(id:)` hasn't created the `NSWindow` on this turn, and `WindowConfiguringView` configures it
    /// on the next — waiting one extra cycle orders front after the window actually exists.
    private func makeSettingsKeyAndActive() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.orderSettingsFront()
            DispatchQueue.main.async {
                self?.orderSettingsFront()
            }
        }
    }

    private func orderSettingsFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
