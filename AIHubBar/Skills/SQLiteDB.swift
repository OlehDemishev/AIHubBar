import Foundation
import SQLite3

/// A small wrapper over the system's SQLite (with FTS5), enough for the Skills Catalog. Not thread-safe by itself:
/// its owner serializes the calls.
final class SQLiteDB {
    struct Failure: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    /// A value to bind or read.
    enum Value: Equatable {
        case null, int(Int64), real(Double), text(String)
    }

    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(handle)
            throw Failure(message: message)
        }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" { try execute("PRAGMA journal_mode = WAL") }
    }

    deinit { sqlite3_close(handle) }

    private func failure() -> Failure { Failure(message: String(cString: sqlite3_errmsg(handle))) }

    /// Runs statements with no parameters and no rows.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "error"
            sqlite3_free(error)
            throw Failure(message: message)
        }
    }

    /// One row of a result, read by column index.
    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
        func bool(_ index: Int32) -> Bool { sqlite3_column_int64(statement, index) != 0 }
        func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
        func text(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
        func optionalText(_ index: Int32) -> String? { isNull(index) ? nil : text(index) }
        func optionalInt(_ index: Int32) -> Int? { isNull(index) ? nil : int(index) }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            }
        }
        return statement
    }

    /// Runs one statement; returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: Value...) throws -> Int { try run(sql, values) }

    @discardableResult
    func run(_ sql: String, _ values: [Value]) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ values: Value..., map: (Row) throws -> T) throws -> [T] { try query(sql, values, map: map) }

    func query<T>(_ sql: String, _ values: [Value], map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            rows.append(try map(Row(statement: statement)))
        }
        return rows
    }

    func first<T>(_ sql: String, _ values: Value..., map: (Row) throws -> T) throws -> T? { try query(sql, values, map: map).first }

    var lastInsertID: Int { Int(sqlite3_last_insert_rowid(handle)) }

    /// Runs `work` in one transaction: all of it or none.
    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? first("PRAGMA user_version") { $0.int(0) }) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }
}

extension SQLiteDB.Value {
    static func optional(_ text: String?) -> Self { text.map { .text($0) } ?? .null }
    static func optional(_ number: Int?) -> Self { number.map { .int(Int64($0)) } ?? .null }
    static func bool(_ value: Bool) -> Self { .int(value ? 1 : 0) }
}
