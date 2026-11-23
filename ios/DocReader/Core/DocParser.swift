import Foundation

/// Витягує текст зі старого формату Word 97–2003 (.doc) через таблицю фрагментів (piece table).
/// Форматування не відтворюється – лише текст, абзаци та таблиці.
enum DocParser {

    static func parse(_ bytes: [UInt8]) throws -> [TextBlock] {
        let cfb = try Cfb(bytes)
        guard let wd = cfb.stream("WordDocument") else { throw DocError("У файлі немає тексту Word.") }
        guard wd.count >= 0x200 else { throw DocError("Пошкоджений файл .doc.") }
        let ident = le16(wd, 0)
        guard ident == 0xA5EC || ident == 0xA5DC else { throw DocError("Файл не є документом Word.") }
        let nFib = le16(wd, 2)
        let flags = le16(wd, 0x0A)
        if flags & 0x0100 != 0 { throw DocError("Документ зашифровано паролем.") }

        let text: String
        if nFib < 101 {
            // Word 6/95: текст лежить суцільно між fcMin і fcMac в однобайтовому кодуванні
            let fcMin = le32(wd, 0x18)
            let fcMac = le32(wd, 0x1C)
            guard fcMin >= 0, fcMac <= wd.count, fcMac > fcMin else { throw DocError("Не вдалося прочитати текст.") }
            text = decode(wd[fcMin..<fcMac], .windows1251)
        } else {
            text = try readPieces(cfb, wd, flags)
        }
        return try toBlocks(text)
    }

    private static func readPieces(_ cfb: Cfb, _ wd: [UInt8], _ flags: Int) throws -> String {
        guard let table = cfb.stream(flags & 0x0200 != 0 ? "1Table" : "0Table") else {
            throw DocError("Пошкоджений файл .doc (немає таблиці).")
        }
        // FIB: FibBase(32) → csw + fibRgW → cslw + fibRgLw → cbRgFcLcb + fibRgFcLcb
        var pos = 32
        let csw = le16(wd, pos); pos += 2 + csw * 2
        let cslw = le16(wd, pos)
        let rgLw = pos + 2
        pos += 2 + cslw * 4
        let ccpText = le32(wd, rgLw + 3 * 4)
        pos += 2 // cbRgFcLcb
        let fcClx = le32(wd, pos + 33 * 8)
        let lcbClx = le32(wd, pos + 33 * 8 + 4)
        let notFound = DocError("Не вдалося знайти текст у файлі.")
        guard fcClx >= 0, lcbClx > 0, fcClx + lcbClx <= table.count else { throw notFound }

        var p = fcClx
        let end = fcClx + lcbClx
        while p < end && table[p] == 0x01 {
            let cb = le16(table, p + 1)
            p += 3 + cb
        }
        guard p < end, table[p] == 0x02 else { throw notFound }
        let lcb = le32(table, p + 1)
        p += 5
        let n = (lcb - 4) / 12
        guard n > 0, p + lcb <= table.count else { throw notFound }

        var result = ""
        let limit = ccpText > 0 ? ccpText : Int.max
        for i in 0..<n {
            let cpStart = le32(table, p + i * 4)
            var cpEnd = le32(table, p + (i + 1) * 4)
            if cpStart >= limit { break }
            if cpEnd > limit { cpEnd = limit }
            let count = cpEnd - cpStart
            if count <= 0 { continue }
            let pcd = p + (n + 1) * 4 + i * 8
            let fcRaw = le32(table, pcd + 2)
            let compressed = fcRaw & 0x4000_0000 != 0
            if compressed {
                let off = (fcRaw & 0x3FFF_FFFF) / 2
                let len = min(count, wd.count - off)
                if off >= 0 && off < wd.count && len > 0 {
                    result += decode(wd[off..<(off + len)], .windowsCP1252)
                }
            } else {
                let off = fcRaw
                let len = min(count * 2, wd.count - off) & ~1
                if off >= 0 && off < wd.count && len > 0 {
                    result += decode(wd[off..<(off + len)], .utf16LittleEndian)
                }
            }
        }
        return result
    }

    /// Перетворює спеціальні символи Word на звичайний текст і ділить на абзаци.
    private static func toBlocks(_ raw: String) throws -> [TextBlock] {
        var sb = ""
        sb.reserveCapacity(raw.utf16.count)
        // для кожного рівня поля: true – вже показуємо результат (після роздільника 0x14)
        var showing: [Bool] = []
        for ch in raw.unicodeScalars {
            switch ch.value {
            case 0x13: showing.append(false); continue
            case 0x14: if !showing.isEmpty { showing[showing.count - 1] = true }; continue
            case 0x15: if !showing.isEmpty { showing.removeLast() }; continue
            default: break
            }
            if showing.contains(false) { continue }
            switch ch.value {
            case 0x0D, 0x0C: sb.append("\r")
            case 0x07: sb.append("\u{07}")
            case 0x0B: sb.append("\n")
            case 0x09: sb.append("\t")
            case 0x1E: sb.append("-")
            case 0x1F, 0x01, 0x08, 0x05, 0x02, 0x03, 0x04: break
            default: if ch.value >= 0x20 { sb.unicodeScalars.append(ch) }
            }
        }
        // кінець рядка таблиці – два маркери 0x07 поспіль
        let text = sb
            .replacingOccurrences(of: "\u{07}\u{07}", with: "\r")
            .replacingOccurrences(of: "\u{07}\r", with: "\r")
            .replacingOccurrences(of: "\u{07}", with: tableCellSeparator)
        var blocks: [TextBlock] = []
        for para in text.components(separatedBy: "\r") {
            let t = para.trimmingTrailingWhitespace()
            blocks.append(.paragraph(.plain(t, tableRow: t.contains(tableCellSeparator))))
        }
        trimTrailingEmpty(&blocks)
        if blocks.isEmpty { throw DocError("Документ порожній або текст не вдалося прочитати.") }
        return blocks
    }
}

extension String {
    /// Прибирає пробіли й переноси в кінці рядка (аналог Kotlin trimEnd()).
    func trimmingTrailingWhitespace() -> String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s)
    }
}
