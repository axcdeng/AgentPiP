import Foundation

@MainActor
final class Preferences: ObservableObject {
    enum DisplayMode: String, CaseIterable, Identifiable {
        case pip, notch

        var id: Self { self }
        var label: String { self == .pip ? "PiP" : "Notch" }
    }

    enum NotchLayout: String, CaseIterable, Identifiable {
        case compact, detailed

        var id: Self { self }
        var label: String { rawValue.capitalized }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case light, dark

        var id: Self { self }
        var label: String { rawValue.capitalized }
    }

    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var collapsed: Bool { didSet { defaults.set(collapsed, forKey: "collapsed") } }
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") } }
    @Published var notchLayout: NotchLayout { didSet { defaults.set(notchLayout.rawValue, forKey: "notchLayout") } }
    @Published var notchExpanded = false
    @Published var comfortableDensity: Bool { didSet { defaults.set(comfortableDensity, forKey: "comfortableDensity") } }
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused") } }
    @Published var automaticallyRevealHiddenThreads: Bool { didSet { defaults.set(automaticallyRevealHiddenThreads, forKey: "automaticallyRevealHiddenThreads") } }
    @Published var automaticallyShowNewThreads: Bool { didSet { defaults.set(automaticallyShowNewThreads, forKey: "automaticallyShowNewThreads") } }
    @Published var alwaysShowPIPOnAgentStart: Bool { didSet { defaults.set(alwaysShowPIPOnAgentStart, forKey: "alwaysShowPIPOnAgentStart") } }
    @Published var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var hiddenIDs: Set<String> { didSet { save(hiddenIDs, key: "hiddenIDs") } }
    @Published var dismissedIDs: Set<String> { didSet { save(dismissedIDs, key: "dismissedIDs") } }

    private init() {
        collapsed = defaults.bool(forKey: "collapsed")
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .pip
        notchLayout = NotchLayout(rawValue: defaults.string(forKey: "notchLayout") ?? "") ?? .detailed
        comfortableDensity = defaults.bool(forKey: "comfortableDensity")
        paused = defaults.bool(forKey: "paused")
        automaticallyRevealHiddenThreads = defaults.object(forKey: "automaticallyRevealHiddenThreads") as? Bool ?? true
        automaticallyShowNewThreads = defaults.object(forKey: "automaticallyShowNewThreads") as? Bool ?? true
        alwaysShowPIPOnAgentStart = defaults.object(forKey: "alwaysShowPIPOnAgentStart") as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .light
        hiddenIDs = Set(defaults.stringArray(forKey: "hiddenIDs") ?? [])
        dismissedIDs = Set(defaults.stringArray(forKey: "dismissedIDs") ?? [])
    }

    func hide(_ id: String) { hiddenIDs.insert(id) }
    func restore(_ id: String) { hiddenIDs.remove(id) }
    func dismiss(_ id: String) { dismissedIDs.insert(id) }
    private func save(_ value: Set<String>, key: String) { defaults.set(Array(value), forKey: key) }
}
