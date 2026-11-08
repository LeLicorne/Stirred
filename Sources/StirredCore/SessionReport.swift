import Foundation

// MARK: - Data

public struct SystemInfo: Codable, Sendable, Equatable {
    public var macOS: String
    public var chip: String
    public var memoryGB: Int
    public var lowPowerMode: Bool
    public var onBattery: Bool

    public init(macOS: String, chip: String, memoryGB: Int, lowPowerMode: Bool, onBattery: Bool) {
        self.macOS = macOS; self.chip = chip; self.memoryGB = memoryGB
        self.lowPowerMode = lowPowerMode; self.onBattery = onBattery
    }

    public static func current() -> SystemInfo {
        let power = PowerState.current
        return SystemInfo(
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            memoryGB: HardwareProfile.current.memoryGB,
            lowPowerMode: power.lowPowerMode, onBattery: power.onBattery)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public struct SessionSample: Codable, Sendable, Equatable {
    public var t: Double              // seconds since the game process appeared
    public var gpuPercent: Int?       // whole-GPU utilisation (all apps), from ioreg
    public var cpuPercent: Double     // summed over the game's processes; 100 = one full core (approximate)
    public var rssMB: Int
    public var processCount: Int

    public init(t: Double, gpuPercent: Int?, cpuPercent: Double, rssMB: Int, processCount: Int) {
        self.t = t; self.gpuPercent = gpuPercent; self.cpuPercent = cpuPercent
        self.rssMB = rssMB; self.processCount = processCount
    }
}

public struct SessionRecord: Codable, Sendable, Equatable {
    public var gameName: String
    public var store: String
    public var storeID: String
    public var backend: String
    public var latency: String
    public var engine: String
    public var processNeedle: String
    public var startedAt: Date
    public var endedAt: Date?
    public var environment: [String: String]
    public var planWarnings: [String]
    public var system: SystemInfo
    public var samples: [SessionSample]
    /// Folder name of the game under steamapps/common: used to tell this game's logs from other games'.
    public var installDirName: String? = nil
    /// True when Stirred itself started Steam for this session (so it may close it afterwards).
    public var startedSteam: Bool? = nil
}

// MARK: - Sampling

public enum SystemSampler {
    /// `ioreg -r -d 1 -w0 -c AGXAccelerator` output -> "Device Utilization %".
    public static func parseGPUUtilization(_ ioreg: String) -> Int? {
        guard let range = ioreg.range(of: #""Device Utilization %"=(\d+)"#, options: .regularExpression) else { return nil }
        return Int(ioreg[range].split(separator: "=").last ?? "")
    }

    /// `ps -Ao pcpu,rss,command` output -> totals over lines whose command contains `needle`.
    public static func parseProcesses(_ ps: String, containing needle: String) -> (count: Int, cpu: Double, rssMB: Int) {
        var count = 0, cpu = 0.0, rssKB = 0
        for line in ps.split(separator: "\n") where line.contains(needle) {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let c = Double(parts[0]), let r = Int(parts[1]) else { continue }
            count += 1; cpu += c; rssKB += r
        }
        return (count, cpu, rssKB / 1024)
    }

    public static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    public static func sample(processNeedle: String, at t: Double) -> SessionSample {
        let gpu = parseGPUUtilization(run("/usr/sbin/ioreg", ["-r", "-d", "1", "-w0", "-c", "AGXAccelerator"]))
        let procs = parseProcesses(run("/bin/ps", ["-Ao", "pcpu,rss,command"]), containing: processNeedle)
        return SessionSample(t: t, gpuPercent: gpu, cpuPercent: procs.cpu, rssMB: procs.rssMB, processCount: procs.count)
    }
}

// MARK: - Privacy

/// Removes the user's name and home path from text before it is stored in a report.
public struct Redactor: Sendable {
    public let home: String
    public let user: String

    public init(home: String = NSHomeDirectory(), user: String = NSUserName()) {
        self.home = home; self.user = user
    }

    public func redact(_ text: String) -> String {
        var out = text.replacingOccurrences(of: home, with: "~")
        out = out.replacingOccurrences(of: "/Users/\(user)", with: "/Users/<user>")
        if let regex = try? NSRegularExpression(pattern: #"(?i)(\\users\\)[^\\]+"#) {
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1<user>")
        }
        return out
    }
}

// MARK: - Log collection

public enum LogCollector {
    /// Last `maxBytes` of a file as text (NUL bytes removed: Unity logs contain some).
    public static func tail(_ url: URL, maxBytes: Int = 64_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
    }

    /// First `maxBytes` of a file as text (Unity prints the game's own folder in its first lines).
    public static func head(_ url: URL, maxBytes: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
    }

    public static func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// Files called `name` under `root`, modified at or after `date`.
    public static func files(named name: String, under root: URL, after date: Date, before end: Date = .distantFuture) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.lastPathComponent == name {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified >= date, modified <= end { found.append(url) }
        }
        return found
    }

    /// Files in `directory` (non-recursive) with the given extension, modified at or after `date`.
    public static func recentFiles(in directory: URL, extension ext: String? = nil, after date: Date, before end: Date = .distantFuture) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { url in
            guard ext == nil || url.pathExtension == ext else { return false }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (modified ?? .distantPast) >= date && (modified ?? .distantPast) <= end
        }
    }

    /// Lines that usually explain a problem: renderer init, crashes, exceptions, errors.
    public static func keyLines(in text: String, limit: Int = 14) -> [String] {
        let pattern = #"(?i)(Direct3D|Renderer:|Initialize engine|Crash|Exception|error|failed|OutOfMemory)"#
        return Array(text.split(separator: "\n").filter {
            $0.range(of: pattern, options: .regularExpression) != nil
        }.prefix(limit).map { String($0.prefix(220)) })
    }
}

// MARK: - Report

public enum ReportBuilder {
    public static func stats(_ values: [Double]) -> (avg: Double, max: Double)? {
        guard !values.isEmpty else { return nil }
        return (values.reduce(0, +) / Double(values.count), values.max() ?? 0)
    }

