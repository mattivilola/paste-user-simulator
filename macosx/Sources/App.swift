import AppKit
import ApplicationServices
import Sparkle

@main
@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let typing = TypingSession()
    private lazy var hotKey = HotKey { [weak self] in self?.toggleTyping() }
    private var shortcut = Shortcut.standard
    private var shortcutAvailable = false
    private var settings: SettingsWindow?
    private var clipboardTimer: Timer?
    private var clipboardChange = -1
    private var hasText = false
    private var updater: SPUStandardUpdaterController?
    private let summaryItem = NSMenuItem()
    private let stopItem = NSMenuItem(title: "Stop Typing", action: #selector(stopTyping(_:)), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Grant Accessibility Access…",
                                            action: #selector(requestAccess), keyEquivalent: "")
    private let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")

    private var speed: Int {
        let stored = UserDefaults.standard.integer(forKey: "charactersPerMinute")
        return TypingPace.range.contains(stored) ? stored : TypingPace.standard
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
        stopItem.target = self
        menu.addItem(stopItem)
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())
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
        for event in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification,
                      NSWorkspace.sessionDidResignActiveNotification] {
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

    func menuWillOpen(_ menu: NSMenu) {
        permissionItem.isHidden = CGPreflightPostEventAccess()
        refreshClipboard()
        refreshStatus()
    }

    private func toggleTyping() {
        if typing.isRunning {
            typing.stop()
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
        typing.start(text: text, rate: speed, target: target)
    }

    @objc private func refreshClipboard() {
        let clipboard = NSPasteboard.general
        guard clipboard.changeCount != clipboardChange else { return }
        clipboardChange = clipboard.changeCount
        hasText = clipboard.availableType(from: [.string]) != nil
        refreshStatus()
    }

    private func refreshStatus() {
        let running = typing.isRunning
        let description: String
        if running {
            description = "Typing · \(shortcut.displayName) to stop"
        } else if !shortcutAvailable {
            description = "Shortcut unavailable · Open Settings"
        } else if hasText {
            description = "Text on clipboard · \(shortcut.displayName) to type"
        } else {
            description = "No text on clipboard"
        }

        let symbol = running ? "keyboard.fill" : hasText ? "doc.on.clipboard.fill" : "doc.on.clipboard"
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

    @objc private func requestAccess() { CGRequestPostEventAccess() }

    @objc private func checkForUpdates() { updater?.checkForUpdates(nil) }

    @objc private func showSettings() {
        if settings == nil {
            settings = SettingsWindow(speed: speed, shortcut: shortcut, saveSpeed: {
                UserDefaults.standard.set($0, forKey: "charactersPerMinute")
            }, saveShortcut: { [weak self] candidate in
                guard let self, hotKey.register(candidate) else { return false }
                shortcut = candidate
                shortcutAvailable = true
                UserDefaults.standard.set(try? JSONEncoder().encode(candidate), forKey: "shortcut")
                refreshStatus()
                return true
            })
        }
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }
}
