import Combine
import Foundation
import ServiceManagement
import UsageDomain

@MainActor
final class AppSettings: ObservableObject {
    enum MeterContentOrder: String, CaseIterable, Identifiable {
        case graphLeading
        case graphTrailing

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .graphLeading: L10n.text("graph_leading")
            case .graphTrailing: L10n.text("graph_trailing")
            }
        }
    }

    private enum Key {
        static let opensDetailsOnHover = "opensDetailsOnHover"
        static let showsCodexMenu = "showsCodexMenu"
        static let showsClaudeMenu = "showsClaudeMenu"
        static let menuMeterStyle = "menuMeterStyle"
        static let showsRemainingPercentage = "showsRemainingPercentage"
        static let showsMenuLabel = "showsMenuLabel"
        static let meterContentOrder = "meterContentOrder"
        static let appLanguage = L10n.defaultsKey
    }

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var showsCodexMenu: Bool
    @Published private(set) var showsClaudeMenu: Bool
    @Published private(set) var menuVisibilityError: String?
    @Published var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Key.appLanguage)
        }
    }
    @Published var opensDetailsOnHover: Bool {
        didSet {
            defaults.set(opensDetailsOnHover, forKey: Key.opensDetailsOnHover)
        }
    }
    @Published var menuMeterStyle: MenuMeterStyle {
        didSet {
            defaults.set(menuMeterStyle.rawValue, forKey: Key.menuMeterStyle)
        }
    }
    @Published var showsRemainingPercentage: Bool {
        didSet {
            defaults.set(showsRemainingPercentage, forKey: Key.showsRemainingPercentage)
        }
    }
    @Published var showsMenuLabel: Bool {
        didSet {
            defaults.set(showsMenuLabel, forKey: Key.showsMenuLabel)
        }
    }
    @Published var meterContentOrder: MeterContentOrder {
        didSet {
            defaults.set(meterContentOrder.rawValue, forKey: Key.meterContentOrder)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = SMAppService.mainApp.status == .enabled
        launchAtLoginError = nil
        opensDetailsOnHover = defaults.object(forKey: Key.opensDetailsOnHover) as? Bool ?? true
        showsCodexMenu = defaults.object(forKey: Key.showsCodexMenu) as? Bool ?? true
        showsClaudeMenu = defaults.object(forKey: Key.showsClaudeMenu) as? Bool ?? true
        menuMeterStyle = defaults.string(forKey: Key.menuMeterStyle)
            .flatMap(MenuMeterStyle.init(rawValue:)) ?? .coloredBar
        showsRemainingPercentage = defaults.object(forKey: Key.showsRemainingPercentage) as? Bool ?? true
        showsMenuLabel = defaults.object(forKey: Key.showsMenuLabel) as? Bool ?? true
        meterContentOrder = defaults.string(forKey: Key.meterContentOrder)
            .flatMap(MeterContentOrder.init(rawValue:)) ?? .graphLeading
        menuVisibilityError = nil
        if let storedLanguage = defaults.string(forKey: Key.appLanguage)
            .flatMap(AppLanguage.init(rawValue:)) {
            appLanguage = storedLanguage
        } else {
            let detectedLanguage = AppLanguage.systemDefault()
            appLanguage = detectedLanguage
            defaults.set(detectedLanguage.rawValue, forKey: Key.appLanguage)
        }

        if !showsCodexMenu, !showsClaudeMenu {
            showsCodexMenu = true
            defaults.set(true, forKey: Key.showsCodexMenu)
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else {
                    launchAtLogin = true
                    return
                }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else {
                    launchAtLogin = false
                    return
                }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }

    func isMenuVisible(for source: UsageSource) -> Bool {
        switch source {
        case .codex: showsCodexMenu
        case .claudeCode: showsClaudeMenu
        }
    }

    func setMenuVisible(_ visible: Bool, for source: UsageSource) {
        let otherIsVisible = switch source {
        case .codex: showsClaudeMenu
        case .claudeCode: showsCodexMenu
        }
        guard visible || otherIsVisible else {
            menuVisibilityError = L10n.text("menu_visibility_error")
            return
        }

        menuVisibilityError = nil
        switch source {
        case .codex:
            showsCodexMenu = visible
            defaults.set(visible, forKey: Key.showsCodexMenu)
        case .claudeCode:
            showsClaudeMenu = visible
            defaults.set(visible, forKey: Key.showsClaudeMenu)
        }
    }
}
