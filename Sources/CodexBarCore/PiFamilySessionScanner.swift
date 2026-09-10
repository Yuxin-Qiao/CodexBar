import Foundation

struct PiFamilySessionRecord: Equatable, Sendable {
    let id: String
    let cwd: String?
    let sessionName: String?
    let startedAt: Date?
    let modifiedAt: Date
    let url: URL
}

enum PiFamilySessionFileParser {
    private static let maximumReadSize = 16 * 1024

    static func parse(
        url: URL,
        dialect: AgentSession.Dialect,
        modifiedAt: Date,
        now: Date) -> PiFamilySessionRecord?
    {
        guard let data = readPrefix(from: url),
              let lines = completeLines(in: data)
        else { return nil }

        var nonEmptyLines = lines.filter { !$0.isEmpty }
        guard !nonEmptyLines.isEmpty else { return nil }

        var titleSlotWasPresent = false
        var titleSlot: String?
        if dialect == .omp,
           let first = Self.jsonObject(from: nonEmptyLines[0]),
           first["type"] as? String == "title"
        {
            titleSlotWasPresent = true
            titleSlot = first["title"] as? String
            nonEmptyLines.removeFirst()
        }

        guard let headerData = nonEmptyLines.first,
              let header = Self.jsonObject(from: headerData),
              header["type"] as? String == "session",
              let id = header["id"] as? String
        else { return nil }
        // Provider-specific by design: Pi session files require the upstream v3 header contract.
        if dialect == .pi, header["version"] as? Int != 3 {
            return nil
        }

        let rawTitle = switch dialect {
        case .pi:
            Self.latestPiSessionName(in: url, prefixLines: nonEmptyLines)
        case .omp:
            titleSlotWasPresent ? titleSlot : header["title"] as? String
        }
        let sessionName = rawTitle.flatMap(Self.sanitizedTitle)
        let startedAt = (header["timestamp"] as? String).flatMap(Self.parseDate)

        return PiFamilySessionRecord(
            id: id,
            cwd: header["cwd"] as? String,
            sessionName: sessionName,
            startedAt: startedAt,
            modifiedAt: min(modifiedAt, now),
            url: url)
    }

    private static func latestPiSessionName(in url: URL, prefixLines: [Data]) -> String? {
        var latest = Self.latestPiSessionName(in: prefixLines)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return latest }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(Self.maximumReadSize) else { return latest }

        let tailReadSize = 64 * 1024
        let offset = size > UInt64(tailReadSize) ? size - UInt64(tailReadSize) : 0
        do {
            try handle.seek(toOffset: offset)
            guard let tail = try handle.read(upToCount: tailReadSize), !tail.isEmpty else { return latest }
            var lines: [Data] = []
            for line in [UInt8](tail).split(separator: 0x0A, omittingEmptySubsequences: true) {
                lines.append(Data(line))
            }
            if offset > 0, !lines.isEmpty {
                lines.removeFirst()
            }
            latest = Self.latestPiSessionName(in: lines) ?? latest
        } catch {
            return latest
        }
        return latest
    }

    private static func latestPiSessionName(in lines: [Data]) -> String? {
        lines.reversed().compactMap { line -> String? in
            guard let entry = Self.jsonObject(from: line),
                  entry["type"] as? String == "session_info"
            else { return nil }
            return entry["name"] as? String
        }.first
    }

    private static func readPrefix(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: Self.maximumReadSize)
    }

    private static func completeLines(in data: Data) -> [Data]? {
        var lines: [Data] = []
        var lineStart = data.startIndex

        for index in data.indices where data[index] == 0x0A {
            lines.append(data.subdata(in: lineStart..<index))
            lineStart = data.index(after: index)
        }

        // A line without its terminating newline is either a partial bounded
        // read or a truncated record. Do not attempt to parse it at the limit.
        if lineStart < data.endIndex, data.count < Self.maximumReadSize {
            lines.append(data.subdata(in: lineStart..<data.endIndex))
        }
        guard lineStart == data.endIndex || !lines.isEmpty else { return nil }
        return lines
    }

    private static func jsonObject(from data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func sanitizedTitle(_ value: String) -> String? {
        var result = ""
        for scalar in value.unicodeScalars {
            guard !CharacterSet.controlCharacters.contains(scalar),
                  !CharacterSet.newlines.contains(scalar)
            else { continue }
            guard result.unicodeScalars.count < 64 else { break }
            result.unicodeScalars.append(scalar)
        }
        return result.isEmpty ? nil : result
    }
}

