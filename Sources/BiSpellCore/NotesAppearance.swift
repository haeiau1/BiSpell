import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Notes UI themes: classic trio + fancy set (Rose Quartz, Sakura Dusk, Parchment Luxe).
public enum NotesTheme: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case paper
    case nightInk
    case roseQuartz
    case sakuraDusk
    case parchmentLuxe

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .paper: return "Paper"
        case .nightInk: return "Night Ink"
        case .roseQuartz: return "Rose Quartz"
        case .sakuraDusk: return "Sakura Dusk"
        case .parchmentLuxe: return "Parchment Luxe"
        }
    }
}

/// Writing font — System, Avenir Next, Palatino (fancy).
public enum NotesFontOption: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case avenirNext
    case palatino

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .avenirNext: return "Avenir Next"
        case .palatino: return "Palatino"
        }
    }

    /// PostScript / family names tried in order.
    public var fontNames: [String] {
        switch self {
        case .system: return []
        case .avenirNext: return ["Avenir Next", "AvenirNext-Regular"]
        case .palatino: return ["Palatino", "Palatino-Roman", "Palatino Linotype"]
        }
    }
}

public struct NotesAppearanceSettings: Codable, Equatable, Sendable {
    public var theme: NotesTheme
    public var font: NotesFontOption
    /// Point size for the body editor (title scales slightly larger in UI).
    public var fontSize: Double

    public static let `default` = NotesAppearanceSettings(
        theme: .system,
        font: .system,
        fontSize: 15
    )

    public init(theme: NotesTheme, font: NotesFontOption, fontSize: Double = 15) {
        self.theme = theme
        self.font = font
        self.fontSize = fontSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(NotesTheme.self, forKey: .theme) ?? .system
        font = try c.decodeIfPresent(NotesFontOption.self, forKey: .font) ?? .system
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 15
    }
}

public final class NotesAppearanceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "BiSpell.NotesAppearance"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> NotesAppearanceSettings {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(NotesAppearanceSettings.self, from: data) else {
            return .default
        }
        return value
    }

    public func save(_ settings: NotesAppearanceSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

#if canImport(AppKit)
public extension NotesTheme {
    struct Colors: Sendable {
        public var editorBackground: NSColor
        public var editorText: NSColor
        public var sidebarBackground: NSColor
        public var chromeBackground: NSColor
        public var secondaryText: NSColor
    }

    /// Resolve colors for the current appearance (light/dark for `.system`).
    func colors(effectiveDark: Bool) -> Colors {
        switch self {
        case .system:
            return Colors(
                editorBackground: .textBackgroundColor,
                editorText: .textColor,
                sidebarBackground: .windowBackgroundColor,
                chromeBackground: .windowBackgroundColor,
                secondaryText: .secondaryLabelColor
            )
        case .paper:
            // Warm cream paper + dark ink (readable in both OS modes).
            return Colors(
                editorBackground: NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.90, alpha: 1),
                editorText: NSColor(calibratedRed: 0.18, green: 0.14, blue: 0.10, alpha: 1),
                sidebarBackground: NSColor(calibratedRed: 0.94, green: 0.91, blue: 0.84, alpha: 1),
                chromeBackground: NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.87, alpha: 1),
                secondaryText: NSColor(calibratedRed: 0.40, green: 0.34, blue: 0.28, alpha: 1)
            )
        case .nightInk:
            return Colors(
                editorBackground: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1),
                editorText: NSColor(calibratedRed: 0.88, green: 0.89, blue: 0.91, alpha: 1),
                sidebarBackground: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.11, alpha: 1),
                chromeBackground: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1),
                secondaryText: NSColor(calibratedRed: 0.62, green: 0.64, blue: 0.68, alpha: 1)
            )
        case .roseQuartz:
            // Soft blush field + deep plum ink.
            return Colors(
                editorBackground: NSColor(calibratedRed: 0.97, green: 0.92, blue: 0.93, alpha: 1),
                editorText: NSColor(calibratedRed: 0.28, green: 0.14, blue: 0.22, alpha: 1),
                sidebarBackground: NSColor(calibratedRed: 0.92, green: 0.84, blue: 0.87, alpha: 1),
                chromeBackground: NSColor(calibratedRed: 0.95, green: 0.88, blue: 0.90, alpha: 1),
                secondaryText: NSColor(calibratedRed: 0.52, green: 0.36, blue: 0.42, alpha: 1)
            )
        case .sakuraDusk:
            // Atmospheric lavender-dark with pale rose text.
            return Colors(
                editorBackground: NSColor(calibratedRed: 0.14, green: 0.11, blue: 0.16, alpha: 1),
                editorText: NSColor(calibratedRed: 0.94, green: 0.86, blue: 0.90, alpha: 1),
                sidebarBackground: NSColor(calibratedRed: 0.11, green: 0.09, blue: 0.14, alpha: 1),
                chromeBackground: NSColor(calibratedRed: 0.17, green: 0.13, blue: 0.20, alpha: 1),
                secondaryText: NSColor(calibratedRed: 0.72, green: 0.60, blue: 0.70, alpha: 1)
            )
        case .parchmentLuxe:
            // Aged parchment + sepia ink (richer than Paper).
            return Colors(
                editorBackground: NSColor(calibratedRed: 0.95, green: 0.90, blue: 0.78, alpha: 1),
                editorText: NSColor(calibratedRed: 0.27, green: 0.18, blue: 0.10, alpha: 1),
                sidebarBackground: NSColor(calibratedRed: 0.88, green: 0.80, blue: 0.64, alpha: 1),
                chromeBackground: NSColor(calibratedRed: 0.91, green: 0.84, blue: 0.70, alpha: 1),
                secondaryText: NSColor(calibratedRed: 0.48, green: 0.36, blue: 0.22, alpha: 1)
            )
        }
    }
}

public extension NotesFontOption {
    func nsFont(size: CGFloat) -> NSFont {
        switch self {
        case .system:
            return NSFont.systemFont(ofSize: size)
        case .avenirNext, .palatino:
            for name in fontNames {
                if let font = NSFont(name: name, size: size) {
                    return font
                }
            }
            // Fallback chain
            if self == .palatino, let georgia = NSFont(name: "Georgia", size: size) {
                return georgia
            }
            return NSFont.systemFont(ofSize: size)
        }
    }
}
#endif
