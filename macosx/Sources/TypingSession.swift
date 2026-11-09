import AppKit
import ApplicationServices
import Carbon

enum TypingPace {
    enum Variation: Int, CaseIterable {
        case off = 0
        case subtle = 10
        case moderate = 20
        case strong = 35
    }

    static let range = 60...1200
    static let standard = 300

    static func delay(after character: Character, rate: Int, variation: Variation) -> Duration {
        let seconds = 60.0 / Double(rate)
        let pause = ".!?,;:\n".contains(character) ? 0.65 : 0
        let spread = Double(variation.rawValue) / 100
        let multiplier = variation == .off ? 1 : Double.random(in: (1 - spread)...(1 + spread))
        return .seconds(seconds * (multiplier + pause))
    }
}

enum TypoRate {
    static let range = 0...10
    private static let keyboardRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    static func replacement(for letter: Character, rate: Int, roll: Int) -> Character? {
        guard roll < rate, letter.isASCII, letter.isLetter else { return nil }
        let lowercase = Character(letter.lowercased())
        for row in keyboardRows {
            guard let index = row.firstIndex(of: lowercase) else { continue }
            let next = row.index(after: index)
            let neighbor = row[next == row.endIndex ? row.index(before: index) : next]
            return letter.isUppercase ? Character(neighbor.uppercased()) : neighbor
        }
        return nil
    }
}

struct PendingTypo {
    private let expectedText: String
    private let expectedCaret: Int

    init?(text: String, caret: Int, letter: Character) {
        let text = text as NSString
        guard (0...text.length).contains(caret) else { return nil }
        let insertion = String(letter)
        expectedText = text.replacingCharacters(in: NSRange(location: caret, length: 0), with: insertion)
        expectedCaret = caret + insertion.utf16.count
    }

    func canCorrect(text: String?, caret: Int?) -> Bool {
        guard let text, caret == expectedCaret else { return false }
        return text.utf16.elementsEqual(expectedText.utf16)
    }
}

@MainActor
final class TypingSession {
    private var task: Task<Void, Never>?
    private var canContinueAcrossApps = false
    private var hasSwitchedApps = false
    var onChange: (() -> Void)?
    var isRunning: Bool { task != nil }
    private(set) var isWaitingForTarget = false

    private let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    func start(text: String, rate: Int, variation: TypingPace.Variation, typoRate: Int,
               keepTypingInBackground: Bool, target: NSRunningApplication) {
        let pid = target.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let textRoles = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]
        guard task == nil, let field = focusedElement(in: app),
              let role = attribute(kAXRoleAttribute, of: field) as? String, textRoles.contains(role),
              attribute(kAXSubroleAttribute, of: field) as? String != kAXSecureTextFieldSubrole,
              let source = CGEventSource(stateID: .privateState)
        else { NSSound.beep(); return }

