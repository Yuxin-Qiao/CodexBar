import CodexBarCore
import Testing
@testable import CodexBar

struct UsageSpendBundleProofTests {
    @Test
    func `proof mode stays inert without an output directory`() {
        #expect(UsageSpendBundleProof.requestDirectory(environment: [:]) == nil)
        #expect(UsageSpendBundleProof.requestDirectory(environment: [
            "CODEXBAR_SPEND_BUNDLE_PROOF_DIR": "   ",
        ]) == nil)
    }

    @Test
    func `proof mode trims its output directory`() {
        #expect(UsageSpendBundleProof.requestDirectory(environment: [
            "CODEXBAR_SPEND_BUNDLE_PROOF_DIR": " /tmp/proof ",
        ]) == "/tmp/proof")
    }

    @Test
    func `proof mode requires every isolation boundary`() {
        #expect(UsageSpendBundleProof.isolationFailure(environment: [:]) != nil)
        var environment = [
            "CFFIXED_USER_HOME": "/tmp/proof/home",
            "HOME": "/tmp/proof/home",
            "CODEX_HOME": "/tmp/proof/codex",
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
            CodexCredentialFileAccess.isolationEnvironmentKey: "1",
            "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1",
            "SWIFT_TESTING": "1",
            "SWIFT_TESTING_ENABLED": "1",
        ]
        #expect(UsageSpendBundleProof.isolationFailure(environment: environment) == nil)
        environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] = "0"
        #expect(UsageSpendBundleProof.isolationFailure(environment: environment)?.contains("expected 1") == true)
    }
}
