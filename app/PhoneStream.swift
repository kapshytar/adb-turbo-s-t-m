import Cocoa

// Меню-бар: телефон как диск (no-copy rclone-mount). Выбор транспорта + переподключение.
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let adb        = NSString(string: "~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath
    // скрипты лежат внутри .app (Resources) — портативно, без привязки к чужому пути
    var upScript:   String { (Bundle.main.resourcePath ?? "") + "/phone-stream-up.sh" }
    var downScript: String { (Bundle.main.resourcePath ?? "") + "/phone-stream-down.sh" }
    let mountPoint = NSString(string: "~/PhoneStream").expandingTildeInPath
    var busy = false
    var transport: String {                       // "auto" | "wifi" | "usb"
        get { UserDefaults.standard.string(forKey: "transport") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "transport") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let p = Bundle.main.resourcePath, let img = NSImage(contentsOfFile: p + "/menubar.png") {
            img.isTemplate = false
            img.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = img
        } else { statusItem.button?.title = "📱" }
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
    }

    // ---- helpers ----
    func sh(_ cmd: String) -> String {
        let t = Process(); t.launchPath = "/bin/bash"; t.arguments = ["-c", cmd]
        let pipe = Pipe(); t.standardOutput = pipe; t.standardError = pipe
        t.launch(); t.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    func isMounted() -> Bool { sh("/sbin/mount | grep -q PhoneStream && echo y").contains("y") }
    func usbAvailable() -> Bool {
        !sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | grep -v _adb-tls | grep -v ':'")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func wifiAvailable() -> Bool {
        !sh("\(adb) mdns services 2>/dev/null | grep _adb-tls-connect")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // ---- menu ----
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if busy {
            let b = NSMenuItem(title: "⏳ Работаю…", action: nil, keyEquivalent: ""); b.isEnabled = false
            menu.addItem(b); menu.addItem(.separator())
            menu.addItem(item("Выход", #selector(quit), "q")); return
        }
        let mounted = isMounted(), usb = usbAvailable(), wifi = wifiAvailable()

        let st = NSMenuItem(title: mounted ? "● Подключён (~/PhoneStream)" : "○ Не подключён", action: nil, keyEquivalent: "")
        st.isEnabled = false; menu.addItem(st)
        menu.addItem(.separator())
        if mounted {
            menu.addItem(item("Открыть папку", #selector(openFolder), "o"))
            menu.addItem(item("Отключить", #selector(unmount), "u"))
        } else {
            menu.addItem(item("Подключить", #selector(mountAction), "m"))
        }
        menu.addItem(.separator())
        let hdr = NSMenuItem(title: "Транспорт:", action: nil, keyEquivalent: ""); hdr.isEnabled = false
        menu.addItem(hdr)
        addTransport(menu, "Авто", "auto", true)
        addTransport(menu, "Wi-Fi", "wifi", wifi)
        addTransport(menu, "USB (турбо)", "usb", usb)
        menu.addItem(.separator())
        menu.addItem(item("Переподключить", #selector(reconnect), "r"))
        menu.addItem(item("Зеркало экрана", #selector(mirror), ""))
        menu.addItem(.separator())
        menu.addItem(item("Выход", #selector(quit), "q"))
    }

    func scrcpyPath() -> String? {
        for p in ["/usr/local/bin/scrcpy", "/opt/homebrew/bin/scrcpy"]
            where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }
    func pickDeviceSerial() -> String? {
        let usb = sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | grep -v _adb-tls | grep -v ':' | head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !usb.isEmpty { return usb }
        let wifi = sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | grep -E '_adb-tls|:' | head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return wifi.isEmpty ? nil : wifi
    }
    @objc func mirror() {
        guard let scr = scrcpyPath() else {
            let a = NSAlert(); a.messageText = "scrcpy не установлен"
            a.informativeText = "Зеркало экрана работает через scrcpy. Установить через Homebrew?"
            a.addButton(withTitle: "Установить (brew)"); a.addButton(withTitle: "Отмена")
            if a.runModal() == .alertFirstButtonReturn {
                run(["-lc", "brew install scrcpy"]) { code, out in
                    self.alert(code == 0 ? "scrcpy установлен" : "Не удалось установить",
                               code == 0 ? "Готово — нажми «Зеркало экрана» снова." : out)
                }
            }
            return
        }
        guard let serial = pickDeviceSerial() else {
            alert("Телефон не подключён", "Сначала подключи телефон (USB или Wi-Fi)."); return
        }
        let t = Process(); t.launchPath = "/bin/bash"
        t.arguments = ["-c", "ADB=\(adb) \(scr) -s \(serial) >/dev/null 2>&1 &"]
        try? t.run()
    }
    func addTransport(_ menu: NSMenu, _ title: String, _ key: String, _ available: Bool) {
        let i = NSMenuItem(title: title + (available ? "" : "  (недоступно)"),
                           action: #selector(selectTransport(_:)), keyEquivalent: "")
        i.target = self; i.representedObject = key
        i.state = (transport == key) ? .on : .off
        i.isEnabled = available
        menu.addItem(i)
    }
    func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.target = self; return i
    }

    func run(_ args: [String], _ done: @escaping (Int32, String) -> Void) {
        busy = true
        DispatchQueue.global().async {
            let t = Process(); t.launchPath = "/bin/bash"; t.arguments = args
            let pipe = Pipe(); t.standardOutput = pipe; t.standardError = pipe
            t.launch(); t.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { self.busy = false; done(t.terminationStatus, out) }
        }
    }

    @objc func mountAction() {
        run([upScript, transport]) { code, out in
            if code == 0 { self.openFolder() } else { self.alert("Не удалось подключить", out) }
        }
    }
    @objc func unmount() { run([downScript]) { _, _ in } }
    @objc func selectTransport(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        transport = key
        if isMounted() {
            run([downScript]) { _, _ in
                self.run([self.upScript, key]) { c, o in if c != 0 { self.alert("Не удалось переключить", o) } }
            }
        }
    }
    @objc func reconnect() {
        run(["-c", "\(adb) mdns services >/dev/null 2>&1; \(downScript) >/dev/null 2>&1; \(upScript) \(transport)"]) { code, out in
            if code == 0 { self.openFolder() } else { self.alert("Переподключение не удалось", out) }
        }
    }
    @objc func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint)) }
    @objc func quit() { NSApp.terminate(nil) }
    func alert(_ t: String, _ m: String) {
        let a = NSAlert(); a.messageText = t
        a.informativeText = m.isEmpty ? "Проверь телефон и что sshd запущен в Termux." : m
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
