#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

#if canImport(Glibc) || canImport(Musl)
enum PosixSpawnFileActionsCloseFrom {
    static func addCloseFrom(
        _ fileActions: inout posix_spawn_file_actions_t,
        startingAt minimumFileDescriptor: Int32) -> [Int32]
    {
        #if canImport(Glibc)
        return [posix_spawn_file_actions_addclosefrom_np(&fileActions, minimumFileDescriptor)]
        #else
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") else {
            return []
        }
        return entries.compactMap(Int32.init)
            .filter { $0 >= minimumFileDescriptor }
            .map { posix_spawn_file_actions_addclose(&fileActions, $0) }
        #endif
    }
}
#endif
