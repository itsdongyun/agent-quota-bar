import Foundation
import OSLog

/// Lightweight system logger using Apple's unified logging (Console.app).
public enum AppLogger {
    private static let subsystem = "com.agentquotabar.app"

    public static let provider = Logger(subsystem: subsystem, category: "provider")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
