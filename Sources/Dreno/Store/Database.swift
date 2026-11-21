import Foundation
import SQLite3

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBError: Error, LocalizedError {
    case open(String), prepare(String)
    var errorDescription: String? {
        switch self {
        case .open(let m): return "Banco: \(m)"
        case .prepare(let m): return "SQL: \(m)"
        }
    }
}

/// Wrapper mínimo de SQLite. Cada conexão deve ser usada por uma fila de cada vez.
final class Database {
    let handle: OpaquePointer

    init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            throw DBError.open(h.map { String(cString: sqlite3_errmsg($0)) } ?? "falha ao abrir")
        }
        handle = h
        sqlite3_busy_timeout(h, 4000)
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        migrate()
    }

    deinit { sqlite3_close_v2(handle) }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK, let err {
            NSLog("Dreno SQL: %@", String(cString: err))
            sqlite3_free(err)
        }
    }

    func prepare(_ sql: String) -> Statement? {
        do { return try Statement(handle, sql) } catch {
            NSLog("Dreno prepare: %@", "\(error)")
            return nil
        }
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS sessions(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          started REAL NOT NULL, ended REAL, interval REAL NOT NULL,
          title TEXT, trigger TEXT, host TEXT, ncpu INTEGER,
          battery_wh REAL, overhead REAL);
        CREATE TABLE IF NOT EXISTS procs(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session INTEGER NOT NULL, pid INTEGER NOT NULL, ppid INTEGER, uid INTEGER,
          name TEXT NOT NULL, path TEXT, rpath TEXT, args TEXT, first REAL, last REAL);
        CREATE INDEX IF NOT EXISTS procs_session ON procs(session);
        CREATE TABLE IF NOT EXISTS ticks(
          session INTEGER NOT NULL, k INTEGER NOT NULL, t REAL NOT NULL, dt REAL NOT NULL,
          busy REAL, resid REAL, watts REAL, batt REAL, on_batt INTEGER, charging INTEGER,
          thermal INTEGER, pressure INTEGER, memsnap INTEGER,
          PRIMARY KEY(session, k));
        CREATE TABLE IF NOT EXISTS samples(
          session INTEGER NOT NULL, k INTEGER NOT NULL, proc INTEGER NOT NULL,
          cpu REAL, mem REAL, energy REAL, wakeups REAL, gpu REAL);
        CREATE INDEX IF NOT EXISTS samples_session ON samples(session, k);
        CREATE TABLE IF NOT EXISTS holds(
          session INTEGER NOT NULL, k INTEGER NOT NULL, proc INTEGER, pid INTEGER,
          type TEXT, name TEXT, secs REAL);
        CREATE INDEX IF NOT EXISTS holds_session ON holds(session);
        """)
    }
}

final class Statement {
    let stmt: OpaquePointer

    init(_ db: OpaquePointer, _ sql: String) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        stmt = s
    }

    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    func bind(_ values: Any?...) -> Statement {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            guard let value else { sqlite3_bind_null(stmt, idx); continue }
            switch value {
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int32: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as UInt32: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_PTR)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return self
    }

    func run() { _ = sqlite3_step(stmt) }
    func next() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }
    func optInt(_ i: Int32) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(stmt, i) }
    func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
}
