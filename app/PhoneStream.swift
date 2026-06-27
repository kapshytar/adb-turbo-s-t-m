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
    var rediscoverScript: String { (Bundle.main.resourcePath ?? "") + "/phone-rediscover.sh" }

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
        startKeepalive()   // пока трей запущен — keepalive держит USB-связь горячей
    }
    func applicationWillTerminate(_ note: Notification) { stopKeepalive() }

    // ---- keepalive: пинг телефона, чтобы Mac не усыплял USB-порт ----
    func startKeepalive() {
        let script = (Bundle.main.resourcePath ?? "") + "/phone-keepalive.sh"
        guard FileManager.default.fileExists(atPath: script) else { return }
        let p = Process(); p.launchPath = "/bin/bash"
        p.arguments = ["-c", "pkill -f phone-keepalive.sh 2>/dev/null; rmdir /tmp/phone-keepalive.lock 2>/dev/null; exec bash \"\(script)\""]
        try? p.run()
    }
    func stopKeepalive() {
        let p = Process(); p.launchPath = "/bin/bash"
        p.arguments = ["-c", "pkill -f phone-keepalive.sh 2>/dev/null"]
        try? p.run(); p.waitUntilExit()
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
        // Wi-Fi = ПРЯМОЙ SSH-канал (не Wireless Debugging!). Пинг кэш-IP + открытый sshd:8022.
        // Так Wi-Fi доступен без включения Wireless Debugging на телефоне.
        sh("IP=$(cat ~/.phone_wifi_ip 2>/dev/null); [ -n \"$IP\" ] && ping -c1 -t1 \"$IP\" >/dev/null 2>&1 && nc -z -G2 \"$IP\" 8022 >/dev/null 2>&1 && echo y")
            .contains("y")
    }
    // статусы трёх каналов для прозрачного отображения
    func usbAdbOn() -> Bool { usbAvailable() }      // adb по USB (кабель)
    func wifiSshOn() -> Bool { wifiAvailable() }    // прямой SSH по Wi-Fi
    func wirelessDebugOn() -> Bool {                 // adb по Wi-Fi (Wireless Debugging, mDNS)
        !sh("\(adb) mdns services 2>/dev/null | grep -i _adb-tls-connect")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func phoneModel() -> String {
        let dev = sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if dev.isEmpty { return "" }
        return sh("\(adb) -s \(dev) shell getprop ro.product.model")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // имя секции по конкретному устройству канала: "SM-G975F (USB)" / "SM-G975F (Wi-Fi)"
    func transportLabel(_ wifi: Bool, _ chan: String) -> String {
        // Wi-Fi идёт по прямому SSH (adb-устройства может не быть) → берём модель с любого источника.
        if wifi {
            let m = phoneModel()
            return m.isEmpty ? "\(chan) volume" : "\(m) (\(chan))"
        }
        let dev = sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | grep -v _adb-tls | grep -v ':' | head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if dev.isEmpty { return "\(chan) volume" }
        let m = sh("\(adb) -s \(dev) shell getprop ro.product.model")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? "\(chan) volume" : "\(m) (\(chan))"
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

        // ---- ЦЕНТР ПОДКЛЮЧЕНИЯ: прозрачный статус трёх каналов ----
        let chHdr = NSMenuItem(title: "Каналы связи", action: nil, keyEquivalent: ""); chHdr.isEnabled = false
        menu.addItem(chHdr)
        let lUSB = NSMenuItem(title: "  \(usbAdbOn() ? "🟢" : "⚪️") USB (кабель) — перенос/команды", action: nil, keyEquivalent: ""); lUSB.isEnabled = false; menu.addItem(lUSB)
        let lSSH = NSMenuItem(title: "  \(wifiSshOn() ? "🟢" : "⚪️") Wi-Fi (SSH) — браузинг/стрим/перенос", action: nil, keyEquivalent: ""); lSSH.isEnabled = false; menu.addItem(lSSH)
        let lWD  = NSMenuItem(title: "  \(wirelessDebugOn() ? "🟢" : "⚪️") Wireless-debug — не нужен", action: nil, keyEquivalent: ""); lWD.isEnabled = false; menu.addItem(lWD)
        menu.addItem(item("  ⓘ Какой канал для чего", #selector(helpChannels), ""))
        menu.addItem(item("  Проверить SSH", #selector(checkSSH), ""))
        menu.addItem(item("  Перезапустить SSH на телефоне", #selector(restartSSH), ""))
        menu.addItem(.separator())

        // ---- файловые браузеры ----
        menu.addItem(item("Открыть FileDroid", #selector(openBrowser), "b"))
        menu.addItem(item("Открыть ADB Explorer", #selector(openAdbExplorer), ""))
        menu.addItem(.separator())

        // ---- секция USB volume ----
        let usbHdr = NSMenuItem(title: transportLabel(false, "USB"), action: nil, keyEquivalent: "")
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
        let wifiHdr = NSMenuItem(title: transportLabel(true, "Wi-Fi"), action: nil, keyEquivalent: "")
        wifiHdr.isEnabled = false
        menu.addItem(wifiHdr)
        if wifiM {
            menu.addItem(item("  Open Wi-Fi folder", #selector(openWiFi), ""))
            menu.addItem(item("  Unmount Wi-Fi", #selector(unmountWiFi), ""))
        } else if wifiA {
            menu.addItem(item("  ⚠︎ Mount Wi-Fi (медленно, крайний случай)", #selector(mountWiFi), ""))
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
            // ВАЖНО: вывод в temp-файл, НЕ в Pipe. Демонизированный rclone наследует fd
            // и держит pipe открытым → readDataToEndOfFile() висит вечно (busy не снимался,
            // трей застревал на "Working…"). Обычный файл читается до EOF сразу. stdin→/dev/null.
            let tmp = NSTemporaryDirectory() + "phonestream-\(UUID().uuidString).log"
            FileManager.default.createFile(atPath: tmp, contents: nil)
            let fh = FileHandle(forWritingAtPath: tmp)
            t.standardOutput = fh
            t.standardError = fh
            t.standardInput = FileHandle.nullDevice
            t.launch(); t.waitUntilExit()
            try? fh?.close()
            let out = (try? String(contentsOfFile: tmp, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(atPath: tmp)
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
    @objc func openBrowser() {
        // быстрый браузер телефона (adb-листинг, не Finder); в нём открытие файла = стрим
        let candidates = ["/Applications/FileDroid.app"]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            NSWorkspace.shared.open(URL(fileURLWithPath: c)); return
        }
        alert("Браузер не найден", "Поставь FileDroid в /Applications (или ADBFileExplorer).")
    }

    // ---- Wi-Fi actions ----
    @objc func mountWiFi() {
        let a = NSAlert()
        a.messageText = "Mount по Wi-Fi — медленно, крайний случай"
        a.informativeText = """
        Маунт в Finder по Wi-Fi тормозит (Finder + превью macOS читают файлы целиком) и может подвиснуть при обрыве связи.

        Лучше:
        • Браузить → приложение-браузер (ADB Explorer / FileDroid)
        • Смотреть видео → из браузера, откроется в IINA (стрим, без выкачки)
        • Переносить файлы → по SSH (rclone / Cyberduck)

        Монтировать по Wi-Fi стоит только если другой Mac-программе позарез нужен путь к файлу, а кабеля нет.
        """
        a.addButton(withTitle: "Всё равно смонтировать")
        a.addButton(withTitle: "Отмена")
        if a.runModal() != .alertFirstButtonReturn { return }
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
        // Rediscover: пересканировать mDNS, переподхватить Wi-Fi, поднять упавшее (рабочее не трогаем).
        run(rediscoverScript) { code, out in
            if code != 0 { self.alert("Rediscover failed", out) }
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

    // ---- открыть наш Python-браузер ADBFileExplorer ----
    @objc func openAdbExplorer() {
        let runsh = NSHomeDirectory() + "/PhoneAsExtStorage/ADBFileExplorer/run.sh"
        if FileManager.default.fileExists(atPath: runsh) {
            let t = Process(); t.launchPath = "/bin/bash"
            t.arguments = ["-lc", "cd \"$(dirname \(runsh))\" && nohup bash run.sh >/tmp/adbfe.log 2>&1 &"]
            try? t.run()
        } else {
            alert("ADB Explorer не найден", "Ожидал ~/PhoneAsExtStorage/ADBFileExplorer/run.sh")
        }
    }

    // ---- онбординг: какой канал для чего ----
    @objc func helpChannels() {
        alert("Каналы связи — что для чего",
"""
🟢/⚪️ USB (кабель): телефон по проводу (adb). Самый стабильный. Нужен для команд под shell-uid (чистка кэша, scrcpy-зеркало) и быстрых push/pull. «Mount USB» монтирует папку телефона.

🟢/⚪️ Wi-Fi (SSH): прямой SSH на телефон (порт 8022). Wireless Debugging НЕ требуется. Браузинг, стрим видео в IINA (без выкачки), перенос ~25 МБ/с. ГЛАВНЫЙ канал для шкафа-сервера. «Mount Wi-Fi» монтирует по нему.

⚪️ Wireless-debug: adb по Wi-Fi. Нестабилен (динамический порт, тумблер сам гаснет, удалённо не включить). НЕ используем — SSH лучше во всём.

Правило: кабель воткнут → USB. Без кабеля → Wi-Fi (SSH). Стрим видео — через файловый браузер (открывается в IINA).
""")
    }

    // ---- SSH-отчёт в фоне (не вешает UI) ----
    func sshReport(_ title: String, _ cmd: String) {
        busy = true
        DispatchQueue.global().async {
            let out = self.sh(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.busy = false
                self.alert(title, out.isEmpty
                    ? "Нет ответа от телефона по SSH.\nЕсли sshd упал полностью — запусти на телефоне виджет «Start-SSHD» (Termux:Widget) или перезагрузи телефон (Termux:Boot поднимет sshd сам)."
                    : out)
            }
        }
    }
    @objc func checkSSH() {
        sshReport("Проверка SSH-канала", """
IP=$(cat ~/.phone_wifi_ip 2>/dev/null); KEY=$HOME/.ssh/id_ed25519_phone
echo "IP телефона: ${IP:-неизвестен (подключи раз по USB)}"
[ -n "$IP" ] && { ping -c1 -t2 "$IP" >/dev/null 2>&1 && echo "ping: OK" || echo "ping: FAIL (телефон не в сети)"; }
[ -n "$IP" ] && { nc -z -G2 "$IP" 8022 >/dev/null 2>&1 && echo "sshd:8022: открыт" || echo "sshd:8022: закрыт"; }
[ -n "$IP" ] && ssh -i "$KEY" -p 8022 -o StrictHostKeyChecking=no -o ConnectTimeout=5 u0_a520@"$IP" "echo 'SSH-вход: OK'; echo -n 'модель: '; getprop ro.product.model" 2>/dev/null
""")
    }
    @objc func restartSSH() {
        sshReport("Перезапуск SSH на телефоне", """
IP=$(cat ~/.phone_wifi_ip 2>/dev/null); KEY=$HOME/.ssh/id_ed25519_phone
[ -z "$IP" ] && { echo "Не знаю IP телефона. Подключи раз по USB — закэширую."; exit 0; }
ssh -i "$KEY" -p 8022 -o StrictHostKeyChecking=no -o ConnectTimeout=6 u0_a520@"$IP" 'pgrep -x sshd >/dev/null || sshd; nohup sh ~/sshd-watchdog.sh >/dev/null 2>&1 & sleep 1; echo "sshd pid: $(pgrep -x sshd | tr "\\n" " ")"; echo "watchdog: запущен"' 2>/dev/null
""")
    }

    @objc func quit() { stopKeepalive(); NSApp.terminate(nil) }
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