struct OMPSessionRootResolver: Sendable {
    static func sessionRoots(
        environment: [String: String],
        fileManager: FileManager = .default) -> [URL]
    {
        self.sessionRoots(
            environment: environment,
            baseDirectory: self.currentDirectory(fileManager: fileManager),
            fileManager: fileManager)
    }

    static func sessionRoots(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager = .default) -> [URL]
    {
        guard let profile = activeProfile(in: environment) else {
            // `nil` is the valid default profile. An invalid profile is
            // represented separately so a malformed environment fails closed.
            guard self.profileValueIsValid(in: environment) else { return [] }
            return self.defaultProfileRoots(
                environment: environment,
                baseDirectory: baseDirectory,
                fileManager: fileManager)
        }

        return Self.namedProfileRoots(
            profile: profile,
            environment: environment,
            baseDirectory: baseDirectory,
            fileManager: fileManager)
    }

    static func defaultProfileSessionRoots(
        environment: [String: String],
        fileManager: FileManager = .default) -> [URL]
    {
        self.defaultProfileSessionRoots(
            environment: environment,
            baseDirectory: self.currentDirectory(fileManager: fileManager),
            fileManager: fileManager)
    }

    static func defaultProfileSessionRoots(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager = .default) -> [URL]
    {
        self.defaultProfileRoots(
            environment: self.sanitizedDefaultEnvironment(environment),
            baseDirectory: baseDirectory,
            fileManager: fileManager)
    }

