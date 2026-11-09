import AppKit
import ApplicationServices

enum TypingPace {
    static let range = 60...1200
    static let standard = 300

    static func delay(after character: Character, rate: Int) -> Duration {
        let seconds = 60.0 / Double(rate)
        let pause = ".!?,;:\n".contains(character) ? 0.65 : 0
        return .seconds(seconds * (Double.random(in: 0.75...1.25) + pause))
    }
}

@MainActor
final class TypingSession {
    private var task: Task<Void, Never>?
    var onChange: (() -> Void)?
    var isRunning: Bool { task != nil }

    private let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    func start(text: String, rate: Int, target: NSRunningApplication) {
        let pid = target.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let textRoles = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]
        guard task == nil, let field = focusedElement(in: app),
              let role = attribute(kAXRoleAttribute, of: field) as? String, textRoles.contains(role),
              attribute(kAXSubroleAttribute, of: field) as? String != kAXSecureTextFieldSubrole,
              let source = CGEventSource(stateID: .privateState)
        else { NSSound.beep(); return }

        task = Task {
            defer {
                task = nil
                onChange?()
            }

            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(3)
            while modifiersHeld {
                guard clock.now < deadline else { return }
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled else { return }
            }

            let content = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            var characters = content.makeIterator()
            while let character = characters.next() {
                guard !Task.isCancelled, !modifiersHeld, CGPreflightPostEventAccess(),
                      let focused = focusedElement(in: app), CFEqual(focused, field),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                else { return }

                // Send whitespace as Unicode without using the Return or Tab key codes.
                guard post(String(character), from: source, to: pid) else { return }
                try? await Task.sleep(for: TypingPace.delay(after: character, rate: rate))
            }
        }
        onChange?()
    }

    func stop() { task?.cancel() }

    private var modifiersHeld: Bool {
        !CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).isEmpty
    }

    private func focusedElement(in app: AXUIElement) -> AXUIElement? {
        guard let value = attribute(kAXFocusedUIElementAttribute, of: app),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func post(_ text: String, from source: CGEventSource, to pid: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        let units = Array(text.utf16)
        for event in [down, up] {
            event.flags = []
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
            event.postToPid(pid)
        }
        return true
    }
}
