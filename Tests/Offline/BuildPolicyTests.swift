import Foundation
@main struct PolicyTests {
    static func main() {
        let empty: [String: String] = [:]
        if BuildPolicy.isProduction {
            precondition(BuildPolicy.hardwareAllowed(environment: empty))
            precondition(BuildPolicy.companionEnabled(environment: empty))
            precondition(BuildPolicy.companionPort == 9876)
            precondition(!BuildPolicy.companionLoopbackOnly && BuildPolicy.advertiseCompanion)
        } else {
            precondition(!BuildPolicy.hardwareAllowed(environment: empty))
            precondition(!BuildPolicy.companionEnabled(environment: empty))
            precondition(BuildPolicy.companionPort == 19876)
            precondition(BuildPolicy.companionLoopbackOnly && !BuildPolicy.advertiseCompanion)
            precondition(BuildPolicy.hardwareAllowed(environment: ["PRESENTATION_MODE_ENABLE_HARDWARE":"1"]))
            precondition(!BuildPolicy.hardwareAllowed(environment: ["PRESENTATION_MODE_ENABLE_HARDWARE":"true"]))
        }
        print("PASS: \(BuildPolicy.isProduction ? "production" : "validation") launch/network policy")
    }
}
