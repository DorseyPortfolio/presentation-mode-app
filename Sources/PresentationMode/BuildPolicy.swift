import Foundation

/// Release behavior is selected at build time, never inferred from install path.
enum BuildPolicy {
#if PRESENTATION_MODE_PRODUCTION
    static let isProduction = true
#else
    static let isProduction = false
#endif
    static func hardwareAllowed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isProduction || environment["PRESENTATION_MODE_ENABLE_HARDWARE"] == "1"
    }
    static func companionEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isProduction || environment["PRESENTATION_MODE_ENABLE_COMPANION"] == "1"
    }
    static let companionPort: UInt16 = isProduction ? 9876 : 19876
    static let companionLoopbackOnly = !isProduction
    static let advertiseCompanion = isProduction
}
