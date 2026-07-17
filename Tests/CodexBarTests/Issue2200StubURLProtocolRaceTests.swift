import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Regression test for GitHub issue #2200: URLProtocol test stub handler race.
///
/// Many provider test files declare `nonisolated(unsafe) static var handler` and
/// assign it from test setup without synchronizing with `URLSession`'s background
/// thread that reads it in `canInit(with:)` / `startLoading()`. This test stresses
/// the `StubURLProtocol` from `ProviderHTTPClientTests` to ensure the seam is
/// lock-protected.
struct Issue2200StubURLProtocolRaceTests {

    @Test
    func `concurrent handler assignment races with handler read`() async throws {
        let iterations = 10_000

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<iterations {
                    StubURLProtocol.handler = { request in
                        let response = HTTPURLResponse(
                            url: request.url ?? URL(string: "https://example.com")!,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: nil)!
                        return (Data(#"{"ok":true}"#.utf8), response)
                    }
                }
            }

            group.addTask {
                for _ in 0..<iterations {
                    StubURLProtocol.handler = { request in
                        let response = HTTPURLResponse(
                            url: request.url ?? URL(string: "https://example.com")!,
                            statusCode: 404,
                            httpVersion: "HTTP/1.1",
                            headerFields: nil)!
                        return (Data(#"{"ok":false}"#.utf8), response)
                    }
                }
            }

            group.addTask {
                for _ in 0..<(iterations * 4) {
                    _ = StubURLProtocol.handler != nil
                }
            }

            group.addTask {
                for _ in 0..<(iterations * 4) {
                    StubURLProtocol.handler = nil
                }
            }

            await group.waitForAll()
        }
    }
}