    /// Hints, not verdicts: they are derived from coarse samples.
    public static func findings(for record: SessionRecord, crashDetected: Bool, problems: [String: Int] = [:], extra: [String] = []) -> [String] {
        var out: [String] = extra
        if crashDetected { out.append("CRASH: a crash marker or a new crash dump was found (see excerpts).") }
        for (name, n) in problems.sorted(by: { $0.key < $1.key }) where n > 0 {
            out.append("\(n)x \(name) (MoltenVK/Metal limitation): some objects or effects may be missing or invisible.")
        }
        if record.system.lowPowerMode { out.append("Low Power Mode was ON: macOS caps CPU/GPU speed (measured ~25-30 FPS vs ~130 FPS).") }
        if record.system.onBattery { out.append("The Mac was on battery: performance is reduced.") }
        let live = record.samples.filter { $0.processCount > 0 }
        if live.count < 3 {
            out.append("Too few samples (\(live.count)) to judge performance. Run with --watch while playing.")
            return out
        }
        let gpu = stats(live.compactMap { $0.gpuPercent.map(Double.init) })
        let cpu = stats(live.map(\.cpuPercent))
        if let gpu, let cpu {
            if gpu.avg >= 85 {
                out.append("Probably GPU-bound (GPU avg \(Int(gpu.avg))%): lower resolution/graphics quality.")
            } else if cpu.avg >= 90 && gpu.avg < 60 {
                out.append("Probably CPU-bound (CPU avg \(Int(cpu.avg))% of one core, GPU avg \(Int(gpu.avg))%): Rosetta translation or the game's main thread.")
            } else if gpu.avg < 50 && cpu.avg < 90 {
                out.append("Neither CPU nor GPU is saturated (CPU \(Int(cpu.avg))%, GPU \(Int(gpu.avg))%): look at a frame cap, V-Sync, the present path, or a game waiting on I/O.")
            }
        }
        if let first = live.first, let last = live.last, last.rssMB > first.rssMB + 500 {
            out.append("Memory grew by \(last.rssMB - first.rssMB) MB during the session: possible leak or streaming.")
        }
        return out
    }

    /// Bullet lines under "## Findings" of a generated report.
    public static func findingsSection(of markdown: String) -> [String] {
        var inside = false
        var out: [String] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") { inside = line.hasPrefix("## Findings"); continue }
            if inside, line.hasPrefix("- ") { out.append(String(line.dropFirst(2))) }
        }
        return out
    }

