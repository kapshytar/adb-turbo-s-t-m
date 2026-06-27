import Cocoa

// Menu-bar app: mount the phone as independent volumes (rclone + sftp + Termux sshd),
// plus a Connection Center for the 4 channels (USB / Wi-Fi SSH / Wireless-debug / adb 5555).
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let adb = NSString(string: "~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath
    var busy = false
    var failed = Set<String>()   // channels whose last connect attempt failed (shown red)

    // ---- bundled script paths ----
    var mountScript:    String { (Bundle.main.resourcePath ?? "") + "/phone-mount.sh" }
    var unmountScript:  String { (Bundle.main.resourcePath ?? "") + "/phone-unmount.sh" }
    var mountAllScript: String { (Bundle.main.resourcePath ?? "") + "/phone-mount-all.sh" }
    var rediscoverScript: String { (Bundle.main.resourcePath ?? "") + "/phone-rediscover.sh" }

    // ---- mount points ----
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
        startKeepalive()   // keep the USB link hot while the tray runs
    }
    func applicationWillTerminate(_ note: Notification) { stopKeepalive() }

    // ---- keepalive: ping the phone so macOS doesn't suspend the USB port ----
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

    // ---- state helpers ----
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
        // Wi-Fi = DIRECT SSH channel (not Wireless Debugging). Ping cached IP + open sshd:8022.
        sh("IP=$(cat ~/.phone_wifi_ip 2>/dev/null); [ -n \"$IP\" ] && ping -c1 -t1 \"$IP\" >/dev/null 2>&1 && nc -z -G2 \"$IP\" 8022 >/dev/null 2>&1 && echo y")
            .contains("y")
    }
    func usbAdbOn() -> Bool { usbAvailable() }      // adb over USB (cable)
    func wifiSshOn() -> Bool { wifiAvailable() }    // direct SSH over Wi-Fi
    func wirelessDebugOn() -> Bool {                 // Wireless Debugging advertises via mDNS
        !sh("\(adb) mdns services 2>/dev/null | grep -i _adb-tls-connect")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func wdConnected() -> Bool {                      // adb actually connected over Wi-Fi (ip:port or _adb-tls)
        !sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | grep -E ':[0-9]+$|_adb-tls'")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    // Admin channel is never turned off. If the phone advertises it and we're not connected, connect.
    func autoConnectWD() {
        if wirelessDebugOn() && !wdConnected() {
            _ = sh("EP=$(\(adb) mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}'); [ -n \"$EP\" ] && \(adb) connect \"$EP\" >/dev/null 2>&1")
        }
    }
    // Wi-Fi adb via mDNS / dynamic port (NOT 5555)
    func wdMdnsOn() -> Bool {
        !sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | grep -E '_adb-tls|:[0-9]+' | grep -v ':5555'")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    // Wi-Fi adb on fixed port 5555
    func wd5555On() -> Bool {
        !sh("\(adb) devices | grep ':5555' | grep -w device")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func phoneModel() -> String {
        let dev = sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if dev.isEmpty { return "" }
        return sh("\(adb) -s \(dev) shell getprop ro.product.model")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // section title per channel device: "SM-G975F (USB)" / "SM-G975F (Wi-Fi · SSH)"
    func transportLabel(_ wifi: Bool, _ chan: String) -> String {
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

    // ---- build menu ----
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

        // ---- status line: dot = REACHABLE (any channel), not "mounted" ----
        let model = phoneModel()
        let reach = usbAdbOn() || wifiSshOn()
        var mounted: [String] = []
        if usbM  { mounted.append("USB") }
        if wifiM { mounted.append("Wi-Fi") }
        let mountedStr = mounted.isEmpty ? "no folders mounted" : "folders: " + mounted.joined(separator: "+")
        let statusTitle = "\(reach ? "●" : "○") \(model.isEmpty ? (reach ? "Connected" : "Phone not found") : model) — \(mountedStr)"
        let st = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        menu.addItem(.separator())

        // ---- CONNECTION CENTER: transparent status of the 4 channels ----
        autoConnectWD()  // admin channel not disabled; if advertised, connect automatically
        let chHdr = NSMenuItem(title: "Channels (click to toggle · hover for help)", action: nil, keyEquivalent: ""); chHdr.isEnabled = false
        menu.addItem(chHdr)
        // 4 channels separately, each a clickable toggle; red = connect failed
        addChannel(menu, "USB (cable) — files + commands", usbAdbOn(), "usb", #selector(toggleUSB),
                   "Cable (adb). File push/pull + commands (pm, scrcpy, logcat). Click to reconnect (re-enumerate). If the port is asleep, replug the DATA cable.")
        addChannel(menu, "Wi-Fi SSH (8022) — files, no cable", wifiSshOn(), "ssh", #selector(toggleSSH),
                   "Direct SSH over Wi-Fi (8022). Main channel for files/streaming, ~25 MB/s, multi-stream. Click to check/restart sshd. Not visible in adb apps.")
        addChannel(menu, "Wireless-debug (mDNS) — admin adb", wdMdnsOn(), "wdmdns", #selector(toggleWDmdns),
                   "adb over Wi-Fi via mDNS (dynamic port). Admin commands: scrcpy, pm, logcat. Click: off → connect, on → disconnect. The WD toggle itself is enabled on the phone.")
        addChannel(menu, "adb TCP 5555 (legacy) — admin adb", wd5555On(), "tcp5555", #selector(toggle5555),
                   "Legacy adb-over-tcp on fixed port 5555 (old method, if adbd listens). Does NOT survive a phone reboot. Click: off → connect 5555, on → disconnect.")
        menu.addItem(item("  ⓘ Which channel for what", #selector(helpChannels), ""))
        menu.addItem(item("  Check all channels", #selector(checkAll), ""))
        menu.addItem(item("  Check SSH", #selector(checkSSH), ""))
        menu.addItem(item("  Restart SSH on phone", #selector(restartSSH), ""))
        menu.addItem(.separator())

        // ---- file browsers ----
        menu.addItem(item("Open FileDroid", #selector(openBrowser), "b"))
        menu.addItem(item("Open ADB Explorer", #selector(openAdbExplorer), ""))
        menu.addItem(item("⬇︎ Download from internet to phone", #selector(downloadToPhone), ""))
        menu.addItem(.separator())

        // ---- USB volume ----
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

        // ---- Wi-Fi volume ----
        let wifiHdr = NSMenuItem(title: transportLabel(true, "Wi-Fi · SSH"), action: nil, keyEquivalent: "")
        wifiHdr.isEnabled = false
        wifiHdr.toolTip = "This folder is mounted over Wi-Fi via SSH (NOT via Wireless-debug)."
        menu.addItem(wifiHdr)
        let wifiWarn = NSMenuItem(title: "  ⚠︎ Finder over Wi-Fi is slow — use a browser/IINA/SSH to view", action: nil, keyEquivalent: "")
        wifiWarn.isEnabled = false
        wifiWarn.toolTip = "The Wi-Fi mount goes over SSH — more stable than Wireless-debug, but still FUSE-over-network: if Wi-Fi drops, Finder can hang (a watchdog force-unmounts). For viewing/streaming use a browser + IINA, not Finder."
        menu.addItem(wifiWarn)
        if wifiM {
            menu.addItem(item("  Open Wi-Fi folder", #selector(openWiFi), ""))
            menu.addItem(item("  Unmount Wi-Fi", #selector(unmountWiFi), ""))
        } else if wifiA {
            menu.addItem(item("  ⚠︎ Mount Wi-Fi (slow, last resort)", #selector(mountWiFi), ""))
        } else {
            let na = NSMenuItem(title: "  (unavailable)", action: nil, keyEquivalent: "")
            na.isEnabled = false
            menu.addItem(na)
        }
        menu.addItem(.separator())

        // ---- general actions ----
        menu.addItem(item("Mount all available", #selector(mountAll), "m"))
        menu.addItem(item("🔌 Connect everything", #selector(reconnect), "r"))
        menu.addItem(item("Screen mirror", #selector(mirror), ""))
        menu.addItem(item("Clear phone cache", #selector(clearCache), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), "q"))
    }

    func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self; return i
    }

    // ---- run a bundled SCRIPT FILE: bash <script> <args> ----
    func run(_ scriptPath: String, _ extraArgs: [String] = [], _ done: @escaping (Int32, String) -> Void) {
        exec(launch: "/bin/bash", args: [scriptPath] + extraArgs, done)
    }
    // ---- run an INLINE command correctly: bash -c CMD bash <posArgs...> ($1.. = posArgs) ----
    func runCmd(_ cmd: String, _ posArgs: [String] = [], _ done: @escaping (Int32, String) -> Void) {
        exec(launch: "/bin/bash", args: ["-c", cmd, "phonestream"] + posArgs, done)
    }
    // shared executor: output to a temp file (NOT a Pipe — a daemonized rclone inherits the fd
    // and keeps the pipe open → readDataToEndOfFile() would hang forever, freezing on "Working…").
    private func exec(launch: String, args: [String], _ done: @escaping (Int32, String) -> Void) {
        busy = true
        DispatchQueue.global().async {
            let t = Process()
            t.launchPath = launch
            t.arguments = args
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
    @objc func unmountUSB() { run(unmountScript, ["usb"]) { _, _ in } }
    @objc func openUSB() { NSWorkspace.shared.open(URL(fileURLWithPath: mntUSB)) }
    @objc func openBrowser() {
        let candidates = ["/Applications/FileDroid.app"]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            NSWorkspace.shared.open(URL(fileURLWithPath: c)); return
        }
        alert("Browser not found", "Install FileDroid in /Applications (or ADBFileExplorer).")
    }

    // ---- Wi-Fi actions ----
    @objc func mountWiFi() {
        let a = NSAlert()
        a.messageText = "Wi-Fi mount — slow, last resort"
        a.informativeText = """
        Mounting in Finder over Wi-Fi is slow (Finder + macOS thumbnails read whole files) and can hang if the link drops.

        Better:
        • Browse → a browser app (ADB Explorer / FileDroid)
        • Watch video → from the browser, opens in IINA (streamed, no full download)
        • Transfer files → over SSH (rclone / Cyberduck)

        Only mount over Wi-Fi if another Mac app really needs a file path and there's no cable.
        """
        a.addButton(withTitle: "Mount anyway")
        a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        run(mountScript, ["wifi"]) { code, out in
            if code == 0 { self.openWiFi() } else { self.alert("Wi-Fi mount failed", out) }
        }
    }
    @objc func unmountWiFi() { run(unmountScript, ["wifi"]) { _, _ in } }
    @objc func openWiFi() { NSWorkspace.shared.open(URL(fileURLWithPath: mntWiFi)) }

    // ---- download from internet straight to phone (bypasses Mac disk) ----
    @objc func downloadToPhone() {
        let a = NSAlert()
        a.messageText = "Download from internet to phone"
        a.informativeText = "Paste a URL — the file goes straight to the phone (/sdcard/Download), bypassing the Mac disk. Requires a live Wi-Fi SSH channel."
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        tf.placeholderString = "https://…"
        a.accessoryView = tf
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let url = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let script = """
        URL="$1"
        IP=$(cat ~/.phone_wifi_ip 2>/dev/null); IP=${IP:-192.168.1.202}
        KEY=$HOME/.ssh/id_ed25519_phone
        if ! nc -z -G2 "$IP" 8022 >/dev/null 2>&1; then echo "No SSH link to the phone (8022). Bring up Wi-Fi SSH first."; exit 1; fi
        /usr/local/bin/rclone copyurl "$URL" ":sftp,host=$IP,port=8022,user=u0_a520,key_file=$KEY,shell_type=none:/sdcard/Download" --auto-filename -q \
          && echo "✅ Saved to phone: /sdcard/Download/" \
          || echo "❌ Failed (check the URL and the SSH link)."
        """
        runCmd(script, [url]) { _, out in self.alert("Download to phone", out) }
    }

    // ---- general ----
    @objc func mountAll() {
        run(mountAllScript) { code, out in
            if code == 0 {
                if self.usbMounted()  { self.openUSB() }
                if self.wifiMounted() { self.openWiFi() }
            } else { self.alert("Mount all failed", out) }
        }
    }
    @objc func reconnect() {
        // "Connect everything": run through every init method for each channel + report.
        run(rediscoverScript) { _, out in
            self.alert("Connect everything",
                out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Done." : out)
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
                runCmd("export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; brew install scrcpy") { code, out in
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
        runCmd("\(adb) -s \(serial) shell pm trim-caches 9999999999999") { code, out in
            self.alert(code == 0 ? "Cache cleared" : "Failed",
                       code == 0 ? "App caches cleared on the phone." : out)
        }
    }

    // ---- open our Python browser ADBFileExplorer ----
    @objc func openAdbExplorer() {
        let runsh = NSHomeDirectory() + "/PhoneAsExtStorage/ADBFileExplorer/run.sh"
        if FileManager.default.fileExists(atPath: runsh) {
            let t = Process(); t.launchPath = "/bin/bash"
            t.arguments = ["-lc", "cd \"$(dirname \(runsh))\" && nohup bash run.sh >/tmp/adbfe.log 2>&1 &"]
            try? t.run()
        } else {
            alert("ADB Explorer not found", "Expected ~/PhoneAsExtStorage/ADBFileExplorer/run.sh")
        }
    }

    // ---- onboarding: which channel for what ----
    @objc func helpChannels() {
        alert("4 channels — which for what",
"""
TWO PROTOCOLS: three channels are adb (commands + files), one is SSH (files only).

1) USB (cable) — adb over the wire. Most stable, independent of the network. ~27 MB/s. Commands under shell-uid (scrcpy, pm, logcat) + push/pull. "Mount USB" → folder in Finder.

2) Wi-Fi SSH (8022) — SSH/SFTP over Wi-Fi. MAIN channel for FILES without a cable: browsing, streaming in IINA, transfer ~25 MB/s multi-stream. Fixed port, survives reboot (Termux:Boot). No Android commands. Not visible in adb apps.

3) Wireless-debug (mDNS) — adb over Wi-Fi, dynamic port. For ADMIN commands over the air (scrcpy, pm, logcat). The toggle is enabled on the phone; the port changes on reboot.

4) adb TCP 5555 (legacy) — the same adbd over Wi-Fi, but on the old fixed port 5555. Disappears after a phone reboot. Basically a duplicate of channel #3 (two doors into one room).

IMPORTANT: #3 and #4 are the same adbd on the phone, just different entrances. All Wi-Fi channels share one radio → speeds are ~equal and do NOT add up.

RULE:
• Files over the air → SSH (reliable, reboot-proof).
• Admin commands over the air → Wireless-debug (mDNS).
• Everything at once, most stable → USB.
• Stream video → via a browser app (opens in IINA, no full download).
""")
    }

    // ---- async SSH report (doesn't block the UI) ----
    func sshReport(_ title: String, _ cmd: String) {
        busy = true
        DispatchQueue.global().async {
            let out = self.sh(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.busy = false
                self.alert(title, out.isEmpty
                    ? "No response from the phone over SSH.\nIf sshd is fully down, launch the \"Start-SSHD\" widget on the phone (Termux:Widget) or reboot it (Termux:Boot brings sshd back up)."
                    : out)
            }
        }
    }
    // clickable channel row: 🟢 working / 🔴 failed / ⚪️ off
    func addChannel(_ menu: NSMenu, _ text: String, _ working: Bool, _ key: String, _ sel: Selector, _ tip: String) {
        let dot = working ? "🟢" : (failed.contains(key) ? "🔴" : "⚪️")
        let title = "  \(dot) \(text)"
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        it.toolTip = tip
        if !working && failed.contains(key) {
            it.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
        }
        menu.addItem(it)
    }

    // ---- channel toggles: touch ONLY their own channel, never the working ones ----
    @objc func toggleUSB() {
        if usbAdbOn() { return }   // working — leave it
        runCmd("\(adb) reconnect offline >/dev/null 2>&1; sleep 1; \(adb) devices -l | grep -q usb: && echo OK") { _, out in
            if out.contains("OK") { self.failed.remove("usb") }
            else { self.failed.insert("usb"); self.alert("USB didn't come up", "The port seems suspended. Replug the DATA cable (not charge-only) or try another port — software can't wake it.") }
        }
    }
    @objc func toggleSSH() {
        if wifiSshOn() { alert("Wi-Fi SSH", "Working (port 8022). This is the phone's server channel — no need to turn it off here."); return }
        runCmd("IP=$(cat ~/.phone_wifi_ip 2>/dev/null); IP=${IP:-192.168.1.202}; KEY=$HOME/.ssh/id_ed25519_phone; ssh -i \"$KEY\" -p 8022 -o StrictHostKeyChecking=no -o ConnectTimeout=6 u0_a520@\"$IP\" 'pgrep -x sshd >/dev/null || sshd' 2>/dev/null; sleep 1; nc -z -G2 \"$IP\" 8022 && echo OK") { _, out in
            if out.contains("OK") { self.failed.remove("ssh") }
            else { self.failed.insert("ssh"); self.alert("SSH not responding", "Phone unreachable over SSH. Launch the \"Start-SSHD\" widget on the phone, or wait — the watchdog will bring it up.") }
        }
    }
    @objc func toggleWDmdns() {
        if wdMdnsOn() {  // off: disconnect the mDNS entry/entries, without touching 5555/USB
            runCmd("for d in $(\(adb) devices | awk '/device$/{print $1}' | grep -E '_adb-tls|:[0-9]+' | grep -v ':5555'); do \(adb) disconnect \"$d\" >/dev/null 2>&1; done; echo done") { _, _ in }
        } else {        // on: warm up mDNS (no kill-server, to avoid dropping others) + connect
            runCmd("\(adb) mdns services >/dev/null 2>&1; sleep 1; EP=$(\(adb) mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}'); [ -n \"$EP\" ] && \(adb) connect \"$EP\" >/dev/null 2>&1; sleep 1; \(adb) devices | awk '/device$/{print $1}' | grep -E '_adb-tls|:[0-9]+' | grep -v ':5555' | grep -q . && echo OK") { _, out in
                if out.contains("OK") { self.failed.remove("wdmdns") }
                else { self.failed.insert("wdmdns"); self.alert("Wireless-debug didn't connect", "Enable the Wireless Debugging toggle on the phone (Settings → Developer options). It can't be enabled remotely. If it's on but not seen, click \"Connect everything\" (restarts the adb server).") }
            }
        }
    }
    @objc func toggle5555() {
        if wd5555On() {
            runCmd("IP=$(cat ~/.phone_wifi_ip 2>/dev/null); IP=${IP:-192.168.1.202}; \(adb) disconnect \"$IP:5555\" >/dev/null 2>&1; echo done") { _, _ in }
        } else {
            runCmd("IP=$(cat ~/.phone_wifi_ip 2>/dev/null); IP=${IP:-192.168.1.202}; nc -z -G1 \"$IP\" 5555 && \(adb) connect \"$IP:5555\" >/dev/null 2>&1; sleep 1; \(adb) devices | grep ':5555' | grep -wq device && echo OK") { _, out in
                if out.contains("OK") { self.failed.remove("tcp5555") }
                else { self.failed.insert("tcp5555"); self.alert("5555 unavailable", "adbd isn't listening on 5555 (it disappears after a phone reboot). Bring the phone up via USB or Wireless-debug first.") }
            }
        }
    }
    @objc func checkAll() {
        sshReport("All channels status", """
ADB=\(adb); IP=192.168.1.202
echo "CHANNELS (can be used in parallel):"
U=$("$ADB" devices -l 2>/dev/null | grep 'usb:' | awk '{print $1}')
[ -n "$U" ] && echo "  🟢 USB (cable, adb) — $U  [files push/pull, commands]" || echo "  ⚪️ USB (cable) — none (cable/port)"
WC=$("$ADB" devices 2>/dev/null | grep -E ':[0-9]+|_adb-tls' | grep -c device)
[ "$WC" -gt 0 ] && echo "  🟢 Wi-Fi adb / Wireless-debug — $WC entr(y/ies)  [admin: scrcpy, pm, logcat]" || echo "  ⚪️ Wi-Fi adb / Wireless-debug — none"
if nc -z -G2 "$IP" 8022 >/dev/null 2>&1; then echo "  🟢 Wi-Fi SSH (8022) — $IP  [files/streaming, no cable; NOT shown in adb apps]"; else echo "  ⚪️ Wi-Fi SSH (8022) — none"; fi
echo ""
echo "FOLDERS in Finder (mount):"
/sbin/mount | grep -q Phone-USB  && echo "  🟢 USB folder ~/Phone-USB"   || echo "  ⚪️ USB folder not mounted"
/sbin/mount | grep -q Phone-WiFi && echo "  🟢 Wi-Fi folder ~/Phone-WiFi (over SSH)" || echo "  ⚪️ Wi-Fi folder not mounted"
""")
    }
    @objc func checkSSH() {
        sshReport("Check SSH channel", """
IP=$(cat ~/.phone_wifi_ip 2>/dev/null); KEY=$HOME/.ssh/id_ed25519_phone
echo "Phone IP: ${IP:-unknown (connect once over USB)}"
[ -n "$IP" ] && { ping -c1 -t2 "$IP" >/dev/null 2>&1 && echo "ping: OK" || echo "ping: FAIL (phone not on the network)"; }
[ -n "$IP" ] && { nc -z -G2 "$IP" 8022 >/dev/null 2>&1 && echo "sshd:8022: open" || echo "sshd:8022: closed"; }
[ -n "$IP" ] && ssh -i "$KEY" -p 8022 -o StrictHostKeyChecking=no -o ConnectTimeout=5 u0_a520@"$IP" "echo 'SSH login: OK'; echo -n 'model: '; getprop ro.product.model" 2>/dev/null
""")
    }
    @objc func restartSSH() {
        sshReport("Restart SSH on phone", """
IP=$(cat ~/.phone_wifi_ip 2>/dev/null); KEY=$HOME/.ssh/id_ed25519_phone
[ -z "$IP" ] && { echo "Phone IP unknown. Connect once over USB to cache it."; exit 0; }
ssh -i "$KEY" -p 8022 -o StrictHostKeyChecking=no -o ConnectTimeout=6 u0_a520@"$IP" 'pgrep -x sshd >/dev/null || sshd; nohup sh ~/sshd-watchdog.sh >/dev/null 2>&1 & sleep 1; echo "sshd pid: $(pgrep -x sshd | tr "\\n" " ")"; echo "watchdog: started"' 2>/dev/null
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
