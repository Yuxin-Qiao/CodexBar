import Foundation

/// Explicit failure when a renewal generation ends without confirming its app-server
/// child exited. The coordinator reports this to queued callers instead of starting
/// new credential I/O while an old generation may still be alive.
enum CodexCredentialRenewalError: Error, Sendable {
    case previousProcessExitUnconfirmed
}

actor CodexNativeCredentialRefreshCoordinator {
    private struct QueuedWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
        let operation: @Sendable () async throws -> Void
    }

    private struct HomeState {
        var activeID: UUID
        var activeTask: Task<Void, Never>
        var activeWaiters: [UUID: CheckedContinuation<Void, any Error>]
        /// True once the last active waiter canceled. The home stays occupied until
        /// the old task finishes its cleanup; new callers queue instead of starting I/O.
        var isDraining: Bool
        var queued: [QueuedWaiter]
        /// True when the old process could not be confirmed exited. The home remains
        /// quarantined until the process exit observer reports the actual termination.
        var isQuarantined: Bool
        var exitObserver: (@Sendable () async -> Void)?
        var exitObservationTask: Task<Void, Never>?
    }

    static let shared = CodexNativeCredentialRefreshCoordinator()

    private var statesByHome: [String: HomeState] = [:]

    func waiterCount(home: String) -> Int {
        guard let state = self.statesByHome[home] else { return 0 }
        return state.activeWaiters.count + state.queued.count
    }

    func homeIsOccupied(home: String) -> Bool {
        self.statesByHome[home] != nil
    }

    func refresh(
        home: String,
        operation: @escaping @Sendable () async throws -> Void) async throws
    {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var state = self.statesByHome[home] {
                    if state.isQuarantined {
                        // A previous generation may still own a rotating refresh token.
                        // Fail closed until its actual process exit has been observed.
                        continuation.resume(throwing: CodexCredentialRenewalError.previousProcessExitUnconfirmed)
                    } else if state.isDraining {
                        // The old generation is still tearing down. Queue for the next
                        // generation without joining the canceled operation or starting I/O.
                        state.queued.append(QueuedWaiter(
                            id: waiterID,
                            continuation: continuation,
                            operation: operation))
                        self.statesByHome[home] = state
                    } else {
                        state.activeWaiters[waiterID] = continuation
                        self.statesByHome[home] = state
                    }
                    return
                }
                self.startLocked(home: home, waiterID: waiterID, continuation: continuation, operation: operation)
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel(home: home, waiterID: waiterID) }
        }
    }

    private func startLocked(
        home: String,
        waiterID: UUID,
        continuation: CheckedContinuation<Void, any Error>,
        operation: @escaping @Sendable () async throws -> Void)
    {
        let id = UUID()
        let task = Task {
            let result: Result<Void, any Error>
            do {
                try Task.checkCancellation()
                try await operation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self.finish(home: home, id: id, result: result)
        }
        self.statesByHome[home] = HomeState(
            activeID: id,
            activeTask: task,
            activeWaiters: [waiterID: continuation],
            isDraining: false,
            queued: [],
            isQuarantined: false,
            exitObserver: nil,
            exitObservationTask: nil)
    }

    /// Registers an asynchronous observation for the active generation's child process.
    /// The operation calls this immediately before returning
    /// `previousProcessExitUnconfirmed`, so a later refresh cannot clear the reservation
    /// before the underlying process has actually terminated.
    func registerExitObserver(
        home: String,
        waitForExit: @escaping @Sendable () async -> Void)
    {
        guard var state = self.statesByHome[home], !state.isQuarantined else { return }
        state.exitObserver = waitForExit
        self.statesByHome[home] = state
    }

    private func cancel(home: String, waiterID: UUID) {
        guard var state = self.statesByHome[home] else { return }
        if let waiter = state.activeWaiters.removeValue(forKey: waiterID) {
            waiter.resume(throwing: CancellationError())
            if state.activeWaiters.isEmpty, !state.isDraining {
                // Last active waiter gone: drain the old generation but keep the home
                // occupied so no new app-server starts before the old one is confirmed gone.
                state.isDraining = true
                self.statesByHome[home] = state
                state.activeTask.cancel()
            } else {
                self.statesByHome[home] = state
            }
            return
        }
        if let index = state.queued.firstIndex(where: { $0.id == waiterID }) {
            let queued = state.queued.remove(at: index)
            self.statesByHome[home] = state
            queued.continuation.resume(throwing: CancellationError())
        }
    }

    private func finish(home: String, id: UUID, result: Result<Void, any Error>) {
        guard let current = self.statesByHome[home], current.activeID == id else { return }
        var state = current
        let previousWaiters = state.activeWaiters
        state.activeWaiters = [:]

        if Self.isExitUnconfirmed(result) {
            // The old child may still be alive. Keep the home quarantined, fail all
            // current waiters, and let the registered observer release the reservation
            // only after Foundation reports the actual process termination.
            let queuedWaiters = state.queued
            state.queued = []
            state.isDraining = true
            state.isQuarantined = true
            let observer = state.exitObserver
            state.exitObserver = nil
            self.statesByHome[home] = state
            if let observer {
                let observationTask = Task {
                    await observer()
                    self.exitConfirmed(home: home, id: id)
                }
                guard var updated = self.statesByHome[home], updated.activeID == id else { return }
                updated.exitObservationTask = observationTask
                self.statesByHome[home] = updated
            }
            for waiter in previousWaiters.values {
                waiter.resume(with: result)
            }
            for queued in queuedWaiters {
                queued.continuation.resume(with: result)
            }
            return
        }

        guard !state.queued.isEmpty else {
            self.statesByHome[home] = nil
            for waiter in previousWaiters.values {
                waiter.resume(with: result)
            }
            return
        }
        // The old generation settled. Queued callers get a fresh attempt with the
        // oldest surviving caller's operation; the old result stays with the old waiters.
        let queued = state.queued
        let next = queued[0]
        let newID = UUID()
        var newWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        for waiter in queued {
            newWaiters[waiter.id] = waiter.continuation
        }
        let task = Task {
            let result: Result<Void, any Error>
            do {
                try Task.checkCancellation()
                try await next.operation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self.finish(home: home, id: newID, result: result)
        }
        self.statesByHome[home] = HomeState(
            activeID: newID,
            activeTask: task,
            activeWaiters: newWaiters,
            isDraining: false,
            queued: [],
            isQuarantined: false,
            exitObserver: nil,
            exitObservationTask: nil)
        for waiter in previousWaiters.values {
            waiter.resume(with: result)
        }
    }

    private func exitConfirmed(home: String, id: UUID) {
        guard let state = self.statesByHome[home], state.activeID == id, state.isQuarantined else { return }
        self.statesByHome[home] = nil
    }

    private static func isExitUnconfirmed(_ result: Result<Void, any Error>) -> Bool {
        guard case let .failure(error) = result else { return false }
        return error is CodexCredentialRenewalError
    }
}
