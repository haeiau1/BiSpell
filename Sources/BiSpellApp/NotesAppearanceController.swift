import AppKit
import SwiftUI
import Combine
import BiSpellCore

@MainActor
final class NotesAppearanceController: ObservableObject {
    @Published var settings: NotesAppearanceSettings {
        didSet { store.save(settings) }
    }

    private let store = NotesAppearanceStore()

    init() {
        settings = store.load()
    }

    var theme: NotesTheme {
        get { settings.theme }
        set { settings.theme = newValue }
    }

    var font: NotesFontOption {
        get { settings.font }
        set { settings.font = newValue }
    }

    var fontSize: Double {
        get { settings.fontSize }
        set { settings.fontSize = min(28, max(12, newValue)) }
    }

    func colors(colorScheme: ColorScheme) -> NotesTheme.Colors {
        let dark = colorScheme == .dark
        // Paper/Night Ink ignore OS scheme for their fixed palettes.
        return settings.theme.colors(effectiveDark: dark)
    }

    func bodyFont() -> NSFont {
        settings.font.nsFont(size: CGFloat(settings.fontSize))
    }

    func titleFont() -> NSFont {
        settings.font.nsFont(size: CGFloat(settings.fontSize + 4))
    }
}
