import AppKit
import Carbon

@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let speedLabel = NSTextField(labelWithString: "")
    private let shortcutButton = ShortcutButton()
    private let message = NSTextField(labelWithString: "")
    private let saveSpeed: (Int) -> Void

    init(speed: Int, shortcut: Shortcut, saveSpeed: @escaping (Int) -> Void,
         saveShortcut: @escaping (Shortcut) -> Bool) {
        self.saveSpeed = saveSpeed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 204),
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

        shortcutButton.title = shortcut.displayName
        shortcutButton.setAccessibilityLabel("Change keyboard shortcut")
        shortcutButton.onCapture = saveShortcut
        shortcutButton.onMessage = { [weak self] in self?.message.stringValue = $0 }
        message.stringValue = "Click the shortcut to change it."
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let shortcutRow = NSStackView(views: [NSTextField(labelWithString: "Type / Stop"), shortcutButton])
        shortcutRow.spacing = 12
        let stack = NSStackView(views: [speedLabel, slider, shortcutRow, message])
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
