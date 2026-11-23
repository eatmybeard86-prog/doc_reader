import Foundation
import Compression

/// Мінімальний читач ZIP (для DOCX). Підтримуються методи stored та deflate.
final class ZipArchive {
    struct Entry {
        let name: String
        let method: Int
        let compressedSize: Int
        let size: Int
        let localOffset: Int
    }

    private let bytes: [UInt8]
    private(set) var entries: [String: Entry] = [:]

    init(data: Data) throws {
        bytes = [UInt8](data)
        let n = bytes.count
        guard n >= 22 else { throw DocError("Пошкоджений архів.") }
        // кінець центрального каталогу
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 22 - 65_535)
        while i >= stop {
            if le32u(bytes, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw DocError("Пошкоджений архів (немає каталогу).") }
        let count = le16(bytes, eocd + 10)
        var p = Int(le32u(bytes, eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= n, le32u(bytes, p) == 0x0201_4B50 else { break }
            let method = le16(bytes, p + 10)
            let comp = Int(le32u(bytes, p + 20))
            let size = Int(le32u(bytes, p + 24))
            let nameLen = le16(bytes, p + 28)
            let extraLen = le16(bytes, p + 30)
            let commentLen = le16(bytes, p + 32)
            let local = Int(le32u(bytes, p + 42))
            guard p + 46 + nameLen <= n else { break }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: comp, size: size, localOffset: local)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    func contains(_ name: String) -> Bool { entry(name) != nil }

    private func entry(_ name: String) -> Entry? {
        if let e = entries[name] { return e }
        let lower = name.lowercased()
        return entries.first { $0.key.lowercased() == lower }?.value
    }

    func read(_ name: String) -> Data? {
        guard let e = entry(name) else { return nil }
        let lh = e.localOffset
        guard lh + 30 <= bytes.count, le32u(bytes, lh) == 0x0403_4B50 else { return nil }
        let start = lh + 30 + le16(bytes, lh + 26) + le16(bytes, lh + 28)
        guard start >= 0, start + e.compressedSize <= bytes.count else { return nil }
        let src = Array(bytes[start..<(start + e.compressedSize)])
        switch e.method {
        case 0: return Data(src)
        case 8: return ZipArchive.inflate(src, size: e.size)
        default: return nil
        }
    }

    /// Розпаковує «сирий» deflate-потік (саме такий формат у ZIP).
    static func inflate(_ src: [UInt8], size: Int) -> Data? {
        if size == 0 { return Data() }
        if src.isEmpty { return nil }
        var out = [UInt8](repeating: 0, count: size)
        let written = src.withUnsafeBufferPointer { s -> Int in
            out.withUnsafeMutableBufferPointer { d -> Int in
                compression_decode_buffer(d.baseAddress!, size, s.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        if written <= 0 { return nil }
        return Data(out[0..<written])
    }
}

/// Простий запис ZIP без стиснення (для збереження DOCX).
struct ZipWriter {
    private var out: [UInt8] = []
    private var central: [UInt8] = []
    private var count = 0

    private static func put16(_ v: Int, _ a: inout [UInt8]) {
        a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
    }

    private static func put32(_ v: UInt32, _ a: inout [UInt8]) {
        a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
        a.append(UInt8((v >> 16) & 0xFF)); a.append(UInt8((v >> 24) & 0xFF))
    }

    mutating func add(_ name: String, _ data: Data) {
        let nameBytes = Array(name.utf8)
        let body = [UInt8](data)
        let crc = CRC32.checksum(body)
        let size = UInt32(body.count)
        let offset = UInt32(out.count)

        // локальний заголовок
        ZipWriter.put32(0x0403_4B50, &out)
        ZipWriter.put16(20, &out)        // версія
        ZipWriter.put16(0x0800, &out)    // імена в UTF-8
        ZipWriter.put16(0, &out)         // без стиснення
        ZipWriter.put16(0, &out)         // час
        ZipWriter.put16(0x21, &out)      // дата 1980-01-01
        ZipWriter.put32(crc, &out)
        ZipWriter.put32(size, &out)
        ZipWriter.put32(size, &out)
        ZipWriter.put16(nameBytes.count, &out)
        ZipWriter.put16(0, &out)
        out.append(contentsOf: nameBytes)
        out.append(contentsOf: body)

        // запис центрального каталогу
        ZipWriter.put32(0x0201_4B50, &central)
        ZipWriter.put16(20, &central)
        ZipWriter.put16(20, &central)
        ZipWriter.put16(0x0800, &central)
        ZipWriter.put16(0, &central)
        ZipWriter.put16(0, &central)
        ZipWriter.put16(0x21, &central)
        ZipWriter.put32(crc, &central)
        ZipWriter.put32(size, &central)
        ZipWriter.put32(size, &central)
        ZipWriter.put16(nameBytes.count, &central)
        ZipWriter.put16(0, &central)     // extra
        ZipWriter.put16(0, &central)     // comment
        ZipWriter.put16(0, &central)     // disk
        ZipWriter.put16(0, &central)     // internal attrs
        ZipWriter.put32(0, &central)     // external attrs
        ZipWriter.put32(offset, &central)
        central.append(contentsOf: nameBytes)
        count += 1
    }

    func finish() -> Data {
        var result = out
        let cdOffset = UInt32(out.count)
        result.append(contentsOf: central)
        ZipWriter.put32(0x0605_4B50, &result)
        ZipWriter.put16(0, &result)
        ZipWriter.put16(0, &result)
        ZipWriter.put16(count, &result)
        ZipWriter.put16(count, &result)
        ZipWriter.put32(UInt32(central.count), &result)
        ZipWriter.put32(cdOffset, &result)
        ZipWriter.put16(0, &result)
        return Data(result)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}
