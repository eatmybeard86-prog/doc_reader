import Foundation

/// Помилка відкриття документа з повідомленням для користувача.
struct DocError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum TextAlign: Int {
    case start, center, end, justify
}

/// Фрагмент тексту з однаковим форматуванням.
struct TextRun: Equatable {
    var text: String
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    /// Розмір відносно основного шрифту (1 – звичайний).
    var size: Double = 1
}

/// Абзац тексту (DOC/DOCX/RTF).
struct TextParagraph: Equatable {
    var runs: [TextRun] = []
    var align: TextAlign = .start
    var heading = 0
    var tableRow = false

    var plainText: String { runs.map(\.text).joined() }

    static func plain(_ text: String, tableRow: Bool = false) -> TextParagraph {
        TextParagraph(runs: text.isEmpty ? [] : [TextRun(text: text)], tableRow: tableRow)
    }
}

/// Елемент текстового документа: абзац або вбудоване зображення.
enum TextBlock: Equatable {
    case paragraph(TextParagraph)
    /// Ключ зображення (шлях усередині DOCX або внутрішній ідентифікатор).
    case image(String)

    var paragraph: TextParagraph? {
        if case .paragraph(let p) = self { return p }
        return nil
    }
}

/// Розділювач комірок таблиці в рядку.
let tableCellSeparator = "   │   "

/// Прибирає порожні абзаци в кінці документа.
func trimTrailingEmpty(_ blocks: inout [TextBlock]) {
    while let last = blocks.last, let p = last.paragraph,
          p.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        blocks.removeLast()
    }
}

// MARK: - Читання чисел little-endian

@inline(__always) func le16(_ b: [UInt8], _ off: Int) -> Int {
    guard off >= 0, off + 2 <= b.count else { return 0 }
    return Int(b[off]) | (Int(b[off + 1]) << 8)
}

@inline(__always) func le32u(_ b: [UInt8], _ off: Int) -> UInt32 {
    guard off >= 0, off + 4 <= b.count else { return 0 }
    return UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
}

/// 32-бітне число зі знаком (як у Kotlin-версії: -1, -2 … – спеціальні значення).
@inline(__always) func le32(_ b: [UInt8], _ off: Int) -> Int {
    Int(Int32(bitPattern: le32u(b, off)))
}

extension String.Encoding {
    static let windows1251 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))

    /// Кодова сторінка Windows за номером (1250, 1251, …).
    static func windowsCodePage(_ cp: Int) -> String.Encoding? {
        let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(cp))
        if cf == kCFStringEncodingInvalidId { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

func decode(_ bytes: ArraySlice<UInt8>, _ encoding: String.Encoding) -> String {
    String(data: Data(bytes), encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
}
