import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Кольорова тема сторінки.
///
/// page – колір сторінки (фон), ink – колір тексту, outer – колір проміжків між сторінками,
/// bar / barText – верхня панель. Для PDF та зображень тема застосовується перефарбуванням:
/// світлі пікселі стають кольором сторінки, темні – кольором тексту.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case day = "DAY"
    case night = "NIGHT"
    case sepia = "SEPIA"
    case dusk = "DUSK"
    case contrast = "CONTRAST"
    case green = "GREEN"
    case blue = "BLUE"

    var id: String { rawValue }

    private var hex: (page: UInt32, ink: UInt32, outer: UInt32, bar: UInt32, barText: UInt32) {
        switch self {
        case .day: return (0xFFFFFF, 0x000000, 0xD5D5D5, 0xF2F2F2, 0x202020)
        case .night: return (0x000000, 0xFFFFFF, 0x2A2A2A, 0x101010, 0xFFFFFF)
        case .sepia: return (0xF4ECD8, 0x4A3828, 0xCFC2A3, 0xE6DAC0, 0x3B2C1F)
        case .dusk: return (0x2E2E2E, 0xD8D8D8, 0x181818, 0x202020, 0xE0E0E0)
        case .contrast: return (0x000000, 0xFFE135, 0x333333, 0x101010, 0xFFE135)
        case .green: return (0xCCE8CF, 0x1B2B1C, 0xA3C4A6, 0xB6D6B9, 0x1B2B1C)
        case .blue: return (0x0D1B2A, 0xE6EEF6, 0x050C14, 0x08121D, 0xE6EEF6)
        }
    }

    var title: String {
        switch self {
        case .day: return "Звичайна: чорний текст на білому"
        case .night: return "Нічна: білий текст на чорному"
        case .sepia: return "Сепія: коричневий на бежевому"
        case .dusk: return "Сутінки: світло-сірий на темно-сірому"
        case .contrast: return "Контрастна: жовтий на чорному"
        case .green: return "М'яка зелена: темний текст на зеленуватому"
        case .blue: return "Синя: білий текст на темно-синьому"
        }
    }

    var page: UIColor { UIColor(hex: hex.page) }
    var ink: UIColor { UIColor(hex: hex.ink) }
    var outer: UIColor { UIColor(hex: hex.outer) }
    var bar: UIColor { UIColor(hex: hex.bar) }
    var barText: UIColor { UIColor(hex: hex.barText) }

    /// Чи перефарбовувати растрові сторінки (для звичайної теми – ні).
    var recolor: Bool { self != .day }

    var isDark: Bool { ReaderTheme.luminance(hex.page) < 0.5 }

    static func luminance(_ c: UInt32) -> Double {
        let r = Double((c >> 16) & 0xFF), g = Double((c >> 8) & 0xFF), b = Double(c & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255
    }

    static func named(_ name: String?) -> ReaderTheme {
        name.flatMap(ReaderTheme.init(rawValue:)) ?? .day
    }
}
