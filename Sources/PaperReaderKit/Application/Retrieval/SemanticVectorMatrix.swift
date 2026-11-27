import Accelerate
import Foundation

/// Contiguous row-major store of semantic unit vectors keyed by passage fingerprint.
///
/// One `vDSP_mmul` scores every row in a single pass, replacing per-vector dictionary lookups and
/// dot products. Removed rows are zeroed and reused; the matrix compacts when mostly empty.
struct SemanticVectorMatrix: Sendable {
    private(set) var dimension = 0
    private var storage: [Float] = []
    private var rowOf: [Data: Int] = [:]
    private var freeRows: [Int] = []

    var count: Int { rowOf.count }
    var isEmpty: Bool { rowOf.isEmpty }
    var keys: Dictionary<Data, Int>.Keys { rowOf.keys }
    /// Allocated rows, including zeroed free rows awaiting reuse.
    var rowCount: Int { dimension == 0 ? 0 : storage.count / dimension }

    func contains(_ key: Data) -> Bool { rowOf[key] != nil }
    func row(of key: Data) -> Int? { rowOf[key] }

    subscript(key: Data) -> [Float]? {
        guard let row = rowOf[key] else { return nil }
        return Array(storage[row * dimension..<(row + 1) * dimension])
    }

    mutating func reserveCapacity(rows: Int, dimension: Int) {
        guard self.dimension == 0 || self.dimension == dimension else { return }
        self.dimension = dimension
        storage.reserveCapacity(rows * dimension)
        rowOf.reserveCapacity(rows)
    }

    /// Copies raw little-endian `Float32` bytes (any alignment) into a row. Returns `false` when
    /// the vector is empty, has a different dimension or contains non-finite values.
    @discardableResult
    mutating func insert(_ key: Data, bytes: UnsafeRawBufferPointer) -> Bool {
        let width = bytes.count / MemoryLayout<Float>.size
        guard width > 0, bytes.count % MemoryLayout<Float>.size == 0 else { return false }
        if rowOf.isEmpty && freeRows.isEmpty && storage.isEmpty { dimension = width }
        guard width == dimension else { return false }
        let row: Int
        if let existing = rowOf[key] {
            row = existing
        } else if let reused = freeRows.popLast() {
            row = reused
        } else {
            row = rowCount
            storage.append(contentsOf: repeatElement(0, count: dimension))
        }
        let finite = storage.withUnsafeMutableBufferPointer { buffer -> Bool in
            let target = UnsafeMutableRawBufferPointer(
                start: buffer.baseAddress! + row * dimension, count: dimension * MemoryLayout<Float>.size)
            target.copyMemory(from: bytes)
            return buffer[row * dimension..<(row + 1) * dimension].allSatisfy(\.isFinite)
        }
        guard finite else {
            release(row)
            if rowOf[key] == row { rowOf.removeValue(forKey: key) }
            return false
        }
        rowOf[key] = row
        return true
    }

    @discardableResult
    mutating func insert(_ key: Data, _ vector: [Float]) -> Bool {
        vector.withUnsafeBytes { insert(key, bytes: $0) }
    }

    mutating func remove(_ key: Data) {
        guard let row = rowOf.removeValue(forKey: key) else { return }
        release(row)
        if rowOf.isEmpty {
            self = SemanticVectorMatrix()
        } else if freeRows.count >= 1_024, freeRows.count * 2 > rowCount {
            compact()
        }
    }

    private mutating func release(_ row: Int) {
        storage.withUnsafeMutableBufferPointer { buffer in
            (buffer.baseAddress! + row * dimension).update(repeating: 0, count: dimension)
        }
        freeRows.append(row)
    }

    private mutating func compact() {
        var next = SemanticVectorMatrix()
        next.reserveCapacity(rows: rowOf.count, dimension: dimension)
        storage.withUnsafeBytes { raw in
            let stride = dimension * MemoryLayout<Float>.size
            for (key, row) in rowOf.sorted(by: { $0.value < $1.value }) {
                next.insert(key, bytes: UnsafeRawBufferPointer(rebasing: raw[row * stride..<(row + 1) * stride]))
            }
        }
        self = next
    }

    /// Scores every allocated row against `query` (`rowCount x dimension` times `dimension x 1`).
    func scores(_ query: [Float]) -> [Float]? {
        guard dimension > 0, query.count == dimension else { return nil }
        let rows = rowCount
        var out = [Float](repeating: 0, count: rows)
        guard rows > 0 else { return out }
        storage.withUnsafeBufferPointer { matrix in
            query.withUnsafeBufferPointer { vector in
                out.withUnsafeMutableBufferPointer { result in
                    vDSP_mmul(
                        matrix.baseAddress!, 1, vector.baseAddress!, 1, result.baseAddress!, 1,
                        vDSP_Length(rows), 1, vDSP_Length(dimension))
                }
            }
        }
        return out
    }

    /// Scores one row; cheaper than `scores(_:)` when only a few rows are eligible.
    func score(row: Int, _ query: [Float]) -> Float {
        storage.withUnsafeBufferPointer { matrix in
            query.withUnsafeBufferPointer { vector in
                var result: Float = 0
                vDSP_dotpr(
                    matrix.baseAddress! + row * dimension, 1, vector.baseAddress!, 1, &result,
                    vDSP_Length(dimension))
                return result
            }
        }
    }
}
