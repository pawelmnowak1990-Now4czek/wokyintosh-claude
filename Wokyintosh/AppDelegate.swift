import Cocoa
import ServiceManagement
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var bridge: NativeBridge!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Rejestracja przed budową menu, bo pozycja "Open at Login"
        // odczytuje stan przy tworzeniu.
        registerLoginItemIfPossible()
        buildMainMenu()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]

        let dock = dockScreen()

        guard let screen = dock ?? NSScreen.main ?? NSScreen.screens.first else {
            showFatal("No display is available.")
            return
        }

        let frame: NSRect
        let style: NSWindow.StyleMask

        if dock != nil {
            frame = screen.frame
            style = [.borderless]
        } else {
            let visible = screen.visibleFrame
            let width = min(1180.0, visible.width * 0.88)
            let height = min(664.0, visible.height * 0.84)
            frame = NSRect(
                x: visible.midX - width / 2,
                y: visible.midY - height / 2,
                width: width,
                height: height
            )
            style = [.titled, .closable, .miniaturizable, .resizable]
        }

        window = DashboardWindow(
            contentRect: frame,
            styleMask: style,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // NSWindow(contentRect:…screen:) liczy ramkę względem początku podanego
        // ekranu, więc na drugim monitorze okno wylądowałoby o jego szerokość
        // za daleko. setFrame przyjmuje współrzędne globalne i to prostuje.
        window.setFrame(frame, display: false)

        window.title = "Wokyintosh"
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(
            calibratedRed: 0.87,
            green: 0.84,
            blue: 0.77,
            alpha: 1.0
        )
        window.contentView = webView
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Bez activate(ignoringOtherApps:) — przy autostarcie dashboard
        // nie ma wyrywać użytkownika z pracy na głównym monitorze.
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        guard
            let resourcesURL = Bundle.main.resourceURL,
            let indexURL = Bundle.main.url(
                forResource: "index",
                withExtension: "html",
                subdirectory: "Resources"
            )
        else {
            showFatal("Wokyintosh resources are missing.")
            return
        }

        webView.loadFileURL(indexURL, allowingReadAccessTo: resourcesURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        bridge = NativeBridge(webView: webView)
        bridge.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Rejestracja autostartu działa tylko dla aplikacji zainstalowanej
    /// w /Applications. Uruchomiona z build/ albo z Pobranych trafia do
    /// tymczasowej kopii (App Translocation) i rejestracja nie ma sensu.
    private func registerLoginItemIfPossible() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }

        // Po wyrejestrowaniu status potrafi być .notFound zamiast .notRegistered,
        // więc pytamy wprost o to, co nas interesuje: czy autostart jest włączony.
        let status = SMAppService.mainApp.status
        guard status != .enabled, status != .requiresApproval else { return }

        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Wokyintosh: nie udało się zarejestrować autostartu: \(error)")
        }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("Wokyintosh: przełączenie autostartu nie powiodło się: \(error)")
        }
    }

    /// Ekran dokowanego wyświetlacza: najpierw po nazwie, potem po rozdzielczości.
    private func dockScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let named = screens.first(where: { $0.localizedName == "Wokyis" }) { return named }
        return screens.first(where: { $0.frame.width == 1280 && $0.frame.height == 720 })
    }

    @objc private func screensChanged() {
        guard let dock = dockScreen() else { return }
        window.setFrame(dock.frame, display: true)
    }

    private func showFatal(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Wokyintosh"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()

        let loginItem = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        appMenu.addItem(loginItem)
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(
            NSMenuItem(
                title: "Quit Wokyintosh",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}

/// Okno bez ramki musi umieć zostać oknem kluczowym, inaczej Cmd+Q nie działa.
final class DashboardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
