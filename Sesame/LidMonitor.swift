//
//  LidMonitor.swift
//  Sesame
//
//  Reads the clamshell (lid) state from IOPMrootDomain, so a wake can be classified as "the lid was
//  just opened" rather than "something else woke the Mac".
//
//  This is what separates Sesame's two modes. Opening the lid is an unambiguous "I am coming back to
//  this machine", and is worth scanning for automatically. A lock that happens with the lid already
//  open — a manual lock, a sleep from the Apple menu, a display timeout — is not: the Mac may well be
//  sitting in front of someone who deliberately locked it, and a camera that starts hunting for a
//  face every time is both wrong and unnerving. That case waits to be asked.
//

import Foundation
import IOKit

enum LidMonitor {
    /// `nil` on a machine with no clamshell at all (a desktop), or if the property is unreadable.
    /// Callers treat `nil` as "not a lid machine", which keeps desktops on the manual path.
    static var isLidClosed: Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return (property as? Bool) ?? (property as? NSNumber)?.boolValue
    }

    /// What the firmware says woke the machine, e.g. "LID0" or "EC.LidOpen" for a lid open. Read
    /// alongside the clamshell state rather than instead of it: the exact strings vary across Macs,
    /// so this is corroboration and a debugging aid, not the decision.
    static var lastWakeReason: String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service, "IOPMRootDomainWakeReason" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        guard let reason = property as? String, !reason.isEmpty else { return nil }
        return reason
    }

    /// True when the wake reason names the lid. Matches the spellings seen across Intel and Apple
    /// silicon rather than one exact string.
    static var wakeReasonNamesLid: Bool {
        guard let reason = lastWakeReason?.uppercased() else { return false }
        return reason.contains("LID")
    }
}
