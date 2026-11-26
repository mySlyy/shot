import AppKit
import Carbon.HIToolbox

// User-mappable global shortcuts (Options > Keyboard Shortcuts…): Capture Area / Window / Screen,
// Bring Shots to Front, Open All Shots in Editor.
// Stored per action in UserDefaults; no value = the default, an empty value = no shortcut.

/// A key combination: Carbon key code + Carbon modifiers (what RegisterEventHotKey takes), plus the
/// key's character without modifiers (for menus and display; F-keys/arrows use AppKit's function-key chars).
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var key: String

    /// Same keys pressed (the stored character does not matter).
    func matches(_ other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.command) ? cmdKey : 0) | (flags.contains(.shift) ? shiftKey : 0)
            | (flags.contains(.option) ? optionKey : 0) | (flags.contains(.control) ? controlKey : 0)
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { f.insert(.control) }
        if modifiers & optionKey != 0 { f.insert(.option) }
        if modifiers & shiftKey != 0 { f.insert(.shift) }
        if modifiers & cmdKey != 0 { f.insert(.command) }
        return f
    }

    /// e.g. "⌃⌥⇧⌘5", "⌘F6", "⌥Space".
    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + Self.keyName(keyCode, key)
    }

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    static func keyName(_ keyCode: Int, _ key: String) -> String {
        functionKeys[keyCode] ?? namedKeys[keyCode] ?? (key.isEmpty ? "#\(keyCode)" : key.uppercased())
    }
}

enum ShortcutAction: UInt32, CaseIterable {
    case area = 1, window = 2, screen = 3 // also the HotKeys ids (4 = Edit Last Shot, fixed)
    case bringToFront = 5, openAll = 6

    var title: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .screen: return "Capture Screen"
        case .bringToFront: return "Bring Shots to Front"
        case .openAll: return "Open All Shots in Editor"
        }
    }

    /// Capture actions only (nil for the editor-window actions).
    var mode: CaptureMode? {
        switch self {
        case .area: return .area
        case .window: return .window
        case .screen: return .screen
        case .bringToFront, .openAll: return nil
        }
    }

    /// ⌘⇧5 area, ⌘⇧4 window, ⌘⇧3 screen (macOS' own screenshot shortcuts must be off for these),
    /// ⌘⇧F bring open shots to front, ⌘⌥⇧O open all shots of the folder. Global: they win over the
    /// same keys in other apps (e.g. ⌘⇧F Find in Files), hence mappable/removable.
    var defaultShortcut: Shortcut {
        switch self {
        case .area: return Shortcut(keyCode: kVK_ANSI_5, modifiers: cmdKey | shiftKey, key: "5")
        case .window: return Shortcut(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey, key: "4")
        case .screen: return Shortcut(keyCode: kVK_ANSI_3, modifiers: cmdKey | shiftKey, key: "3")
        case .bringToFront: return Shortcut(keyCode: kVK_ANSI_F, modifiers: cmdKey | shiftKey, key: "f")
        case .openAll: return Shortcut(keyCode: kVK_ANSI_O, modifiers: cmdKey | shiftKey | optionKey, key: "o")
        }
    }

    var prefKey: String { "shortcut.\(self)" }

    /// Fixed (not mappable): ⌃⇧E Edit Last Shot, HotKeys id 4.
    static let editLast = Shortcut(keyCode: kVK_ANSI_E, modifiers: controlKey | shiftKey, key: "e")
    static let editLastID: UInt32 = 4
}

extension Settings {
    /// The action's shortcut: stored value, else the default; nil = removed by the user.
    static func shortcut(for action: ShortcutAction) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: action.prefKey) else { return action.defaultShortcut }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? action.defaultShortcut
    }

    /// nil stores "no shortcut" (not the default; see resetShortcut).
    static func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        UserDefaults.standard.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: action.prefKey)
    }

    static func resetShortcut(for action: ShortcutAction) {
        UserDefaults.standard.removeObject(forKey: action.prefKey)
    }
}

/// Registers the mappable shortcuts with HotKeys; `perform` is set once by the AppDelegate.
@MainActor
enum ShortcutRegistry {
    static var perform: ((ShortcutAction) -> Void)?

    static func applyAll() {
        for action in ShortcutAction.allCases { apply(action) }
    }

    /// (Re)registers the action's current shortcut; false if macOS refused it (taken by another app).
    @discardableResult
    static func apply(_ action: ShortcutAction) -> Bool {
        guard let s = Settings.shortcut(for: action) else {
            HotKeys.shared.unregister(id: action.rawValue)
            return true
        }
        return HotKeys.shared.register(id: action.rawValue, keyCode: s.keyCode, modifiers: s.modifiers) {
            perform?(action)
        }
    }

    /// Which other Slyy Shot shortcut already uses these keys (title), if any.
    static func conflict(_ s: Shortcut, excluding action: ShortcutAction) -> String? {
        if s.matches(ShortcutAction.editLast) { return "Edit Last Shot" }
        return ShortcutAction.allCases.first { $0 != action && Settings.shortcut(for: $0).map(s.matches) == true }?.title
    }

    enum Change: Equatable { case saved, conflict(String), taken }