    public static func markdown(
        record: SessionRecord, crashDetected: Bool, newDumps: [String],
        keyLines: [String], excerptNames: [String], problems: [String: Int] = [:], extra: [String] = []
    ) -> String {
        let live = record.samples.filter { $0.processCount > 0 }
        let duration = record.endedAt.map { Int($0.timeIntervalSince(record.startedAt)) }
        var md = "# Session report: \(record.gameName)\n\n"
        md += "| | |\n|---|---|\n"
        md += "| Game | \(record.gameName) (\(record.store) \(record.storeID)) |\n"
        md += "| Backend | \(record.backend) |\n| Latency profile | \(record.latency) |\n| Engine | \(record.engine) |\n"
        md += "| Duration | \(duration.map { "\($0) s" } ?? "n/a") |\n"
        md += "| Crash detected | \(crashDetected ? "YES" : "no") |\n\n"
        md += "## System\n\(record.system.chip), \(record.system.memoryGB) GB, macOS \(record.system.macOS)\n"
        md += "- Low Power Mode: \(record.system.lowPowerMode ? "ON" : "off")\n- On battery: \(record.system.onBattery ? "yes" : "no")\n\n"
        md += "## Findings\n"
        let found = findings(for: record, crashDetected: crashDetected, problems: problems, extra: extra)
        md += found.isEmpty ? "- Nothing notable.\n\n" : found.map { "- \($0)\n" }.joined() + "\n"
        md += "## Performance samples (\(live.count))\n"
        if let cpu = stats(live.map(\.cpuPercent)) { md += "- CPU of the game: avg \(Int(cpu.avg))%, max \(Int(cpu.max))% (100% = one core, approximate)\n" }
        if let gpu = stats(live.compactMap { $0.gpuPercent.map(Double.init) }) { md += "- GPU (whole machine): avg \(Int(gpu.avg))%, max \(Int(gpu.max))%\n" }
        if let mem = stats(live.map { Double($0.rssMB) }) { md += "- Memory: avg \(Int(mem.avg)) MB, max \(Int(mem.max)) MB\n" }
        md += "- FPS are not logged (DXVK only draws them on screen): use `--hud` and send a screenshot.\n\n"
        md += "## Plan\nEnvironment: " + (record.environment.isEmpty ? "(none)" : record.environment.sorted { $0.key < $1.key }.map { "`\($0.key)=\($0.value)`" }.joined(separator: " ")) + "\n"
        for warning in record.planWarnings { md += "- warning: \(warning)\n" }
        md += "\n## Key log lines\n"
        md += keyLines.isEmpty ? "(none)\n" : "```\n" + keyLines.joined(separator: "\n") + "\n```\n"
        if !newDumps.isEmpty { md += "\n## New crash dumps\n" + newDumps.map { "- \($0)\n" }.joined() }
        md += "\n## Files\n- session.json, samples.csv\n" + excerptNames.map { "- excerpts/\($0)\n" }.joined()
        return md
    }
}

// MARK: - Recorder

public struct SessionRecorder: Sendable {
    public let directory: URL
    public var record: SessionRecord

    public static func sessionsDirectory(_ paths: StirredPaths) -> URL {
        paths.logs.appendingPathComponent("sessions", isDirectory: true)
    }

    public static func begin(
        game: Game, plan: LaunchPlan, engine: String, processNeedle: String,
        paths: StirredPaths, system: SystemInfo = .current(), now: Date = Date()
    ) throws -> SessionRecorder {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = sessionsDirectory(paths)
            .appendingPathComponent("\(formatter.string(from: now))-\(game.storeID)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = SessionRecord(
            gameName: game.name, store: game.store, storeID: game.storeID,
            backend: plan.backend.rawValue, latency: plan.latency.rawValue, engine: engine,
            processNeedle: processNeedle, startedAt: now, endedAt: nil,
            environment: plan.environment, planWarnings: plan.warnings, system: system, samples: [],
            installDirName: game.installDirectory?.lastPathComponent)
        let recorder = SessionRecorder(directory: directory, record: record)
        try recorder.save()
        let latest = sessionsDirectory(paths).appendingPathComponent("latest")
        try? FileManager.default.removeItem(at: latest)
        try? FileManager.default.createSymbolicLink(at: latest, withDestinationURL: directory)
        return recorder
    }

