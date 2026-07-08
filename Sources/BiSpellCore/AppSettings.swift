import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var turkishEnabled: Bool
    public var englishEnabled: Bool
    public var launchAtLogin: Bool
    public var useClipboardFallback: Bool
    public var hotkeyFallbackEnabled: Bool
    /// When true, BiSpell may set AXManualAccessibility on Electron/Chromium apps
    /// if the focused element is missing. Default off — those apps pay a large AX tax.
    public var electronSupportEnabled: Bool
    public var deniedBundleIDs: Set<String>
    public var debounceMilliseconds: Int
    public var maxSuggestions: Int
    public var minWordLength: Int

    public static let `default` = AppSettings(
        isEnabled: true,
        turkishEnabled: true,
        englishEnabled: true,
        launchAtLogin: false,
        useClipboardFallback: false,
        hotkeyFallbackEnabled: true,
        electronSupportEnabled: false,
        deniedBundleIDs: [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.apple.SecurityAgent",
            "com.1password.1password",
            "com.agilebits.onepassword7"
        ],
        debounceMilliseconds: 250,
        maxSuggestions: 5,
        minWordLength: 2
    )

    public init(
        isEnabled: Bool,
        turkishEnabled: Bool,
        englishEnabled: Bool,
        launchAtLogin: Bool,
        useClipboardFallback: Bool,
        hotkeyFallbackEnabled: Bool,
        electronSupportEnabled: Bool = false,
        deniedBundleIDs: Set<String>,
        debounceMilliseconds: Int,
        maxSuggestions: Int,
        minWordLength: Int
    ) {
        self.isEnabled = isEnabled
        self.turkishEnabled = turkishEnabled
        self.englishEnabled = englishEnabled
        self.launchAtLogin = launchAtLogin
        self.useClipboardFallback = useClipboardFallback
        self.hotkeyFallbackEnabled = hotkeyFallbackEnabled
        self.electronSupportEnabled = electronSupportEnabled
        self.deniedBundleIDs = deniedBundleIDs
        self.debounceMilliseconds = debounceMilliseconds
        self.maxSuggestions = maxSuggestions
        self.minWordLength = minWordLength
    }

    // Preserve older saved settings when new keys appear.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? Self.default.isEnabled
        turkishEnabled = try c.decodeIfPresent(Bool.self, forKey: .turkishEnabled) ?? Self.default.turkishEnabled
        englishEnabled = try c.decodeIfPresent(Bool.self, forKey: .englishEnabled) ?? Self.default.englishEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? Self.default.launchAtLogin
        useClipboardFallback = try c.decodeIfPresent(Bool.self, forKey: .useClipboardFallback) ?? Self.default.useClipboardFallback
        hotkeyFallbackEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyFallbackEnabled) ?? Self.default.hotkeyFallbackEnabled
        electronSupportEnabled = try c.decodeIfPresent(Bool.self, forKey: .electronSupportEnabled) ?? false
        deniedBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .deniedBundleIDs) ?? Self.default.deniedBundleIDs
        debounceMilliseconds = try c.decodeIfPresent(Int.self, forKey: .debounceMilliseconds) ?? Self.default.debounceMilliseconds
        maxSuggestions = try c.decodeIfPresent(Int.self, forKey: .maxSuggestions) ?? Self.default.maxSuggestions
        minWordLength = try c.decodeIfPresent(Int.self, forKey: .minWordLength) ?? Self.default.minWordLength
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "BiSpell.AppSettings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
