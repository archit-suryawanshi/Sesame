//
//  GlobalHotKey.swift
//  Sesame
//
//  A system-wide keyboard shortcut, registered through Carbon's RegisterEventHotKey.
//
//  Deliberately not an NSEvent global monitor: that route requires Accessibility. This app does hold
//  that permission, but Settings is where you go to *fix* a permission problem, so the way in must
//  not itself depend on one. RegisterEventHotKey needs none.
//

import AppKit
import Carbon.HIToolbox

final class GlobalHotKey {
    /// Four-char code 'SSME', so the shared Carbon handler can ignore hot keys registered by
    /// anything else in the process (Sparkle, a framework) rather than swallowing them.
    fileprivate static let signature: OSType = 0x53534D45

    /// Touched only from the main thread: Carbon dispatches hot-key events on the main run loop, and
    /// every registration happens during app launch. `nonisolated(unsafe)` because the C callback
    /// below is a bare function pointer that cannot carry actor isolation.
    nonisolated(unsafe) fileprivate static var registry: [UInt32: GlobalHotKey] = [:]
    nonisolated(unsafe) private static var nextIdentifier: UInt32 = 1
    nonisolated(unsafe) private static var sharedHandler: EventHandlerRef?

    private let identifier: UInt32
    fileprivate let action: () -> Void
    private var reference: EventHotKeyRef?

    /// Returns nil when the combination is already claimed by another app, so the caller can say so
    /// rather than leave the user pressing a shortcut that will never fire.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.identifier = Self.nextIdentifier
        self.action = action
        Self.nextIdentifier += 1
        Self.installSharedHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        reference = ref
        Self.registry[identifier] = self
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Self.registry[identifier] = nil
    }

    private static func installSharedHandlerIfNeeded() {
        guard sharedHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyEventHandler, 1, &spec, nil, &sharedHandler)
    }
}

/// Free function rather than a closure literal: it is passed as a C function pointer, which cannot
/// capture anything, so the hot key is identified by the id Carbon hands back instead.
private func hotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
        return OSStatus(eventNotHandledErr)
    }
    guard let hotKey = GlobalHotKey.registry[hotKeyID.id] else {
        return OSStatus(eventNotHandledErr)
    }
    hotKey.action()
    return noErr
}

extension GlobalHotKey {
    /// Control-Option-Command-S. Chosen from the three-modifier space, which macOS itself leaves
    /// almost entirely free, so it is unlikely to collide with a system or app shortcut.
    static let settingsKeyCode = UInt32(kVK_ANSI_S)
    static let settingsModifiers = UInt32(controlKey | optionKey | cmdKey)
    static let settingsShortcutDescription = "⌃⌥⌘S"
}
