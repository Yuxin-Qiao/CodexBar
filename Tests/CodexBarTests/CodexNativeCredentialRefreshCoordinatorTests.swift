import Foundation
import Testing
@testable import CodexBarCore

struct CodexNativeCredentialRefreshCoordinatorTests {
    @Test
    func `canceling one waiter preserves shared renewal for another`() async throws {
        let coordinator = CodexNativeCredentialRefreshCoordinator()
        let gate = Gate()
        let first = Task { try await coordinator.refresh(home: "home") { await gate.wait() } }
        defer { first.cancel() }
        try await self.waitForCount(1, coordinator: coordinator)
        let second = Task {
            try await coordinator.refresh(home: "home") { Issue.record("Renewal must be coalesced") }
        }
        defer { second.cancel() }
        try await self.waitForCount(2, coordinator: coordinator)
        first.cancel()
        try await self.waitForCount(1, coordinator: coordinator)
        await #expect(throws: CancellationError.self) { try await first.value }
        await gate.release()
        try await second.value
        #expect(await coordinator.waiterCount(home: "home") == 0)
    }

    @Test
    func `last waiter cancellation cancels renewal and allows replacement`() async throws {
        let coordinator = CodexNativeCredentialRefreshCoordinator()
        let canceled = Gate()
        let first = Task {
            try await coordinator.refresh(home: "home") {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await canceled.release()
                    throw error
                }
            }
        }
        defer { first.cancel() }
        try await self.waitForCount(1, coordinator: coordinator)
        first.cancel()
        try await self.waitForCount(0, coordinator: coordinator)
        await #expect(throws: CancellationError.self) { try await first.value }
        try await coordinator.refresh(home: "home") {}
        // The underlying operation must observe cancellation, not just lose its waiter.
        let deadline = ContinuousClock.now + .seconds(2)
        while await !(canceled.isReleased), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await canceled.isReleased)
    }

    @Test
    func `old completion cannot clear a replacement renewal`() async throws {
        let coordinator = CodexNativeCredentialRefreshCoordinator()
        let old = Gate()
        let oldFinished = Gate()
        let replacement = Gate()
        let first = Task {
            try await coordinator.refresh(home: "home") {
                await old.wait()
                await oldFinished.release()
            }
        }
        try await self.waitForCount(1, coordinator: coordinator)
        first.cancel()
        try await self.waitForCount(0, coordinator: coordinator)
        await #expect(throws: CancellationError.self) { try await first.value }
        let second = Task { try await coordinator.refresh(home: "home") { await replacement.wait() } }
        defer { second.cancel() }
        try await self.waitForCount(1, coordinator: coordinator)
        await old.release()
        await oldFinished.wait()
        #expect(await coordinator.waiterCount(home: "home") == 1)
        await replacement.release()
        try await second.value
    }

    private func waitForCount(_ count: Int, coordinator: CodexNativeCredentialRefreshCoordinator) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await coordinator.waiterCount(home: "home") != count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await coordinator.waiterCount(home: "home") == count)
    }

    private actor Gate {
        private(set) var isReleased = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !self.isReleased else { return }
            await withCheckedContinuation { self.continuation = $0 }
        }

        func release() {
            self.isReleased = true
            self.continuation?.resume()
            self.continuation = nil
        }
    }
}
