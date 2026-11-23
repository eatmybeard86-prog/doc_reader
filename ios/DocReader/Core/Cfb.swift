import Foundation

/// Мінімальний читач OLE2 / Compound File Binary (контейнер старих .doc).
final class Cfb {
    private struct Entry {
        let name: String
        let type: Int
        let start: Int
        let size: Int
    }

    private let data: [UInt8]
    private let sectorShift: Int
    private let sectorSize: Int
    private let miniShift: Int
    private let miniCutoff: Int
    private let fat: [Int]
    private let miniFat: [Int]
    private let entries: [Entry]
    private let miniStream: [UInt8]

    init(_ data: [UInt8]) throws {
        self.data = data
        guard data.count >= 512, le32u(data, 0) == 0xE011_CFD0, le32u(data, 4) == 0xE11A_B1A1 else {
            throw DocError("Файл не є документом Word 97–2003.")
        }
        let shift = le16(data, 0x1E)
        guard (7...16).contains(shift) else { throw DocError("Пошкоджений файл .doc.") }
        sectorShift = shift
        sectorSize = 1 << shift
        miniShift = le16(data, 0x20)
        let numFat = le32(data, 0x2C)
        let firstDir = le32(data, 0x30)
        miniCutoff = Int(le32u(data, 0x38))
        let firstMiniFat = le32(data, 0x3C)
        var difatSector = le32(data, 0x44)

        let sSize = sectorSize
        func sectorOffset(_ sid: Int) -> Int { (sid + 1) << shift }

        // список секторів FAT
        var fatSectors: [Int] = []
        for i in 0..<109 {
            let s = le32(data, 0x4C + i * 4)
            if s >= 0 { fatSectors.append(s) }
        }
        var guardCount = 0
        while difatSector >= 0 && guardCount < 100_000 {
            guardCount += 1
            let off = sectorOffset(difatSector)
            guard off + sSize <= data.count else { break }
            let per = sSize / 4 - 1
            for i in 0..<per {
                let s = le32(data, off + i * 4)
                if s >= 0 { fatSectors.append(s) }
            }
            difatSector = le32(data, off + per * 4)
        }
        if numFat > 0 && fatSectors.count > numFat { fatSectors = Array(fatSectors.prefix(numFat)) }
        let per = sSize / 4
        var fatTable = [Int](repeating: -2, count: fatSectors.count * per)
        for (idx, s) in fatSectors.enumerated() {
            let off = sectorOffset(s)
            for i in 0..<per where off + i * 4 + 4 <= data.count {
                fatTable[idx * per + i] = le32(data, off + i * 4)
            }
        }
        fat = fatTable

        // каталог
        let dir = Cfb.readChain(source: data, start: firstDir, table: fatTable, size: sSize, offset: sectorOffset)
        var list: [Entry] = []
        var pos = 0
        while pos + 128 <= dir.count {
            let nameLen = le16(dir, pos + 64)
            let chars = min(max(nameLen / 2 - 1, 0), 31)
            var units: [UInt16] = []
            for i in 0..<chars { units.append(UInt16(le16(dir, pos + i * 2))) }
            let type = Int(dir[pos + 66])
            list.append(Entry(name: String(decoding: units, as: UTF16.self), type: type,
                              start: le32(dir, pos + 116), size: Int(le32u(dir, pos + 120))))
            pos += 128
        }
        entries = list

        if firstMiniFat >= 0 {
            let b = Cfb.readChain(source: data, start: firstMiniFat, table: fatTable, size: sSize, offset: sectorOffset)
            miniFat = (0..<(b.count / 4)).map { le32(b, $0 * 4) }
        } else {
            miniFat = []
        }
        if let root = list.first(where: { $0.type == 5 }), root.start >= 0 {
            miniStream = Cfb.readChain(source: data, start: root.start, table: fatTable, size: sSize, offset: sectorOffset)
        } else {
            miniStream = []
        }
    }

    func stream(_ name: String) -> [UInt8]? {
        guard let e = entries.first(where: { $0.type == 2 && $0.name == name }) else { return nil }
        let bytes: [UInt8]
        if e.size < miniCutoff {
            // малі потоки зберігаються всередині miniStream
            let ms = miniShift
            bytes = Cfb.readChain(source: miniStream, start: e.start, table: miniFat, size: 1 << ms) { $0 << ms }
        } else {
            let sh = sectorShift
            bytes = Cfb.readChain(source: data, start: e.start, table: fat, size: sectorSize) { ($0 + 1) << sh }
        }
        return bytes.count > e.size ? Array(bytes.prefix(e.size)) : bytes
    }

    private static func readChain(source: [UInt8], start: Int, table: [Int], size: Int, offset: (Int) -> Int) -> [UInt8] {
        var out: [UInt8] = []
        var s = start
        var guardCount = 0
        while s >= 0 && s < table.count && guardCount <= table.count {
            guardCount += 1
            let off = offset(s)
            if off < 0 || off >= source.count { break }
            out.append(contentsOf: source[off..<min(off + size, source.count)])
            s = table[s]
        }
        return out
    }
}
