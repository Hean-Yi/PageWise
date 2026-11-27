import CSQLite
import Foundation
import Testing

@testable import PaperReaderKit

@Test func semanticVectorMatrixReusesRowsCompactsAndRejectsInvalidVectors() throws {
    var matrix = SemanticVectorMatrix()
    let key = { (i: Int) in Data(repeating: UInt8(i % 251), count: 31) + Data([UInt8(i / 251)]) }
    for i in 0..<3_000 {
        let inserted = matrix.insert(key(i), [Float(i), 1, 0])
        #expect(inserted)
    }
    #expect(matrix.count == 3_000 && matrix.dimension == 3)
    let wrongDimension = matrix.insert(key(9_999), [1, 2])
    #expect(!wrongDimension)
    let nonFinite = matrix.insert(key(9_998), [.nan, 0, 0])
    #expect(!nonFinite)
    #expect(!matrix.contains(key(9_998)))
    for i in 0..<2_000 { matrix.remove(key(i)) }
    #expect(matrix.count == 1_000)
    #expect(matrix.rowCount < 3_000)  // compacted once most rows were free
    #expect(matrix[key(2_500)] == [2_500, 1, 0])
    let scores = try #require(matrix.scores([0, 1, 0]))
    #expect(scores[try #require(matrix.row(of: key(2_999)))] == 1)
    #expect(matrix.score(row: try #require(matrix.row(of: key(2_100))), [1, 0, 0]) == 2_100)
    for i in 2_000..<3_000 { matrix.remove(key(i)) }
    #expect(matrix.isEmpty && matrix.dimension == 0)
    let resized = matrix.insert(key(1), [1, 0, 0, 0])  // a new encoder space may change the width
    #expect(resized)
}

@Test func vectorCacheMovesLegacyWithoutRowidVectorsInsteadOfReencoding() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("vectors.sqlite")
    let key = Data(repeating: 0x42, count: 32)
    let vector: [Float] = [0.6, 0.8]
    try LibraryStore.database(at: url) { db in
        try LibraryStore.execute(
            db,
            "CREATE TABLE vectors_ns (namespace BLOB NOT NULL, fingerprint BLOB NOT NULL, vector BLOB NOT NULL, PRIMARY KEY (namespace, fingerprint)) WITHOUT ROWID"
        )
        try LibraryRecords.statement(db, "INSERT INTO vectors_ns VALUES(?,?,?)") { stmt in
            try LibraryRecords.bind(Data("notes".utf8), to: 1, in: stmt)
            try LibraryRecords.bind(key, to: 2, in: stmt)
            try LibraryRecords.bind(vector.withUnsafeBytes { Data($0) }, to: 3, in: stmt)
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }
    #expect(try SemanticVectorCache(url: url, namespace: "papers").load().isEmpty)
    #expect(try SemanticVectorCache(url: url, namespace: "notes").load()[key] == vector)
    let legacyLeft = try LibraryStore.database(at: url) { db in
        try LibraryRecords.statement(db, "SELECT 1 FROM sqlite_master WHERE name='vectors_ns'") {
            sqlite3_step($0) == SQLITE_ROW
        }
    }
    #expect(!legacyLeft)
}
