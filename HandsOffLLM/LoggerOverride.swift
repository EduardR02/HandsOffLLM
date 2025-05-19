//
//  LoggerOverride.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 20.05.25.
//

import Foundation

#if !DEBUG
/// In Release builds this stub will shadow OSLog.Logger
/// so that every call becomes a no-op and the real os_log APIs never get linked.
struct Logger {
    init(subsystem: String, category: String) {}
    func debug(_ message: String) {}
    func info(_ message: String) {}
    func error(_ message: String) {}
    func fault(_ message: String) {}
    func warning(_ message: String) {}
    func notice(_ message: String) {}
}
#endif
