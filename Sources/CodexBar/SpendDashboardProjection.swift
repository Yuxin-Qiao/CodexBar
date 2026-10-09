import CodexBarCore
import Foundation

/// Immutable inputs for CPU work. No account probing or UI access happens in this projection.
struct SpendDashboardProjectionRequest: Sendable {
    let inputs: [SpendDashboardModel.ProviderInput]
    let reportingPeriod: CostReportingPeriod
    let now: Date
    let calendar: Calendar
    let preferredCurrencyCode: String
    let hiddenSourceIDs: Set<String>
    let hideNativeCodexWhenOpenCodexPresent: Bool
    let selectedDay: Date?

    func build() -> SpendDashboardModel {
        SpendDashboardModel.build(
            inputs: self.inputs,
            reportingPeriod: self.reportingPeriod,
            now: self.now,
            calendar: self.calendar,
            preferredCurrencyCode: self.preferredCurrencyCode,
            hiddenSourceIDs: self.hiddenSourceIDs,
            hideNativeCodexWhenOpenCodexPresent: self.hideNativeCodexWhenOpenCodexPresent,
            selectedDay: self.selectedDay)
    }

    static func buildOffMainActor(_ request: Self) async -> SpendDashboardModel {
        // A Task created by the controller inherits MainActor. Detach only this pure, Sendable computation.
        await Task.detached(priority: .userInitiated) { request.build() }.value
    }
}

/// One active projection and one replaceable pending request, including across stop/reopen.
/// Superseded work drains before the latest request starts; it can never publish an old result.
@MainActor
final class SpendDashboardProjectionWorker {
    typealias Builder = @Sendable (SpendDashboardProjectionRequest) async -> SpendDashboardModel

    private struct Work {
        let revision: UInt64
        let request: SpendDashboardProjectionRequest
        let completion: @MainActor (SpendDashboardModel) -> Void
    }

    private let builder: Builder
    private var revision: UInt64 = 0
    private var pending: Work?
    private var task: Task<Void, Never>?

    init(builder: @escaping Builder = SpendDashboardProjectionRequest.buildOffMainActor) {
        self.builder = builder
    }

    func submit(
        _ request: SpendDashboardProjectionRequest,
        completion: @escaping @MainActor (SpendDashboardModel) -> Void)
    {
        self.revision &+= 1
        self.pending = Work(revision: self.revision, request: request, completion: completion)
        guard self.task == nil else { return }
        let builder = self.builder
        self.task = Task { [weak self] in
            while let work = self?.pending {
                self?.pending = nil
                let model = await builder(work.request)
                guard let self else { return }
                if work.revision == self.revision {
                    work.completion(model)
                }
            }
            self?.task = nil
        }
    }

    func invalidate() {
        self.revision &+= 1
        self.pending = nil
    }
}
