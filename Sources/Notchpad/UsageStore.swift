import Foundation

struct DayUsage: Identifiable, Equatable, Codable {
    var id: String { day }
    let day: String            // yyyy-MM-dd
    var total: Int
    var messages: Int
}

struct UsageSnapshot: Equatable {
    var todayTotal = 0
    var todayOutput = 0
    var todayMessages = 0
    var todayByModel: [String: Int] = [:]
    var blockTotal = 0
    var blockMessages = 0
    var blockStart: Date?
    var lastUpdated: Date?

    /// Oldest → newest, always seven entries so the chart keeps its shape.
    var week: [DayUsage] = []
    var weekTotal = 0
    var weekMessages = 0
    var topProjects: [(name: String, total: Int)] = []

    var blockEnd: Date? { blockStart.map { $0.addingTimeInterval(5 * 3600) } }

    var blockRemaining: TimeInterval? {
        guard let end = blockEnd else { return nil }
        return max(0, end.timeIntervalSinceNow)
    }

    var blockProgress: Double {
        guard let start = blockStart else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(start) / (5 * 3600)))
    }

    var topModel: String? { todayByModel.max(by: { $0.value < $1.value })?.key }

    var dailyAverage: Int { week.isEmpty ? 0 : weekTotal / max(1, week.filter { $0.total > 0 }.count) }

    static func == (a: UsageSnapshot, b: UsageSnapshot) -> Bool {
        a.todayTotal == b.todayTotal && a.todayMessages == b.todayMessages
            && a.blockTotal == b.blockTotal && a.week == b.week
            && a.topProjects.map(\.name) == b.topProjects.map(\.name)
            && a.topProjects.map(\.total) == b.topProjects.map(\.total)
    }
}

private struct Entry: Codable {
    let date: Date
    let total: Int
    let output: Int
    let model: String
    let project: String
}

private struct UsageCache: Codable {
    static let schema = 2

    var schema = UsageCache.schema
    var offsets: [String: UInt64] = [:]
    var days: [String: DayUsage] = [:]
    var projectDays: [String: [String: Int]] = [:]      // project → day → tokens
    var modelDays: [String: [String: Int]] = [:]        // day → model → tokens
    var recent: [Entry] = []                            // last ~30h, for the 5h block
}

