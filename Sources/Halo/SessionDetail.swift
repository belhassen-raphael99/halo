import Foundation
import SwiftUI

/// What a session is asking or doing, in a few lines, read from the end of its transcript
/// (`~/.claude/projects/<folder>/<session id>.jsonl`). Local and read-only.
struct SessionDetail: Equatable, Sendable {
    /// "Question", "Autorisation demandée", "En ce moment", "Dernière réponse"…
    var title: String
    var lines: [String] = []
    /// A command or a path, shown in monospace.
    var code: String?
    /// The choices of a question, when Claude offered some.
    var options: [String] = []
}

enum SessionDetailReader {
    /// Reads the transcript's tail and describes its last step for the given state.
    /// Runs off the main thread: transcripts can weigh tens of megabytes.
    static func read(transcript: URL, state: SessionState, strings: Strings) -> SessionDetail? {
        for budget in [384 * 1_024, 2 * 1_024 * 1_024] {
            if let last = lastStep(in: transcript, tailBytes: budget) {
                return describe(last, state: state, s: strings)
            }
        }
        return nil
    }

    // MARK: - Transcript

    private enum Step {
        case tool(name: String, input: [String: Any])
        case text(String)
    }

    /// The last thing the main conversation did: a tool call, or a text reply.
    private static func lastStep(in url: URL, tailBytes: Int) -> Step? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // cut mid-line