    private static func defaultProfileRoots(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager) -> [URL]
    {
        guard let home = homeURL(
            environment: environment,
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        else { return [] }
        guard let configRoot = Self.configRoot(home: home, environment: environment) else { return [] }
        let customAgentRoot = Self.customAgentRoot(
            environment: environment,
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        let agentRoot: URL
        if let customAgentRoot {
            agentRoot = customAgentRoot
        } else {
            guard let canonicalAgentRoot = Self.canonicalAgentRoot(
                configRoot.appendingPathComponent("agent", isDirectory: true),
                home: home)
            else { return [] }
            agentRoot = canonicalAgentRoot
        }

        guard let root = Self.sessionRoot(agentRoot: agentRoot, fileManager: fileManager) else { return [] }

        #if os(macOS) || os(Linux)
        if customAgentRoot == nil,
           let xdgDataHome = Self.environmentURL(
               environment["XDG_DATA_HOME"],
               baseDirectory: baseDirectory,
               fileManager: fileManager)
        {
            let xdgSessions = xdgDataHome
                .appendingPathComponent("omp", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            if Self.isDirectory(xdgSessions, fileManager: fileManager),
               let root = Self.sessionRoot(
                   agentRoot: xdgDataHome.appendingPathComponent("omp", isDirectory: true),
                   fileManager: fileManager)
            {
                return [root]
            }
        }
        #endif

        return [root]
    }

    private static func namedProfileRoots(
        profile: String,
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager) -> [URL]
    {
        guard let home = homeURL(
            environment: environment,
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        else { return [] }
        guard let configRoot = Self.configRoot(home: home, environment: environment) else { return [] }
        let profileRoot = configRoot
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)
        guard let agentRoot = Self.canonicalAgentRoot(
            profileRoot.appendingPathComponent("agent", isDirectory: true),
            home: home)
        else { return [] }

        guard let root = Self.sessionRoot(agentRoot: agentRoot, fileManager: fileManager) else { return [] }
        #if os(macOS) || os(Linux)
        if let xdgDataHome = Self.environmentURL(
            environment["XDG_DATA_HOME"],
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        {
            let xdgProfileRoot = xdgDataHome
                .appendingPathComponent("omp", isDirectory: true)
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(profile, isDirectory: true)
            let xdgSessions = xdgProfileRoot.appendingPathComponent("sessions", isDirectory: true)
            if Self.isDirectory(xdgSessions, fileManager: fileManager),
               let root = Self.sessionRoot(
                   agentRoot: xdgProfileRoot,
                   fileManager: fileManager)
            {
                return [root]
            }
        }
        #endif

        return [root]
    }

    private static func profileValueIsValid(in environment: [String: String]) -> Bool {
        let value = if let omp = environment["OMP_PROFILE"] {
            omp
        } else {
            environment["PI_PROFILE"]
        }
        if case .invalid = Self.normalizedProfile(value) {
            return false
        }
        return true
    }

    private static func activeProfile(in environment: [String: String]) -> String? {
        let value = if let omp = environment["OMP_PROFILE"] {
            omp
        } else {
            environment["PI_PROFILE"]
        }
        guard case let .named(profile) = Self.normalizedProfile(value) else { return nil }
        return profile
    }

    private enum ProfileValue {
        case `default`
        case named(String)
        case invalid
    }

    private static func normalizedProfile(_ value: String?) -> ProfileValue {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalized.isEmpty || normalized == "default" {
            return .default
        }

        let scalars = Array(normalized.unicodeScalars)
        guard let first = scalars.first,
              scalars.count <= 64,
              Self.isASCIIAlphaNumeric(first),
              scalars.dropFirst().allSatisfy(Self.isProfileTailScalar),
              normalized != ".",
              normalized != "..",
              !normalized.hasSuffix("."),
              !Self.isWindowsReservedProfileName(normalized)
        else { return .invalid }

        return .named(normalized)
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isProfileTailScalar(_ scalar: Unicode.Scalar) -> Bool {
        self.isASCIIAlphaNumeric(scalar) ||
            scalar.value == 46 ||
            scalar.value == 95 ||
            scalar.value == 45
    }

    private static func isWindowsReservedProfileName(_ value: String) -> Bool {
        let uppercased = value.uppercased()
        let base = uppercased.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        switch base {
        case "CON", "PRN", "AUX", "NUL":
            return true
        default:
            return (base.hasPrefix("COM") || base.hasPrefix("LPT")) &&
                base.count == 4 &&
                base.last.map(\.isNumber) == true
        }
    }

    private static func homeURL(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager) -> URL?
    {
        guard let home = environmentURL(
            environment["HOME"],
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        else { return nil }
        return home
    }

    private static func configRoot(home: URL, environment: [String: String]) -> URL? {
        let name: String = if let configuredPath = environment["PI_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredPath.isEmpty
        {
            configuredPath
        } else {
            ".omp"
        }
        guard !name.hasPrefix("/") else { return nil }

        let canonicalHome = Self.canonicalURL(home)
        let configRoot = Self.canonicalURL(
            canonicalHome.appendingPathComponent(name, isDirectory: true))
        guard Self.isWithin(root: canonicalHome, candidate: configRoot) else { return nil }
        return configRoot
    }

    private static func customAgentRoot(
        environment: [String: String],
        baseDirectory: URL?,
        fileManager: FileManager) -> URL?
    {
        self.environmentURL(
            environment["PI_CODING_AGENT_DIR"],
            baseDirectory: baseDirectory,
            fileManager: fileManager)
    }

    private static func environmentURL(
        _ value: String?,
        baseDirectory: URL?,
        fileManager: FileManager) -> URL?
    {
        guard let value else { return nil }
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            guard let baseDirectory else { return nil }
            url = baseDirectory.appendingPathComponent(path, isDirectory: true)
        }
        return Self.canonicalURL(url)
    }

    private static func sanitizedDefaultEnvironment(_ environment: [String: String]) -> [String: String] {
        // A process with an inaccessible environment must not inherit
        // process-specific config, custom roots, XDG roots, or profile
        // selectors from the scanner's ambient environment. HOME is the only
        // input needed to identify the standard default profile root.
        guard let home = environment["HOME"] else { return [:] }
        return ["HOME": home]
    }

    private static func currentDirectory(fileManager: FileManager) -> URL {
        URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    }

    private static func sessionRoot(agentRoot: URL, fileManager: FileManager) -> URL? {
        let canonicalAgentRoot = Self.canonicalURL(agentRoot)
        let candidate = Self.canonicalURL(
            agentRoot.appendingPathComponent("sessions", isDirectory: true))
        guard Self.isWithin(root: canonicalAgentRoot, candidate: candidate) else { return nil }
        return candidate
    }

    private static func canonicalAgentRoot(_ agentRoot: URL, home: URL) -> URL? {
        let canonicalHome = Self.canonicalURL(home)
        let canonicalAgentRoot = Self.canonicalURL(agentRoot)
        guard Self.isWithin(root: canonicalHome, candidate: canonicalAgentRoot) else { return nil }
        return canonicalAgentRoot
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) &&
            isDirectory.boolValue
    }

    fileprivate static func isWithin(root: URL, candidate: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        if rootPath == "/" {
            return candidatePath.hasPrefix("/")
        }
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

struct PiFamilySessionScanner: Sendable {
    struct ScanInput: Sendable {
        let processes: [AgentProcessRecord]
        let cwdByPID: [Int32: String]
        let environment: [String: String]
        let now: Date
        let host: String
        let config: SessionScanConfig
    }

    private enum RootLayout: Hashable, Sendable {
        case projectDirectories
        case direct
    }

    private struct SessionRoot: Hashable, Sendable {
        let url: URL
        let layout: RootLayout
    }

    private struct ProfileSessionRootResolution {
        let roots: [URL]
        let isComplete: Bool
    }

    private struct PiSessionRootResolution {
        let roots: [SessionRoot]
        let isComplete: Bool
    }

    private struct OMPSessionRootResolution {
        let roots: [SessionRoot]
        let profileDiscoveryIsComplete: Bool
    }

    struct CostSessionRoot: Hashable, Sendable {
        let url: URL
        let missingIsKnownEmpty: Bool
        let resolutionIsComplete: Bool

        init(url: URL, missingIsKnownEmpty: Bool, resolutionIsComplete: Bool = true) {
            self.url = url
            self.missingIsKnownEmpty = missingIsKnownEmpty
            self.resolutionIsComplete = resolutionIsComplete
        }
    }

    static func scan(
        input: ScanInput,
        directoryBudget: inout DirectoryMetadataScanBudget) -> [AgentSession]
    {
        let processes = input.processes
        let cwdByPID = input.cwdByPID
        let now = input.now
        let host = input.host
        let config = input.config
        // Provider-specific by design: Pi-family sessions are correlated only with Pi provider processes.
        let liveProcesses = Array(AgentSessionCorrelation.newestProcessesFirst(
            processes.filter { AgentPSOutputParser.provider(for: $0) == .pi })
            .prefix(max(0, config.maxProcessCount)))
        guard !liveProcesses.isEmpty else {
            // Pi-family sessions are process-backed in the local scanner. Never
            // turn an old session file into a file-only AgentSession.
            return []
        }

        var recordsByRoot: [String: [PiFamilySessionRecord]] = [:]
        var usedRecordURLs = Set<String>()
        var sessions: [AgentSession] = []

        for process in liveProcesses {
            guard let dialect = AgentPSOutputParser.piDialect(for: process) else { continue }
            let processCWD = cwdByPID[process.pid]
            let processStandardizedCWD = processCWD
                .flatMap { $0.isEmpty ? nil : Self.standardizedPath($0) }

            var record: PiFamilySessionRecord?
            if let processStartedAt = process.startedAt,
               let processStandardizedCWD,
               let processCWD
            {
                let roots = Self.sessionRoots(
                    for: process,
                    dialect: dialect,
                    cwd: processCWD,
                    environment: input.environment)
                for root in roots {
                    guard directoryBudget.hasTimeRemaining() else { break }
                    let canonicalRoot = Self.canonicalURL(root.url)
                    let rootKey = "\(dialect.rawValue):\(root.layout):\(canonicalRoot.path)"
                    let rootRecords: [PiFamilySessionRecord]
                    if let cached = recordsByRoot[rootKey] {
                        rootRecords = cached
                    } else {
                        let discovered = Self.records(
                            in: canonicalRoot,
                            now: now,
                            dialect: dialect,
                            layout: root.layout,
                            directoryBudget: &directoryBudget)
                        recordsByRoot[rootKey] = discovered
                        rootRecords = discovered
                    }

                    if let candidate = rootRecords.first(where: { candidate in
                        guard candidate.modifiedAt >= processStartedAt,
                              let recordCWD = candidate.cwd,
                              !recordCWD.isEmpty,
                              Self.standardizedPath(recordCWD) == processStandardizedCWD
                        else { return false }
                        return !usedRecordURLs.contains(Self.canonicalURL(candidate.url).path)
                    }) {
                        record = candidate
                        usedRecordURLs.insert(Self.canonicalURL(candidate.url).path)
                        break
                    }
                }
            }

            let cwd = processCWD ?? record?.cwd
            let id = record?.id ?? "pid:\(process.pid)"
            let startedAt = record?.startedAt ?? process.startedAt

            // Provider-specific by design: this branch emits a Pi-family AgentSession with its fixed provider identity.
            sessions.append(AgentSession(
                id: id,
                provider: .pi,
                dialect: dialect,
                source: .cli,
                state: config.state(
                    lastActivityAt: record?.modifiedAt,
                    now: now,
                    hasLiveProcess: true),
                pid: process.pid,
                cwd: cwd,
                projectName: Self.projectName(cwd),
                sessionName: record?.sessionName,
                startedAt: startedAt,
                lastActivityAt: record?.modifiedAt,
                transcriptPath: record?.url.path,
                host: host))
        }

        var seen = Set<String>()
        return sessions
            .sorted { lhs, rhs in
                if lhs.state != rhs.state {
                    return lhs.state == .active
                }
                let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
                let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return (lhs.pid ?? Int32.min) > (rhs.pid ?? Int32.min)
            }
            .filter { seen.insert("\($0.host):\($0.id)").inserted }
    }

    private static func sessionRoots(
        for process: AgentProcessRecord,
        dialect: AgentSession.Dialect,
        cwd: String,
        environment: [String: String]) -> [SessionRoot]
    {
        // Provider-specific by design: Pi and OMP use different on-disk session-root contracts.
        switch dialect {
        case .pi:
            self.piSessionRootResolution(
                process: process,
                cwd: cwd,
                environment: environment).roots
        case .omp:
            self.ompSessionRoots(process: process, cwd: cwd, environment: environment)
        }
    }

    /// Resolves the same Pi-family roots used by live-session discovery for historical cost scans.
    /// Keeping this in one resolver prevents the menu and cost surfaces from silently reading different stores.
    static func costSessionRoots(
        environment: [String: String],
        baseDirectory: URL? = nil) -> [CostSessionRoot]
    {
        self.costSessionRoots(
            environment: environment,
            baseDirectories: baseDirectory.map { [$0] })
    }

    /// Resolves historical roots for every known Pi project directory. Project-level Pi settings are
    /// relative to the process working directory, so a single app-wide current directory is not enough
    /// when several Pi processes are active in different projects.
    static func costSessionRoots(
        environment: [String: String],
        baseDirectories: [URL]? = nil) -> [CostSessionRoot]
    {
        let cwdURLs = (baseDirectories?.isEmpty == false ? baseDirectories! : [URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)])
            .map(Self.canonicalURL)
        let uniqueCWDs = cwdURLs.reduce(into: [URL]()) { result, url in
            guard !result.contains(where: { $0.path == url.path }) else { return }
            result.append(url)
        }
        let process = AgentProcessRecord(pid: 0, ppid: 0, startedAt: nil, command: "")
        // Provider-specific by design: historical cost scans must resolve both Pi dialects through the shared root
        // resolver.
        let dialects: [AgentSession.Dialect] = [.pi, .omp]
        var output: [CostSessionRoot] = []
        var seen = Set<String>()

        for dialect in dialects {
            var roots: [SessionRoot] = []
            var rootResolutionIsComplete = true
            for cwdURL in uniqueCWDs {
                switch dialect {
                case .pi:
                    let resolution = Self.piSessionRootResolution(
                        process: process,
                        cwd: cwdURL.path,
                        environment: environment)
                    roots.append(contentsOf: resolution.roots)
                    rootResolutionIsComplete = rootResolutionIsComplete && resolution.isComplete
                case .omp:
                    let resolution = Self.ompSessionRootResolution(
                        process: process,
                        cwd: cwdURL.path,
                        environment: environment)
                    roots.append(contentsOf: resolution.roots)
                    rootResolutionIsComplete = rootResolutionIsComplete && resolution.profileDiscoveryIsComplete
                }
            }
            let hasExplicitSelection = Self.hasExplicitCostRootSelection(
                dialect: dialect,
                environment: environment)
            if roots.isEmpty, hasExplicitSelection {
                output.append(CostSessionRoot(
                    url: Self.unresolvedCostSessionRoot(for: dialect),
                    missingIsKnownEmpty: false,
                    resolutionIsComplete: false))
                continue
            }
            var seenDialectRoots = Set<String>()
            for root in roots {
                let canonical = Self.canonicalURL(root.url)
                guard seenDialectRoots.insert(canonical.path).inserted else { continue }
                guard seen.insert(canonical.path).inserted else { continue }
                let defaultRoot = Self.defaultCostSessionRoot(for: dialect, environment: environment)
                output.append(CostSessionRoot(
                    url: canonical,
                    missingIsKnownEmpty: !hasExplicitSelection && defaultRoot.map { $0 == canonical } == true,
                    resolutionIsComplete: true))
            }
            if !rootResolutionIsComplete {
                let unresolved = Self.unresolvedCostSessionRoot(for: dialect)
                guard seen.insert(unresolved.path).inserted else { continue }
                output.append(CostSessionRoot(
                    url: unresolved,
                    missingIsKnownEmpty: false,
                    resolutionIsComplete: false))
            }
        }
        return output
    }

    private static func unresolvedCostSessionRoot(for dialect: AgentSession.Dialect) -> URL {
        // Keep an unresolved selection visible to the cost scanner without ever enumerating a
        // real directory. The completion flag is the source of truth; this path is only a stable
        // cache-key component and a defensive placeholder.
        URL(fileURLWithPath: "/.codexbar-unresolved-\(dialect.rawValue)", isDirectory: true)
    }

    private static func defaultCostSessionRoot(
        for dialect: AgentSession.Dialect,
        environment: [String: String]) -> URL?
    {
        guard let home = homeURL(environment) else { return nil }
        // Provider-specific by design: Pi and OMP keep their default histories under distinct home directories.
        let directory = dialect == .pi ? ".pi" : ".omp"
        return Self.canonicalURL(
            home
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("agent", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true))
    }

    private static func hasExplicitCostRootSelection(
        dialect: AgentSession.Dialect,
        environment: [String: String]) -> Bool
    {
        // Provider-specific by design: these environment keys select Pi-family history roots rather than generic
        // policy.
        let keys: [String] = switch dialect {
        case .pi:
            ["PI_CODING_AGENT_SESSION_DIR", "PI_CODING_AGENT_DIR"]
        case .omp:
            [
                "PI_CODING_AGENT_SESSION_DIR",
                "PI_CONFIG_DIR",
                "PI_CODING_AGENT_DIR",
                "OMP_PROFILE",
                "PI_PROFILE",
            ]
        }
        return keys.contains { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func ompSessionRoots(
        process: AgentProcessRecord,
        cwd: String,
        environment: [String: String]) -> [SessionRoot]
    {
        self.ompSessionRootResolution(process: process, cwd: cwd, environment: environment).roots
    }

    private static func ompSessionRootResolution(
        process: AgentProcessRecord,
        cwd: String,
        environment: [String: String]) -> OMPSessionRootResolution
    {
        if let explicit = commandLineValue("--session-dir", in: process.command),
           let url = pathURL(explicit, cwd: cwd, home: environment["HOME"])
        {
            return OMPSessionRootResolution(
                roots: [SessionRoot(url: url, layout: .direct)],
                profileDiscoveryIsComplete: true)
        }
        if let configured = environment["PI_CODING_AGENT_SESSION_DIR"],
           let url = pathURL(configured, cwd: cwd, home: environment["HOME"])
        {
            return OMPSessionRootResolution(
                roots: [SessionRoot(url: url, layout: .direct)],
                profileDiscoveryIsComplete: true)
        }

        guard let home = homeURL(environment) else {
            return OMPSessionRootResolution(roots: [], profileDiscoveryIsComplete: false)
        }
        var safeEnvironment = ["HOME": home.path]
        for key in [
            "PI_CONFIG_DIR",
            "PI_CODING_AGENT_DIR",
            "XDG_DATA_HOME",
            "OMP_PROFILE",
            "PI_PROFILE",
        ] {
            safeEnvironment[key] = environment[key]
        }
        if let profile = Self.commandLineValue("--profile", in: process.command) {
            safeEnvironment["OMP_PROFILE"] = profile
        }

        let baseDirectory = URL(fileURLWithPath: cwd, isDirectory: true)
        var urls = OMPSessionRootResolver.sessionRoots(
            environment: safeEnvironment,
            baseDirectory: baseDirectory)
        var profileDiscoveryIsComplete = true

        if safeEnvironment["OMP_PROFILE"] == nil,
           safeEnvironment["PI_PROFILE"] == nil
        {
            let profileParents = [
                home
                    .appendingPathComponent(".omp", isDirectory: true)
                    .appendingPathComponent("profiles", isDirectory: true),
                Self.xdgDataHome(environment, home: home)
                    .appendingPathComponent("omp", isDirectory: true)
                    .appendingPathComponent("profiles", isDirectory: true),
            ]
            for parent in profileParents {
                let resolution = Self.profileSessionRoots(in: parent)
                urls.append(contentsOf: resolution.roots)
                profileDiscoveryIsComplete = profileDiscoveryIsComplete && resolution.isComplete
            }
        }

        var seen = Set<String>()
        let roots: [SessionRoot] = urls.compactMap { url in
            let canonical = Self.canonicalURL(url)
            guard seen.insert(canonical.path).inserted else { return nil }
            return SessionRoot(url: canonical, layout: .projectDirectories)
        }
        return OMPSessionRootResolution(
            roots: roots,
            profileDiscoveryIsComplete: profileDiscoveryIsComplete)
    }

    private static func piSessionRootResolution(
        process: AgentProcessRecord,
        cwd: String,
        environment: [String: String]) -> PiSessionRootResolution
    {
        if let explicit = commandLineValue("--session-dir", in: process.command) {
            guard let url = pathURL(explicit, cwd: cwd, home: environment["HOME"]) else {
                return PiSessionRootResolution(roots: [], isComplete: false)
            }
            return PiSessionRootResolution(
                roots: [SessionRoot(url: url, layout: .direct)],
                isComplete: true)
        }
        if let configured = environment["PI_CODING_AGENT_SESSION_DIR"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            guard let url = pathURL(configured, cwd: cwd, home: environment["HOME"]) else {
                return PiSessionRootResolution(roots: [], isComplete: false)
            }
            return PiSessionRootResolution(
                roots: [SessionRoot(url: url, layout: .direct)],
                isComplete: true)
        }
        if let agentDirectory = environment["PI_CODING_AGENT_DIR"],
           !agentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            guard let agentRoot = pathURL(agentDirectory, cwd: cwd, home: environment["HOME"]) else {
                return PiSessionRootResolution(roots: [], isComplete: false)
            }
            return PiSessionRootResolution(
                roots: [SessionRoot(
                    url: agentRoot.appendingPathComponent("sessions", isDirectory: true),
                    layout: .projectDirectories)],
                isComplete: true)
        }

        guard let home = Self.homeURL(environment) else {
            return PiSessionRootResolution(roots: [], isComplete: false)
        }
        // Provider-specific by design: Pi's settings paths are distinct from OMP's profile roots.
        let globalSettings = home
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("settings.json")
        let projectSettings = URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("settings.json")

        let configured: String?
        switch Self.sessionDirectoryResolution(in: projectSettings) {
        case let .configured(value):
            configured = value
        case .unavailable:
            return PiSessionRootResolution(roots: [], isComplete: false)
        case .missing, .noSessionDirectory:
            switch Self.sessionDirectoryResolution(in: globalSettings) {
            case let .configured(value):
                configured = value
            case .unavailable:
                return PiSessionRootResolution(roots: [], isComplete: false)
            case .missing, .noSessionDirectory:
                configured = nil
            }
        }

        if let configured {
            guard let url = Self.pathURL(configured, cwd: cwd, home: home.path) else {
                return PiSessionRootResolution(roots: [], isComplete: false)
            }
            return PiSessionRootResolution(
                roots: [SessionRoot(url: url, layout: .direct)],
                isComplete: true)
        }

        // Provider-specific by design: this path is Pi's default project session directory.
        return PiSessionRootResolution(
            roots: [SessionRoot(
                url: home
                    .appendingPathComponent(".pi", isDirectory: true)
                    .appendingPathComponent("agent", isDirectory: true)
                    .appendingPathComponent("sessions", isDirectory: true),
                layout: .projectDirectories)],
            isComplete: true)
    }

    private enum ProfileDirectoryInspection {
        case missing
        case readableDirectory
        case unavailable
    }

    private static func profileDirectoryInspection(_ url: URL) -> ProfileDirectoryInspection {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue,
              fileManager.isReadableFile(atPath: url.path)
        else {
            return .unavailable
        }
        return .readableDirectory
    }

    private static func profileSessionRoots(in profilesDirectory: URL) -> ProfileSessionRootResolution {
        switch self.profileDirectoryInspection(profilesDirectory) {
        case .missing:
            return ProfileSessionRootResolution(roots: [], isComplete: true)
        case .unavailable:
            return ProfileSessionRootResolution(roots: [], isComplete: false)
        case .readableDirectory:
            break
        }

        let profiles: [URL]
        do {
            profiles = try FileManager.default.contentsOfDirectory(
                at: profilesDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            return ProfileSessionRootResolution(roots: [], isComplete: false)
        }

        var roots: [URL] = []
        var isComplete = true
        let canonicalProfilesDirectory = Self.canonicalURL(profilesDirectory)
        for profile in profiles {
            guard roots.count < 64 else {
                isComplete = false
                break
            }
            let canonicalProfile = Self.canonicalURL(profile)
            guard OMPSessionRootResolver.isWithin(
                root: canonicalProfilesDirectory,
                candidate: canonicalProfile)
            else { continue }
            switch Self.profileDirectoryInspection(canonicalProfile) {
            case .missing, .unavailable:
                isComplete = false
                continue
            case .readableDirectory:
                break
            }
            let xdgLayout = canonicalProfile.appendingPathComponent("sessions", isDirectory: true)
            switch Self.profileDirectoryInspection(xdgLayout) {
            case .readableDirectory:
                roots.append(xdgLayout)
                continue
            case .unavailable:
                isComplete = false
            case .missing:
                break
            }
            let agentLayout = canonicalProfile
                .appendingPathComponent("agent", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            switch Self.profileDirectoryInspection(agentLayout) {
            case .readableDirectory:
                roots.append(agentLayout)
            case .unavailable:
                isComplete = false
            case .missing:
                break
            }
        }
        return ProfileSessionRootResolution(
            roots: roots.sorted { $0.path < $1.path },
            isComplete: isComplete)
    }

    private enum PiSettingsSessionDirectoryResolution {
        case missing
        case noSessionDirectory
        case configured(String)
        case unavailable
    }

    private static func sessionDirectoryResolution(in settingsURL: URL) -> PiSettingsSessionDirectoryResolution {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: settingsURL.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard !isDirectory.boolValue,
              let values = try? settingsURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= 1024 * 1024,
              let data = try? Data(contentsOf: settingsURL, options: [.mappedIfSafe]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .unavailable
        }
        guard let rawValue = object["sessionDir"] else { return .noSessionDirectory }
        guard let sessionDir = rawValue as? String,
              !sessionDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .unavailable
        }
        return .configured(sessionDir)
    }

    private static func commandLineValue(_ flag: String, in command: String) -> String? {
        let tokens = command.split(whereSeparator: \ .isWhitespace).map(String.init)
        for index in tokens.indices {
            if tokens[index] == flag, index + 1 < tokens.count {
                let value = tokens[index + 1]
                return value.hasPrefix("-") ? nil : value
            }
            let prefix = flag + "="
            if tokens[index].hasPrefix(prefix) {
                let value = String(tokens[index].dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func pathURL(_ path: String, cwd: String, home: String?) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded: String = if trimmed == "~", let home {
            home
        } else if trimmed.hasPrefix("~/"), let home {
            URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true).path
        } else {
            trimmed
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(expanded, isDirectory: true).standardizedFileURL
    }

    private static func homeURL(_ environment: [String: String]) -> URL? {
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
    }

    private static func xdgDataHome(_ environment: [String: String], home: URL) -> URL {
        if let configured = environment["XDG_DATA_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func records(
        in root: URL,
        now: Date,
        dialect: AgentSession.Dialect,
        layout: RootLayout,
        directoryBudget: inout DirectoryMetadataScanBudget) -> [PiFamilySessionRecord]
    {
        let fileManager = FileManager.default
        var records: [PiFamilySessionRecord] = []
        let canonicalRoot = Self.canonicalURL(root)

        guard directoryBudget.hasTimeRemaining() else { return [] }
        let projectDirectories: [URL]
        switch layout {
        case .direct:
            projectDirectories = [canonicalRoot]
        case .projectDirectories:
            let directories = directoryBudget.childDirectories(in: canonicalRoot, fileManager: fileManager)
            projectDirectories = directoryBudget.compactMapWhileTimeRemains(directories) { directory in
                let canonical = Self.canonicalURL(directory)
                return OMPSessionRootResolver.isWithin(root: canonicalRoot, candidate: canonical) ? canonical : nil
            }.sorted { $0.path < $1.path }
        }

        for projectDirectory in projectDirectories {
            guard directoryBudget.hasTimeRemaining() else { break }
            let entries = directoryBudget.files(in: projectDirectory, fileManager: fileManager)
            let files = directoryBudget.compactMapWhileTimeRemains(entries) { entry -> URL? in
                guard entry.pathExtension == "jsonl" else { return nil }
                let file = Self.canonicalURL(entry)
                guard OMPSessionRootResolver.isWithin(root: canonicalRoot, candidate: file),
                      Self.isDirectFile(in: file, projectDirectory: projectDirectory)
                else { return nil }
                return file
            }.sorted { $0.path < $1.path }

            for file in files {
                guard directoryBudget.hasTimeRemaining() else { break }
                guard let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                    values.isRegularFile == true,
                    let modifiedAt = values.contentModificationDate,
                    let record = PiFamilySessionFileParser.parse(
                        url: file,
                        dialect: dialect,
                        modifiedAt: modifiedAt,
                        now: now)
                else { continue }
                records.append(record)
            }
        }

        var seenURLs = Set<String>()
        var seenIDs = Set<String>()
        return records
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                if lhs.id != rhs.id {
                    return lhs.id < rhs.id
                }
                return lhs.url.path < rhs.url.path
            }
            .filter {
                seenURLs.insert(Self.canonicalURL($0.url).path).inserted &&
                    seenIDs.insert($0.id).inserted
            }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func projectName(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).standardizedFileURL.lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isDirectFile(in file: URL, projectDirectory: URL) -> Bool {
        file.deletingLastPathComponent().standardizedFileURL.path == projectDirectory.path
    }
}
