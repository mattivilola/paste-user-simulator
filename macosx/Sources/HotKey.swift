import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_V),
                                   modifiers: UInt32(cmdKey | optionKey), label: "V")

    var displayName: String {
        let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + label
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .option, .control]).isEmpty,
              let key = event.characters(byApplyingModifiers: [])?.uppercased(),
              !key.isEmpty,
              key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) ||
                  CharacterSet.punctuationCharacters.contains($0) ||
                  CharacterSet.symbols.contains($0) }),
              event.specialKey == nil
        else { return nil }

        let modifiers = [(NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey),
                         (.control, controlKey), (.shift, shiftKey)]
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers.reduce(0) {
            flags.contains($1.0) ? $0 | UInt32($1.1) : $0
        }, label: key)
    }

    private init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }
}

@MainActor
final class HotKey {
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var shortcut: Shortcut?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyReleased))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ candidate: Shortcut) -> Bool {
        guard handler != nil else { return false }
        if shortcut?.keyCode == candidate.keyCode, shortcut?.modifiers == candidate.modifiers {
            return true
        }
        var newRegistration: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5055534D, id: 1)
        guard RegisterEventHotKey(candidate.keyCode, candidate.modifiers, id,
                                  GetApplicationEventTarget(), 0, &newRegistration) == noErr,
              let newRegistration
        else { return false }

        if let registration { UnregisterEventHotKey(registration) }
        registration = newRegistration
        shortcut = candidate
        return true
    }

    func invalidate() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
    }
}
