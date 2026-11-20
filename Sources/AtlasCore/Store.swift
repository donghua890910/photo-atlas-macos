import Foundation
import CSQLite
import Darwin

public enum WriteState: String, Sendable {
    case pending, writing, needsVerification = "needs_verification", verified, blocked
}

public struct CachedResult: Sendable {
    public let description: String
    public let keywords: [String]
    public let sensitive: Bool
    public let category: String?
    public let origin: String
    public let writeState: WriteState
}

public struct MetadataSnapshot {
    public let description: String
    public let keywords: [String]
}

public struct WriteReceipt: Sendable {
    public let description: String
    public let keywords: [String]
    public let addedKeywords: [String]
    public let status: String
}

public enum TaskKind: String, Sendable { case ai, gps, write }
public struct ClaimedTask: Sendable {
    public let id: Int64
    public let assetID: String
    public let kind: TaskKind
    public let token: String
}

public struct PeopleWriteOperation: Sendable {
    public let id: String
    public let assetID: String
    public let beforeDescription: String
    public let beforeKeywords: [String]
    public let addedKeywords: [String]
    public let afterKeywords: [String]?
    public let writeReturned: Bool
    public let undoEligible: Bool
    public let state: String
}

public struct LegacySuggestion: Sendable {
    public let source: String
    public let line: Int
    public let result: AIResult
}

public struct DashboardStats: Sendable {
    public let aiCached: Int
    public let verifiedWrites: Int
    public let sensitive: Int
    public let pendingWrites: Int
    public let needsVerification: Int
}

public struct ScanProgress: Sendable {
    public let enabled: Bool
    public let pending: Int
    public let running: Int
    public let done: Int
    public let skipped: Int
    public let pendingIndex: Int
    public let runningIndex: Int
    public let indexed: Int
    public let pendingWrites: Int
    public let runningWrites: Int
    public let uncertainWrites: Int
    public var outstanding: Int { pending + running + pendingIndex + runningIndex + pendingWrites + runningWrites }
}

public struct LegacyRecord {
    public let source: String
    public let aiState: String?
    public let gpsState: String?
    public var verified: Bool { false }
}

public enum StoreError: Error {
    case database(String)
    case invalidInput
    case invalidTransition
    case unsupportedVersion
}

