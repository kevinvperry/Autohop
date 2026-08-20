import Foundation
import GRDB

// AI CONTEXT — tvOS compact projection database. This is intentionally a
// separate purgeable GRDB store from the full synced domain database. It gives
// launch/focus rendering a bounded data set and prevents SwiftUI from traversing
// every Subscription/Episode graph. Authoritative data remains CloudKit/iPhone.
public final class TVProjectionStore: @unchecked Sendable {
    private let db: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String) throws {
        db = try DatabaseQueue(path: path)
        try db.write { database in
            try database.create(table: "tv_projection", ifNotExists: true) { table in
                table.column("key", .text).primaryKey()
                table.column("updatedAt", .double).notNull()
                table.column("payload", .blob).notNull()
            }
        }
    }

    public func loadLibrary() throws -> [TVLibraryProjectionEntry] {
        try load([TVLibraryProjectionEntry].self, key: "library") ?? []
    }

    public func libraryUpdatedAt() throws -> Date? {
        try db.read { database in
            guard let seconds = try Double.fetchOne(
                database,
                sql: "SELECT updatedAt FROM tv_projection WHERE key = ?",
                arguments: ["library"]
            ) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    public func saveLibrary(_ entries: [TVLibraryProjectionEntry]) throws {
        try save(entries, key: "library")
    }

    public func loadQueue() throws -> QueueSnapshot? { try load(QueueSnapshot.self, key: "queue") }
    public func saveQueue(_ snapshot: QueueSnapshot) throws { try save(snapshot, key: "queue") }

    public func loadEpisodes(subscriptionID: UUID) throws -> TVEpisodeProjection? {
        try load(TVEpisodeProjection.self, key: "episodes:\(subscriptionID.uuidString)")
    }

    public func saveEpisodes(_ projection: TVEpisodeProjection) throws {
        try save(projection, key: "episodes:\(projection.subscriptionID.uuidString)")
        try db.write { database in
            let keys = try Row.fetchAll(database, sql: "SELECT key FROM tv_projection WHERE key LIKE 'episodes:%' ORDER BY updatedAt DESC")
                .compactMap { $0["key"] as String? }
            for key in keys.dropFirst(12) {
                try database.execute(sql: "DELETE FROM tv_projection WHERE key = ?", arguments: [key])
            }
        }
    }

    public func purge() throws {
        try db.write { try $0.execute(sql: "DELETE FROM tv_projection") }
    }

    private func load<Value: Decodable>(_ type: Value.Type, key: String) throws -> Value? {
        try db.read { database in
            guard let data: Data = try Data.fetchOne(database, sql: "SELECT payload FROM tv_projection WHERE key = ?", arguments: [key]) else { return nil }
            return try decoder.decode(type, from: data)
        }
    }

    private func save<Value: Encodable>(_ value: Value, key: String) throws {
        let data = try encoder.encode(value)
        try db.write { database in
            try database.execute(
                sql: "INSERT INTO tv_projection(key, updatedAt, payload) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET updatedAt=excluded.updatedAt, payload=excluded.payload",
                arguments: [key, Date().timeIntervalSince1970, data]
            )
        }
    }
}
