import Accelerate
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import PaperReaderKit

// Opt-in experiment: end-to-end `SemanticPassageIndex.matches` latency over a pre-encoded
// on-disk cache. Run with `PAGEWISE_VECTOR_BENCH=1` in release mode. Synthetic data only.

private let benchDimension = 384

private func benchFootprintMiB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

private func benchVector(_ seed: UInt64) -> [Float] {
    var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    var values = [Float](repeating: 0, count: benchDimension)
    for j in 0..<benchDimension {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        values[j] = Float(state >> 40) / Float(1 << 24) - 0.5
    }
    return vDSP.divide(values, sqrt(vDSP.sumOfSquares(values)))
}

private actor PreEncodedEncoder: SemanticTextEncoder {
    nonisolated let identifier = "bench"
    private(set) var encodeCalls = 0
    func isInstalled() -> Bool { true }
    func retrievalQuery(_ text: String) -> (vector: [Float], minimum: Float)? {
        (benchVector(UInt64(text.count) &+ 7_777_777), 0)
    }
    func encode(_ texts: [String], as role: SemanticTextRole) -> [[Float]] {
        encodeCalls += texts.count
        return texts.map { benchVector(UInt64($0.hashValue.magnitude)) }
    }
}

private func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_VECTOR_BENCH"] == "1"))
func vectorIndexEndToEndBenchmark() async throws {
    let sizes = (ProcessInfo.processInfo.environment["PAGEWISE_VECTOR_BENCH_SIZES"] ?? "10000,50000,200000")
        .split(separator: ",").compactMap { Int($0) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pagewise-e2e-bench-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let filler = String(repeating: "Equal compute budgets were matched across ablations. ", count: 6)
    var lines = ["N | cold first matches ms | warm p50 ms | warm p95 ms | footprint delta MiB | sqlite MiB"]

    for n in sizes {
        let sources = (0..<max(1, n / 100)).map { _ in UUID() }
        let passages = (0..<n).map { i in
            SemanticPassage(sourceID: sources[i / 100 % sources.count], chunk: i % 100, text: "\(i) \(filler)")
        }
        let url = root.appendingPathComponent("vectors-\(n).sqlite")
        let seed = SemanticVectorCache(url: url, namespace: "papers")
        _ = try seed.load(writer: "seed")
        var batch: [Data: [Float]] = [:]
        for (i, p) in passages.enumerated() {
            let key = Data(SHA256.hash(data: Data("bench/v1/\(p.sourceID)/\(p.chunk)/\(p.text)".utf8)))
            batch[key] = benchVector(UInt64(i))
            if batch.count == 5_000 || i == n - 1 {
                try seed.update(adding: batch, removing: [], writer: "seed")
                batch = [:]
            }
        }
        let fileMiB =
            Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1_048_576

        let encoder = PreEncodedEncoder()
        let index = SemanticPassageIndex(encoder: encoder, cacheURL: url, namespace: "papers")
        let allowed = Set(sources)
        let clock = ContinuousClock()
        let before = benchFootprintMiB()
        var first: [SemanticMatch] = []
        let cold = try await clock.measure {
            first = try await index.matches("query", passages: passages, allowed: allowed, limit: 20)
        }
        let delta = benchFootprintMiB() - before
        #expect(first.count == 20)
        #expect(await encoder.encodeCalls == 0)
        var samples: [Double] = []
        for run in 0..<16 {
            let elapsed = try await clock.measure {
                _ = try await index.matches("query \(run)", passages: passages, allowed: allowed, limit: 20)
            }
            if run > 0 { samples.append(ms(elapsed)) }
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[min(samples.count - 1, Int(Double(samples.count - 1) * 0.95))]
        lines.append("\(n) | \(ms(cold)) | \(p50) | \(p95) | \(delta) | \(fileMiB)")
    }
    print("VECTOR_E2E_BENCH\n" + lines.joined(separator: "\n"))
}
