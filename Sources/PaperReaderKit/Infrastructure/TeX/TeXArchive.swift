import Foundation
import zlib

/// Bounded in-memory reader. Archive names never become filesystem write capabilities.
enum TeXArchive {
    static let expandedLimit = 200_000_000

    static func looksLikeSource(_ data: Data) -> Bool {
        if data.starts(with: [0x1f, 0x8b]) { return true }
        if data.count >= 512, tarChecksum(Array(data.prefix(512))) { return true }
        return String(data: data, encoding: .utf8)?.contains("\\documentclass") == true
            || String(data: data, encoding: .utf8)?.contains("\\documentstyle") == true
    }

    static func unpack(_ original: Data) throws -> [String: Data] {
        guard !original.isEmpty, original.count <= 50_000_000 else { throw failure("源码包过大或为空") }
        let data = try original.starts(with: [0x1f, 0x8b]) ? gunzip(original) : original
        try Task.checkCancellation()
        if data.count < 512 || !tarChecksum(Array(data.prefix(512))) {
            guard let text = String(data: data, encoding: .utf8), text.contains("\\begin{document}"),
                !text.contains("\0"), data.count <= 8_000_000
            else { throw failure("源码格式无法识别") }
            return ["main.tex": data]
        }
        var files: [String: Data] = [:]
        var seen: Set<String> = []
        var cursor = 0
        var entries = 0
        while cursor + 512 <= data.count {
            try Task.checkCancellation()
            let header = Array(data[cursor..<(cursor + 512)])
            if header.allSatisfy({ $0 == 0 }) {
                guard data[cursor...].allSatisfy({ $0 == 0 }) else { throw failure("源码包尾部无效") }
                guard !files.isEmpty else { throw failure("源码包没有文件") }
                return files
            }
            entries += 1
            guard entries <= 1_000, tarChecksum(header), let size = octal(header[124..<136]),
                size <= expandedLimit, size <= data.count - cursor - 512
            else { throw failure("源码包损坏或超出解包限制") }
            let type = header[156]
            guard [0, 48, 53].contains(type) else { throw failure("源码包含不支持的链接或归档记录") }
            let prefix = string(header[345..<500])
            let name = string(header[0..<100])
            let raw = prefix.isEmpty ? name : prefix + "/" + name
            if type == 53, [".", "./"].contains(raw), size == 0 {
                cursor += 512
                continue
            }
            let path = try safePath(raw)
            guard seen.insert(path).inserted else { throw failure("源码包含重复路径") }
            if type != 53 {
                files[path] = data.subdata(in: (cursor + 512)..<(cursor + 512 + size))
            } else if size != 0 {
                throw failure("源码目录记录无效")
            }
            cursor += 512 + ((size + 511) / 512) * 512
        }
        throw failure("源码包不完整")
    }

    static func safePath(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\\"), !raw.contains(":"),
            !raw.contains("\0"), raw.utf8.count <= 1_024
        else { throw failure("源码路径无效") }
        let parts = raw.split(separator: "/")
        guard !parts.contains("..") else { throw failure("源码路径越界") }
        let result = parts.filter { $0 != "." }.joined(separator: "/")
        guard !result.isEmpty else { throw failure("源码路径为空") }
        return result
    }

    private static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw failure("无法准备源码解压")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try Task.checkCancellation()
                let status = buffer.withUnsafeMutableBytes { bytes in
                    stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = 65_536
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = 65_536 - Int(stream.avail_out)
                guard output.count + count <= expandedLimit else { throw failure("源码解压后体积超限") }
                output.append(contentsOf: buffer.prefix(count))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw failure("源码包含多个压缩流或尾部数据") }
                    return output
                }
                guard status == Z_OK, count > 0 || stream.avail_in > 0 else { throw failure("源码压缩流损坏") }
            }
        }
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    private static func octal(_ bytes: ArraySlice<UInt8>) -> Int? {
        let value = string(bytes).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? 0 : Int(value, radix: 8)
    }
    private static func tarChecksum(_ header: [UInt8]) -> Bool {
        guard header.count == 512, let stored = octal(header[148..<156]) else { return false }
        return stored == header.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
    }
    static func failure(_ reason: String) -> ReaderError { .message("TeX：\(reason)。") }
}
