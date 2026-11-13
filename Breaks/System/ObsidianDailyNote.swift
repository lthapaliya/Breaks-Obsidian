//
//  ObsidianDailyNote.swift
//  Breaks
//
//  Sandboxed access to an Obsidian vault via security-scoped bookmark,
//  plus live appends to a single PomoLogger.md. Each day gets a
//  "## <date>" heading; entries nest under it. Write failures surface
//  via lastError and queue the session for retry instead of dropping it.
//

import Foundation
import AppKit
import Combine

// MARK: - Vault Access

final class ObsidianVaultStore: ObservableObject {
    static let logFilename = "PomoLogger.md"

    @Published private(set) var vaultURL: URL?
    @Published var lastError: String?

    private let ud = UserDefaults.shared
    private let bookmarkKey = "obsidianVaultBookmark"
    private var accessedURL: URL?

    init() { restoreAccess() }

    deinit { accessedURL?.stopAccessingSecurityScopedResource() }

    /// Let the user pick the vault folder; retain access with a bookmark.
    func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Obsidian Vault"
        panel.message = "Breaks will append completed focus blocks to \(Self.logFilename) here."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try url.bookmarkData(options: .withSecurityScope)
            ud.set(data, forKey: bookmarkKey)
        } catch {
            lastError = "Couldn't save vault access: \(error.localizedDescription)"
            return
        }
        applyResolved(url)
    }

    func restoreAccess() {
        guard let data = ud.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data,
                              options: [.withoutUI],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                ud.set(fresh, forKey: bookmarkKey)
            }
            applyResolved(url)
        } catch {
            lastError = "Couldn't reopen vault access: \(error.localizedDescription)"
        }
    }

    func logURL() -> URL? {
        vaultURL?.appendingPathComponent(Self.logFilename)
    }

    /// Append an entry under its day's heading, creating the file (and
    /// the heading) when missing. Day grouping is derived from the file
    /// itself, so it stays correct across restarts and date rollovers.
    func appendEntry(_ markdown: String, day: Date, to url: URL) throws {
        let heading = Self.dayHeading(for: day)
        let fm = FileManager.default
        let block = markdown + "\n"
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (heading + "\n\n" + block).write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        let lastHeading = content.components(separatedBy: .newlines).last(where: { $0.hasPrefix("## ") })
        let prefix = (lastHeading == heading) ? "\n" : "\n\n" + heading + "\n\n"
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((prefix + block).utf8))
        try? handle.close()
    }

    static func dayHeading(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "## EEEE, MMM d, yyyy"
        return formatter.string(from: date)
    }

    // MARK: Internals
    private func applyResolved(_ url: URL) {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        guard url.startAccessingSecurityScopedResource() else {
            lastError = "macOS denied access to the selected vault."
            vaultURL = nil
            return
        }
        accessedURL = url
        vaultURL = url
        lastError = nil
    }
}

// MARK: - Entry Rendering

enum DailyNoteEntry {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func markdown(for session: BlockSession) -> String {
        let end = session.endedAt ?? Date()
        let min = { (t: TimeInterval) in Int((t / 60).rounded()) }
        let result = session.result?.rawValue ?? "stopped"
        var lines: [String] = []
        lines.append("### \(time.string(from: session.startedAt))–\(time.string(from: end)) — \(session.label)")
        lines.append("  - Started: \(time.string(from: session.startedAt))")
        lines.append("  - Ended: \(time.string(from: end))")
        lines.append("  - Focus time: \(min(session.focusSeconds)) min")
        lines.append("  - Idle detected: \(min(session.idleSeconds)) min")
        lines.append("  - Paused: \(min(session.pausedSeconds)) min")
        lines.append("  - Result: \(result)")
        return lines.joined(separator: "\n")
    }
}
