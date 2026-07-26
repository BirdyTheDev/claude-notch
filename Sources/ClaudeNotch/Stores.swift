import AppKit
import EventKit
import SwiftUI

// MARK: - Shelf

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

/// A temporary drop zone: park files in the notch, drag them out somewhere else.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    @Published private(set) var items: [ShelfItem] = []

    private let key = "shelfPaths"

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { ShelfItem(url: URL(fileURLWithPath: $0)) }
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(ShelfItem(url: url))
        }
        if items.count > 12 { items.removeFirst(items.count - 12) }
        persist()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: key)
    }
}

// MARK: - Timer

@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()

    enum Phase: String { case idle, focus, rest }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var total: TimeInterval = 1
    @Published private(set) var completedRounds = 0

    private var ticker: Timer?

    var isRunning: Bool { ticker != nil }
    /// Idle means an empty ring, not a full one.
    var progress: Double {
        guard phase != .idle, total > 0 else { return 0 }
        return 1 - remaining / total
    }

    var display: String {
        let seconds = Int(max(0, remaining.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func start(minutes: Double, phase: Phase = .focus) {
        self.phase = phase
        total = minutes * 60
        remaining = total
        resume()
    }

    func resume() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        ticker?.invalidate()
        ticker = nil
    }

    func stop() {
        pause()
        phase = .idle
        remaining = 0
        total = 1          // keeps the progress ring empty while idle
    }

    private func tick() {
        remaining -= 1
        guard remaining <= 0 else { return }
        pause()
        NSSound(named: "Glass")?.play()
        if phase == .focus {
            completedRounds += 1
            // The break is queued but not started.
            phase = .rest
            total = Prefs.shared.breakMinutes * 60
            remaining = total
        } else {
            stop()
        }
    }
}

// MARK: - Weather

struct WeatherSnapshot: Equatable {
    var city = ""
    var temperature: Double = 0
    var apparent: Double = 0
    var code: Int = 0
    var high: Double = 0
    var low: Double = 0
    var wind: Double = 0
    var updated: Date?

    var symbol: String {
        switch code {
        case 0: return "sun.max"
        case 1, 2: return "cloud.sun"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...57: return "cloud.drizzle"
        case 61...67, 80...82: return "cloud.rain"
        case 71...77, 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }

    var summary: String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Thunderstorm"
        default: return "—"
        }
    }
}

/// Keyless weather via open-meteo: geocode the city name, then fetch the forecast.
@MainActor
final class WeatherStore: ObservableObject {
    static let shared = WeatherStore()
    @Published private(set) var snapshot = WeatherSnapshot()
    @Published private(set) var error: String?

    private var lastCity = ""

    func refresh(city: String) async {
        let city = city.trimmingCharacters(in: .whitespaces)
        guard !city.isEmpty else { return }
        if lastCity == city, let updated = snapshot.updated, Date().timeIntervalSince(updated) < 900 { return }

        do {
            let geo = "https://geocoding-api.open-meteo.com/v1/search?name=\(city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? city)&count=1&language=en&format=json"
            let (geoData, _) = try await URLSession.shared.data(from: URL(string: geo)!)
            guard let geoJSON = try JSONSerialization.jsonObject(with: geoData) as? [String: Any],
                  let results = geoJSON["results"] as? [[String: Any]],
                  let place = results.first,
                  let lat = place["latitude"] as? Double,
                  let lon = place["longitude"] as? Double
            else {
                error = "City not found"
                return
            }

            let url = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1"
            let (data, _) = try await URLSession.shared.data(from: URL(string: url)!)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any] else { return }
            let daily = json["daily"] as? [String: Any]

            var snap = WeatherSnapshot()
            snap.city = (place["name"] as? String) ?? city
            snap.temperature = current["temperature_2m"] as? Double ?? 0
            snap.apparent = current["apparent_temperature"] as? Double ?? 0
            snap.code = current["weather_code"] as? Int ?? 0
            snap.wind = current["wind_speed_10m"] as? Double ?? 0
            snap.high = (daily?["temperature_2m_max"] as? [Double])?.first ?? 0
            snap.low = (daily?["temperature_2m_min"] as? [Double])?.first ?? 0
            snap.updated = Date()
            snapshot = snap
            lastCity = city
            error = nil
        } catch {
            self.error = "Could not load the forecast"
        }
    }
}

// MARK: - Calendar

struct AgendaItem: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color

    var timeLabel: String {
        if allDay { return "all day" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: start)
    }

    var relative: String {
        let minutes = Int(start.timeIntervalSinceNow / 60)
        if minutes < -1 { return "now" }
        if minutes < 60 { return "\(max(0, minutes))m" }
        return "\(minutes / 60)h"
    }
}

@MainActor
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()
    private let store = EKEventStore()

    @Published private(set) var events: [AgendaItem] = []
    @Published private(set) var authorized = false
    @Published private(set) var denied = false

    func requestAccess() async {
        do {
            authorized = try await store.requestFullAccessToEvents()
            denied = !authorized
        } catch {
            denied = true
            authorized = false
        }
        if authorized { refresh() }
    }

    func refreshIfAuthorized() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorized = status == .fullAccess
        denied = status == .denied || status == .restricted
        if authorized { refresh() }
    }

    private func refresh() {
        let now = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 24, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-1800), end: end, calendars: nil)
        events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map { event in
                AgendaItem(id: event.eventIdentifier ?? UUID().uuidString,
                           title: event.title ?? "(untitled)",
                           start: event.startDate,
                           end: event.endDate,
                           allDay: event.isAllDay,
                           color: Color(nsColor: event.calendar.color ?? .systemBlue))
            }
    }
}

// MARK: - Media

struct MediaSnapshot: Equatable {
    var title = ""
    var artist = ""
    var playing = false
    var available = false
}

/// Talks to Music.app over AppleScript. The first call raises the Automation prompt,
/// so nothing runs until the module is actually enabled.
@MainActor
final class MediaStore: ObservableObject {
    static let shared = MediaStore()
    @Published private(set) var snapshot = MediaSnapshot()

    /// Only talks to Music.app when something on screen actually shows it — otherwise the
    /// Automation prompt would appear at a random moment and osascript would run forever.
    func refresh(force: Bool = false) {
        guard force || Prefs.shared.peekLeft == .media || Prefs.shared.peekRight == .media else { return }
        let script = """
        if application "Music" is running then
            tell application "Music"
                if player state is playing or player state is paused then
                    return (name of current track) & "\\n" & (artist of current track) & "\\n" & (player state as text)
                end if
            end tell
        end if
        return ""
        """
        Task.detached {
            let output = Self.run(script)
            await MainActor.run {
                let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                var snap = MediaSnapshot()
                if lines.count >= 3 {
                    snap.title = lines[0]
                    snap.artist = lines[1]
                    snap.playing = lines[2].contains("playing")
                    snap.available = true
                }
                self.snapshot = snap
            }
        }
    }

    func toggle() { runAsync("tell application \"Music\" to playpause") }
    func next() { runAsync("tell application \"Music\" to next track") }
    func previous() { runAsync("tell application \"Music\" to previous track") }

    private func runAsync(_ script: String) {
        Task.detached { _ = Self.run(script); await MainActor.run { self.refresh() } }
    }

    nonisolated private static func run(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Quick commands

enum CommandRunner {
    @MainActor
    static func run(_ command: QuickCommand) {
        if command.inTerminal {
            Launcher.openShell(command: command.command)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command.command]
            do {
                try process.run()
            } catch {
                Launcher.onError?("Could not run the command")
            }
        }
    }
}