    /// Validates, stores and registers a new shortcut (nil = remove). Keeps the old one on failure.
    static func change(_ action: ShortcutAction, to s: Shortcut?) -> Change {
        if let s, let other = conflict(s, excluding: action) { return .conflict(other) }
        let before = UserDefaults.standard.object(forKey: action.prefKey)
        Settings.setShortcut(s, for: action)
        guard apply(action) else {
            UserDefaults.standard.set(before, forKey: action.prefKey) // nil removes = default again
            apply(action)
            return .taken
        }
        return .saved
    }

    /// Back to the default, unless another action took those keys meanwhile.
    static func reset(_ action: ShortcutAction) -> Change {
        if let other = conflict(action.defaultShortcut, excluding: action) { return .conflict(other) }
        let before = UserDefaults.standard.object(forKey: action.prefKey)
        Settings.resetShortcut(for: action)
        guard apply(action) else {
            UserDefaults.standard.set(before, forKey: action.prefKey)
            apply(action)
            return .taken
        }
        return .saved
    }
}

/// Button that records a key combination: click, press the keys. Esc cancels, ⌫ removes the shortcut.
/// Needs ⌘, ⌥ or ⌃ (⇧ alone would block typing that character everywhere); F-keys also work alone.
@MainActor
final class ShortcutRecorder: NSButton {
    let item: ShortcutAction
    /// New shortcut, or nil when removed with ⌫.
    var onRecord: ((Shortcut?) -> Void)?
    var onInvalid: (() -> Void)?

    private(set) var recording = false {
        didSet {
            guard recording != oldValue else { return }
            if recording { HotKeys.shared.suspend() } else { HotKeys.shared.resume() }
            refresh()
        }
    }

    init(item: ShortcutAction) {
        self.item = item
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func refresh() {
        title = recording ? "Type shortcut…" : (Settings.shortcut(for: item)?.display ?? "None")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func clicked() {
        window?.makeFirstResponder(self)
        recording = true
    }

    func stopRecording() {
        recording = false
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if recording { handle(event) } else { super.keyDown(with: event) }
    }

    /// ⌘-combinations arrive here, before keyDown (and before the menu's ⌘W, ⌘Q …).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        if flags.isEmpty, code == kVK_Escape {
            recording = false
            return
        }
        if flags.isEmpty, code == kVK_Delete || code == kVK_ForwardDelete {
            recording = false
            onRecord?(nil)
            return
        }
        guard !flags.intersection([.command, .option, .control]).isEmpty || Shortcut.functionKeys[code] != nil else {
            onInvalid?() // beeps
            return // keep recording
        }
        let key = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").lowercased()
        recording = false
        onRecord?(Shortcut(keyCode: code, modifiers: Shortcut.carbon(flags), key: key))
    }
}

/// Options > Keyboard Shortcuts…: one recorder + "Default" button per action.
@MainActor
final class ShortcutsWindow: NSObject, NSWindowDelegate {
    private static var current: ShortcutsWindow?
    static let hint = "Click a shortcut, then press the new keys (with ⌘, ⌥ or ⌃). ⌫ removes it, Esc cancels.\n"
        + "⌘⇧3/4/5 only work with macOS' own screenshot shortcuts switched off (Keyboard Shortcuts > Screenshots)."

    static func show() {
        let w = current ?? ShortcutsWindow()
        current = w
        NSApp.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
    }

    let window: NSWindow
    private(set) var recorders: [ShortcutRecorder] = []
    let message = NSTextField(wrappingLabelWithString: ShortcutsWindow.hint)

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 280), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self

        var rows: [[NSView]] = []
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder(item: action)
            recorder.onRecord = { [weak self] s in self?.report(ShortcutRegistry.change(action, to: s), s) }
            recorder.onInvalid = { [weak self] in self?.say("Add ⌘, ⌥ or ⌃ to the key (or use an F-key).", error: true) }
            recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
            recorders.append(recorder)
            let reset = NSButton(title: "Default", target: self, action: #selector(resetClicked(_:)))
            reset.tag = Int(action.rawValue)
            reset.toolTip = "Back to \(action.defaultShortcut.display)"
            let controls = NSStackView(views: [recorder, reset]) // one cell: "Default" stays next to the recorder
            controls.spacing = 8
            rows.append([NSTextField(labelWithString: action.title + ":"), controls])
        }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .none
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
        grid.column(at: 1).xPlacement = .leading
        grid.setContentHuggingPriority(.required, for: .horizontal) // natural width, left-aligned
        grid.rowSpacing = 10
        grid.columnSpacing = 10

        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.preferredMaxLayoutWidth = 420
        let stack = NSStackView(views: [grid, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
        window.center()
    }

    @objc private func resetClicked(_ sender: NSButton) {
        guard let action = ShortcutAction(rawValue: UInt32(sender.tag)) else { return }
        recorders.forEach { $0.stopRecording() }
        report(ShortcutRegistry.reset(action), action.defaultShortcut)
    }

    private func report(_ change: ShortcutRegistry.Change, _ s: Shortcut?) {
        recorders.forEach { $0.refresh() }
        switch change {
        case .saved: say(Self.hint, error: false)
        case .conflict(let other): say("\(s?.display ?? "") is already used for \(other).", error: true)
        case .taken: say("\(s?.display ?? "") is taken by another app; pick other keys.", error: true)
        }
    }

    private func say(_ text: String, error: Bool) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
        if error { NSSound.beep() }
    }

    func windowWillClose(_ notification: Notification) {
        recorders.forEach { $0.stopRecording() } // never leave the hotkeys suspended
        say(Self.hint, error: false)
    }
}