    public static func load(_ directory: URL) throws -> SessionRecorder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        return SessionRecorder(directory: directory, record: try decoder.decode(SessionRecord.self, from: data))
    }

    public mutating func add(_ sample: SessionSample) { record.samples.append(sample) }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: directory.appendingPathComponent("session.json"))
    }

    /// Collects logs, writes `report.md`, `samples.csv`, `excerpts/*` and returns the report URL.
    @discardableResult
    public mutating func finish(paths: StirredPaths, prefix: URL, redactor: Redactor = Redactor(), now: Date = Date()) throws -> URL {
        if record.endedAt == nil { record.endedAt = now }   // regenerating an old report keeps its real end
        let until = (record.endedAt ?? now).addingTimeInterval(180)
        let fm = FileManager.default
        let steamRoot = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
        let since = record.startedAt.addingTimeInterval(-60)
        let excerptsDir = directory.appendingPathComponent("excerpts", isDirectory: true)
        try fm.createDirectory(at: excerptsDir, withIntermediateDirectories: true)

        var excerpts: [(name: String, text: String)] = []
        func add(_ name: String, _ url: URL, maxBytes: Int = 64_000) {
            if let text = LogCollector.tail(url, maxBytes: maxBytes) { excerpts.append((name, redactor.redact(text))) }
        }
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let stem = record.processNeedle.lowercased().replacingOccurrences(of: ".exe", with: "")
        var unityIndex = 0
        for log in LogCollector.files(named: "Player.log", under: users, after: since, before: until) {
            // Unity prints the game's own folder first: skip other games' logs.
            if let dir = record.installDirName, let head = LogCollector.head(log),
               !head.localizedCaseInsensitiveContains(dir) { continue }
            add("unity-Player\(unityIndex == 0 ? "" : "-\(unityIndex)").log", log)
            unityIndex += 1
        }
        add("steam-gameprocess_log.txt", steamRoot.appendingPathComponent("logs/gameprocess_log.txt"), maxBytes: 16_000)
        add("steam-console_log.txt", steamRoot.appendingPathComponent("logs/console_log.txt"), maxBytes: 16_000)
        for url in LogCollector.recentFiles(in: paths.logs.appendingPathComponent("dxvk"), extension: "log", after: since, before: until)
        where stem.isEmpty || url.lastPathComponent.lowercased().hasPrefix(stem) {
            add("dxvk-\(url.lastPathComponent)", url, maxBytes: 32_000)
        }

        // Only this game's crash dumps (Steam's own assert_steam/crash_steamsysinfo dumps are not the game's).
        let gameDumps = LogCollector.recentFiles(in: steamRoot.appendingPathComponent("dumps"), after: since, before: until)
            .map(\.lastPathComponent).filter { stem.isEmpty || $0.lowercased().contains(stem) }
        // Steam writes `assert_<exe>` dumps for non-fatal assertions (e.g. overlay): the game usually keeps running.
        let assertions = gameDumps.filter { $0.hasPrefix("assert_") }
        let dumps = gameDumps.filter { !$0.hasPrefix("assert_") }
        let extra = assertions.isEmpty ? [] : ["Steam recorded \(assertions.count) assertion dump(s) (\(assertions[0])). Usually non-fatal (the game keeps running); only a concern if the game also closed."]
        let crash = !dumps.isEmpty || excerpts.contains { $0.name.hasPrefix("unity-Player") && $0.text.contains("Crash!!!") }
        for (name, text) in excerpts { try text.write(to: excerptsDir.appendingPathComponent(name), atomically: true, encoding: .utf8) }

        let graphicsText = excerpts.filter { $0.name.hasPrefix("dxvk-") }.map(\.text).joined(separator: "\n")
        let problems = [
            "pipeline compile failures": LogCollector.count(of: "Failed to compile pipeline", in: graphicsText),
            "geometry-shader stream output unsupported": LogCollector.count(of: "Transform feedback not supported", in: graphicsText),
        ]

        var csv = "t,gpu_percent,cpu_percent,rss_mb,processes\n"
        for s in record.samples { csv += "\(String(format: "%.1f", s.t)),\(s.gpuPercent.map(String.init) ?? ""),\(String(format: "%.1f", s.cpuPercent)),\(s.rssMB),\(s.processCount)\n" }
        try csv.write(to: directory.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8)

        let unity = excerpts.first { $0.name.hasPrefix("unity-Player") }?.text ?? ""
        let md = ReportBuilder.markdown(
            record: record, crashDetected: crash, newDumps: dumps,
            keyLines: LogCollector.keyLines(in: unity), excerptNames: excerpts.map(\.name), problems: problems, extra: extra)
        let report = directory.appendingPathComponent("report.md")
        try md.write(to: report, atomically: true, encoding: .utf8)
        try save()
        return report
    }
}
