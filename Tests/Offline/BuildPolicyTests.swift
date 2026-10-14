import Foundation
@main struct PolicyTests {
    static func main() {
        let empty: [String: String] = [:]
        if BuildPolicy.isProduction {
            precondition(BuildPolicy.companionEnabled(environment: empty))
            precondition(BuildPolicy.companionPort == 9876)
            precondition(!BuildPolicy.companionLoopbackOnly && BuildPolicy.advertiseCompanion)
        } else {
            precondition(!BuildPolicy.companionEnabled(environment: empty))
            precondition(BuildPolicy.companionPort == 19876)
            precondition(BuildPolicy.companionLoopbackOnly && !BuildPolicy.advertiseCompanion)
        }
        print("PASS: \(BuildPolicy.isProduction ? "production" : "validation") launch/network policy")
    }
}
