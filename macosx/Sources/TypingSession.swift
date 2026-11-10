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
    static let adjustment = 30

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

struct TextAtCaret {
    let before: String
    let after: String

    init(before: String, after: String) {
        self.before = before
        self.after = after
    }

    init?(text: String, caret: Int) {
        let text = text as NSString
        guard (0...text.length).contains(caret) else { return nil }
        self.init(before: text.substring(to: caret), after: text.substring(from: caret))
    }
}

struct PendingTypo {
    let original: TextAtCaret
    let letter: Character

    func canCorrect(_ current: TextAtCaret) -> Bool {
        normalized(current.before) == normalized(original.before + String(letter)) &&
            normalized(current.after) == normalized(original.after)
    }

    private func normalized(_ text: String) -> String {
        // Rich editors may turn a trailing non-breaking space into a regular space as a word grows.
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }
}

@MainActor
final class TypingSession {
    enum Phase: Equatable {
        case typing, waitingForTarget, paused, checkLastCharacter
    }

    struct Progress {
        let appName: String
        let total: Int
        var rate: Int
        var typed = 0
        var phase = Phase.typing

        var percent: Int { typed * 100 / total }
    }

    private var task: Task<Void, Never>?
    private var targetPID: pid_t?
    private var leftTargetApp = false
    private var resumeRequested = false
    private var compatibilityInput: [UInt32]?
    var onChange: (() -> Void)?
    private(set) var progress: Progress?

