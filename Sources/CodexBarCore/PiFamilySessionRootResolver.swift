import Foundation

/// Resolves the historical Pi-family roots used by cost and usage discovery.
public enum PiFamilySessionRootResolver {
    /// Returns resolved roots for Pi and OMP historical session stores.
    ///
    /// Unresolved placeholders are omitted so callers can use the result for read-only source detection.
    public static func costSessionRootURLs(
        environment: [String: String],
        baseDirectory: URL? = nil,
        processContexts: [PiSessionProcessContext] = []) -> [URL]
    {
        PiFamilySessionScanner.costSessionRoots(
            environment: environment,
            baseDirectories: baseDirectory.map { [$0] },
            processContexts: processContexts)
            .filter(\.resolutionIsComplete)
            .map(\.url)
    }
}
