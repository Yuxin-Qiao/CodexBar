import Foundation
import Testing
@testable import CodexBarCore

#if os(Linux)
@Suite(.serialized)
struct ProcessPipeCaptureLinuxTests {
    @Test
    func `ProcessPipeCapture releases its pipe read end after capture`() throws {
        let initialFDs = try countOpenFDs()
        for _ in 0..<100 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/echo")
            proc.arguments = ["hello"]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice

            let capture = ProcessPipeCapture(pipe: out)
            capture.start()
            try proc.run()
            proc.waitUntilExit()
            _ = capture.finishSynchronously(timeout: 0.25)
        }
        let finalFDs = try countOpenFDs()

        // Allow a small tolerance for unrelated fd churn, but ensure we are
        // not leaking pipe read ends (which would show as ~100 extra fds).
        #expect(finalFDs - initialFDs <= 10)
    }

    @Test
    func `ProcessPipeCapture does not SIGILL when file descriptors are exhausted`() throws {
        var savedLimit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &savedLimit) == 0 else {
            Issue.record("getrlimit failed")
            return
        }

        // Lower the soft limit to a small value to force the EMFILE branch.
        let lowLimit = rlimit(rlim_cur: 64, rlim_max: savedLimit.rlim_max)
        guard setrlimit(RLIMIT_NOFILE, &lowLimit) == 0 else {
            Issue.record("setrlimit failed")
            return
        }
        defer {
            _ = setrlimit(RLIMIT_NOFILE, &savedLimit)
        }

        // Pre-fill the fd table.
        var pipes: [Pipe] = []
        for _ in 0..<25 {
            pipes.append(Pipe())
        }

        // Creating another ProcessPipeCapture should not crash with SIGILL.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/echo")
        proc.arguments = ["hello"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice

        let capture = ProcessPipeCapture(pipe: out)
        capture.start()
        try proc.run()
        proc.waitUntilExit()
        _ = capture.finishSynchronously(timeout: 0.25)

        // If we reach here, the process survived.
        #expect(true)
    }
}

private func countOpenFDs() throws -> Int {
    let entries = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
    return entries.count
}
#endif
