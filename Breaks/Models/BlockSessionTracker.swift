//
//  BlockSessionTracker.swift
//  Breaks
//
//  Explicit per-block session record: wall-clock start/end, pauses,
//  estimated idle, and result. The in-progress session persists so a
//  quit/restart doesn't lose it; the session ID prevents duplicate
//  exports after recovery.
//

import Foundation
import Combine

// MARK: - Session Record

enum BlockResult: String, Codable {
    case completed
    case messy
    case stopped
    case skipped
}

struct BlockSession: Codable, Identifiable {
    let id: UUID
    let label: String
    let startedAt: Date
    var endedAt: Date?
    var pausedSeconds: TimeInterval
    var pauseCount: Int
    var idleSeconds: TimeInterval
    var result: BlockResult?

    init(id: UUID = UUID(), label: String, startedAt: Date) {
        self.id = id
        self.label = label
        self.startedAt = startedAt
        self.endedAt = nil
        self.pausedSeconds = 0
        self.pauseCount = 0
        self.idleSeconds = 0
        self.result = nil
    }

    var focusSeconds: TimeInterval {
        guard let endedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(startedAt) - pausedSeconds - idleSeconds)
    }
}

// MARK: - Tracker

final class BlockSessionTracker: ObservableObject {
    @Published private(set) var current: BlockSession?
    /// Completed session waiting for the Good/Messy/Skipped resolution
    /// before its note entry is written.
    @Published private(set) var awaiting: BlockSession?

    private let ud = UserDefaults.shared
    private let sessionKey = "blockSession.current"
    private let awaitingKey = "blockSession.awaiting"
    private let exportedKey = "blockSession.exportedIDs"
    private let pendingKey = "blockSession.pendingExports"
    private var pauseStartedAt: Date?
    private var exportedIDs: Set<String>
    /// Sessions whose append failed; retried on the next successful write.
    @Published private(set) var pendingExports: [BlockSession]

    init() {
        exportedIDs = Set(ud.object(forKey: exportedKey) as? [String] ?? [])
        let decoder = JSONDecoder()
        pendingExports = (ud.data(forKey: pendingKey)).flatMap { try? decoder.decode([BlockSession].self, from: $0) } ?? []
        if let data = ud.data(forKey: sessionKey) {
            current = try? decoder.decode(BlockSession.self, from: data)
        }
        if let data = ud.data(forKey: awaitingKey) {
            awaiting = try? decoder.decode(BlockSession.self, from: data)
        }
    }

    func begin(label: String) {
        // A recovered in-progress session keeps its ID and timestamps.
        guard current == nil else { return }
        current = BlockSession(label: label, startedAt: Date())
        save()
    }

    func pause() {
        guard current != nil, pauseStartedAt == nil else { return }
        pauseStartedAt = Date()
        current?.pauseCount += 1
        save()
    }

    func resume() {
        guard let started = pauseStartedAt else { return }
        pauseStartedAt = nil
        current?.pausedSeconds += Date().timeIntervalSince(started)
        save()
    }

    /// Idle is an estimate: the app detects inactivity, not intent.
    func addIdle(_ seconds: TimeInterval) {
        guard current != nil else { return }
        current?.idleSeconds += seconds
        save()
    }

    @discardableResult
    func end(_ result: BlockResult) -> BlockSession? {
        guard var session = current else { return nil }
        if let started = pauseStartedAt {
            session.pausedSeconds += Date().timeIntervalSince(started)
            pauseStartedAt = nil
        }
        session.endedAt = Date()
        session.result = result
        current = nil
        save()
        return session
    }

    // MARK: Outcome staging
    func holdForOutcome(_ session: BlockSession) {
        awaiting = session
        saveAwaiting()
    }

    @discardableResult
    func takeAwaiting() -> BlockSession? {
        let session = awaiting
        awaiting = nil
        saveAwaiting()
        return session
    }

    // MARK: Export bookkeeping
    func alreadyExported(_ session: BlockSession) -> Bool {
        exportedIDs.contains(session.id.uuidString)
    }

    func markExported(_ session: BlockSession) {
        exportedIDs.insert(session.id.uuidString)
        ud.set(Array(exportedIDs), forKey: exportedKey)
        if !pendingExports.isEmpty {
            pendingExports.removeAll { $0.id == session.id }
            savePending()
        }
    }

    func queuePendingExport(_ session: BlockSession) {
        guard !pendingExports.contains(where: { $0.id == session.id }) else { return }
        pendingExports.append(session)
        savePending()
    }

    // MARK: Persistence
    private func save() {
        if let session = current, let data = try? JSONEncoder().encode(session) {
            ud.set(data, forKey: sessionKey)
        } else {
            ud.removeObject(forKey: sessionKey)
        }
    }

    private func saveAwaiting() {
        if let awaiting, let data = try? JSONEncoder().encode(awaiting) {
            ud.set(data, forKey: awaitingKey)
        } else {
            ud.removeObject(forKey: awaitingKey)
        }
    }

    private func savePending() {
        if let data = try? JSONEncoder().encode(pendingExports) {
            ud.set(data, forKey: pendingKey)
        }
    }
}
