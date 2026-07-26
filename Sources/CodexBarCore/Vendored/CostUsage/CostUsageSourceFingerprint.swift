import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One bounded content sample: FNV-1a (64-bit) over up to `sampleBytes` read at a fixed offset.
struct CostUsageFileSampleHash: Codable, Equatable {
    var offset: Int64
    var length: Int64
    var fnv1a: UInt64
}

/// tokscale-style sampling fingerprint for per-file cache freshness (mirrors `SourceFingerprint`
/// in tokscale-core's message_cache.rs): size + nanosecond mtime + FNV-1a over 5 fixed sample
/// points x 4 KiB, plus a whole-file SHA-256 used to tell a pure `touch` apart from a real edit.
struct CostUsageSourceFingerprint: Codable, Equatable {
    static let sampleBytes: Int64 = 4096
    static let samplePoints = 5
    private static let hashBufferBytes = 64 * 1024

    var size: Int64
    var mtimeUnixNs: Int64
    var samples: [CostUsageFileSampleHash]
    /// Whole-file SHA-256 (hex). Compared only when size/mtime moved, so the hot path
    /// never pays for a full read.
    var contentSHA256: String?

    enum Freshness: Equatable {
        /// Size, mtime and all bounded samples match; validation read at most
        /// `samplePoints x sampleBytes` and no full-file hash was computed.
        case unchanged
        /// Metadata moved but the whole-file hash still matches: a pure touch.
        /// Carries the refreshed fingerprint the caller should store.
        case touched(CostUsageSourceFingerprint)
        /// Real content change, an unreadable file, or no usable cached fingerprint.
        /// Carries the fresh fingerprint describing the current file.
        case changed(CostUsageSourceFingerprint)

        /// The freshly computed fingerprint carried by touched/changed results, reusable by
        /// rescan paths so a changed file is hashed only once per scan.
        var freshFingerprint: CostUsageSourceFingerprint? {
            switch self {
            case .unchanged:
                nil
            case let .touched(fresh), let .changed(fresh):
                fresh
            }
        }
    }

    // MARK: - Validation

    /// Cheap metadata first: when size + mtime match, only the bounded samples are recomputed
    /// (<=20 KiB). When metadata moved, rebuild the complete fingerprint so a touch (same
    /// content hash) can be distinguished from a real modification.
    static func check(
        fileURL: URL,
        size: Int64,
        mtimeUnixNs: Int64,
        cached: CostUsageSourceFingerprint?) -> Freshness
    {
        if let cached,
           cached.size == size,
           cached.mtimeUnixNs == mtimeUnixNs,
           let samples = self.sampleHashes(fileURL: fileURL, size: size),
           samples == cached.samples
        {
            return .unchanged
        }

        guard let fresh = self.make(fileURL: fileURL, size: size, mtimeUnixNs: mtimeUnixNs) else {
            return .changed(CostUsageSourceFingerprint(
                size: size,
                mtimeUnixNs: mtimeUnixNs,
                samples: [],
                contentSHA256: nil))
        }
        if let cached,
           let cachedHash = cached.contentSHA256,
           cachedHash == fresh.contentSHA256
        {
            return .touched(fresh)
        }
        return .changed(fresh)
    }

    /// Builds a complete fingerprint (samples + whole-file hash) for the current file content.
    /// Returns nil when the file cannot be read consistently (e.g. truncated mid-read).
    static func make(
        fileURL: URL,
        size: Int64,
        mtimeUnixNs: Int64) -> CostUsageSourceFingerprint?
    {
        guard let samples = self.sampleHashes(fileURL: fileURL, size: size),
              let contentSHA256 = self.contentHash(fileURL: fileURL, expectedSize: size)
        else { return nil }
        return CostUsageSourceFingerprint(
            size: size,
            mtimeUnixNs: mtimeUnixNs,
            samples: samples,
            contentSHA256: contentSHA256)
    }

    // MARK: - Sampling

    /// Fixed sample offsets matching tokscale: start / quarter / half / three-quarter / final
    /// window, sorted and deduplicated, capped at `samplePoints`.
    static func sampleOffsets(size: Int64) -> [(offset: Int64, length: Int64)] {
        let sampleLength = min(size, self.sampleBytes)
        guard sampleLength > 0 else { return [] }
        let maxOffset = size - sampleLength
        let raw: [Int64] = maxOffset == 0
            ? [0]
            : [0, maxOffset / 4, maxOffset / 2, maxOffset / 4 * 3, maxOffset]
        var seen: Set<Int64> = []
        var offsets: [Int64] = []
        for offset in raw.sorted() where !seen.contains(offset) {
            seen.insert(offset)
            offsets.append(offset)
        }
        return offsets.prefix(self.samplePoints).map { (offset: $0, length: sampleLength) }
    }

    static func sampleHashes(fileURL: URL, size: Int64) -> [CostUsageFileSampleHash]? {
        let offsets = self.sampleOffsets(size: size)
        guard !offsets.isEmpty else { return [] }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var samples: [CostUsageFileSampleHash] = []
        for (offset, length) in offsets {
            do {
                try handle.seek(toOffset: UInt64(offset))
                guard let data = try handle.read(upToCount: Int(length)), data.count == length
                else { return nil }
                samples.append(CostUsageFileSampleHash(
                    offset: offset,
                    length: length,
                    fnv1a: self.fnv1a(data)))
            } catch {
                return nil
            }
        }
        return samples
    }

    static func fnv1a(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    // MARK: - Whole-file hash

    /// Streams exactly `expectedSize` bytes through SHA-256. Reading a fixed size keeps the
    /// hash tied to the stat snapshot the caller already validated against.
    private static func contentHash(fileURL: URL, expectedSize: Int64) -> String? {
        guard expectedSize >= 0 else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = expectedSize
        while remaining > 0 {
            let chunk = Int(min(remaining, Int64(self.hashBufferBytes)))
            do {
                guard let data = try handle.read(upToCount: chunk), !data.isEmpty else { return nil }
                hasher.update(data: data)
                remaining -= Int64(data.count)
            } catch {
                return nil
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
