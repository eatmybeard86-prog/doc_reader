import Foundation

/// Дуже простий конвертер RTF → текст. Використовується, якщо вбудований у систему розбір RTF не впорався.
enum RtfParser {
    private static let skipDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer", "headerl", "headerr",
        "headerf", "footerl", "footerr", "footerf", "footnote", "object", "themedata", "colorschememapping",
        "latentstyles", "datastore", "xmlnstbl", "listtable", "listoverridetable", "rsidtbl", "generator",
        "filetbl", "revtbl", "pgdsctbl", "fldinst", "bkmkstart", "bkmkend", "shppict", "nonshppict",
    ]

    static func parse(_ bytes: [UInt8]) throws -> [TextBlock] {
        // ISO-8859-1: кожен байт – один символ
        let src = bytes.map { Character(Unicode.Scalar($0)) }
        let srcString = String(src)
        var encoding: String.Encoding = .windowsCP1252
        if let r = srcString.range(of: "\\\\ansicpg(\\d+)", options: .regularExpression) {
            let digits = srcString[r].dropFirst("\\ansicpg".count)
            if let cp = Int(digits), let enc = String.Encoding.windowsCodePage(cp) { encoding = enc }
        }
        if encoding == .windowsCP1252 && srcString.contains("\\fcharset204") { encoding = .windows1251 }

        var out = ""
        var pending: [UInt8] = [] // байти \'hh, що декодуються разом
        func flushBytes() {
            if !pending.isEmpty {
                out += decode(pending[...], encoding)
                pending.removeAll()
            }
        }

        var skipStack: [Bool] = []
        var ucStack: [Int] = []
        var skip = false
        var uc = 1
        var toSkip = 0 // символів для пропуску після \uN
        var i = 0
        let n = src.count
        while i < n {
            let c = src[i]
            switch c {
            case "{":
                skipStack.append(skip); ucStack.append(uc); i += 1
            case "}":
                flushBytes()
                if !skipStack.isEmpty { skip = skipStack.removeLast(); uc = ucStack.removeLast() }
                i += 1
            case "\\":
                i += 1
                if i >= n { break }
                let d = src[i]
                if d == "'" {
                    let hex = String(src[(i + 1)..<min(i + 3, n)])
                    i += 3
                    if toSkip > 0 { toSkip -= 1; continue }
                    if !skip, let v = UInt8(hex, radix: 16) { pending.append(v) }
                    continue
                }
                if !d.isLetter {
                    i += 1
                    if d == "*" { skip = true; continue }
                    if toSkip > 0 { toSkip -= 1; continue }
                    flushBytes()
                    if !skip {
                        switch d {
                        case "\\", "{", "}": out.append(d)
                        case "~": out.append(" ")
                        case "_": out.append("-")
                        case "\n", "\r", "\r\n": out.append("\n")
                        default: break
                        }
                    }
                    continue
                }
                let startWord = i
                while i < n && src[i].isLetter && src[i].isASCII { i += 1 }
                let word = String(src[startWord..<i])
                let startNum = i
                if i < n && (src[i] == "-" || src[i].isNumber) {
                    i += 1
                    while i < n && src[i].isNumber && src[i].isASCII { i += 1 }
                }
                let num = Int(String(src[startNum..<i]))
                if i < n && src[i] == " " { i += 1 }
                flushBytes()
                if skipDestinations.contains(word) { skip = true; continue }
                if skip { continue }
                switch word {
                case "par", "line", "sect", "page", "row": out.append("\n")
                case "cell": out += tableCellSeparator
                case "tab": out.append("\t")
                case "emdash": out.append("—")
                case "endash": out.append("–")
                case "bullet": out.append("•")
                case "lquote": out.append("‘")
                case "rquote": out.append("’")
                case "ldblquote": out.append("“")
                case "rdblquote": out.append("”")
                case "uc": uc = num ?? 1
                case "u":
                    var code = num ?? 0
                    if code < 0 { code += 65_536 }
                    if let scalar = Unicode.Scalar(UInt32(code)) { out.unicodeScalars.append(scalar) }
                    toSkip = uc
                default: break
                }
            case "\r", "\n", "\r\n":
                i += 1
            default:
                i += 1
                if toSkip > 0 { toSkip -= 1; continue }
                if !skip { flushBytes(); out.append(c) }
            }
        }
        flushBytes()
        var blocks: [TextBlock] = out.components(separatedBy: "\n").map { line in
            let t = line.trimmingTrailingWhitespace()
            return .paragraph(.plain(t, tableRow: t.contains(tableCellSeparator)))
        }
        trimTrailingEmpty(&blocks)
        if blocks.isEmpty { throw DocError("Документ порожній.") }
        return blocks
    }
}
