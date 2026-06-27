import Cocoa

// Menu-bar app: двойной маунт телефона как двух независимых томов (rclone + sftp + Termux sshd).
// USB  → ~/Phone-USB  (порт 8022, volname "Phone USB")
// Wi-Fi → ~/Phone-WiFi (порт 8023, volname "Phone WiFi")
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let adb = NSString(string: "~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath
    var busy = false

    // ---- пути к скриптам из бандла ----
    var mountScript:    String { (Bundle.main.resourcePath ?? "") + "/phone-mount.sh" }
    var unmountScript:  String { (Bundle.main.resourcePath ?? "") + "/phone-unmount.sh" }
    var mountAllScript: String { (Bundle.main.resourcePath ?? "") + "/phone-mount-all.sh" }

    // ---- точки маунта ----
    let mntUSB  = NSString(string: "~/Phone-USB").expandingTildeInPath
    let mntWiFi = NSString(string: "~/Phone-WiFi").expandingTildeInPath

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let p = Bundle.main.resourcePath, let img = NSImage(contentsOfFile: p + "/menubar.png") {
            img.isTemplate = false
            img.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = img
        } else { statusItem.button?.title = "📱" }
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
    }

    // ---- хелперы состояния ----
    func sh(_ cmd: String) -> String {
        let t = Process(); t.launchPath = "/bin/bash"; t.arguments = ["-c", cmd]
        let pipe = Pipe(); t.standardOutput = pipe; t.standardError = pipe
        t.launch(); t.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func usbMounted()  -> Bool { sh("/sbin/mount | grep -q 'Phone-USB'  && echo y").contains("y") }
    func wifiMounted() -> Bool { sh("/sbin/mount | grep -q 'Phone-WiFi' && echo y").contains("y") }

    func usbAvailable() -> Bool {
        !sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | grep -v _adb-tls | grep -v ':'")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func wifiAvailable() -> Bool {
        !sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | grep -E ':|_adb-tls'")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func phoneModel() -> String {
        let dev = sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if dev.isEmpty { return "" }
        return sh("\(adb) -s \(dev) shell getprop ro.product.model")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ---- построить меню ----
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if busy {
            let b = NSMenuItem(title: "⏳ Working…", action: nil, keyEquivalent: "")
            b.isEnabled = false
            menu.addItem(b)
            menu.addItem(.separator())
            menu.addItem(item("Quit", #selector(quit), "q"))
            return
        }

        let usbM  = usbMounted()
        let wifiM = wifiMounted()
        let usbA  = usbAvailable()
        let wifiA = wifiAvailable()

        // ---- статус-строка ----
        var parts: [String] = []
        if usbM  { parts.append("USB") }
        if wifiM { parts.append("Wi-Fi") }
        let model = phoneModel()
        let statusTitle = parts.isEmpty
            ? (model.isEmpty ? "○ Not connected" : "○ \(model) (not mounted)")
            : "● \(model.isEmpty ? "" : "\(model) — ")\(parts.joined(separator: " + "))"
        let st = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        menu.addItem(.separator())

        // ---- секция USB volume ----
        let usbHdr = NSMenuItem(title: "USB volume", action: nil, keyEquivalent: "")
        usbHdr.isEnabled = false
        menu.addItem(usbHdr)
        if usbM {
            menu.addItem(item("  Open USB folder", #selector(openUSB), ""))
            menu.addItem(item("  Unmount USB", #selector(unmountUSB), ""))
        } else if usbA {
            menu.addItem(item("  Mount USB", #selector(mountUSB), ""))
        } else {
            let na = NSMenuItem(title: "  (unavailable)", action: nil, keyEquivalent: "")
            na.isEnabled = false
            menu.addItem(na)
        }
        menu.addItem(.separator())

        // ---- секция Wi-Fi volume ----
        let wifiHdr = NSMenuItem(title: "Wi-Fi volume", action: nil, keyEquivalent: "")
        wifiHdr.isEnabled = false
        menu.addItem(wifiHdr)
        if wifiM {
            menu.addItem(item("  Open Wi-Fi folder", #selector(openWiFi), ""))
            menu.addItem(item("  Unmount Wi-Fi", #selector(unmountWiFi), ""))
        } else if wifiA {
            menu.addItem(item("  Mount Wi-Fi", #selector(mountWiFi), ""))
        } else {
            let na = NSMenuItem(title: "  (unavailable)", action: nil, keyEquivalent: "")
            na.isEnabled = false
            menu.addItem(na)
        }
        menu.addItem(.separator())

        // ---- общие действия ----
        menu.addItem(item("Mount all available", #selector(mountAll), "m"))
        menu.addItem(item("Reconnect", #selector(reconnect), "r"))
        menu.addItem(item("Screen mirror", #selector(mirror), ""))
        menu.addItem(item("Clear phone cache", #selector(clearCache), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), "q"))
    }

    func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self; return i
    }

    // ---- run: запуск скрипта из бандла ----
    func run(_ scriptPath: String, _ extraArgs: [String] = [], _ done: @escaping (Int32, String) -> Void) {
        busy = true
        DispatchQueue.global().async {
            let t = Process()
            t.launchPath = "/bin/bash"
            t.arguments = [scriptPath] + extraArgs
            let pipe = Pipe()
            t.standardOutput = pipe; t.standardError = pipe
            t.launch(); t.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { self.busy = false; done(t.terminationStatus, out) }
        }
    }

    // ---- USB actions ----
    @objc func mountUSB() {
        run(mountScript, ["usb"]) { code, out in
            if code == 0 { self.openUSB() } else { self.alert("USB mount failed", out) }
        }
    }
    @objc func unmountUSB() {
        run(unmountScript, ["usb"]) { _, _ in }
    }
    @objc func openUSB() {
        NSWorkspace.shared.open(URL(fileURLWithPath: mntUSB))
    }

    // ---- Wi-Fi actions ----
    @objc func mountWiFi() {
        run(mountScript, ["wifi"]) { code, out in
            if code == 0 { self.openWiFi() } else { self.alert("Wi-Fi mount failed", out) }
        }
    }
    @objc func unmountWiFi() {
        run(unmountScript, ["wifi"]) { _, _ in }
    }
    @objc func openWiFi() {
        NSWorkspace.shared.open(URL(fileURLWithPath: mntWiFi))
    }

    // ---- общие ----
    @objc func mountAll() {
        run(mountAllScript) { code, out in
            if code == 0 {
                // открыть оба (что смонтировано)
                if self.usbMounted()  { self.openUSB() }
                if self.wifiMounted() { self.openWiFi() }
            } else {
                self.alert("Mount all failed", out)
            }
        }
    }
    @objc func reconnect() {
        // размонтировать оба и смонтировать заново
        run(unmountScript, ["all"]) { _, _ in
            self.run(self.mountAllScript) { code, out in
                if code == 0 {
                    if self.usbMounted()  { self.openUSB() }
                    if self.wifiMounted() { self.openWiFi() }
                } else {
                    self.alert("Reconnect failed", out)
                }
            }
        }
    }

    // ---- scrcpy ----
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
            let a = NSAlert(); a.messageText = "scrcpy not installed"
            a.informativeText = "Screen mirroring uses scrcpy. Install it via Homebrew?"
            a.addButton(withTitle: "Install (brew)"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn {
                run("/bin/bash", ["-lc", "brew install scrcpy"]) { code, out in
                    self.alert(code == 0 ? "scrcpy installed" : "Install failed",
                               code == 0 ? "Done — click \"Screen mirror\" again." : out)
                }
            }
            return
        }
        guard let serial = pickDeviceSerial() else {
            alert("Phone not connected", "Connect your phone first (USB or Wi-Fi)."); return
        }
        let t = Process(); t.launchPath = "/bin/bash"
        t.arguments = ["-c", "ADB=\(adb) \(scr) -s \(serial) >/dev/null 2>&1 &"]
        try? t.run()
    }

    // ---- clear cache ----
    @objc func clearCache() {
        let a = NSAlert(); a.messageText = "Clear all app caches on the phone?"
        a.informativeText = "Frees space by clearing every app's cache. Caches rebuild automatically when you use the apps. Your files and data are NOT touched."
        a.addButton(withTitle: "Clear cache"); a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        guard let serial = pickDeviceSerial() else {
            alert("Phone not connected", "Connect your phone first (USB or Wi-Fi)."); return
        }
        run("/bin/bash", ["-c", "\(adb) -s \(serial) shell pm trim-caches 9999999999999"]) { code, out in
            self.alert(code == 0 ? "Cache cleared" : "Failed",
                       code == 0 ? "App caches cleared on the phone." : out)
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
    func alert(_ t: String, _ m: String) {
        let a = NSAlert(); a.messageText = t
        a.informativeText = m.isEmpty ? "Check the phone and that sshd is running in Termux." : m
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
