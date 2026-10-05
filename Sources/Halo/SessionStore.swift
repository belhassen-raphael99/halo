import AppKit
import Foundation
import Observation

/// Builds the list of icons from two sources Claude already keeps on disk:
/// - `~/.claude/sessions/<pid>.json`: one file per running session, with its live
///   status (`busy` / `idle` / `waiting`). No hooks needed.
/// - the Desktop app's session files: titles, paused sessions, and `lastFocusedAt`,
///   which tells whether you have looked at a session since its turn ended.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [Session] = []
    /// Sessions you removed from the bar with ✕ (and that still exist).
    private(set) var hiddenCount = 0

    /// Live sessions first, then a divider, then paused ones.
    var strip: Strip {
        let live = sessions.filter(\.isLive).count
        return Strip(count: sessions.count, dividerBefore: live > 0 && live < sessions.count ? live : nil)
    }

    @ObservationIgnored var onChange: (() -> Void)?
    /// A session changed state (old, new): for the sounds.
    @ObservationIgnored var onStateChange: ((SessionState, SessionState) -> Void)?
    @ObservationIgnored private let settings: HaloSettings

    @ObservationIgnored private let registryDir: URL
    @ObservationIgnored private let desktopStoreDir: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var polling = true

    /// Session id → when you last looked at it through Halo or the Claude app (ms).
    @ObservationIgnored private var acknowledgedAt: [String: Double] = [:]
    /// Session id → last status seen, to catch the moment a turn ends.
    @ObservationIgnored private var previousStatus: [String: String] = [:]
    /// Session id → when its last turn ended (ms).
    @ObservationIgnored private var turnEnd: [String: Double] = [:]

    /// Session id → when you removed it from the bar (ms). It comes back on its own
    /// when you start a new turn in it.
    @ObservationIgnored private var hiddenAt: [String: Double] = [:]

    @ObservationIgnored private var desktop: [String: DesktopRecord] = [:]
    @ObservationIgnored private var desktopFiles: [URL: (modified: Date, id: String)] = [:]
    @ObservationIgnored private var lastDesktopScan = Date.distantPast

    private static let claudeBundleId = "com.anthropic.claudefordesktop"
    /// Status changes this soon after a process starts are its boot, not a turn.
    private static let bootGraceMs: Double = 15_000
    /// Paused sessions shown: active in the last 7 days, 6 at most.
    private static let hiddenKey = "halo.hidden"

    init(settings: HaloSettings) {
        self.settings = settings
        let home = FileManager.default.homeDirectoryForCurrentUser
        registryDir = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        desktopStoreDir = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// Fixed sessions, no polling: for snapshots.
    convenience init(preview: [Session]) {
        self.init(settings: HaloSettings(persistent: false))
        polling = false
        sessions = preview
    }

    /// Restores the sessions removed with ✕ in a previous run.
    func loadHidden() {
        hiddenAt = UserDefaults.standard.dictionary(forKey: Self.hiddenKey) as? [String: Double] ?? [:]
    }

    /// One pass over both sources, for `--dump`.
    func snapshot() -> [Session] {
        refresh()
        return sessions
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// You opened the session from Halo: whatever finished is now seen.
    func acknowledge(_ session: Session) {
        acknowledgedAt[session.id] = Self.nowMs
        refresh()
    }

    /// ✕ on the icon: take the session off the bar. Nothing changes in the Claude app.
    func hide(_ session: Session) {
        hiddenAt[session.id] = Self.nowMs
        saveHidden()
        refresh()
    }

    func unhideAll() {
        hiddenAt = [:]
        saveHidden()
        refresh()
    }

    private func saveHidden() {
        UserDefaults.standard.set(hiddenAt, forKey: Self.hiddenKey)
    }

    // MARK: - Refresh

    private func refresh() {
        guard polling else { return }
        if Date().timeIntervalSince(lastDesktopScan) >= 1 {
            scanDesktop()
            lastDesktopScan = Date()
        }
        let now = Self.nowMs

        // While the Claude app is in front, the session it shows (last focused) counts as seen.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.claudeBundleId,
           let current = desktop.values.filter({ !$0.archived }).max(by: { $0.lastFocusedAt < $1.lastFocusedAt }) {
            acknowledgedAt[current.id] = now
        }

        var live: [(started: Double, session: Session)] = []
        // Every running session, hidden ones included: those are never "paused".
        var runningIds = Set<String>()
        for entry in readRegistry() {
            let id = entry.hostSessionId ?? "pid-\(entry.pid)"
            runningIds.insert(id)
            let record = entry.hostSessionId.flatMap { desktop[$0] }
            let status = entry.status ?? "idle"
            let started = entry.startedAt ?? 0
            let since = entry.statusUpdatedAt ?? started

            if let previous = previousStatus[id], previous != "idle", status == "idle",
               since - started > Self.bootGraceMs {
                turnEnd[id] = since
            }
            previousStatus[id] = status

            if let hidden = hiddenAt[id] {
                if status != "idle" && since > hidden {
                    hiddenAt[id] = nil
                    saveHidden()
                } else {
                    continue
                }
            }

            let state: SessionState
            switch status {
            case "busy": state = .working
            case "waiting": state = .needsYou(reason: entry.waitingFor ?? "")
            default:
                let seen = max(record?.lastFocusedAt ?? 0, acknowledgedAt[id] ?? 0)
                if let end = turnEnd[id], end > seen { state = .done } else { state = .rest }
            }

            let folder = URL(fileURLWithPath: entry.cwd ?? "?").lastPathComponent
            let name = [entry.name, record?.title].compactMap { $0 }.first { !$0.isEmpty } ?? folder
            live.append((started, Session(
                id: id, pid: entry.pid, name: name, cwd: entry.cwd ?? "",
                isDesktop: entry.entrypoint == "claude-desktop", hostSessionId: entry.hostSessionId,
                transcriptId: entry.sessionId,
                state: state, stateSince: state == .done ? (turnEnd[id] ?? since) : since)))
        }
        live.sort { $0.started < $1.started }

        let pausedWindowMs = Double(settings.pausedDays) * 86_400_000
        let paused = !settings.showPaused ? [] : desktop.values
            .filter { !$0.archived && !runningIds.contains($0.id) && hiddenAt[$0.id] == nil
                && now - $0.lastActivityAt < pausedWindowMs }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(settings.pausedLimit)
            .map { record in
                Session(id: record.id, pid: nil,
                        name: record.title.isEmpty ? URL(fileURLWithPath: record.cwd).lastPathComponent : record.title,
                        cwd: record.cwd, isDesktop: true, hostSessionId: record.id,
                        transcriptId: record.cliSessionId,
                        state: .paused, stateSince: record.lastActivityAt)
            }

        for key in Set(previousStatus.keys).subtracting(runningIds) {
            previousStatus[key] = nil
            turnEnd[key] = nil
        }
        // Forget hidden sessions that no longer exist anywhere.
        let gone = hiddenAt.keys.filter { desktop[$0] == nil && !runningIds.contains($0) }
        if !gone.isEmpty {
            for key in gone { hiddenAt[key] = nil }
            saveHidden()
        }
        if hiddenCount != hiddenAt.count { hiddenCount = hiddenAt.count }

        let next = live.map(\.session) + paused
        if let onStateChange {
            let before = Dictionary(sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
            for session in next {
                if let old = before[session.id], old != session.state { onStateChange(old, session.state) }
            }
        }
        if next != sessions {
            sessions = next
            onChange?()
        }
    }

    // MARK: - Registry

    private struct RegistryEntry: Decodable {
        let pid: Int32
        let sessionId: String?
        let cwd: String?
        let name: String?
        let status: String?
        let waitingFor: String?
        let kind: String?
        let entrypoint: String?
        let hostSessionId: String?
        let startedAt: Double?
        let statusUpdatedAt: Double?
    }

    private func readRegistry() -> [RegistryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: registryDir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> RegistryEntry? in
                guard let data = try? Data(contentsOf: url),
                      let entry = try? decoder.decode(RegistryEntry.self, from: data) else { return nil }
                guard entry.kind == nil || entry.kind == "interactive" else { return nil }
                return Self.isAlive(entry.pid) ? entry : nil
            }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Desktop app session files

    private struct DesktopRecord {
        let id: String
        let cliSessionId: String?
        let title: String
        let cwd: String
        let archived: Bool
        let lastActivityAt: Double
        let lastFocusedAt: Double
    }

    /// Re-reads only the files whose modification date changed. The fields we need sit
    /// in the first few hundred bytes, so we read the head only (files weigh ~500 KB).
    private func scanDesktop() {
        let fm = FileManager.default
        var present = Set<URL>()
        for level1 in (try? fm.contentsOfDirectory(at: desktopStoreDir, includingPropertiesForKeys: nil)) ?? [] {
            for level2 in (try? fm.contentsOfDirectory(at: level1, includingPropertiesForKeys: nil)) ?? [] {
                let files = (try? fm.contentsOfDirectory(
                    at: level2, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    present.insert(file)
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    if desktopFiles[file]?.modified == modified { continue }
                    guard let record = Self.readRecord(file) else { continue }
                    desktop[record.id] = record
                    desktopFiles[file] = (modified, record.id)
                }
            }
        }
        for (file, entry) in desktopFiles where !present.contains(file) {
            desktop[entry.id] = nil
            desktopFiles[file] = nil
        }
    }

    private static func readRecord(_ url: URL) -> DesktopRecord? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8_192) else { return nil }
        let text = String(decoding: head, as: UTF8.self)
        guard let id = text.firstMatch(of: /"sessionId"\s*:\s*"(local_[A-Za-z0-9-]+)"/)?.1 else { return nil }
        return DesktopRecord(
            id: String(id),
            cliSessionId: text.firstMatch(of: /"cliSessionId"\s*:\s*"([A-Za-z0-9-]+)"/).map { String($0.1) },
            title: string(text.firstMatch(of: /"title"\s*:\s*"((?:[^"\\]|\\.)*)"/)?.1),
            cwd: string(text.firstMatch(of: /"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/)?.1),
            archived: text.firstMatch(of: /"isArchived"\s*:\s*(true|false)/)?.1 == "true",
            lastActivityAt: Double(text.firstMatch(of: /"lastActivityAt"\s*:\s*(\d+)/)?.1 ?? "") ?? 0,
            lastFocusedAt: Double(text.firstMatch(of: /"lastFocusedAt"\s*:\s*(\d+)/)?.1 ?? "") ?? 0)
    }

    /// Decodes a JSON string body (escapes included).
    private static func string(_ raw: Substring?) -> String {
        guard let raw else { return "" }
        return (try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))) ?? String(raw)
    }

    private static var nowMs: Double { Date().timeIntervalSince1970 * 1_000 }
}
