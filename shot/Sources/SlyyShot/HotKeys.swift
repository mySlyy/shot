import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey: works system-wide without the
/// Accessibility permission. One hotkey per id; registering an id again replaces it.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var handlers: [UInt32: () -> Void] = [:]
    private var specs: [UInt32: (keyCode: Int, modifiers: Int)] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false
    /// While a shortcut is being recorded: all hotkeys off, so the keys reach the recorder
    /// instead of starting a capture.
    private var suspended = false

    /// False if macOS refused the key combination (e.g. registered by another app).
    @discardableResult
    func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        installHandlerOnce()
        unregister(id: id)
        handlers[id] = handler
        specs[id] = (keyCode, modifiers)
        return suspended || activate(id)
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        specs[id] = nil
        handlers[id] = nil
    }

    func suspend() {
        guard !suspended else { return }
        suspended = true
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        for id in specs.keys { activate(id) }
    }

    @discardableResult
    private func activate(_ id: UInt32) -> Bool {
        guard let spec = specs[id] else { return false }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5348_4F54), id: id) // 'SHOT'
        let status = RegisterEventHotKey(UInt32(spec.keyCode), UInt32(spec.modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Slyy Shot: hotkey \(id) not registered (status \(status)); taken by another app?")
            return false
        }
        refs[id] = ref
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
