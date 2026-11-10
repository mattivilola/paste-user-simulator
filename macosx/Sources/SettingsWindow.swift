import AppKit
import Carbon

@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let speedLabel = NSTextField(labelWithString: "")
    private let shortcutButton = ShortcutButton()
    private let message = NSTextField(labelWithString: "")
    private let saveSpeed: (Int) -> Void
    private let saveSpeedVariation: (TypingPace.Variation) -> Void
    private let saveTypoRate: (Int) -> Void
    private let saveBackgroundTyping: (Bool) -> Void
    private let saveCompatibilityTyping: (Bool) -> Void

    init(speed: Int, speedVariation: TypingPace.Variation, shortcut: Shortcut, typoRate: Int,
         keepTypingInBackground: Bool, allowCompatibilityTyping: Bool, saveSpeed: @escaping (Int) -> Void,
         saveSpeedVariation: @escaping (TypingPace.Variation) -> Void, saveTypoRate: @escaping (Int) -> Void,
         saveBackgroundTyping: @escaping (Bool) -> Void, saveCompatibilityTyping: @escaping (Bool) -> Void,
         saveShortcut: @escaping (Shortcut) -> Bool) {
        self.saveSpeed = saveSpeed
        self.saveSpeedVariation = saveSpeedVariation
        self.saveTypoRate = saveTypoRate
        self.saveBackgroundTyping = saveBackgroundTyping
        self.saveCompatibilityTyping = saveCompatibilityTyping
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Paste User Simulator Settings"
        window.delegate = self
        window.center()

        let range = TypingPace.range
        let slider = NSSlider(value: Double(speed), minValue: Double(range.lowerBound),
                              maxValue: Double(range.upperBound), target: self,
                              action: #selector(speedChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 316).isActive = true
        slider.setAccessibilityLabel("Typing speed in characters per minute")
        speedLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        updateSpeedLabel(speed)

        let variation = NSPopUpButton()
        for option in TypingPace.Variation.allCases {
            let title = switch option {
            case .off: "Off"
            case .subtle: "10% · Subtle"
            case .moderate: "20% · Moderate"
            case .strong: "35% · Strong"
            }
            variation.addItem(withTitle: title)
            variation.lastItem?.tag = option.rawValue
        }
        variation.selectItem(withTag: speedVariation.rawValue)
        variation.setAccessibilityLabel("Speed variation")
        variation.toolTip = "How much the time between keystrokes can vary."
        variation.target = self
        variation.action = #selector(speedVariationChanged(_:))
        let variationRow = NSStackView(views: [NSTextField(labelWithString: "Speed variation"), variation])
        variationRow.spacing = 12

        shortcutButton.title = shortcut.displayName
        shortcutButton.setAccessibilityLabel("Change keyboard shortcut")
        shortcutButton.onCapture = saveShortcut
        shortcutButton.onMessage = { [weak self] in self?.message.stringValue = $0 }
        message.stringValue = "Click the shortcut to change it."
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let shortcutRow = NSStackView(views: [NSTextField(labelWithString: "Type / Stop"), shortcutButton])
        shortcutRow.spacing = 12
        let typos = NSPopUpButton()
        typos.addItems(withTitles: TypoRate.range.map { $0 == 0 ? "Off" : String($0) })
        typos.selectItem(at: typoRate)
        typos.setAccessibilityLabel("Typos per 100 letters")
        typos.toolTip = "Average number of corrected typos per 100 A–Z letters."
        typos.target = self
        typos.action = #selector(typoRateChanged(_:))
        let typoRow = NSStackView(views: [NSTextField(labelWithString: "Typos per 100 letters"), typos])
        typoRow.spacing = 12

        let background = NSButton(checkboxWithTitle: "Keep typing after switching apps", target: self,
                                  action: #selector(backgroundTypingChanged(_:)))
        background.state = keepTypingInBackground ? .on : .off
        background.toolTip = "Continues only while the original field keeps focus in its app."

        let compatibility = NSButton(checkboxWithTitle: "Compatibility Mode", target: self,
                                     action: #selector(compatibilityTypingChanged(_:)))
        compatibility.state = allowCompatibilityTyping ? .on : .off
        compatibility.toolTip = "Type in the active window when an editor does not expose its text field."

        let stack = NSStackView(views: [speedLabel, slider, variationRow, typoRow, background, compatibility,
                                       shortcutRow, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            ])
        }
    }

    required init?(coder: NSCoder) { nil }

    func windowDidResignKey(_ notification: Notification) {
        shortcutButton.finishCapture()
    }

    @objc private func speedChanged(_ slider: NSSlider) {
        updateSpeedLabel(slider.integerValue)
        saveSpeed(slider.integerValue)
    }

    @objc private func speedVariationChanged(_ popup: NSPopUpButton) {
        if let option = TypingPace.Variation(rawValue: popup.selectedTag()) {
            saveSpeedVariation(option)
        }
    }

    @objc private func typoRateChanged(_ popup: NSPopUpButton) {
        saveTypoRate(popup.indexOfSelectedItem)
    }

    @objc private func backgroundTypingChanged(_ checkbox: NSButton) {
        saveBackgroundTyping(checkbox.state == .on)
    }

    @objc private func compatibilityTypingChanged(_ checkbox: NSButton) {
        saveCompatibilityTyping(checkbox.state == .on)
    }

    private func updateSpeedLabel(_ speed: Int) {
        speedLabel.stringValue = "Typing speed  ·  \(speed) characters/min"
    }
}

@MainActor
private final class ShortcutButton: NSButton {
    var onCapture: ((Shortcut) -> Bool)?
    var onMessage: ((String) -> Void)?
    private var previousTitle: String?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginCapture)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    @objc private func beginCapture() {
        guard previousTitle == nil, window?.makeFirstResponder(self) == true else { return }
        previousTitle = title
        title = "Press shortcut"
        onMessage?("Use ⌘, ⌥ or ⌃ with a printable key.")
    }

    override func resignFirstResponder() -> Bool {
        finishCapture()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard previousTitle != nil else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) {
            finishCapture()
            return
        }
        guard let shortcut = Shortcut(event: event) else {
            onMessage?("Use ⌘, ⌥ or ⌃ with a printable key.")
            return
        }
        guard onCapture?(shortcut) == true else {
            onMessage?("That shortcut is unavailable. Try another.")
            return
        }
        previousTitle = shortcut.displayName
        finishCapture()
    }

    func finishCapture() {
        guard let previousTitle else { return }
        title = previousTitle
        self.previousTitle = nil
        onMessage?("Click the shortcut to change it.")
    }
}