        let initialRange = keepTypingInBackground ? selectedRange(in: field) : nil
        let initialLength = keepTypingInBackground ? textLength(in: field) : nil
        // An empty editor has only one insertion point, even if its range is not exposed yet.
        let startedEmpty = initialLength == 0 &&
            (initialRange == nil || (initialRange?.length == 0 && initialRange?.location == 0))
        var appendConfirmed = startedEmpty || (initialRange?.length == 0 && initialRange?.location == initialLength)
        var initialTextToVerify: String?
        if keepTypingInBackground && !appendConfirmed &&
            (initialRange == nil || (initialRange?.location == 0 && initialRange?.length == 0)) {
            initialTextToVerify = attribute(kAXValueAttribute, of: field) as? String
        }
        canContinueAcrossApps = appendConfirmed || initialTextToVerify != nil
        hasSwitchedApps = false
        task = Task {
            defer {
                task = nil
                isWaitingForTarget = false
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
            var pendingFirstAppend: (initial: String, inserted: String, deadline: ContinuousClock.Instant)?
            var hasPostedKey = false
            @MainActor func canType() async -> Bool {
                var requestedCaretMove = false
                while !Task.isCancelled, !target.isTerminated, CGPreflightPostEventAccess() {
                    let hasOriginalFocus = focusedElement(in: app).map { CFEqual($0, field) } ?? false
                    let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid

                    if hasOriginalFocus, let pending = pendingFirstAppend {
                        if let current = attribute(kAXValueAttribute, of: field) as? String,
                           !current.utf16.elementsEqual(pending.initial.utf16) {
                            let appended = pending.initial + pending.inserted
                            // Some empty rich-text editors expose a one-unit placeholder
                            // that the first real character replaces.
                            appendConfirmed = current.utf16.elementsEqual(appended.utf16) ||
                                (pending.initial.utf16.count == 1 && current.utf16.elementsEqual(pending.inserted.utf16))
                            canContinueAcrossApps = appendConfirmed
                            pendingFirstAppend = nil
                        } else if clock.now < pending.deadline {
                            try? await Task.sleep(for: .milliseconds(25))
                            continue
                        } else if isFrontmost && !hasSwitchedApps {
                            // Keep foreground typing usable if the editor can't confirm the first key.
                            canContinueAcrossApps = false
                            pendingFirstAppend = nil
                        }
                    }

                    if !isFrontmost {
                        guard canContinueAcrossApps else { return false }
                        hasSwitchedApps = true
                        if appendConfirmed && hasOriginalFocus &&
                            caretAtEnd(in: field, requireText: true) {
                            setWaitingForTarget(false)
                            return true
                        }
                        // Some apps stop exposing their focused field when they become inactive.
                        setWaitingForTarget(true)
                        requestedCaretMove = false
                    } else if hasOriginalFocus {
                        if modifiersHeld {
                            // Give app-switch shortcuts time to finish before sending more keys.
                            guard canContinueAcrossApps else { return false }
                            try? await Task.sleep(for: .milliseconds(25))
                            continue
                        }
                        if canContinueAcrossApps && !appendConfirmed && hasSwitchedApps &&
                            pendingFirstAppend == nil && caretAtEnd(in: field) {
                            appendConfirmed = true
                        }
                        // If the user switched away before the first key, the original
                        // empty field can still be resumed without a reported caret.
                        let canStartInEmptyField = startedEmpty && !hasPostedKey &&
                            textLength(in: field) == 0 && selectedRange(in: field) == nil
                        if !hasSwitchedApps || (appendConfirmed && (caretAtEnd(in: field) || canStartInEmptyField)) {
                            setWaitingForTarget(false)
                            return true
                        }
                        guard canContinueAcrossApps else { return false }
                        if appendConfirmed, !requestedCaretMove, let end = textLength(in: field) {
                            let selection = selectedRange(in: field)
                            if selection == nil || (selection?.length == 0 && (selection?.location ?? 0) <= end) {
                                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                                    _ = moveCaret(to: end, in: field)
                                    requestedCaretMove = true
                                }
                            }
                        }
                    } else if !isWaitingForTarget && !hasSwitchedApps {
                        return false
                    }

                    setWaitingForTarget(true)
                    try? await Task.sleep(for: .milliseconds(150))
                }
                return false
            }

            for character in content {
                guard await canType() else { return }

                if typoRate > 0,
                   let typo = TypoRate.replacement(for: character, rate: typoRate, roll: Int.random(in: 0..<100)),
                   let caret = insertionPoint(in: field),
                   let text = attribute(kAXValueAttribute, of: field) as? String,
                   let pending = PendingTypo(text: text, caret: caret, letter: typo) {
                    guard await canType(), post(String(typo), from: source, to: pid) else { return }
                    hasPostedKey = true
                    let pause = TypingPace.delay(after: typo, rate: rate, variation: variation)
                    try? await Task.sleep(for: pause + .milliseconds(100))

                    // Only delete when the field contains the exact insertion we just made.
                    guard await canType(),
                          pending.canCorrect(text: attribute(kAXValueAttribute, of: field) as? String,
                                             caret: insertionPoint(in: field)),
                          post("\u{7F}", key: CGKeyCode(kVK_Delete), from: source, to: pid)
                    else { return }
                }

                if character.isNewline, role == kAXTextAreaRole {
                    // Rich-text fields can ignore a Unicode newline, but handle Shift-Return.
                    guard post("\r", key: CGKeyCode(kVK_Return), flags: .maskShift, from: source, to: pid)
                    else { return }
                } else {
                    guard post(String(character), from: source, to: pid) else { return }
                }
                hasPostedKey = true
                if let initial = initialTextToVerify {
                    pendingFirstAppend = (initial, String(character), clock.now + .milliseconds(250))
                    initialTextToVerify = nil
                }
                try? await Task.sleep(for: TypingPace.delay(after: character, rate: rate, variation: variation))
            }
        }
        onChange?()
    }

    func stop() { task?.cancel() }

    private func setWaitingForTarget(_ waiting: Bool) {
        guard isWaitingForTarget != waiting else { return }
        isWaitingForTarget = waiting
        onChange?()
    }

    func appDidSwitch() {
        guard isRunning else { return }
        if canContinueAcrossApps {
            hasSwitchedApps = true
        } else {
            stop()
        }
    }

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

    private func insertionPoint(in field: AXUIElement) -> Int? {
        guard let range = selectedRange(in: field), range.length == 0 else { return nil }
        return range.location
    }

    private func selectedRange(in field: AXUIElement) -> CFRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: field),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.location != NSNotFound, range.length >= 0
        else { return nil }
        return range
    }

    private func textLength(in field: AXUIElement) -> Int? {
        let count = attribute(kAXNumberOfCharactersAttribute, of: field) as? Int
        if let count, count > 0 {
            return count
        }
        if let value = attribute(kAXValueAttribute, of: field) as? String {
            return value.utf16.count
        }
        return count == 0 ? 0 : nil
    }

    private func caretAtEnd(in field: AXUIElement, requireText: Bool = false) -> Bool {
        guard let end = textLength(in: field), !requireText || end > 0 else { return false }
        return insertionPoint(in: field) == end
    }

    private func moveCaret(to end: Int, in field: AXUIElement) -> Bool {
        var range = CFRange(location: end, length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private func post(_ text: String, key: CGKeyCode = 0, flags: CGEventFlags = [],
                      from source: CGEventSource, to pid: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        let units = Array(text.utf16)
        for event in [down, up] {
            event.flags = flags
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
            event.postToPid(pid)
        }
        return true
    }
}