    private let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    private let textRoles = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]
    private let opaqueRoles = ["AXWebArea", kAXGroupRole]

    func start(text: String, rate: Int, variation: TypingPace.Variation, typoRate: Int,
               keepTypingInBackground: Bool, allowCompatibilityTyping: Bool, target: NSRunningApplication) {
        let pid = target.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard task == nil, !text.isEmpty, let field = focusedElement(in: app),
              let role = attribute(kAXRoleAttribute, of: field) as? String,
              attribute(kAXSubroleAttribute, of: field) as? String != kAXSecureTextFieldSubrole,
              let source = CGEventSource(stateID: .privateState)
        else { NSSound.beep(); return }

        let compatibility = !textRoles.contains(role)
        let window = elementAttribute(kAXFocusedWindowAttribute, of: app)
        if compatibility {
            guard allowCompatibilityTyping, opaqueRoles.contains(role), window != nil, !IsSecureEventInputEnabled()
            else { NSSound.beep(); return }
        }
        compatibilityInput = compatibility ? hardwareInputCounts() : nil
        let initialRange = compatibility ? nil : selectedRange(in: field)
        let initialLength = compatibility ? nil : textLength(in: field)
        let startedEmpty = initialLength == 0 &&
            (initialRange == nil || (initialRange?.length == 0 && initialRange?.location == 0))
        var appendConfirmed = startedEmpty || (initialRange?.length == 0 && initialRange?.location == initialLength)
        if !appendConfirmed && role == kAXTextAreaRole {
            appendConfirmed = textAtMarker(in: field)?.after.isEmpty == true
        }
        var initialTextToVerify: String?
        if !compatibility && !appendConfirmed &&
            (initialRange == nil || (initialRange?.location == 0 && initialRange?.length == 0)) {
            initialTextToVerify = attribute(kAXValueAttribute, of: field) as? String
        }

        let content = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        targetPID = pid
        leftTargetApp = false
        resumeRequested = false
        progress = Progress(appName: target.localizedName ?? "Original app", total: content.count, rate: rate)
        task = Task {
            defer {
                task = nil
                targetPID = nil
                compatibilityInput = nil
                progress = nil
                onChange?()
            }

            let clock = ContinuousClock()
            var pendingFirstAppend: (initial: String, inserted: String, deadline: ContinuousClock.Instant)?
            var needsRecovery = false
            var manualPause: Phase?

            @MainActor func didResume() {
                manualPause = nil
                needsRecovery = false
                leftTargetApp = false
                resumeRequested = false
                setPhase(.typing)
            }

            @MainActor func canType() async -> Bool {
                while !Task.isCancelled, !target.isTerminated, CGPreflightPostEventAccess() {
                    let currentField = focusedElement(in: app)
                    let hasOriginalFocus = currentField.map { CFEqual($0, field) } ?? false
                    let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                    if !isFrontmost || !hasOriginalFocus || leftTargetApp { needsRecovery = true }
                    let checkWindow = isFrontmost && (compatibility || needsRecovery || manualPause != nil)
                    let sameWindow = !checkWindow || (window.map { original in
                        elementAttribute(kAXFocusedWindowAttribute, of: app).map { CFEqual($0, original) } == true
                    } ?? true)

                    if compatibility {
                        // A container can stay focused even when its actual editor changes.
                        let ready = isFrontmost && sameWindow && hasOriginalFocus && !IsSecureEventInputEnabled()
                        let inputNow = hardwareInputCounts()
                        if needsRecovery || !ready || compatibilityInput != inputNow {
                            manualPause = .paused
                        }
                        if ready, !modifiersHeld, manualPause == nil || resumeRequested,
                           NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                            compatibilityInput = inputNow
                            didResume()
                            return true
                        }
                    } else {
                        if hasOriginalFocus, let pending = pendingFirstAppend {
                            if let current = attribute(kAXValueAttribute, of: field) as? String,
                               !current.utf16.elementsEqual(pending.initial.utf16) {
                                let appended = pending.initial + pending.inserted
                                // Some rich-text editors expose a one-unit placeholder until the first key.
                                appendConfirmed = current.utf16.elementsEqual(appended.utf16) ||
                                    (pending.initial.utf16.count == 1 && current.utf16.elementsEqual(pending.inserted.utf16))
                                pendingFirstAppend = nil
                            } else if isFrontmost && clock.now >= pending.deadline {
                                pendingFirstAppend = nil
                            } else if isFrontmost && !needsRecovery {
                                try? await Task.sleep(for: .milliseconds(25))
                                continue
                            }
                        }

                        if hasOriginalFocus, !modifiersHeld, manualPause == nil || resumeRequested {
                            if isFrontmost && sameWindow {
                                if !needsRecovery && manualPause == nil {
                                    setPhase(.typing)
                                    return true
                                }
                                let selection = selectedRange(in: field)
                                let length = textLength(in: field)
                                let atEnd = (selection?.length == 0 && selection?.location == length) ||
                                    textAtMarker(in: field)?.after.isEmpty == true
                                let canStartInEmptyField = startedEmpty && progress?.typed == 0 &&
                                    length == 0 && selection == nil
                                let explicitResume = resumeRequested && (selection?.length ?? 0) == 0
                                if (appendConfirmed && (atEnd || canStartInEmptyField)) || explicitResume,
                                   NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                                    if explicitResume { appendConfirmed = atEnd || canStartInEmptyField }
                                    didResume()
                                    return true
                                }
                            } else if !isFrontmost && keepTypingInBackground && appendConfirmed &&
                                        manualPause == nil && caretAtEnd(in: field, requireText: true) {
                                setPhase(.typing)
                                return true
                            }
                        }
                    }

                    if !isFrontmost || !sameWindow || !hasOriginalFocus || !modifiersHeld {
                        resumeRequested = false
                    }
                    if let manualPause {
                        setPhase(manualPause)
                    } else if needsRecovery {
                        setPhase(appendConfirmed || pendingFirstAppend != nil ? .waitingForTarget : .paused)
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return false
            }

            @MainActor func simulateTypo(_ letter: Character, after previous: Character?) async -> Bool {
                // Skip the simulation when the editor is still reporting text from before the last key.
                func pending(_ snapshot: TextAtCaret?) -> PendingTypo? {
                    guard let snapshot else { return nil }
                    if let previous, previous.isASCII, previous.isLetter, snapshot.before.last != previous { return nil }
                    return PendingTypo(original: snapshot, letter: letter)
                }
                let markerTypo = role == kAXTextAreaRole ? pending(textAtMarker(in: field)) : nil
                let rangeTypo = pending(textAtSelection(in: field))
                guard markerTypo != nil || rangeTypo != nil else { return true }
                guard !modifiersHeld, focusedElement(in: app).map({ CFEqual($0, field) }) == true else {
                    return await canType()
                }
                guard post(String(letter), from: source, to: pid) else { return false }
                let pause = TypingPace.delay(after: letter, rate: progress?.rate ?? rate, variation: variation)
                try? await Task.sleep(for: pause + .milliseconds(100))

                for _ in 0..<16 {
                    guard await canType() else { return false }
                    let verifiedAtMarker = markerTypo.map { pending in
                        textAtMarker(in: field).map(pending.canCorrect) == true
                    } ?? false
                    let verified = verifiedAtMarker || (rangeTypo.map { pending in
                        textAtSelection(in: field).map(pending.canCorrect) == true
                    } ?? false)
                    if verified, !modifiersHeld, focusedElement(in: app).map({ CFEqual($0, field) }) == true {
                        return post("\u{7F}", key: CGKeyCode(kVK_Delete), from: source, to: pid)
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                // An edit or cursor move we cannot verify needs manual correction.
                manualPause = .checkLastCharacter
                resumeRequested = false
                return await canType()
            }

            var previous: Character?
            for character in content {
                guard await canType() else { return }

                if !compatibility, initialTextToVerify == nil, typoRate > 0,
                   let typo = TypoRate.replacement(for: character, rate: typoRate, roll: Int.random(in: 0..<100)) {
                    guard await simulateTypo(typo, after: previous) else { return }
                }

                if character.isNewline, role == kAXTextAreaRole || compatibility {
                    // Rich-text fields can ignore a Unicode newline, but handle Shift-Return.
                    guard post("\r", key: CGKeyCode(kVK_Return), flags: .maskShift, from: source, to: pid)
                    else { return }
                } else {
                    guard post(String(character), from: source, to: pid) else { return }
                }
                if let initial = initialTextToVerify {
                    pendingFirstAppend = (initial, String(character), clock.now + .milliseconds(250))
                    initialTextToVerify = nil
                }
                previous = character
                progress?.typed += 1
                onChange?()
                if progress?.typed == progress?.total { return }
                try? await Task.sleep(for: TypingPace.delay(after: character, rate: progress?.rate ?? rate,
                                                           variation: variation))
            }
        }
        onChange?()
    }

    func stop() { task?.cancel() }

    func setRate(_ rate: Int) {
        guard progress != nil, progress?.rate != rate else { return }
        progress?.rate = rate
        onChange?()
    }

    func allowSpeedButtonClick() {
        guard progress?.phase == .typing, var expected = compatibilityInput else { return }
        expected[1] &+= 1 // Left mouse down in our own panel.
        if hardwareInputCounts() == expected { compatibilityInput = expected }
    }

    func requestResume() -> Bool {
        guard let progress, progress.phase != .typing,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return false }
        resumeRequested = true
        return true
    }

    func appDidSwitch(to pid: pid_t) {
        if let targetPID, targetPID != pid {
            leftTargetApp = true
            resumeRequested = false
        }
    }

    private func setPhase(_ phase: Phase) {
        guard progress?.phase != phase else { return }
        progress?.phase = phase
        onChange?()
    }

    private var modifiersHeld: Bool {
        !CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).isEmpty
    }

    private func hardwareInputCounts() -> [UInt32] {
        let events: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return events.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
    }

    private func focusedElement(in app: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXFocusedUIElementAttribute, of: app)
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element),
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

    private func textAtSelection(in field: AXUIElement) -> TextAtCaret? {
        guard let caret = insertionPoint(in: field),
              let text = attribute(kAXValueAttribute, of: field) as? String else { return nil }
        return TextAtCaret(text: text, caret: caret)
    }

    private func textAtMarker(in field: AXUIElement) -> TextAtCaret? {
        // Use the same text representation for both the content and the insertion point.
        guard (selectedRange(in: field)?.length ?? 0) == 0,
              let selected = attribute("AXSelectedTextMarkerRange", of: field),
              CFGetTypeID(selected) == AXTextMarkerRangeGetTypeID(),
              parameterizedAttribute("AXStringForTextMarkerRange", of: field, with: selected) as? String == "",
              let whole = parameterizedAttribute("AXTextMarkerRangeForUIElement", of: field, with: field),
              CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID() else { return nil }
        let fieldRange = whole as! AXTextMarkerRange
        let caret = AXTextMarkerRangeCopyStartMarker(selected as! AXTextMarkerRange)
        let before = AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyStartMarker(fieldRange), caret)
        let after = AXTextMarkerRangeCreate(nil, caret, AXTextMarkerRangeCopyEndMarker(fieldRange))
        guard let prefix = parameterizedAttribute("AXStringForTextMarkerRange", of: field, with: before) as? String,
              let suffix = parameterizedAttribute("AXStringForTextMarkerRange", of: field, with: after) as? String
        else { return nil }
        return TextAtCaret(before: prefix, after: suffix)
    }

    private func parameterizedAttribute(_ name: String, of element: AXUIElement, with parameter: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success
        else { return nil }
        return result
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
        if let end = textLength(in: field), (!requireText || end > 0), insertionPoint(in: field) == end {
            return true
        }
        guard let text = textAtMarker(in: field) else { return false }
        return text.after.isEmpty && (!requireText || !text.before.isEmpty)
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