/// Reads token usage straight out of ~/.claude/projects/**.jsonl.
///
/// Files are tailed incrementally and the aggregate is cached on disk, so a restart
/// does not re-parse a week of transcripts (which is well over a hundred megabytes).
actor UsageStore {
    private let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    private var cache = UsageCache()
    private var seen: Set<String> = []
    private var loaded = false

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("usage-cache.json")
    }

    func refresh() -> UsageSnapshot {
        loadCacheIfNeeded()

        let entryCutoff = Date().addingTimeInterval(-30 * 3600)
        let dayCutoff = Calendar.current.date(byAdding: .day, value: -8, to: Date()) ?? Date()
        scan(since: dayCutoff)

        cache.recent.removeAll { $0.date < entryCutoff }
        let keepDays = Set((0..<9).compactMap { offset -> String? in
            Calendar.current.date(byAdding: .day, value: -offset, to: Date()).map { Self.dayFormatter.string(from: $0) }
        })
        cache.days = cache.days.filter { keepDays.contains($0.key) }
        cache.modelDays = cache.modelDays.filter { keepDays.contains($0.key) }
        for (project, days) in cache.projectDays {
            let kept = days.filter { keepDays.contains($0.key) }
            if kept.isEmpty { cache.projectDays.removeValue(forKey: project) } else { cache.projectDays[project] = kept }
        }
        persist()

        return snapshot()
    }

    // MARK: snapshot

    private func snapshot() -> UsageSnapshot {
        var snap = UsageSnapshot()
        let today = Self.dayFormatter.string(from: Date())

        if let day = cache.days[today] {
            snap.todayTotal = day.total
            snap.todayMessages = day.messages
        }
        snap.todayByModel = cache.modelDays[today] ?? [:]
        snap.todayOutput = cache.recent.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.output }

        // Seven fixed slots, oldest first, so the chart does not jump around.
        var week: [DayUsage] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = Self.dayFormatter.string(from: date)
            week.append(cache.days[key] ?? DayUsage(day: key, total: 0, messages: 0))
        }
        snap.week = week
        snap.weekTotal = week.reduce(0) { $0 + $1.total }
        snap.weekMessages = week.reduce(0) { $0 + $1.messages }

        let weekKeys = Set(week.map(\.day))
        snap.topProjects = cache.projectDays
            .map { project, days in
                (name: project, total: days.filter { weekKeys.contains($0.key) }.values.reduce(0, +))
            }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
            .prefix(4)
            .map { $0 }

        // Rolling 5h block: walk forward, starting a new block after a five-hour gap.
        let sorted = cache.recent.sorted { $0.date < $1.date }
        var blockStart: Date?
        var blockEntries: [Entry] = []
        for entry in sorted {
            if let start = blockStart, entry.date.timeIntervalSince(start) < 5 * 3600 {
                blockEntries.append(entry)
            } else {
                blockStart = floorToHour(entry.date)
                blockEntries = [entry]
            }
        }
        if let start = blockStart, Date().timeIntervalSince(start) < 5 * 3600 {
            snap.blockStart = start
            snap.blockTotal = blockEntries.reduce(0) { $0 + $1.total }
            snap.blockMessages = blockEntries.count
        }
        snap.lastUpdated = Date()
        return snap
    }

    private func floorToHour(_ date: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
    }

    // MARK: cache

    private func loadCacheIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(UsageCache.self, from: data),
              decoded.schema == UsageCache.schema
        else { return }
        cache = decoded
        // Offsets without aggregates would keep counting from the wrong baseline for ever;
        // a full re-parse takes well under a second, so prefer that over silent drift.
        if cache.days.isEmpty && !cache.offsets.isEmpty { cache.offsets = [:] }
    }

    private func persist() {
        // Request IDs are not persisted: a line can only be seen twice if bytes are
        // re-read, and the stored offsets already prevent that.
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: scanning

    private func scan(since cutoff: Date) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return }
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let modified = values?.contentModificationDate, modified >= cutoff else { continue }
                let size = UInt64(values?.fileSize ?? 0)
                let start = cache.offsets[file.path] ?? 0
                if size <= start { continue }
                cache.offsets[file.path] = parse(file: file, from: start, cutoff: cutoff)
            }
        }
        // Forget files that are gone or rotated away.
        cache.offsets = cache.offsets.filter { fm.fileExists(atPath: $0.key) }
    }

    /// Returns the offset consumed (a trailing partial line is left for the next pass).
    private func parse(file: URL, from start: UInt64, cutoff: Date) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return start }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return start }

        var slice = data[data.startIndex...]
        if slice.last != UInt8(ascii: "\n") {
            guard let lastNewline = slice.lastIndex(of: UInt8(ascii: "\n")) else { return start }
            slice = slice[slice.startIndex...lastNewline]
        }
        let consumed = start + UInt64(slice.count)
        let entryCutoff = Date().addingTimeInterval(-30 * 3600)

        for line in slice.split(separator: UInt8(ascii: "\n")) where line.count > 2 {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = obj["timestamp"] as? String,
                  let date = ISO8601DateFormatter.claude.date(from: stamp),
                  date >= cutoff
            else { continue }

            if let requestId = obj["requestId"] as? String {
                if seen.contains(requestId) { continue }
                seen.insert(requestId)
            }

            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let total = input + output + cacheWrite + cacheRead
            let model = (message["model"] as? String) ?? "unknown"
            let project = ((obj["cwd"] as? String).map { ($0 as NSString).lastPathComponent })
                ?? file.deletingLastPathComponent().lastPathComponent
            let day = Self.dayFormatter.string(from: date)

            var dayUsage = cache.days[day] ?? DayUsage(day: day, total: 0, messages: 0)
            dayUsage.total += total
            dayUsage.messages += 1
            cache.days[day] = dayUsage
            cache.projectDays[project, default: [:]][day, default: 0] += total
            cache.modelDays[day, default: [:]][model, default: 0] += total

            if date >= entryCutoff {
                cache.recent.append(Entry(date: date, total: total, output: output, model: model, project: project))
            }
        }
        return consumed
    }
}

extension ISO8601DateFormatter {
    static let claude: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

enum Fmt {
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(n) / 1_000_000)
        default: return String(format: "%.2fB", Double(n) / 1_000_000_000)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func model(_ id: String) -> String {
        id.replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    static func weekday(_ day: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US")
        out.dateFormat = "EEEEE"
        return out.string(from: date)
    }
}
