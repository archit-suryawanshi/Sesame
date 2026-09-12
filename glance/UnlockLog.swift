//
//  UnlockLog.swift
//  glance
//
//  Everything that decides an unlock happens while the screen is locked, where no window is visible
//  and `statusMessage` is written to nobody and then overwritten. A scan that silently resolved to
//  nothing left no trace at all, so "it just doesn't unlock" was undiagnosable from the outside.
//
//  These go to the unified log instead, readable afterwards with:
//      log show --predicate 'subsystem == "app.sesame.unlock"' --last 15m --info
//
//  Nothing secret is logged: no password bytes, no embeddings, no frames. Similarity scores,
//  thresholds and gate names only, marked `.public` so they aren't redacted to <private> and the
//  log becomes useless.
//

import Foundation
import os

enum UnlockLog {
    static let subsystem = "app.sesame.unlock"

    private static let logger = Logger(subsystem: subsystem, category: "scan")

    /// A gate that stopped an unlock before scanning even started.
    static func blocked(_ reason: String) {
        logger.info("blocked: \(reason, privacy: .public)")
    }

    static func event(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    /// The per-frame scoring line. Deliberately `debug` — it fires at camera rate and would
    /// otherwise drown the entries that matter.
    static func frame(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func outcome(_ message: String) {
        logger.notice("outcome: \(message, privacy: .public)")
    }

    static func failure(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