        for line in lines.reversed() {
            guard line.contains("\"assistant\""),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "assistant",
                  json["isSidechain"] as? Bool != true,
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content.reversed() {
                switch block["type"] as? String {
                case "tool_use":
                    return .tool(name: block["name"] as? String ?? "?", input: block["input"] as? [String: Any] ?? [:])
                case "text":
                    if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .text(text)
                    }
                default:
                    continue
                }
            }
        }
        return nil
    }

    // MARK: - Wording

    private static func describe(_ step: Step, state: SessionState, s: Strings) -> SessionDetail {
        switch (state, step) {
        case (.needsYou, .tool("AskUserQuestion", let input)):
            let question = (input["questions"] as? [[String: Any]])?.first
            let options = (question?["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            return SessionDetail(title: s.questionForYou,
                                 lines: preview(question?["question"] as? String ?? "", maxLines: 3),
                                 options: Array(options.prefix(4)))
        case (.needsYou, .tool("ExitPlanMode", _)):
            return SessionDetail(title: s.planToApprove, lines: [s.planWaiting])
        case (.needsYou, .tool(let name, let input)):
            let action = toolAction(name: name, input: input, s: s)
            return SessionDetail(title: s.permissionRequested, lines: [action.verb], code: action.subject)
        case (.needsYou, .text(let text)):
            return SessionDetail(title: s.waitingReply, lines: preview(text, maxLines: 4))
        case (.working, .tool(let name, let input)):
            let action = toolAction(name: name, input: input, s: s)
            return SessionDetail(title: s.rightNow, lines: [action.verb], code: action.subject)
        case (.working, .text(let text)):
            return SessionDetail(title: s.writingReply, lines: preview(text, maxLines: 3))
        case (_, .text(let text)):
            return SessionDetail(title: s.lastReply, lines: preview(text, maxLines: 4))
        case (_, .tool(let name, let input)):
            let action = toolAction(name: name, input: input, s: s)
            return SessionDetail(title: s.lastAction, lines: [action.verb], code: action.subject)
        }
    }

    /// "Run a command" + "npm run build", "Edit a file" + "page.tsx"…
    private static func toolAction(name: String, input: [String: Any], s: Strings) -> (verb: String, subject: String?) {
        func file(_ key: String = "file_path") -> String? {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        switch name {
        case "Bash":
            // Claude's own description of the command, in whatever language it wrote it.
            let command = (input["command"] as? String)?.split(separator: "\n").first.map(String.init)
            return (input["description"] as? String ?? s.runCommand, command)
        case "Read": return (s.readFile, file())
        case "Edit", "MultiEdit": return (s.editFile, file())
        case "Write": return (s.writeFile, file())
        case "NotebookEdit": return (s.editNotebook, file("notebook_path"))
        case "Grep", "Glob": return (s.searchCode, input["pattern"] as? String)
        case "WebFetch": return (s.openWebPage, (input["url"] as? String).flatMap { URL(string: $0)?.host })
        case "WebSearch": return (s.searchWeb, input["query"] as? String)
        case "Task", "Agent": return (s.startAgent, input["description"] as? String)
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                return (s.connectedTool, parts.last.map(String.init))
            }
            return (s.useTool(name), nil)
        }
    }

    /// The first lines of a reply, without the Markdown symbols.
    private static func preview(_ text: String, maxLines: Int) -> [String] {
        // Code fences ("```text") are layout, not content.
        let lines = text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .map { line -> String in
            var cleaned = String(line)
            for symbol in ["**", "__", "`"] { cleaned = cleaned.replacingOccurrences(of: symbol, with: "") }
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            while let first = cleaned.first, "#>-*|".contains(first) {
                cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            return cleaned
        }
        .filter { !$0.isEmpty && !$0.allSatisfy { "-|: ".contains($0) } }
        return Array(lines.prefix(maxLines))
    }
}

/// Finds and caches transcripts, and the details read from them.
@MainActor
final class SessionDetailStore {
    static let shared = SessionDetailStore()

    private var paths: [String: URL] = [:]
    private var cache: [String: (key: String, detail: SessionDetail?)] = [:]
    private let projects = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    func detail(for session: Session, strings: Strings) async -> SessionDetail? {
        guard let transcriptId = session.transcriptId, let url = transcript(transcriptId) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(session.state)|\(strings.lang)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let cached = cache[session.id], cached.key == key { return cached.detail }
        let state = session.state
        let detail = await Task.detached(priority: .userInitiated) {
            SessionDetailReader.read(transcript: url, state: state, strings: strings)
        }.value
        cache[session.id] = (key, detail)
        return detail
    }

    func transcript(_ id: String) -> URL? {
        if let known = paths[id] { return known }
        let name = "\(id).jsonl"
        for folder in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            let candidate = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                paths[id] = candidate
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Card

/// The hover card: the session's name and state, then what it asks or does.
struct SessionCard: View {
    let session: Session
    let showDetails: Bool

    @State private var detail: SessionDetail?
    /// Snapshots give details directly instead of reading transcripts.
    @Environment(\.previewDetails) private var previewDetails
    @Environment(\.strings) private var strings

    var body: some View {
        let preset = previewDetails[session.id]
        let shown = preset ?? detail
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(session.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(strings.elapsed(sinceMs: session.stateSince))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize()
            }
            if showDetails, let shown {
                Text(shown.title.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(color)
                ForEach(Array(shown.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let code = shown.code {
                    Text(code)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                if !shown.options.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(shown.options, id: \.self) { option in
                            Label(option, systemImage: "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Text(strings.label(session.state))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: showDetails && shown != nil ? 290 : nil, alignment: .leading)
        .frame(maxWidth: 290)
        .background(GlassBackground(cornerRadius: 12))
        .environment(\.layoutDirection, strings.lang.layoutDirection)
        .task(id: "\(session.id)|\(session.state)|\(session.stateSince)|\(strings.lang)") {
            guard showDetails, preset == nil else { return }
            detail = await SessionDetailStore.shared.detail(for: session, strings: strings)
        }
    }

    private var color: Color {
        switch session.state {
        case .needsYou: return Palette.alert
        case .done: return Palette.done
        case .working: return Palette.aurora[2]
        case .rest: return .white.opacity(0.7)
        case .paused: return Color(white: 0.6)
        }
    }

    private var hint: String {
        switch session.state {
        case .needsYou: return strings.hintNeedsYou
        case .paused: return strings.hintPaused
        default: return strings.hintDefault
        }
    }

}
