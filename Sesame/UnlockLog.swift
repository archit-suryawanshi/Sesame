//
//  UnlockLog.swift
//  Sesame
//
//  Everything that decides an unlock happens while the screen is locked, where no window is visible
//  and `statusMessage` is written to nobody and then overwritten. A scan that silently resolved to
//  nothing left no trace at all, so "it just doesn't unlock" was undiagnosable from the outside.
//
//  These go to the unified log instead, readable afterwards with:
//      log show --predicate 'subsystem == "app.sesame.unlock"' --last 15m
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
    ///
    /// `notice`, not `info`. The unified log does not persist `info` or `debug` to disk unless the
    /// subsystem has been explicitly configured to, so the first version of this logged the two most
    /// useful lines here straight into a buffer that `log show` could never read back. A diagnostic
    /// that only works if you already knew to turn it on is not a diagnostic.
    static func blocked(_ reason: String) {
        logger.notice("blocked: \(reason, privacy: .public)")
    }

    static func event(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    /// The per-frame scoring line. Deliberately `debug` — it fires at camera rate and would
    /// otherwise drown the entries that matter, so unlike the rest it is genuinely not persisted.
    /// To see it, watch live while locking the screen:
    ///
    ///     log stream --predicate 'subsystem == "app.sesame.unlock"' --level debug
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
