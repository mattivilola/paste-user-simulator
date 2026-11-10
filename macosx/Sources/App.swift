import AppKit
import ApplicationServices
import Sparkle

@main
@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let typing = TypingSession()
    private lazy var feedback = TypingFeedbackPanel()
    private lazy var hotKey = HotKey { [weak self] in self?.toggleTyping() }
    private var shortcut = Shortcut.standard
    private var shortcutAvailable = false
    private var settings: SettingsWindow?
    private var clipboardTimer: Timer?
    private var clipboardChange = -1
    private var hasText = false
    private var updater: SPUStandardUpdaterController?
    private let summaryItem = NSMenuItem()
    private let previewItem = NSMenuItem()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let stopItem = NSMenuItem(title: "Stop Typing", action: #selector(stopTyping(_:)), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Grant Accessibility Access…",
                                            action: #selector(requestAccess), keyEquivalent: "")
    private let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")

    private var speed: Int {
        let stored = UserDefaults.standard.integer(forKey: "charactersPerMinute")
        return TypingPace.range.contains(stored) ? stored : TypingPace.standard
    }

    private var speedVariation: TypingPace.Variation {
        let stored = UserDefaults.standard.object(forKey: "typingVariationPercent") as? Int
        return stored.flatMap(TypingPace.Variation.init(rawValue:)) ?? .moderate
    }

    private var typoRate: Int {
        let stored = UserDefaults.standard.integer(forKey: "typosPer100Letters")
        return TypoRate.range.contains(stored) ? stored : 0
    }

    private var keepTypingInBackground: Bool {
        UserDefaults.standard.bool(forKey: "keepTypingInBackground")
    }

    private var allowCompatibilityTyping: Bool {
        UserDefaults.standard.bool(forKey: "allowCompatibilityTyping")
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = UserDefaults.standard.data(forKey: "shortcut"),
           let stored = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = stored
        }
        shortcutAvailable = hotKey.register(shortcut)
        typing.onChange = { [weak self] in self?.refreshStatus() }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(summaryItem)
        previewLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.maximumNumberOfLines = 4
        previewLabel.cell?.truncatesLastVisibleLine = true
        previewItem.isHidden = true
        menu.addItem(previewItem)
        stopItem.target = self
        menu.addItem(stopItem)
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        let aboutItem = menu.addItem(withTitle: "About Paste User Simulator",
                                     action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        let settingsItem = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        if let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, feed.hasPrefix("https:"),
           let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty {
            updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            updatesItem.target = self
            menu.addItem(updatesItem)
        }
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit Paste User Simulator",
                                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        statusItem.menu = menu

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(frontmostAppChanged(_:)),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(stopTyping(_:)), name: event, object: nil)
        }

        refreshClipboard()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(refreshClipboard),
                          userInfo: nil, repeats: true)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardTimer?.invalidate()
        typing.stop()
        hotKey.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.propertiesToUpdate.contains(.propertyItemTitle) else { return }
        permissionItem.isHidden = CGPreflightPostEventAccess()
        refreshClipboard()
        refreshStatus()
        refreshClipboardPreview()
    }

    func menuDidClose(_ menu: NSMenu) {
        previewLabel.stringValue = ""
    }

    private func toggleTyping() {
        if typing.isRunning {
            typing.stop()
            feedback.show("Typing stopped", symbol: "stop.circle.fill")
            return
        }
        guard let target = NSWorkspace.shared.frontmostApplication,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { NSSound.beep(); return }
        guard CGPreflightPostEventAccess() else {
            requestAccess()
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }
        typing.start(text: text, rate: speed, variation: speedVariation, typoRate: typoRate,
                     keepTypingInBackground: keepTypingInBackground,
                     allowCompatibilityTyping: allowCompatibilityTyping, target: target)
        if typing.isRunning {
            feedback.show("Typing started", symbol: "keyboard.fill", hint: "Keep the original field focused")
        } else {
            let hint = allowCompatibilityTyping ? "Click inside the field and try again" :
                "Try Compatibility Mode in Settings"
            feedback.show("No text field detected", symbol: "keyboard", hint: hint)
        }
    }

    @objc private func refreshClipboard() {
        let clipboard = NSPasteboard.general
        guard clipboard.changeCount != clipboardChange else { return }
        clipboardChange = clipboard.changeCount
        hasText = clipboard.availableType(from: [.string]) != nil
        refreshStatus()
    }

    private func refreshClipboardPreview() {
        let clipboard = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        guard hasText, clipboard.availableType(from: [concealed]) == nil,
              let text = clipboard.string(forType: .string) else {
            previewItem.isHidden = true
            return
        }
        let prefix = text.prefix(512)
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previewItem.isHidden = true
            return
        }

        previewLabel.stringValue = prefix.endIndex == text.endIndex ? String(prefix) : prefix + "…"
        let width: CGFloat = 248
        let inset: CGFloat = 16
        let height = ceil(previewLabel.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
        previewLabel.frame = NSRect(x: inset, y: 5, width: width, height: height)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * inset, height: height + 8))
        view.addSubview(previewLabel)
        previewItem.view = view
        previewItem.isHidden = false
    }

    private func refreshStatus() {
        let running = typing.isRunning
        let description: String
        if typing.isWaitingForTarget {
            description = "Paused · Focus the original field at its end"
        } else if running {
            description = "Typing · \(shortcut.displayName) to stop"
        } else if !shortcutAvailable {
            description = "Shortcut unavailable · Open Settings"
        } else if hasText {
            description = "Text on clipboard · \(shortcut.displayName) to type"
        } else {
            description = "No text on clipboard"
        }

        let symbol: String
        if typing.isWaitingForTarget {
            symbol = "pause.circle"
        } else {
            symbol = running ? "keyboard.fill" : hasText ? "doc.on.clipboard.fill" : "doc.on.clipboard"
        }
        let button = statusItem.button
        button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button?.image?.isTemplate = true
        button?.toolTip = description
        button?.setAccessibilityLabel("Paste User Simulator")
        button?.setAccessibilityValue(description)
        summaryItem.title = description
        stopItem.isHidden = !running
    }

    @objc private func stopTyping(_ sender: Any?) { typing.stop() }

    @objc private func frontmostAppChanged(_ notification: Notification) { typing.appDidSwitch() }

    @objc private func requestAccess() { CGRequestPostEventAccess() }

    @objc private func checkForUpdates() { updater?.checkForUpdates(nil) }

    @objc private func showAbout() {
        activateApp()
        let credits = NSAttributedString(
            string: "Created with ❤️ by Matti Vilola.\nDistributed and sponsored by ILO APPLICATIONS SL.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func showSettings() {
        if settings == nil {
            settings = SettingsWindow(speed: speed, speedVariation: speedVariation, shortcut: shortcut, typoRate: typoRate,
                                      keepTypingInBackground: keepTypingInBackground,
                                      allowCompatibilityTyping: allowCompatibilityTyping, saveSpeed: {
                UserDefaults.standard.set($0, forKey: "charactersPerMinute")
            }, saveSpeedVariation: {
                UserDefaults.standard.set($0.rawValue, forKey: "typingVariationPercent")
            }, saveTypoRate: {
                UserDefaults.standard.set($0, forKey: "typosPer100Letters")
            }, saveBackgroundTyping: { [weak self] enabled in
                UserDefaults.standard.set(enabled, forKey: "keepTypingInBackground")
                if !enabled { self?.typing.stop() }
            }, saveCompatibilityTyping: { [weak self] enabled in
                UserDefaults.standard.set(enabled, forKey: "allowCompatibilityTyping")
                if !enabled { self?.typing.stop() }
            }, saveShortcut: { [weak self] candidate in
                guard let self, hotKey.register(candidate) else { return false }
                shortcut = candidate
                shortcutAvailable = true
                UserDefaults.standard.set(try? JSONEncoder().encode(candidate), forKey: "shortcut")
                refreshStatus()
                return true
            })
        }
        activateApp()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    private func activateApp() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
private final class TypingFeedbackPanel: NSPanel {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var dismissal: Task<Void, Never>?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 196, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)

        let surface = NSVisualEffectView()
        surface.material = .hudWindow
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 14
        surface.layer?.masksToBounds = true

        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = .labelColor
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        let row = NSStackView(views: [icon, label])
        row.alignment = .centerY
        row.spacing = 8
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [row, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])
        contentView = surface
    }

    func show(_ message: String, symbol: String, hint: String? = nil) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
        else { return }
        dismissal?.cancel()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.stringValue = message
        hintLabel.stringValue = hint ?? ""
        hintLabel.isHidden = hint == nil
        setContentSize(hint == nil ? NSSize(width: 196, height: 44) : NSSize(width: 240, height: 62))
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 16))
        orderFrontRegardless()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(hint == nil ? 1250 : 2200))
            guard !Task.isCancelled else { return }
            self?.orderOut(nil)
        }
    }
}