public final class Store {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let db { sqlite3_close(db) }
            db = nil
            throw StoreError.database(message)
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(db, 5000)
            let version = try scalarInt("PRAGMA user_version")
            guard version <= 20 else { throw StoreError.unsupportedVersion }
            if version > 0 && version < 20 { try backupBeforeMigration(url: url, version: version) }
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            if version == 0 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE results (
                    asset_id TEXT PRIMARY KEY NOT NULL,
                    description TEXT NOT NULL,
                    keywords TEXT NOT NULL,
                    sensitive INTEGER NOT NULL CHECK(sensitive IN (0,1)),
                    write_state TEXT NOT NULL CHECK(write_state IN ('pending','writing','needs_verification','verified','blocked')),
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                PRAGMA user_version=1;
                COMMIT;
                """)
            }
            if version < 2 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE legacy_records (
                    source TEXT NOT NULL, asset_id TEXT NOT NULL, filename TEXT,
                    ai_state TEXT, gps_state TEXT,
                    PRIMARY KEY(source, asset_id)
                );
                PRAGMA user_version=2;
                COMMIT;
                """)
            }
            if version < 3 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE write_snapshots (
                    asset_id TEXT PRIMARY KEY NOT NULL,
                    description TEXT NOT NULL,
                    keywords TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                PRAGMA user_version=3;
                COMMIT;
                """)
            }
            if version < 4 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE write_receipts (
                    asset_id TEXT PRIMARY KEY NOT NULL,
                    description TEXT NOT NULL,
                    keywords TEXT NOT NULL,
                    added_keywords TEXT NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('ready','undoing','undone','needs_review'))
                );
                PRAGMA user_version=4;
                COMMIT;
                """)
            }
            if version < 5 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE tasks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, asset_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('ai','gps','write')),
                    state TEXT NOT NULL CHECK(state IN ('pending','running','done','needs_verification')),
                    priority INTEGER NOT NULL, token TEXT, lease_expires INTEGER,
                    UNIQUE(asset_id,kind)
                );
                CREATE INDEX tasks_ready ON tasks(state, priority DESC, id);
                PRAGMA user_version=5;
                COMMIT;
                """)
            }
            if version < 6 {
                try execute("""
                BEGIN IMMEDIATE;
                ALTER TABLE tasks ADD COLUMN next_attempt INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE tasks ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
                PRAGMA user_version=6;
                COMMIT;
                """)
            }
            if version < 7 {
                try execute("""
                BEGIN IMMEDIATE;
                DROP INDEX tasks_ready;
                ALTER TABLE tasks RENAME TO old_tasks;
                CREATE TABLE tasks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, asset_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('ai','gps','write')),
                    state TEXT NOT NULL CHECK(state IN ('pending','running','done','needs_verification','no_local_preview')),
                    priority INTEGER NOT NULL, token TEXT, lease_expires INTEGER,
                    next_attempt INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(asset_id,kind)
                );
                INSERT INTO tasks(id,asset_id,kind,state,priority,token,lease_expires,next_attempt,attempts)
                  SELECT id,asset_id,kind,state,priority,token,lease_expires,next_attempt,attempts FROM old_tasks;
                DROP TABLE old_tasks;
                CREATE INDEX tasks_ready ON tasks(state, priority DESC, id);
                PRAGMA user_version=7;
                COMMIT;
                """)
            }
            if version < 8 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE legacy_results (
                    source TEXT NOT NULL, line INTEGER NOT NULL, asset_id TEXT NOT NULL,
                    payload TEXT NOT NULL, PRIMARY KEY(source,line)
                );
                CREATE INDEX legacy_results_asset ON legacy_results(asset_id);
                PRAGMA user_version=8;
                COMMIT;
                """)
            }
            if version < 9 {
                try execute("""
                BEGIN IMMEDIATE;
                ALTER TABLE results ADD COLUMN category TEXT;
                PRAGMA user_version=9;
                COMMIT;
                """)
            }
            if version < 10 {
                try execute("""
                BEGIN IMMEDIATE;
                ALTER TABLE results ADD COLUMN origin TEXT NOT NULL DEFAULT 'current';
                PRAGMA user_version=10;
                COMMIT;
                """)
            }
            if version < 11 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE person_candidates (
                    asset_id TEXT PRIMARY KEY NOT NULL, names TEXT NOT NULL,
                    source TEXT NOT NULL DEFAULT 'photos_index',
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                PRAGMA user_version=11;
                COMMIT;
                """)
            }
            if version < 12 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE people_operations (
                    id TEXT PRIMARY KEY NOT NULL, asset_id TEXT NOT NULL,
                    before_description TEXT NOT NULL, before_keywords TEXT NOT NULL,
                    added_keywords TEXT NOT NULL, after_keywords TEXT,
                    state TEXT NOT NULL CHECK(state IN ('prepared','writing','needs_verification','verified')),
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE UNIQUE INDEX people_one_active ON people_operations(asset_id)
                    WHERE state IN ('prepared','writing','needs_verification');
                PRAGMA user_version=12;
                COMMIT;
                """)
            }
            if version < 13 {
                try execute("""
                BEGIN IMMEDIATE;
                DROP INDEX people_one_active;
                ALTER TABLE people_operations RENAME TO old_people_operations;
                CREATE TABLE people_operations (
                    id TEXT PRIMARY KEY NOT NULL, asset_id TEXT NOT NULL,
                    before_description TEXT NOT NULL, before_keywords TEXT NOT NULL,
                    added_keywords TEXT NOT NULL, after_keywords TEXT,
                    state TEXT NOT NULL CHECK(state IN ('prepared','writing','needs_verification','verified','undoing','undo_uncertain','undone')),
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                INSERT INTO people_operations(rowid,id,asset_id,before_description,before_keywords,added_keywords,after_keywords,state,created_at)
                    SELECT rowid,id,asset_id,before_description,before_keywords,added_keywords,after_keywords,state,created_at FROM old_people_operations;
                DROP TABLE old_people_operations;
                CREATE UNIQUE INDEX people_one_active ON people_operations(asset_id)
                    WHERE state IN ('prepared','writing','needs_verification','undoing','undo_uncertain');
                PRAGMA user_version=13;
                COMMIT;
                """)
            }
            if version < 14 {
                try execute("""
                BEGIN IMMEDIATE;
                ALTER TABLE people_operations ADD COLUMN write_returned INTEGER NOT NULL DEFAULT 0 CHECK(write_returned IN (0,1));
                ALTER TABLE people_operations ADD COLUMN undo_eligible INTEGER NOT NULL DEFAULT 0 CHECK(undo_eligible IN (0,1));
                PRAGMA user_version=14;
                COMMIT;
                """)
            }
            if version < 15 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE location_candidates (
                    asset_id TEXT PRIMARY KEY NOT NULL, status TEXT NOT NULL,
                    keywords TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'photos_reverse_geolocation',
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                PRAGMA user_version=15;
                COMMIT;
                """)
            }
            if version < 16 {
                try execute("""
                BEGIN IMMEDIATE;
                ALTER TABLE people_operations ADD COLUMN source TEXT NOT NULL DEFAULT 'people' CHECK(source IN ('people','location'));
                PRAGMA user_version=16;
                COMMIT;
                """)
            }
            if version < 17 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE scan_control(id INTEGER PRIMARY KEY CHECK(id=1),enabled INTEGER NOT NULL CHECK(enabled IN (0,1)));
                INSERT INTO scan_control VALUES(1,0);
                PRAGMA user_version=17;
                COMMIT;
                """)
            }
            if version < 18 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE privacy_decisions(asset_id TEXT PRIMARY KEY NOT NULL,source TEXT NOT NULL CHECK(source='manual'),
                    cancelled_writes INTEGER NOT NULL,cancelled_metadata INTEGER NOT NULL,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
                PRAGMA user_version=18;
                COMMIT;
                """)
            }
            if version < 19 {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE automatic_writes(asset_id TEXT PRIMARY KEY NOT NULL);
                PRAGMA user_version=19;
                COMMIT;
                """)
            }
            if version < 20 {
                try execute("""
                BEGIN IMMEDIATE;
                UPDATE results SET write_state='pending'
                WHERE write_state='blocked' AND sensitive=1
                    AND NOT EXISTS (SELECT 1 FROM privacy_decisions p WHERE p.asset_id=results.asset_id);
                PRAGMA user_version=20;
                COMMIT;
                """)
            }
            try execute("CREATE INDEX IF NOT EXISTS tasks_ready_fair ON tasks(state, priority DESC, attempts, id)")
            try execute("CREATE INDEX IF NOT EXISTS tasks_ready_by_kind ON tasks(kind, state, priority DESC, attempts, id)")
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    public func statistics() throws -> DashboardStats {
        let stmt = try prepare("""
        SELECT count(*),
          coalesce(sum(CASE WHEN write_state='verified' AND NOT EXISTS (SELECT 1 FROM write_receipts WHERE write_receipts.asset_id=results.asset_id AND status='undone') THEN 1 ELSE 0 END),0),
          coalesce(sum(CASE WHEN sensitive=1 THEN 1 ELSE 0 END),0),
          coalesce(sum(CASE WHEN write_state='pending' THEN 1 ELSE 0 END),0),
          coalesce(sum(CASE WHEN write_state IN ('writing','needs_verification') THEN 1 ELSE 0 END),0)
        FROM results
        """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw dbError() }
        return DashboardStats(aiCached: Int(sqlite3_column_int64(stmt, 0)), verifiedWrites: Int(sqlite3_column_int64(stmt, 1)),
                              sensitive: Int(sqlite3_column_int64(stmt, 2)), pendingWrites: Int(sqlite3_column_int64(stmt, 3)),
                              needsVerification: Int(sqlite3_column_int64(stmt, 4)))
    }

    public func cache(assetID: String, description: String, keywords: [String], sensitive: Bool, category: String? = nil, origin: String = "current") throws {
        guard !origin.isEmpty, origin.utf8.count <= 256, !origin.contains("\0"), !assetID.isEmpty, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !keywords.isEmpty, (category?.count ?? 0) <= 50, keywords.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw StoreError.invalidInput
        }
        let data = try JSONEncoder().encode(keywords)
        let classifiedSensitive = sensitive || SensitiveContent.requiresReview(description: description, keywords: keywords, category: category)
        let encoded = String(decoding: data, as: UTF8.self)
        let stmt = try prepare("INSERT INTO results(asset_id,description,keywords,sensitive,write_state,category,origin) VALUES(?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        try bind(description, to: stmt, at: 2)
        try bind(encoded, to: stmt, at: 3)
        guard sqlite3_bind_int(stmt, 4, classifiedSensitive ? 1 : 0) == SQLITE_OK else { throw dbError() }
        try bind("pending", to: stmt, at: 5)
        if let category { try bind(category, to: stmt, at: 6) }
        else if sqlite3_bind_null(stmt, 6) != SQLITE_OK { throw dbError() }
        try bind(origin, to: stmt, at: 7)
        try stepDone(stmt)
    }

    /// Cancels only unstarted operations and records the manual decision in one transaction.
    public func markPendingSensitive(assetID: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let update = try prepare("UPDATE results SET sensitive=1,write_state='blocked',updated_at=CURRENT_TIMESTAMP WHERE asset_id=? AND write_state='pending' AND NOT EXISTS (SELECT 1 FROM people_operations o WHERE o.asset_id=results.asset_id AND o.state IN ('writing','needs_verification','undoing','undo_uncertain')) AND NOT EXISTS (SELECT 1 FROM tasks t WHERE t.asset_id=results.asset_id AND t.kind='write' AND t.state IN ('running','needs_verification'))")
            defer { sqlite3_finalize(update) }
            try bind(assetID, to: update, at: 1)
            try stepDone(update)
            guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
            let cancel = try prepare("DELETE FROM tasks WHERE asset_id=? AND kind='write' AND state='pending'")
            defer { sqlite3_finalize(cancel) }
            try bind(assetID, to: cancel, at: 1)
            try stepDone(cancel)
            let writes = sqlite3_changes(db)
            try removeAutomaticWrite(assetID: assetID)
            let cancelledWrites = writes + sqlite3_changes(db)
            let metadata = try prepare("DELETE FROM people_operations WHERE asset_id=? AND state='prepared'")
            defer { sqlite3_finalize(metadata) }
            try bind(assetID, to: metadata, at: 1)
            try stepDone(metadata)
            let operations = sqlite3_changes(db)
            let audit = try prepare("INSERT INTO privacy_decisions(asset_id,source,cancelled_writes,cancelled_metadata) VALUES(?,'manual',?,?)")
            defer { sqlite3_finalize(audit) }
            try bind(assetID, to: audit, at: 1)
            guard sqlite3_bind_int(audit, 2, cancelledWrites) == SQLITE_OK, sqlite3_bind_int(audit, 3, operations) == SQLITE_OK else { throw dbError() }
            try stepDone(audit)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func hasManualPrivacyDecision(assetID: String) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM privacy_decisions WHERE asset_id=?")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        let code = sqlite3_step(stmt)
        if code == SQLITE_ROW { return true }
        guard code == SQLITE_DONE else { throw dbError() }
        return false
    }

    public func editPending(assetID: String, description: String, keywords: [String]) throws {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let words = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !description.isEmpty, description.count <= 200, !words.isEmpty, words.count <= 20,
              words.allSatisfy({ $0.count <= 50 }) else { throw StoreError.invalidInput }
        let classifiedSensitive = SensitiveContent.requiresReview(description: description, keywords: words, category: nil)
        let stmt = try prepare("UPDATE results SET description=?,keywords=?,sensitive=max(sensitive,?),updated_at=CURRENT_TIMESTAMP WHERE asset_id=? AND write_state='pending' AND NOT EXISTS (SELECT 1 FROM write_snapshots WHERE write_snapshots.asset_id=results.asset_id)")
        defer { sqlite3_finalize(stmt) }
        try bind(description, to: stmt, at: 1)
        try bind(String(decoding: try JSONEncoder().encode(words), as: UTF8.self), to: stmt, at: 2)
        guard sqlite3_bind_int(stmt, 3, classifiedSensitive ? 1 : 0) == SQLITE_OK else { throw dbError() }
        try bind(assetID, to: stmt, at: 4)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func result(assetID: String) throws -> CachedResult? {
        let stmt = try prepare("SELECT description,keywords,sensitive,write_state,category,origin FROM results WHERE asset_id=?")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW, let description = sqlite3_column_text(stmt, 0),
              let keywords = sqlite3_column_text(stmt, 1), let stateText = sqlite3_column_text(stmt, 3),
              let state = WriteState(rawValue: String(cString: stateText)), let origin = sqlite3_column_text(stmt, 5) else { throw dbError() }
        let decoded = try JSONDecoder().decode([String].self, from: Data(String(cString: keywords).utf8))
        return CachedResult(description: String(cString: description), keywords: decoded,
                            sensitive: sqlite3_column_int(stmt, 2) != 0,
                            category: sqlite3_column_text(stmt, 4).map { String(cString: $0) }, origin: String(cString: origin), writeState: state)
    }

    public func records(query: String = "", filter: RecordFilter = .all, limit: Int = 51, offset: Int = 0) throws -> [RecordSummary] {
        guard query.count <= 200, !query.contains("\0"), (1...201).contains(limit), (0...1_000_000).contains(offset) else { throw StoreError.invalidInput }
        let condition: String
        switch filter {
        case .all: condition = "1=1"
        case .pending: condition = "r.write_state='pending'"
        case .verified: condition = "r.write_state='verified'"
        case .needsVerification: condition = "r.write_state IN ('writing','needs_verification') OR wr.status IN ('undoing','needs_review') OR EXISTS (SELECT 1 FROM people_operations o WHERE o.asset_id=a.asset_id AND o.state IN ('writing','needs_verification','undoing','undo_uncertain'))"
        case .sensitive: condition = "r.sensitive=1"
        case .metadata: condition = "p.asset_id IS NOT NULL OR l.asset_id IS NOT NULL"
        }
        let stmt = try prepare("""
        WITH assets AS (SELECT asset_id FROM results UNION SELECT asset_id FROM person_candidates UNION SELECT asset_id FROM location_candidates)
        SELECT a.asset_id,r.description,r.keywords,r.write_state,coalesce(r.sensitive,0),p.names,l.keywords,
               max(coalesce(r.updated_at,''),coalesce(p.updated_at,''),coalesce(l.updated_at,'')) AS updated,
               EXISTS (SELECT 1 FROM people_operations o WHERE o.asset_id=a.asset_id AND o.state IN ('writing','needs_verification','undoing','undo_uncertain')),wr.status
        FROM assets a LEFT JOIN results r ON r.asset_id=a.asset_id
        LEFT JOIN person_candidates p ON p.asset_id=a.asset_id LEFT JOIN location_candidates l ON l.asset_id=a.asset_id
        LEFT JOIN write_receipts wr ON wr.asset_id=a.asset_id
        WHERE (\(condition)) AND (?='' OR a.asset_id LIKE ? ESCAPE '\\' OR r.description LIKE ? ESCAPE '\\'
            OR r.keywords LIKE ? ESCAPE '\\' OR p.names LIKE ? ESCAPE '\\' OR l.keywords LIKE ? ESCAPE '\\')
        ORDER BY updated DESC,a.asset_id LIMIT ? OFFSET ?
        """)
        defer { sqlite3_finalize(stmt) }
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        try bind(query, to: stmt, at: 1)
        for index in 2...6 { try bind("%" + escaped + "%", to: stmt, at: Int32(index)) }
        guard sqlite3_bind_int64(stmt, 7, Int64(limit)) == SQLITE_OK, sqlite3_bind_int64(stmt, 8, Int64(offset)) == SQLITE_OK else { throw dbError() }
        let decoder = JSONDecoder()
        var rows: [RecordSummary] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0), let updated = sqlite3_column_text(stmt, 7) else { throw dbError() }
            func text(_ column: Int32) -> String? { sqlite3_column_text(stmt, column).map { String(cString: $0) } }
            func words(_ column: Int32) throws -> [String] {
                guard let value = text(column) else { return [] }
                return try decoder.decode([String].self, from: Data(value.utf8))
            }
            rows.append(try RecordSummary(id: String(cString: id), description: text(1), keywords: words(2), state: text(3).flatMap(WriteState.init(rawValue:)), sensitive: sqlite3_column_int(stmt, 4) != 0, people: words(5), places: words(6), updatedAt: String(cString: updated), metadataNeedsVerification: sqlite3_column_int(stmt, 8) != 0, receiptStatus: text(9)))
        }
    }

    public func saveSnapshot(assetID: String, description: String, keywords: [String]) throws {
        let encoded = String(decoding: try JSONEncoder().encode(keywords), as: UTF8.self)
        let stmt = try prepare("INSERT INTO write_snapshots(asset_id,description,keywords) SELECT asset_id,?,? FROM results WHERE asset_id=? AND write_state='pending' AND NOT EXISTS (SELECT 1 FROM people_operations WHERE people_operations.asset_id=results.asset_id AND people_operations.state IN ('prepared','writing','needs_verification','undoing','undo_uncertain'))")
        defer { sqlite3_finalize(stmt) }
        try bind(description, to: stmt, at: 1)
        try bind(encoded, to: stmt, at: 2)
        try bind(assetID, to: stmt, at: 3)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func snapshot(assetID: String) throws -> MetadataSnapshot? {
        let stmt = try prepare("SELECT description,keywords FROM write_snapshots WHERE asset_id=?")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let description = sqlite3_column_text(stmt, 0), let keywords = sqlite3_column_text(stmt, 1) else { throw dbError() }
        let decoded = try JSONDecoder().decode([String].self, from: Data(String(cString: keywords).utf8))
        return MetadataSnapshot(description: String(cString: description), keywords: decoded)
    }

    public func beginWrite(assetID: String) throws {
        let stmt = try prepare("UPDATE results SET write_state='writing',updated_at=CURRENT_TIMESTAMP WHERE asset_id=? AND write_state='pending' AND EXISTS (SELECT 1 FROM write_snapshots WHERE write_snapshots.asset_id=results.asset_id) AND NOT EXISTS (SELECT 1 FROM tasks WHERE tasks.asset_id=results.asset_id AND kind='write') AND NOT EXISTS (SELECT 1 FROM people_operations WHERE people_operations.asset_id=results.asset_id AND people_operations.state IN ('prepared','writing','needs_verification','undoing','undo_uncertain'))")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    /// Confirms completion only when a fresh Photos read contains every expected value.
    public func confirmWrite(assetID: String, description: String, keywords: [String]) throws {
        try execute("SAVEPOINT confirm_write")
        do {
            guard let cached = try result(assetID: assetID),
                  cached.writeState == .writing || cached.writeState == .needsVerification,
                  let before = try snapshot(assetID: assetID) else { throw StoreError.invalidTransition }
            let expectedDescription = before.description.isEmpty ? cached.description : before.description
            let observed = Set(keywords)
            guard description == expectedDescription,
                  Set(before.keywords).isSubset(of: observed),
                  Set(cached.keywords).isSubset(of: observed) else { throw StoreError.invalidTransition }
            if cached.writeState == .writing {
                let original = Set(before.keywords)
                let added = cached.keywords.filter { !original.contains($0) }
                let receipt = try prepare("INSERT INTO write_receipts(asset_id,description,keywords,added_keywords,status) VALUES(?,?,?,?, 'ready')")
                defer { sqlite3_finalize(receipt) }
                try bind(assetID, to: receipt, at: 1)
                try bind(description, to: receipt, at: 2)
                try bind(String(decoding: try JSONEncoder().encode(keywords), as: UTF8.self), to: receipt, at: 3)
                try bind(String(decoding: try JSONEncoder().encode(added), as: UTF8.self), to: receipt, at: 4)
                try stepDone(receipt)
            }
            let stmt = try prepare("UPDATE results SET write_state='verified',updated_at=CURRENT_TIMESTAMP WHERE asset_id=? AND write_state IN ('writing','needs_verification')")
            defer { sqlite3_finalize(stmt) }
            try bind(assetID, to: stmt, at: 1)
            try stepDone(stmt)
            guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
            let resolve = try prepare("UPDATE tasks SET state='done',token=NULL,lease_expires=NULL WHERE asset_id=? AND kind='write' AND state='needs_verification'")
            defer { sqlite3_finalize(resolve) }
            try bind(assetID, to: resolve, at: 1)
            try stepDone(resolve)
            try execute("RELEASE confirm_write")
        } catch {
            try? execute("ROLLBACK TO confirm_write")
            try? execute("RELEASE confirm_write")
            throw error
        }
    }

    /// A single-photo approval or an automatic scan request schedules one write.
    public func approveWrite(assetID: String, description: String, keywords: [String], automatic: Bool = false) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if automatic {
                guard try scanEnabled(), try automaticWriteCandidate(assetID: assetID) == assetID else {
                    throw StoreError.invalidTransition
                }
            }
            if let previous = try snapshot(assetID: assetID) {
                guard previous.description == description && previous.keywords == keywords else { throw StoreError.invalidTransition }
            } else { try saveSnapshot(assetID: assetID, description: description, keywords: keywords) }
            try enqueue(assetID: assetID, kind: .write, priority: 100)
            try removeAutomaticWrite(assetID: assetID)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func hasQueuedWrite(assetID: String) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM tasks WHERE asset_id=? AND kind='write' AND state IN ('pending','running','needs_verification')")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        let code = sqlite3_step(stmt)
        if code == SQLITE_ROW { return true }
        guard code == SQLITE_DONE else { throw dbError() }
        return false
    }

    func uncertainWriteAssetIDs() throws -> [String] {
        let stmt = try prepare("SELECT asset_id FROM tasks WHERE kind='write' AND state='needs_verification' ORDER BY id")
        defer { sqlite3_finalize(stmt) }
        var ids: [String] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return ids }
            guard code == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0) else { throw dbError() }
            ids.append(String(cString: id))
        }
    }

    public func confirmAndFinishWrite(task: ClaimedTask, now: Int64, description: String, keywords: [String]) throws {
        guard task.kind == .write else { throw StoreError.invalidInput }
        try execute("BEGIN IMMEDIATE")
        do {
            let stmt = try prepare("SELECT 1 FROM tasks WHERE id=? AND asset_id=? AND kind='write' AND state='running' AND token=? AND lease_expires>?")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_bind_int64(stmt, 1, task.id) == SQLITE_OK else { throw dbError() }
            try bind(task.assetID, to: stmt, at: 2)
            try bind(task.token, to: stmt, at: 3)
            guard sqlite3_bind_int64(stmt, 4, now) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.invalidTransition }
            try confirmWrite(assetID: task.assetID, description: description, keywords: keywords)
            try finishTask(id: task.id, token: task.token, now: now)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func writeReceipt(assetID: String) throws -> WriteReceipt? {
        let stmt = try prepare("SELECT description,keywords,added_keywords,status FROM write_receipts WHERE asset_id=?")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let description = sqlite3_column_text(stmt, 0),
              let keywords = sqlite3_column_text(stmt, 1), let added = sqlite3_column_text(stmt, 2),
              let status = sqlite3_column_text(stmt, 3) else { throw dbError() }
        let decoder = JSONDecoder()
        return try WriteReceipt(description: String(cString: description),
            keywords: decoder.decode([String].self, from: Data(String(cString: keywords).utf8)),
            addedKeywords: decoder.decode([String].self, from: Data(String(cString: added).utf8)),
            status: String(cString: status))
    }

    public func beginUndo(assetID: String) throws {
        guard let receipt = try writeReceipt(assetID: assetID), !receipt.addedKeywords.isEmpty else { throw StoreError.invalidTransition }
        let stmt = try prepare("UPDATE write_receipts SET status='undoing' WHERE asset_id=? AND status='ready' AND NOT EXISTS (SELECT 1 FROM people_operations WHERE people_operations.asset_id=write_receipts.asset_id AND people_operations.state IN ('prepared','writing','needs_verification','undoing','undo_uncertain'))")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func finishUndo(assetID: String, description: String, keywords: [String]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            guard let receipt = try writeReceipt(assetID: assetID), receipt.status == "undoing",
                  description == receipt.description,
                  keywords == receipt.keywords.filter({ !receipt.addedKeywords.contains($0) }) else { throw StoreError.invalidTransition }
            let stmt = try prepare("UPDATE write_receipts SET status='undone' WHERE asset_id=? AND status='undoing'")
            defer { sqlite3_finalize(stmt) }
            try bind(assetID, to: stmt, at: 1)
            try stepDone(stmt)
            guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func markUndoNeedsReview(assetID: String) throws {
        let stmt = try prepare("UPDATE write_receipts SET status='needs_review' WHERE asset_id=? AND status='undoing'")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func markNeedsVerification(assetID: String) throws {
        let stmt = try prepare("UPDATE results SET write_state='needs_verification',updated_at=CURRENT_TIMESTAMP WHERE asset_id=? AND write_state='writing'")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func recoverInterruptedWrites() throws {
        try execute("UPDATE results SET write_state='needs_verification',updated_at=CURRENT_TIMESTAMP WHERE write_state='writing'")
    }

    public func setScanEnabled(_ enabled: Bool) throws {
        try execute("UPDATE scan_control SET enabled=\(enabled ? 1 : 0) WHERE id=1")
    }

    public func scanEnabled() throws -> Bool { try scalarInt("SELECT enabled FROM scan_control WHERE id=1") == 1 }

    private static let readyAutomaticWrites = """
        FROM automatic_writes a JOIN results r ON r.asset_id=a.asset_id
        WHERE r.write_state='pending' AND r.origin NOT LIKE 'legacy:%'
        AND NOT EXISTS (SELECT 1 FROM tasks t WHERE t.asset_id=a.asset_id AND t.kind='write')
        AND NOT EXISTS (SELECT 1 FROM write_snapshots s WHERE s.asset_id=a.asset_id)
        AND NOT EXISTS (SELECT 1 FROM people_operations p WHERE p.asset_id=a.asset_id
                        AND p.state IN ('prepared','writing','needs_verification','undoing','undo_uncertain'))
        """

    private func automaticWriteCandidate(assetID: String? = nil, skipping: Set<String> = []) throws -> String? {
        let stmt = try prepare("SELECT a.asset_id \(Self.readyAutomaticWrites) AND (? IS NULL OR a.asset_id=?) ORDER BY a.rowid")
        defer { sqlite3_finalize(stmt) }
        if let assetID {
            try bind(assetID, to: stmt, at: 1)
            try bind(assetID, to: stmt, at: 2)
        }
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0) else { throw dbError() }
            let candidate = String(cString: id)
            if !skipping.contains(candidate) { return candidate }
        }
    }

    private func removeAutomaticWrite(assetID: String) throws {
        let stmt = try prepare("DELETE FROM automatic_writes WHERE asset_id=?")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        try stepDone(stmt)
    }

    public func nextAutomaticWrite(skipping: Set<String> = []) throws -> String? {
        guard try scanEnabled() else { return nil }
        return try automaticWriteCandidate(skipping: skipping)
    }

    public func scanProgress() throws -> ScanProgress {
        let stmt = try prepare("SELECT coalesce(sum(state='pending'),0),coalesce(sum(state='running'),0),coalesce(sum(state='done'),0),coalesce(sum(state='no_local_preview'),0) FROM tasks WHERE kind='ai'")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw dbError() }
        return try ScanProgress(enabled: scanEnabled(), pending: Int(sqlite3_column_int64(stmt,0)), running: Int(sqlite3_column_int64(stmt,1)), done: Int(sqlite3_column_int64(stmt,2)), skipped: Int(sqlite3_column_int64(stmt,3)),
            pendingIndex: Int(scalarInt("SELECT count(*) FROM tasks WHERE kind='gps' AND state='pending'")),
            runningIndex: Int(scalarInt("SELECT count(*) FROM tasks WHERE kind='gps' AND state='running'")),
            indexed: Int(scalarInt("SELECT count(*) FROM tasks WHERE kind='gps' AND state='done'")),
            pendingWrites: Int(scalarInt("SELECT count(*) FROM tasks WHERE kind='write' AND state='pending'")) + Int(scalarInt("SELECT count(*) \(Self.readyAutomaticWrites)")),
            runningWrites: Int(scalarInt("SELECT count(*) FROM tasks WHERE kind='write' AND state='running'")),
            uncertainWrites: Int(scalarInt("SELECT count(*) FROM tasks WHERE kind='write' AND state='needs_verification'")))
    }

    @discardableResult
    public func enqueueIndexAssets(_ ids: [String]) throws -> Int {
        guard ids.count <= 500, ids.allSatisfy({ PersonKeywords.assetUUID(for: $0) != nil }) else { throw StoreError.invalidInput }
        try execute("BEGIN IMMEDIATE")
        do {
            var added = 0
            for id in ids {
                let stmt = try prepare("INSERT OR IGNORE INTO tasks(asset_id,kind,state,priority) VALUES(?,'gps','pending',20)")
                defer { sqlite3_finalize(stmt) }
                try bind(id, to: stmt, at: 1)
                try stepDone(stmt)
                added += Int(sqlite3_changes(db))
            }
            try execute("COMMIT")
            return added
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Local candidates and task completion commit together; this never marks a Photos write.
    public func cacheAndFinishIndex(id: Int64, token: String, now: Int64, value: PhotoIndexCandidates) throws {
        guard let location = value.location, location.status != .readError else { throw StoreError.invalidInput }
        try execute("BEGIN IMMEDIATE")
        do {
            let stmt = try prepare("SELECT asset_id FROM tasks WHERE id=? AND kind='gps' AND state='running' AND token=? AND lease_expires>?")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK else { throw dbError() }
            try bind(token, to: stmt, at: 2)
            guard sqlite3_bind_int64(stmt, 3, now) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW, let asset = sqlite3_column_text(stmt, 0) else { throw StoreError.invalidTransition }
            let assetID = String(cString: asset)
            try recordPersonCandidates(assetID: assetID, names: value.names)
            try recordLocationCandidates(assetID: assetID, value: location)
            let update = try prepare("UPDATE tasks SET state='done',token=NULL,lease_expires=NULL WHERE id=? AND token=? AND state='running'")
            defer { sqlite3_finalize(update) }
            guard sqlite3_bind_int64(update, 1, id) == SQLITE_OK else { throw dbError() }
            try bind(token, to: update, at: 2)
            try stepDone(update)
            guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }


    /// Adds bounded batches without re-enqueueing cached or already scheduled assets.
    @discardableResult
    public func enqueueAIAssets(_ ids: [String], priority: Int, automaticallyWrite: Bool = false) throws -> Int {
        guard ids.count <= 500, (-1000...1000).contains(priority),
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else { throw StoreError.invalidInput }
        if ids.isEmpty { return 0 }
        try execute("BEGIN IMMEDIATE")
        do {
            let stmt = try prepare("INSERT OR IGNORE INTO tasks(asset_id,kind,state,priority) SELECT ?,'ai','pending',? WHERE NOT EXISTS (SELECT 1 FROM results WHERE asset_id=?)")
            defer { sqlite3_finalize(stmt) }
            let request = automaticallyWrite ? try prepare("INSERT OR IGNORE INTO automatic_writes(asset_id) VALUES(?)") : nil
            defer { if let request { sqlite3_finalize(request) } }
            var added = 0
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try bind(id, to: stmt, at: 1)
                guard sqlite3_bind_int64(stmt, 2, Int64(priority)) == SQLITE_OK else { throw dbError() }
                try bind(id, to: stmt, at: 3)
                try stepDone(stmt)
                added += Int(sqlite3_changes(db))
                if let request {
                    sqlite3_reset(request)
                    try bind(id, to: request, at: 1)
                    try stepDone(request)
                    added += Int(sqlite3_changes(db))
                }
            }
            try execute("COMMIT")
            return added
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func enqueue(assetID: String, kind: TaskKind, priority: Int) throws {
        guard !assetID.isEmpty, (-1000...1000).contains(priority) else { throw StoreError.invalidInput }
        if kind == .write {
            let check = try prepare("SELECT 1 FROM results WHERE asset_id=? AND write_state='pending' AND EXISTS (SELECT 1 FROM write_snapshots WHERE write_snapshots.asset_id=results.asset_id) AND NOT EXISTS (SELECT 1 FROM people_operations WHERE people_operations.asset_id=results.asset_id AND people_operations.state IN ('prepared','writing','needs_verification','undoing','undo_uncertain'))")
            defer { sqlite3_finalize(check) }
            try bind(assetID, to: check, at: 1)
            guard sqlite3_step(check) == SQLITE_ROW else { throw StoreError.invalidTransition }
        }
        let stmt = try prepare("INSERT OR IGNORE INTO tasks(asset_id,kind,state,priority) VALUES(?,?,'pending',?)")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        try bind(kind.rawValue, to: stmt, at: 2)
        guard sqlite3_bind_int64(stmt, 3, Int64(priority)) == SQLITE_OK else { throw dbError() }
        try stepDone(stmt)
    }

    // The worker must hold the exclusive lease before recovering another process's tasks.
    func recoverInterruptedTasks(now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        guard now >= 0, now <= Int64.max - 3600 else { throw StoreError.invalidInput }
        try execute("BEGIN IMMEDIATE")
        do {
            let retry = try prepare("UPDATE tasks SET next_attempt=MAX(next_attempt, ? + MIN(3600, 30 * (1 << MIN(7, MAX(0, attempts - 1))))) WHERE state='running' AND kind IN ('ai','gps')")
            defer { sqlite3_finalize(retry) }
            guard sqlite3_bind_int64(retry, 1, now) == SQLITE_OK else { throw dbError() }
            try stepDone(retry)
            try recoverTaskLeases(through: Int64.max)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func recoverTaskLeases(through cutoff: Int64) throws {
        let uncertain = try prepare("UPDATE results SET write_state='needs_verification' WHERE write_state='writing' AND asset_id IN (SELECT asset_id FROM tasks WHERE kind='write' AND state='running' AND lease_expires<=?)")
        defer { sqlite3_finalize(uncertain) }
        guard sqlite3_bind_int64(uncertain, 1, cutoff) == SQLITE_OK else { throw dbError() }
        try stepDone(uncertain)
        let expired = try prepare("UPDATE tasks SET state=CASE WHEN kind='write' THEN 'needs_verification' ELSE 'pending' END,token=NULL,lease_expires=NULL WHERE state='running' AND lease_expires<=?")
        defer { sqlite3_finalize(expired) }
        guard sqlite3_bind_int64(expired, 1, cutoff) == SQLITE_OK else { throw dbError() }
        try stepDone(expired)
    }

    public func claimNext(now: Int64, leaseSeconds: Int64, kind: TaskKind? = nil) throws -> ClaimedTask? {
        guard now >= 0, leaseSeconds > 0, leaseSeconds <= 86_400, now <= Int64.max - leaseSeconds else { throw StoreError.invalidInput }
        try execute("BEGIN IMMEDIATE")
        do {
            try recoverTaskLeases(through: now)
            let filter = kind == nil ? "" : "AND kind=?"
            let select = try prepare("SELECT id,asset_id,kind FROM tasks WHERE state='pending' AND next_attempt<=? \(filter) ORDER BY priority DESC,attempts,id LIMIT 1")
            defer { sqlite3_finalize(select) }
            guard sqlite3_bind_int64(select, 1, now) == SQLITE_OK else { throw dbError() }
            if let kind {
                try bind(kind.rawValue, to: select, at: 2)
            }
            let code = sqlite3_step(select)
            if code == SQLITE_DONE { try execute("COMMIT"); return nil }
            guard code == SQLITE_ROW, let idText = sqlite3_column_text(select, 1), let kindText = sqlite3_column_text(select, 2),
                  let kind = TaskKind(rawValue: String(cString: kindText)) else { throw dbError() }
            let id = sqlite3_column_int64(select, 0)
            let assetID = String(cString: idText)
            let token = UUID().uuidString
            if kind == .write {
                let mark = try prepare("UPDATE results SET write_state='writing' WHERE asset_id=? AND write_state='pending' AND EXISTS (SELECT 1 FROM write_snapshots WHERE write_snapshots.asset_id=results.asset_id) AND NOT EXISTS (SELECT 1 FROM people_operations WHERE people_operations.asset_id=results.asset_id AND people_operations.state IN ('prepared','writing','needs_verification','undoing','undo_uncertain'))")
                defer { sqlite3_finalize(mark) }
                try bind(assetID, to: mark, at: 1)
                try stepDone(mark)
                guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
            }
            let update = try prepare("UPDATE tasks SET state='running', token=?, lease_expires=?, attempts=attempts+1 WHERE id=? AND state='pending'")
            defer { sqlite3_finalize(update) }
            try bind(token, to: update, at: 1)
            guard sqlite3_bind_int64(update, 2, now + leaseSeconds) == SQLITE_OK,
                  sqlite3_bind_int64(update, 3, id) == SQLITE_OK else { throw dbError() }
            try stepDone(update)
            guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
            try execute("COMMIT")
            return ClaimedTask(id: id, assetID: assetID, kind: kind, token: token)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func finishTask(id: Int64, token: String, now: Int64) throws {
        let stmt = try prepare("UPDATE tasks SET state='done',token=NULL,lease_expires=NULL WHERE id=? AND state='running' AND token=? AND lease_expires>? AND ((kind='ai' AND EXISTS (SELECT 1 FROM results WHERE results.asset_id=tasks.asset_id)) OR (kind='write' AND EXISTS (SELECT 1 FROM results WHERE results.asset_id=tasks.asset_id AND results.write_state='verified')))")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK else { throw dbError() }
        try bind(token, to: stmt, at: 2)
        guard sqlite3_bind_int64(stmt, 3, now) == SQLITE_OK else { throw dbError() }
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func cacheAndFinishAI(id: Int64, token: String, now: Int64, description: String, keywords: [String], sensitive: Bool, category: String? = nil) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let stmt = try prepare("SELECT asset_id FROM tasks WHERE id=? AND kind='ai' AND state='running' AND token=? AND lease_expires>?")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK else { throw dbError() }
            try bind(token, to: stmt, at: 2)
            guard sqlite3_bind_int64(stmt, 3, now) == SQLITE_OK else { throw dbError() }
            guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { throw StoreError.invalidTransition }
            let asset = String(cString: text)
            if try result(assetID: asset) == nil {
                try cache(assetID: asset, description: description, keywords: keywords, sensitive: sensitive, category: category)
            }
            try finishTask(id: id, token: token, now: now)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func failTask(id: Int64, token: String, now: Int64) throws {
        guard now >= 0, now <= Int64.max - 3600 else { throw StoreError.invalidInput }
        try execute("BEGIN IMMEDIATE")
        do {
            let select = try prepare("SELECT kind,asset_id,attempts FROM tasks WHERE id=? AND state='running' AND token=? AND lease_expires>?")
            defer { sqlite3_finalize(select) }
            guard sqlite3_bind_int64(select, 1, id) == SQLITE_OK else { throw dbError() }
            try bind(token, to: select, at: 2)
            guard sqlite3_bind_int64(select, 3, now) == SQLITE_OK else { throw dbError() }
            guard sqlite3_step(select) == SQLITE_ROW, let kindText = sqlite3_column_text(select, 0),
                  let assetText = sqlite3_column_text(select, 1), let kind = TaskKind(rawValue: String(cString: kindText)) else { throw StoreError.invalidTransition }
            let asset = String(cString: assetText)
            let attempts = max(1, min(8, Int(sqlite3_column_int(select, 2))))
            let delay = min(Int64(3600), Int64(30) << (attempts - 1))
            if kind == .write {
                let uncertain = try prepare("UPDATE results SET write_state='needs_verification' WHERE asset_id=? AND write_state='writing'")
                defer { sqlite3_finalize(uncertain) }
                try bind(asset, to: uncertain, at: 1)
                try stepDone(uncertain)
            }
            let update = try prepare("UPDATE tasks SET state=?,token=NULL,lease_expires=NULL,next_attempt=? WHERE id=? AND state='running' AND token=?")
            defer { sqlite3_finalize(update) }
            try bind(kind == .write ? "needs_verification" : "pending", to: update, at: 1)
            guard sqlite3_bind_int64(update, 2, now + delay) == SQLITE_OK, sqlite3_bind_int64(update, 3, id) == SQLITE_OK else { throw dbError() }
            try bind(token, to: update, at: 4)
            try stepDone(update)
            guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func markNoLocalPreview(id: Int64, token: String, now: Int64) throws {
        let stmt = try prepare("UPDATE tasks SET state='no_local_preview',token=NULL,lease_expires=NULL WHERE id=? AND kind='ai' AND state='running' AND token=? AND lease_expires>?")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK else { throw dbError() }
        try bind(token, to: stmt, at: 2)
        guard sqlite3_bind_int64(stmt, 3, now) == SQLITE_OK else { throw dbError() }
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func outstanding(kind: TaskKind) throws -> Int {
        let stmt = try prepare("SELECT count(*) FROM tasks WHERE kind=? AND state IN ('pending','running')")
        defer { sqlite3_finalize(stmt) }
        try bind(kind.rawValue, to: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw dbError() }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    public func taskState(id: Int64) throws -> String? {
        let stmt = try prepare("SELECT state FROM tasks WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK else { throw dbError() }
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let state = sqlite3_column_text(stmt, 0) else { throw dbError() }
        return String(cString: state)
    }

    /// All historical sources commit together; any invalid source rolls back the entire import.
    public func importLegacyBundle(_ sources: [URL]) throws -> Int {
        try execute("BEGIN IMMEDIATE")
        do {
            var count = 0
            for url in sources {
                count += url.pathExtension == "jsonl" ? try importLegacyResults(from: url) : try importLegacy(from: url)
            }
            try execute("COMMIT")
            return count
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Preserves original JSONL records as unverified evidence, never as a writable AI result.
    @discardableResult
    public func importLegacyResults(from url: URL) throws -> Int {
        guard ["ai_results.jsonl", "v4_ai_results.jsonl", "v5_ai_results.jsonl", "v6_ai_results.jsonl", "v8_ai_results.jsonl"].contains(url.lastPathComponent),
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 50_000_000 else { throw StoreError.invalidInput }
        let data = try Data(contentsOf: url)
        guard data.count <= 50_000_000, let content = String(data: data, encoding: .utf8) else { throw StoreError.invalidInput }
        try execute("SAVEPOINT legacy_import")
        do {
            let remove = try prepare("DELETE FROM legacy_results WHERE source=?")
            defer { sqlite3_finalize(remove) }
            try bind(url.lastPathComponent, to: remove, at: 1)
            try stepDone(remove)
            let insert = try prepare("INSERT INTO legacy_results(source,line,asset_id,payload) VALUES(?,?,?,?)")
            defer { sqlite3_finalize(insert) }
            var count = 0
            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let raw = String(line)
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                guard raw.utf8.count <= 128_000,
                      let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let id = object["uuid"] as? String, !id.isEmpty, !id.contains("\0") else { throw StoreError.invalidInput }
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                try bind(url.lastPathComponent, to: insert, at: 1)
                guard sqlite3_bind_int64(insert, 2, Int64(index + 1)) == SQLITE_OK else { throw dbError() }
                try bind(id, to: insert, at: 3)
                try bind(raw, to: insert, at: 4)
                try stepDone(insert)
                count += 1
            }
            try execute("RELEASE legacy_import")
            return count
        } catch {
            try? execute("ROLLBACK TO legacy_import; RELEASE legacy_import")
            throw error
        }
    }

    /// Candidate only: the caller must present it for review, not assume a verified Photos write.
    public func legacySuggestion(localIdentifier: String) throws -> LegacySuggestion? {
        guard let uuid = PersonKeywords.assetUUID(for: localIdentifier) else { return nil }
        let stmt = try prepare("""
        SELECT source,line,payload FROM legacy_results WHERE asset_id=? COLLATE NOCASE
        ORDER BY CASE source WHEN 'v8_ai_results.jsonl' THEN 0 WHEN 'v6_ai_results.jsonl' THEN 1
                 WHEN 'v5_ai_results.jsonl' THEN 2 WHEN 'v4_ai_results.jsonl' THEN 3 ELSE 4 END, line DESC LIMIT 100
        """)
        defer { sqlite3_finalize(stmt) }
        try bind(uuid.uuidString, to: stmt, at: 1)
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW, let source = sqlite3_column_text(stmt, 0), let payload = sqlite3_column_text(stmt, 2) else { throw dbError() }
            if let result = try? AIResult.parse(String(cString: payload)) {
                return LegacySuggestion(source: String(cString: source), line: Int(sqlite3_column_int64(stmt, 1)), result: result)
            }
        }
    }

    /// Stores only local reverse-geolocation labels; coordinates are not copied into this database.
    public func recordLocationCandidates(assetID: String, value: LocationCandidates) throws {
        guard PersonKeywords.assetUUID(for: assetID) != nil, value.keywords.count <= 30,
              value.keywords.allSatisfy({ !$0.isEmpty && $0.count <= 100 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw StoreError.invalidInput }
        var seen = Set<String>()
        let keywords = value.keywords.filter { seen.insert($0).inserted }
        guard (value.status == .localAddress && !keywords.isEmpty) || (value.status != .localAddress && keywords.isEmpty) else { throw StoreError.invalidInput }
        let stmt = try prepare("INSERT INTO location_candidates(asset_id,status,keywords) VALUES(?,?,?) ON CONFLICT(asset_id) DO UPDATE SET status=excluded.status,keywords=excluded.keywords,updated_at=CURRENT_TIMESTAMP")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        try bind(value.status.rawValue, to: stmt, at: 2)
        try bind(String(decoding: try JSONEncoder().encode(keywords), as: UTF8.self), to: stmt, at: 3)
        try stepDone(stmt)
    }

    public func locationCandidates(assetID: String) throws -> LocationCandidates? {
        let stmt = try prepare("SELECT status,keywords FROM location_candidates WHERE asset_id=?")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let statusText = sqlite3_column_text(stmt, 0),
              let status = LocationStatus(rawValue: String(cString: statusText)), let words = sqlite3_column_text(stmt, 1) else { throw dbError() }
        return try LocationCandidates(status: status, keywords: JSONDecoder().decode([String].self, from: Data(String(cString: words).utf8)))
    }

    /// Person matches remain separate candidates until an explicit metadata operation adopts them.
    public func recordPersonCandidates(assetID: String, names: [String]) throws {
        guard PersonKeywords.assetUUID(for: assetID) != nil, names.count <= 100,
              names.allSatisfy({ $0.count <= 100 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw StoreError.invalidInput }
        let filtered = PersonKeywords.plan(existing: [], names: names).additions
        let encoded = String(decoding: try JSONEncoder().encode(filtered), as: UTF8.self)
        let stmt = try prepare("INSERT INTO person_candidates(asset_id,names) VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET names=excluded.names,updated_at=CURRENT_TIMESTAMP")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        try bind(encoded, to: stmt, at: 2)
        try stepDone(stmt)
    }

    /// Adds reviewed Photos person candidates to a pending result, never directly to Photos.
    @discardableResult
    public func addPeopleToPendingResult(assetID: String) throws -> Int {
        try execute("BEGIN IMMEDIATE")
        do {
            guard let existing = try result(assetID: assetID),
                  existing.writeState == .pending, try snapshot(assetID: assetID) == nil,
                  let candidates = try personCandidates(assetID: assetID) else { throw StoreError.invalidTransition }
            let plan = PersonKeywords.plan(existing: existing.keywords, names: candidates)
            try editPending(assetID: assetID, description: existing.description, keywords: plan.merged)
            try execute("COMMIT")
            return plan.additions.count
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Creates a distinct journal for names, preserving both the AI state and original metadata.
    public func preparePeopleWrite(assetID: String, description: String, keywords: [String]) throws -> PeopleWriteOperation? {
        try prepareIndexedWrite(assetID: assetID, description: description, keywords: keywords, source: "people")
    }

    public func prepareLocationWrite(assetID: String, description: String, keywords: [String]) throws -> PeopleWriteOperation? {
        try prepareIndexedWrite(assetID: assetID, description: description, keywords: keywords, source: "location")
    }

    private func prepareIndexedWrite(assetID: String, description: String, keywords: [String], source: String) throws -> PeopleWriteOperation? {
        try execute("BEGIN IMMEDIATE")
        do {
            guard let cached = try result(assetID: assetID),
                  cached.writeState == .pending || cached.writeState == .verified else { throw StoreError.invalidTransition }
            let names: [String]
            if source == "people" {
                guard let candidates = try personCandidates(assetID: assetID) else { throw StoreError.invalidTransition }
                names = candidates
            } else {
                guard let candidates = try locationCandidates(assetID: assetID), candidates.status == .localAddress else { throw StoreError.invalidTransition }
                names = candidates.keywords
            }
            if cached.writeState == .pending, try snapshot(assetID: assetID) != nil { throw StoreError.invalidTransition }
            if let receipt = try writeReceipt(assetID: assetID), receipt.status == "undoing" || receipt.status == "needs_review" { throw StoreError.invalidTransition }
            let additions = PersonKeywords.plan(existing: keywords, names: names).additions
            if additions.isEmpty { try execute("COMMIT"); return nil }
            let id = UUID().uuidString
            let insert = try prepare("INSERT INTO people_operations(id,asset_id,before_description,before_keywords,added_keywords,state,source) VALUES(?,?,?,?,?,'prepared',?)")
            defer { sqlite3_finalize(insert) }
            try bind(id, to: insert, at: 1)
            try bind(assetID, to: insert, at: 2)
            try bind(description, to: insert, at: 3)
            try bind(String(decoding: try JSONEncoder().encode(keywords), as: UTF8.self), to: insert, at: 4)
            try bind(String(decoding: try JSONEncoder().encode(additions), as: UTF8.self), to: insert, at: 5)
            try bind(source, to: insert, at: 6)
            try stepDone(insert)
            try execute("COMMIT")
            return PeopleWriteOperation(id: id, assetID: assetID, beforeDescription: description, beforeKeywords: keywords, addedKeywords: additions, afterKeywords: nil, writeReturned: false, undoEligible: false, state: "prepared")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func peopleOperation(id: String) throws -> PeopleWriteOperation? {
        let stmt = try prepare("SELECT asset_id,before_description,before_keywords,added_keywords,state,after_keywords,write_returned,undo_eligible FROM people_operations WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        try bind(id, to: stmt, at: 1)
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let asset = sqlite3_column_text(stmt, 0), let description = sqlite3_column_text(stmt, 1),
              let before = sqlite3_column_text(stmt, 2), let added = sqlite3_column_text(stmt, 3), let state = sqlite3_column_text(stmt, 4) else { throw dbError() }
        let decoder = JSONDecoder()
        let after: [String]?
        if let value = sqlite3_column_text(stmt, 5) { after = try decoder.decode([String].self, from: Data(String(cString: value).utf8)) }
        else { after = nil }
        return try PeopleWriteOperation(id: id, assetID: String(cString: asset), beforeDescription: String(cString: description),
            beforeKeywords: decoder.decode([String].self, from: Data(String(cString: before).utf8)),
            addedKeywords: decoder.decode([String].self, from: Data(String(cString: added).utf8)), afterKeywords: after,
            writeReturned: sqlite3_column_int(stmt, 6) != 0, undoEligible: sqlite3_column_int(stmt, 7) != 0, state: String(cString: state))
    }

    public func latestPeopleOperation(assetID: String) throws -> PeopleWriteOperation? {
        try latestIndexedOperation(assetID: assetID, source: "people")
    }

    public func latestLocationOperation(assetID: String) throws -> PeopleWriteOperation? {
        try latestIndexedOperation(assetID: assetID, source: "location")
    }

    private func latestIndexedOperation(assetID: String, source: String) throws -> PeopleWriteOperation? {
        let stmt = try prepare("SELECT id FROM people_operations WHERE asset_id=? AND source=? ORDER BY rowid DESC LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        try bind(source, to: stmt, at: 2)
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0) else { throw dbError() }
        return try peopleOperation(id: String(cString: id))
    }

    public func cancelPreparedPeopleWrite(operationID: String) throws {
        let stmt = try prepare("DELETE FROM people_operations WHERE id=? AND state='prepared'")
        defer { sqlite3_finalize(stmt) }
        try bind(operationID, to: stmt, at: 1)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func beginPeopleWrite(operationID: String) throws {
        let stmt = try prepare("UPDATE people_operations SET state='writing' WHERE id=? AND state='prepared' AND EXISTS (SELECT 1 FROM results WHERE results.asset_id=people_operations.asset_id AND (write_state='verified' OR (write_state='pending' AND NOT EXISTS (SELECT 1 FROM write_snapshots WHERE write_snapshots.asset_id=results.asset_id)))) AND NOT EXISTS (SELECT 1 FROM write_receipts WHERE write_receipts.asset_id=people_operations.asset_id AND status IN ('undoing','needs_review'))")
        defer { sqlite3_finalize(stmt) }
        try bind(operationID, to: stmt, at: 1)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func markPeopleWriteReturned(operationID: String) throws {
        let stmt = try prepare("UPDATE people_operations SET write_returned=1 WHERE id=? AND state='writing'")
        defer { sqlite3_finalize(stmt) }
        try bind(operationID, to: stmt, at: 1)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func markPeopleNeedsVerification(operationID: String) throws {
        let stmt = try prepare("UPDATE people_operations SET state='needs_verification' WHERE id=? AND state='writing'")
        defer { sqlite3_finalize(stmt) }
        try bind(operationID, to: stmt, at: 1)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func confirmPeopleWrite(operationID: String, description: String, keywords: [String]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            guard let operation = try peopleOperation(id: operationID), operation.state == "writing" || operation.state == "needs_verification",
                  description == operation.beforeDescription, Set(operation.beforeKeywords).isSubset(of: Set(keywords)),
                  Set(operation.addedKeywords).isSubset(of: Set(keywords)) else { throw StoreError.invalidTransition }
            let stmt = try prepare("UPDATE people_operations SET state='verified',after_keywords=?,undo_eligible=write_returned WHERE id=? AND state IN ('writing','needs_verification')")
            defer { sqlite3_finalize(stmt) }
            try bind(String(decoding: try JSONEncoder().encode(keywords), as: UTF8.self), to: stmt, at: 1)
            try bind(operationID, to: stmt, at: 2)
            try stepDone(stmt)
            guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func beginPeopleUndo(operationID: String) throws {
        let stmt = try prepare("UPDATE people_operations SET state='undoing' WHERE id=? AND state='verified' AND after_keywords IS NOT NULL AND undo_eligible=1 AND NOT EXISTS (SELECT 1 FROM results WHERE results.asset_id=people_operations.asset_id AND write_state IN ('writing','needs_verification')) AND NOT EXISTS (SELECT 1 FROM write_receipts WHERE write_receipts.asset_id=people_operations.asset_id AND status IN ('undoing','needs_review'))")
        defer { sqlite3_finalize(stmt) }
        try bind(operationID, to: stmt, at: 1)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func markPeopleUndoUncertain(operationID: String) throws {
        let stmt = try prepare("UPDATE people_operations SET state='undo_uncertain' WHERE id=? AND state='undoing'")
        defer { sqlite3_finalize(stmt) }
        try bind(operationID, to: stmt, at: 1)
        try stepDone(stmt)
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
    }

    public func confirmPeopleUndo(operationID: String, description: String, keywords: [String]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            guard let operation = try peopleOperation(id: operationID),
                  operation.state == "undoing" || operation.state == "undo_uncertain",
                  let after = operation.afterKeywords, description == operation.beforeDescription,
                  keywords == after.filter({ !operation.addedKeywords.contains($0) }) else { throw StoreError.invalidTransition }
            let stmt = try prepare("UPDATE people_operations SET state='undone' WHERE id=? AND state IN ('undoing','undo_uncertain')")
            defer { sqlite3_finalize(stmt) }
            try bind(operationID, to: stmt, at: 1)
            try stepDone(stmt)
            guard sqlite3_changes(db) == 1 else { throw StoreError.invalidTransition }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func peopleWriteState(operationID: String) throws -> String? { try peopleOperation(id: operationID)?.state }


    public func personCandidates(assetID: String) throws -> [String]? {
        let stmt = try prepare("SELECT names FROM person_candidates WHERE asset_id=?")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else { throw dbError() }
        return try JSONDecoder().decode([String].self, from: Data(String(cString: value).utf8))
    }

    public func legacyResultCount(assetID: String) throws -> Int {
        let stmt = try prepare("SELECT count(*) FROM legacy_results WHERE asset_id=?")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw dbError() }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Imports an existing backup read-only; historical statuses are evidence, not verified writes.
    @discardableResult
    public func importLegacy(from url: URL) throws -> Int {
        let query: String
        switch url.lastPathComponent {
        case "photo_progress.sqlite3":
            query = "SELECT uuid, filename, status, NULL FROM photo_status"
        case "v4_progress.sqlite3":
            query = """
            SELECT i.uuid, i.filename, i.state, l.state FROM items i LEFT JOIN location_status l ON i.uuid=l.uuid
            UNION ALL
            SELECT l.uuid, NULL, NULL, l.state FROM location_status l LEFT JOIN items i ON i.uuid=l.uuid WHERE i.uuid IS NULL
            """
        case "v6_progress.sqlite3":
            query = "SELECT uuid, filename, ai_state, gps_state FROM assets"
        case "v8_progress.sqlite3":
            query = "SELECT uuid, filename, ai_state, gps_state FROM photos"
        default: throw StoreError.invalidInput
        }
        guard let targetPath = sqlite3_db_filename(db, "main"),
              URL(fileURLWithPath: String(cString: targetPath)).standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath() else {
            throw StoreError.invalidInput
        }
        var sourceDB: OpaquePointer?
        guard sqlite3_open_v2(url.path, &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let sourceDB { sqlite3_close(sourceDB) }
            throw StoreError.database("无法只读打开历史数据库")
        }
        defer { sqlite3_close(sourceDB) }
        sqlite3_busy_timeout(sourceDB, 5000)
        var read: OpaquePointer?
        guard sqlite3_prepare_v2(sourceDB, query, -1, &read, nil) == SQLITE_OK, let read else {
            throw StoreError.database("无法读取历史数据库：" + String(cString: sqlite3_errmsg(sourceDB)))
        }
        defer { sqlite3_finalize(read) }
        try execute("SAVEPOINT legacy_import")
        do {
            let delete = try prepare("DELETE FROM legacy_records WHERE source=?")
            defer { sqlite3_finalize(delete) }
            try bind(url.lastPathComponent, to: delete, at: 1)
            try stepDone(delete)
            let write = try prepare("INSERT INTO legacy_records(source,asset_id,filename,ai_state,gps_state) VALUES(?,?,?,?,?)")
            defer { sqlite3_finalize(write) }
            var count = 0
            while true {
                let code = sqlite3_step(read)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW, let id = sqlite3_column_text(read, 0), !String(cString: id).isEmpty else {
                    throw StoreError.database("读取历史记录失败或资源标识为空")
                }
                sqlite3_reset(write)
                sqlite3_clear_bindings(write)
                try bind(url.lastPathComponent, to: write, at: 1)
                for index in 0..<4 {
                    if let text = sqlite3_column_text(read, Int32(index)) {
                        try bind(String(cString: text), to: write, at: Int32(index + 2))
                    } else if sqlite3_bind_null(write, Int32(index + 2)) != SQLITE_OK {
                        throw dbError()
                    }
                }
                try stepDone(write)
                count += 1
            }
            try execute("RELEASE legacy_import")
            return count
        } catch {
            try? execute("ROLLBACK TO legacy_import; RELEASE legacy_import")
            throw error
        }
    }

    public func legacyRecords(assetID: String) throws -> [LegacyRecord] {
        let stmt = try prepare("SELECT source, ai_state, gps_state FROM legacy_records WHERE asset_id=? ORDER BY source")
        defer { sqlite3_finalize(stmt) }
        try bind(assetID, to: stmt, at: 1)
        var records: [LegacyRecord] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return records }
            guard code == SQLITE_ROW, let source = sqlite3_column_text(stmt, 0) else { throw dbError() }
            let ai = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let gps = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            records.append(LegacyRecord(source: String(cString: source), aiState: ai, gpsState: gps))
        }
    }

    private func backupBeforeMigration(url: URL, version: Int32) throws {
        let folder = url.deletingLastPathComponent()
        let name = "atlas-before-v\(version)-\(UUID().uuidString)"
        let partial = folder.appendingPathComponent(name + ".partial")
        let final = folder.appendingPathComponent(name + ".sqlite")
        let fd = open(partial.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard fd >= 0 else { throw StoreError.database("无法创建升级备份") }
        close(fd)
        do {
            var destination: OpaquePointer?
            guard sqlite3_open_v2(partial.path, &destination, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let destination else {
                if let destination { sqlite3_close(destination) }
                throw StoreError.database("无法打开升级备份")
            }
            guard let backup = sqlite3_backup_init(destination, "main", db, "main") else {
                sqlite3_close(destination)
                throw StoreError.database("无法初始化升级备份")
            }
            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard step == SQLITE_DONE, finish == SQLITE_OK else {
                sqlite3_close(destination)
                throw StoreError.database("升级备份未完成")
            }
            var mode: OpaquePointer?
            let preparedMode = sqlite3_prepare_v2(destination, "PRAGMA journal_mode=DELETE", -1, &mode, nil)
            let modeOK = preparedMode == SQLITE_OK && sqlite3_step(mode) == SQLITE_ROW && sqlite3_column_text(mode, 0).map { String(cString: $0) } == "delete"
            sqlite3_finalize(mode)
            var check: OpaquePointer?
            let preparedCheck = sqlite3_prepare_v2(destination, "PRAGMA quick_check", -1, &check, nil)
            let checkOK = preparedCheck == SQLITE_OK && sqlite3_step(check) == SQLITE_ROW && sqlite3_column_text(check, 0).map { String(cString: $0) } == "ok"
            sqlite3_finalize(check)
            let closed = sqlite3_close(destination)
            guard modeOK, checkOK, closed == SQLITE_OK else { throw StoreError.database("升级备份完整性检查失败") }
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw dbError() }
        return stmt
    }
    private func bind(_ value: String, to stmt: OpaquePointer, at index: Int32) throws {
        guard !value.contains("\0") else { throw StoreError.invalidInput }
        guard sqlite3_bind_text(stmt, index, value, -1, transient) == SQLITE_OK else { throw dbError() }
    }
    private func stepDone(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw dbError() }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw dbError() }
    }
    private func scalarInt(_ sql: String) throws -> Int32 {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw dbError() }
        return sqlite3_column_int(stmt, 0)
    }
    private func dbError() -> StoreError {
        .database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed")
    }
}
