import Cocoa

// Menu-bar app: mount the phone as independent volumes (rclone + sftp + Termux sshd),
// plus a Connection Center for the 4 channels (USB / Wi-Fi SSH / Wireless-debug / adb 5555).
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let adb = NSString(string: "~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath
    // FIX #3: busy is now a counter so parallel operations don't clobber each other
    var busyCount = 0
    var busy: Bool { busyCount > 0 }
    var failed = Set<String>()   // channels whose last connect attempt failed (shown red)
    // строки выбора устройства (кастомные view-кнопки: клик НЕ закрывает меню, галочка live)
    var deviceRows: [(model: String, display: String, button: NSButton)] = []
    // пункты каналов — храним ссылки, чтобы обновлять точки ВЖИВУЮ при смене устройства
    var channelItems: [(key: String, text: String, item: NSMenuItem)] = []
    // заголовки маунт-секций (USB/Wi-Fi) — обновляем модель live при смене устройства
    var mountHeaders: [(kind: String, item: NSMenuItem)] = []

    // FIX #1: cached phone state — populated by background timer, read by menuNeedsUpdate
    struct PhoneState {
        var model      = ""
        var usbMounted  = false
        var wifiMounted = false
        var usbAdb      = false
        var wifiSsh     = false
        var wdMdns      = false
        var wd5555      = false
        var wifiSshRaw  = false   // сырая доступность SSH (без привязки к устройству)
        var sshOK       = false   // у активного устройства есть живой sshd (mount/upload/download/stream возможны)
        // Список подключённых adb-устройств для подменю выбора.
        // Влияет только на adb-операции (USB-mount, scrcpy, cache).
        // SSH/Wi-Fi-операции (mount-wifi, stream, upload, download) идут на
        // SSH-сервер по закэшированному IP — devices их НЕ затрагивает.
        var devices: [(serial: String, model: String, kind: String, active: Bool)] = []
        var activeModel = ""
    }
    var state = PhoneState()
    var refreshTimer: Timer?

    // ---- bundled script paths ----
    var mountScript:    String { (Bundle.main.resourcePath ?? "") + "/phone-mount.sh" }
    var unmountScript:  String { (Bundle.main.resourcePath ?? "") + "/phone-unmount.sh" }
    var mountAllScript: String { (Bundle.main.resourcePath ?? "") + "/phone-mount-all.sh" }
    var rediscoverScript: String { (Bundle.main.resourcePath ?? "") + "/phone-rediscover.sh" }
    var cfgPath: String { (Bundle.main.resourcePath ?? "") + "/config.sh" }  // для active_ip в инлайнах

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
        startWatchdog()    // proactive guard: force-unmount before a dead mount wedges the OS

        // FIX #1: prime the cache immediately, then refresh every 4 s
        scheduleBackgroundRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.scheduleBackgroundRefresh()
        }
    }
    func applicationWillTerminate(_ note: Notification) {
        refreshTimer?.invalidate()
        // СНАЧАЛА снять тома: после выхода стражей не будет, а оставшийся сетевой FUSE-том
        // подвешивает ОС (Activity Monitor/Finder) и рискует D-state. Best-effort с таймаутом
        // на каждый unmount, чтобы сам выход не завис на мёртвом маунте.
        let p = Process(); p.launchPath = "/bin/bash"
        p.arguments = ["-c", """
        pkill -9 -f 'rclone mount' 2>/dev/null
        for m in "$HOME/Phone-USB" "$HOME/Phone-WiFi"; do
          /sbin/mount | grep -q " $m " || continue
          ( diskutil unmount force "$m" >/dev/null 2>&1 ) & pid=$!
          ( sleep 8; kill -9 $pid 2>/dev/null ) >/dev/null 2>&1 &
          wait $pid 2>/dev/null
          umount -f "$m" >/dev/null 2>&1
          rmdir "$m" 2>/dev/null
        done
        """]
        try? p.run(); p.waitUntilExit()
        stopKeepalive()
        stopWatchdog()
    }

    // FIX #1: background state refresh — all sh() calls happen off the main thread
    func scheduleBackgroundRefresh() {
        let adbPath = adb
        let activeModelPath = NSString(string: "~/.phone_active_model").expandingTildeInPath
        // выбор пользователя на МОМЕНТ старта рефреша (источник истины — файл, не state)
        let startSel = ((try? String(contentsOfFile: activeModelPath, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            var s = PhoneState()
            s.usbMounted  = self.usbMounted()
            s.wifiMounted = self.wifiMounted()
            s.usbAdb      = self.usbAdbOn()
            s.wifiSshRaw  = self.wifiSshOn()
            s.wifiSsh     = s.wifiSshRaw
            // sshOK = доступен ли sshd у активного ЛЮБЫМ путём (Wi-Fi ИЛИ USB-форвард) —
            // правильный примитив для гейтинга mount/upload/download (а не только Wi-Fi).
            s.sshOK       = self.sshOkActive()
            s.wdMdns      = self.wdMdnsOn()
            s.wd5555      = self.wd5555On()
            // model: prefer USB device, fall back to any connected device
            let usbDev = self.sh("\(adbPath) devices | awk '/\\tdevice$/{print $1}' | grep -v _adb-tls | grep -v ':' | head -1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !usbDev.isEmpty {
                s.model = self.sh("\(adbPath) -s \(usbDev) shell getprop ro.product.model")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let anyDev = self.sh("\(adbPath) devices | awk '/\\tdevice$/{print $1}' | head -1")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !anyDev.isEmpty {
                    s.model = self.sh("\(adbPath) -s \(anyDev) shell getprop ro.product.model")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            // Парсим phone-devices.sh → s.devices и s.activeModel
            // (adb-уровень; SSH/Wi-Fi-операции идут на кэшированный IP отдельно)
            let devScript = (Bundle.main.resourcePath ?? "") + "/phone-devices.sh"
            if FileManager.default.fileExists(atPath: devScript) {
                let devOut = self.sh("/bin/bash \"\(devScript)\"")
                var devList: [(serial: String, model: String, kind: String, active: Bool)] = []
                for line in devOut.components(separatedBy: "\n") {
                    let parts = line.components(separatedBy: "\t")
                    guard parts.count >= 4 else { continue }
                    let serial = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let model  = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let kind   = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    let active = parts[3].trimmingCharacters(in: .whitespacesAndNewlines) == "*"
                    guard !serial.isEmpty else { continue }
                    devList.append((serial: serial, model: model, kind: kind, active: active))
                }
                s.devices = devList
                // выбранная модель остаётся «активной» в UI, даже если её сейчас нет в adb
                // (например, доступна только по SSH) — берём выбор из файла как приоритет.
                s.activeModel = devList.first(where: { $0.active })?.model
                    ?? (startSel.isEmpty ? (devList.first?.model ?? s.model) : startSel)
                // Если выбран конкретный девайс — светим ТОЛЬКО его каналы (по модели активного).
                // Если не выбран — оставляем глобальные значения (как раньше).
                if let act = devList.first(where: { $0.active }) {
                    let m = act.model
                    s.usbAdb  = devList.contains { $0.model == m && $0.kind == "USB" }
                    s.wd5555  = devList.contains { $0.model == m && $0.serial.contains(":5555") }
                    s.wdMdns  = devList.contains { $0.model == m && $0.kind == "Wi-Fi" && !$0.serial.contains(":5555") }
                    s.wifiSsh = s.wifiSshRaw && devList.contains { $0.model == m && $0.kind == "Wi-Fi" }
                    s.model   = m
                }
            }

            // FIX #1: autoConnectWD moved here — side-effects belong in background, not in menu drawing
            self.autoConnectWD()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // АНТИ-ГОНКА (исправлено): блокируем ТОЛЬКО если пользователь реально переключил
                // устройство за время рефреша — сравниваем файл выбора на старте и сейчас.
                // Раньше сравнивали с s.activeModel и, когда выбранный телефон отсутствовал в adb,
                // guard отбрасывал КАЖДЫЙ рефреш → меню зависало на старом кэше (фантомный USB).
                let nowSel = ((try? String(contentsOfFile: activeModelPath, encoding: .utf8)) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard startSel == nowSel else { return }
                self.state = s
            }
        }
    }

    // sshOkActive — есть ли у активного устройства живой sshd (Wi-Fi или USB-форвард)
    func sshOkActive() -> Bool {
        sh("source \"\(cfgPath)\" 2>/dev/null; active_ssh_ok").contains("yes")
    }

    // ---- keepalive: ping the phone so macOS doesn't suspend the USB port ----
    func startKeepalive() {
        let script = (Bundle.main.resourcePath ?? "") + "/phone-keepalive.sh"
        guard FileManager.default.fileExists(atPath: script) else { return }
        let p = Process(); p.launchPath = "/bin/bash"
        // -9: keepalive может зависнуть на adb-вызове (D-state) и не реагировать на TERM →
        // тогда при перезапуске трея старые инстансы копились бы. KILL гарантированно снимает их.
        p.arguments = ["-c", "pkill -9 -f phone-keepalive.sh 2>/dev/null; rmdir /tmp/phone-keepalive.lock 2>/dev/null; exec bash \"\(script)\""]
        try? p.run()
    }
    func stopKeepalive() {
        let p = Process(); p.launchPath = "/bin/bash"
        p.arguments = ["-c", "pkill -9 -f phone-keepalive.sh 2>/dev/null"]
        try? p.run(); p.waitUntilExit()
    }
    // ---- proactive watchdog: catches a hanging mount before it wedges the kernel ----
    func startWatchdog() {
        let script = (Bundle.main.resourcePath ?? "") + "/phone-watchdog.sh"
        guard FileManager.default.fileExists(atPath: script) else { return }
        let p = Process(); p.launchPath = "/bin/bash"
        // как и keepalive: снять предыдущий инстанс через -9 (мог зависнуть в D-state на
        // мёртвом маунте и не отпускать lock → при перезапуске трея копились дубли) + очистить
        // lock, затем стартовать один свежий.
        p.arguments = ["-c", "pkill -9 -f phone-watchdog.sh 2>/dev/null; rmdir /tmp/phone-watchdog.lock 2>/dev/null; exec bash \"\(script)\""]
        try? p.run()
    }
    func stopWatchdog() {
        let p = Process(); p.launchPath = "/bin/bash"
        p.arguments = ["-c", "pkill -9 -f phone-watchdog.sh 2>/dev/null; rmdir /tmp/phone-watchdog.lock 2>/dev/null"]
        try? p.run(); p.waitUntilExit()
    }

    // ---- state helpers (called from background thread only) ----
    func sh(_ cmd: String) -> String {
        let t = Process(); t.launchPath = "/bin/bash"; t.arguments = ["-c", cmd]
        let pipe = Pipe(); t.standardOutput = pipe; t.standardError = pipe
        // FIX #6: t.launch() → try? t.run()
        try? t.run(); t.waitUntilExit()
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
        sh("IP=$(source \"\(cfgPath)\" 2>/dev/null; active_ip); [ -n \"$IP\" ] && ping -c1 -t1 \"$IP\" >/dev/null 2>&1 && nc -z -G2 \"$IP\" 8022 >/dev/null 2>&1 && echo y")
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
    // FIX #1: transportLabel reads from cached state.model — no sh() calls
    // section title per channel device: "SM-G975F (USB)" / "SM-G975F (Wi-Fi · SSH)"
    func transportLabel(_ wifi: Bool, _ chan: String) -> String {
        let m = state.model
        if wifi {
            return m.isEmpty ? "\(chan) volume" : "\(m) (\(chan))"
        }
        return m.isEmpty ? "\(chan) volume" : "\(m) (\(chan))"
    }

    // ---- build menu — reads ONLY state.*, no sh() calls ----
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

        // FIX #1: read from cache — zero sh() calls here
        let usbM  = state.usbMounted
        let wifiM = state.wifiMounted
        let usbA  = state.usbAdb
        let wifiA = state.wifiSsh

        // ---- status line: dot = REACHABLE (any channel), not "mounted" ----
        let model = state.model
        let reach = state.usbAdb || state.wifiSsh
        var mounted: [String] = []
        if usbM  { mounted.append("USB") }
        if wifiM { mounted.append("Wi-Fi") }
        let mountedStr = mounted.isEmpty ? "no folders mounted" : "folders: " + mounted.joined(separator: "+")
        var statusTitle = "\(reach ? "●" : "○") \(model.isEmpty ? (reach ? "Connected" : "Phone not found") : model) — \(mountedStr)"
        // Если подключено несколько устройств — показываем активное в статусе
        if state.devices.count > 1 && !state.activeModel.isEmpty {
            statusTitle += " · active: \(state.activeModel)"
        }
        let st = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)

        // ---- подменю выбора устройства (только если устройств > 1) ----
        // Влияет на adb-операции (USB-mount, scrcpy, cache).
        // SSH/Wi-Fi-операции (mount-wifi, stream, upload, download) идут на
        // SSH-сервер по закэшированному IP — это подменю их НЕ затрагивает.
        // дропдаун-список устройств ИНЛАЙН (галочка = активный), дедуп по модели.
        // Всё ниже (каналы и т.д.) привязано к выбранному устройству.
        if !state.devices.isEmpty {
            let hdr = NSMenuItem(title: "Device (click to switch — menu stays open):", action: nil, keyEquivalent: ""); hdr.isEnabled = false
            menu.addItem(hdr)
            deviceRows = []
            var seenModels = Set<String>(); var idx = 0
            for dev in state.devices {
                if seenModels.contains(dev.model) { continue }
                seenModels.insert(dev.model)
                let kinds = Set(state.devices.filter { $0.model == dev.model }.map { $0.kind })
                    .sorted().joined(separator: "+")
                let display = "\(dev.model) — \(kinds)"
                let active = dev.model == state.activeModel
                let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
                let b = NSButton(frame: NSRect(x: 14, y: 0, width: 284, height: 20))
                b.isBordered = false
                b.alignment = .left
                b.tag = idx
                b.target = self
                b.action = #selector(deviceRowClicked(_:))
                styleDeviceButton(b, display, active)
                v.addSubview(b)
                let mi = NSMenuItem(); mi.view = v
                menu.addItem(mi)
                deviceRows.append((model: dev.model, display: display, button: b))
                idx += 1
            }
        }

        menu.addItem(.separator())

        // ---- CONNECTION CENTER: transparent status of the 4 channels ----
        // FIX #1: autoConnectWD() moved to background refresh — removed from here
        let chHdr = NSMenuItem(title: "Channels (click to toggle · hover for help)", action: nil, keyEquivalent: ""); chHdr.isEnabled = false
        menu.addItem(chHdr)
        channelItems = []   // ссылки на пункты каналов для live-обновления при смене устройства
        // 4 channels separately, each a clickable toggle; red = connect failed
        addChannel(menu, "USB (cable) — files + commands", state.usbAdb, "usb", #selector(toggleUSB),
                   "Cable (adb). File push/pull + commands (pm, scrcpy, logcat). Click to reconnect (re-enumerate). If the port is asleep, replug the DATA cable.")
        addChannel(menu, "Wi-Fi SSH (8022) — files, no cable", state.wifiSsh, "ssh", #selector(toggleSSH),
                   "Direct SSH over Wi-Fi (8022). Main channel for files/streaming, ~25 MB/s, multi-stream. Click to check/restart sshd. Not visible in adb apps.")
        addChannel(menu, "Wireless-debug (mDNS) — admin adb", state.wdMdns, "wdmdns", #selector(toggleWDmdns),
                   "adb over Wi-Fi via mDNS (dynamic port). Admin commands: scrcpy, pm, logcat. Click: off → connect, on → disconnect. The WD toggle itself is enabled on the phone.")
        addChannel(menu, "adb TCP 5555 (legacy) — admin adb", state.wd5555, "tcp5555", #selector(toggle5555),
                   "Legacy adb-over-tcp on fixed port 5555 (old method, if adbd listens). Does NOT survive a phone reboot. Click: off → connect 5555, on → disconnect.")
        menu.addItem(item("  ⓘ Which channel for what", #selector(helpChannels), ""))
        menu.addItem(item("  Check all channels", #selector(checkAll), ""))
        menu.addItem(item("  Check SSH", #selector(checkSSH), ""))
        menu.addItem(item("  Restart SSH on phone", #selector(restartSSH), ""))
        menu.addItem(.separator())

        // ---- file browsers ----
        let bFD = item("Open FileDroid", #selector(openBrowser), "b")
        bFD.toolTip = "Browse the phone (adb). Opening a file = adb pull (single-stream); double-click a video = stream in IINA, no download. Best for: browsing, picking files, watching video."
        menu.addItem(bFD)
        let bADB = item("Open ADB Explorer", #selector(openAdbExplorer), "")
        bADB.toolTip = "Same as FileDroid — adb-based browser with EXIF photo previews and click-to-stream. Best for: browsing and previews."
        menu.addItem(bADB)
        // SSH-зависимые передачи: доступны только если у выбранного устройства есть sshd
        let dItem = item("⬇︎ Download from internet to phone" + (state.sshOK ? "" : " — no sshd"), #selector(downloadToPhone), "")
        dItem.isEnabled = state.sshOK
        dItem.toolTip = state.sshOK ? "rclone copyurl over SFTP — pulls a web URL straight onto the phone (/sdcard/Download), bypassing the Mac disk."
                                     : "Unavailable: selected device has no Termux sshd. Install Termux + sshd on it, or pick the server phone."
        menu.addItem(dItem)
        let uItem = item("⬆︎ Upload to phone (fast, multi-stream)" + (state.sshOK ? "" : " — no sshd"), #selector(uploadToPhone), "")
        uItem.isEnabled = state.sshOK
        uItem.toolTip = state.sshOK ? "rclone copy over SFTP, --transfers 8 + multi-thread (MAX speed). Auto channel USB→Wi-Fi. → /sdcard/Download."
                                     : "Unavailable: selected device has no Termux sshd. Install Termux + sshd on it, or pick the server phone."
        menu.addItem(uItem)
        menu.addItem(item("  ⓘ Transfers — which for what", #selector(helpTransfers), ""))
        menu.addItem(.separator())

        // ---- USB volume ----
        mountHeaders = []
        let mdl0 = state.model.isEmpty ? "Phone" : state.model
        let usbHdr = NSMenuItem(title: "\(mdl0) (USB)", action: nil, keyEquivalent: "")
        usbHdr.isEnabled = false
        menu.addItem(usbHdr)
        mountHeaders.append((kind: "USB", item: usbHdr))
        if usbM {
            menu.addItem(item("  Open USB folder", #selector(openUSB), ""))
            menu.addItem(item("  Unmount USB", #selector(unmountUSB), ""))
        } else if usbA && state.sshOK {
            menu.addItem(item("  Mount USB", #selector(mountUSB), ""))
        } else {
            let na = NSMenuItem(title: usbA ? "  (needs Termux sshd on this phone)" : "  (unavailable)", action: nil, keyEquivalent: "")
            na.isEnabled = false
            menu.addItem(na)
        }
        menu.addItem(.separator())

        // ---- Wi-Fi volume ----
        // ⚠ прямо в заголовке тома; подробности — при наведении (без отдельной строки)
        let wifiHdr = NSMenuItem(title: "⚠︎ \(mdl0) (Wi-Fi · SSH)", action: nil, keyEquivalent: "")
        wifiHdr.isEnabled = false
        wifiHdr.toolTip = "Mounted over Wi-Fi via SSH (NOT Wireless-debug). Finder over Wi-Fi is slow and can hang if the link drops (a watchdog force-unmounts). For viewing/streaming use a browser + IINA, not Finder."
        menu.addItem(wifiHdr)
        mountHeaders.append((kind: "WiFi", item: wifiHdr))
        if wifiM {
            menu.addItem(item("  Open Wi-Fi folder", #selector(openWiFi), ""))
            menu.addItem(item("  Unmount Wi-Fi", #selector(unmountWiFi), ""))
        } else if wifiA && state.sshOK {
            menu.addItem(item("  ⚠︎ Mount Wi-Fi (slow, last resort)", #selector(mountWiFi), ""))
        } else {
            let na = NSMenuItem(title: state.sshOK ? "  (unavailable)" : "  (needs Termux sshd on this phone)", action: nil, keyEquivalent: "")
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

        // Kick off a fresh background refresh so next open is up-to-date
        scheduleBackgroundRefresh()
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
    // FIX #3: busyCount counter instead of bool flag; FIX #6: [weak self], try? t.run()
    private func exec(launch: String, args: [String], _ done: @escaping (Int32, String) -> Void) {
        busyCount += 1
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let t = Process()
            t.launchPath = launch
            t.arguments = args
            let tmp = NSTemporaryDirectory() + "phonestream-\(UUID().uuidString).log"
            FileManager.default.createFile(atPath: tmp, contents: nil)
            let fh = FileHandle(forWritingAtPath: tmp)
            t.standardOutput = fh
            t.standardError = fh
            t.standardInput = FileHandle.nullDevice
            // FIX #6: t.launch() → try? t.run()
            try? t.run(); t.waitUntilExit()
            try? fh?.close()
            let out = (try? String(contentsOfFile: tmp, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(atPath: tmp)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.busyCount -= 1
                done(t.terminationStatus, out)
            }
        }
    }

    // ---- USB actions ----
    @objc func mountUSB() {
        run(mountScript, ["usb"]) { [weak self] code, out in
            guard let self = self else { return }
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
        run(mountScript, ["wifi"]) { [weak self] code, out in
            guard let self = self else { return }
            if code == 0 { self.openWiFi() } else { self.alert("Wi-Fi mount failed", out) }
        }
    }
    @objc func unmountWiFi() { run(unmountScript, ["wifi"]) { _, _ in } }
    @objc func openWiFi() { NSWorkspace.shared.open(URL(fileURLWithPath: mntWiFi)) }

    // ---- download from internet straight to phone (bypasses Mac disk) ----
    // FIX #4: URL scheme validation; accessoryView before initialFirstResponder; portable rclone path
    // ---- onboarding: which transfer method for what ----
    @objc func helpTransfers() {
        alert("Transfers — which for what",
"""
PUT FILES ON THE PHONE
• ⬆︎ Upload to phone (fast, multi-stream) — rclone copy over SFTP, --transfers 8 + multi-thread. The FASTEST way. Auto channel: USB → Wi-Fi. Use for: bulk / many / large files. → /sdcard/Download.
• ⬇︎ Download from internet to phone — rclone copyurl over SFTP (single stream). Pulls a web URL straight onto the phone, the Mac disk is never touched. Use for: a download link you want on the phone.

GET / VIEW FILES FROM THE PHONE
• Open FileDroid / ADB Explorer — adb-based browser. Opening a file = adb pull (single-stream). Double-click a video = streamed in IINA, NOT downloaded. Use for: browsing, previews, watching video.
• Mount USB / Wi-Fi folder (Finder) — gives another Mac app a real file path via FUSE. Single-stream, and Wi-Fi mount is slow / can hang. Use ONLY when an app needs a path; not for bulk transfer or browsing big folders.

SPEED CHEAT-SHEET
• Max throughput, many files → Upload button (multi-stream rclone) or, from phone, rclone/Cyberduck.
• USB ~ fastest & most stable; Wi-Fi SSH ~24 MB/s multi-stream; a single huge file over Wi-Fi ~7 MB/s (one stream).
• Watch video → browser → IINA (range stream, instant, no copy). Never double-click a big video in a Finder mount (it downloads the whole file).
""")
    }

    // ---- fast multi-threaded upload to the phone (rclone copy over SFTP) ----
    @objc func uploadToPhone() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Select files/folders to upload to the phone (/sdcard/Download), multi-stream over the fastest channel."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let paths = panel.urls.map { $0.path }
        let script = (Bundle.main.resourcePath ?? "") + "/phone-upload.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            alert("Upload script missing", script); return
        }
        run(script, paths) { [weak self] _, out in
            self?.alert("Upload to phone",
                out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Done." : out)
        }
    }

    @objc func downloadToPhone() {
        let a = NSAlert()
        a.messageText = "Download from internet to phone"
        a.informativeText = "Paste a URL — the file goes straight to the phone (/sdcard/Download), bypassing the Mac disk. Auto-picks the best channel (USB → Wi-Fi SSH)."
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        tf.placeholderString = "https://…"
        // FIX #4: set accessoryView first, then initialFirstResponder
        a.accessoryView = tf
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let url = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        // FIX #4: only allow http/https — block file:// and other schemes
        guard url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") else {
            alert("Only http/https URLs", "For security, only http:// and https:// URLs are supported.")
            return
        }
        // авто-канал (USB→Wi-Fi) через phone-download.sh — единый «мозг» транспорта
        let script = (Bundle.main.resourcePath ?? "") + "/phone-download.sh"
        guard FileManager.default.fileExists(atPath: script) else { alert("Download script missing", script); return }
        run(script, [url]) { [weak self] _, out in
            self?.alert("Download to phone", out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Done." : out)
        }
    }

    // ---- general ----
    @objc func mountAll() {
        run(mountAllScript) { [weak self] code, out in
            guard let self = self else { return }
            if code == 0 {
                // FIX #1: use cached state for post-mount check
                if self.state.usbMounted  { self.openUSB() }
                if self.state.wifiMounted { self.openWiFi() }
            } else { self.alert("Mount all failed", out) }
        }
    }
    @objc func reconnect() {
        // "Connect everything": run through every init method for each channel + report.
        run(rediscoverScript) { [weak self] _, out in
            guard let self = self else { return }
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
        // 1. Активная МОДЕЛЬ из ~/.phone_active_model → серийник из кэша state.devices
        //    (предпочитаем USB-вход этой модели). adb-уровень; SSH/Wi-Fi — отдельно.
        let activePath = NSString(string: "~/.phone_active_model").expandingTildeInPath
        if let saved = try? String(contentsOfFile: activePath, encoding: .utf8) {
            let m = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !m.isEmpty {
                if let d = state.devices.first(where: { $0.model == m && $0.kind == "USB" })
                        ?? state.devices.first(where: { $0.model == m }) {
                    return d.serial
                }
            }
        }
        // 2. Fallback: первый USB-девайс
        let usb = sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | grep -v _adb-tls | grep -v ':' | head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !usb.isEmpty { return usb }
        // 3. Fallback: любой Wi-Fi adb
        let wifi = sh("\(adb) devices | awk '/\\tdevice$/{print $1}' | grep -E '_adb-tls|:' | head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return wifi.isEmpty ? nil : wifi
    }
    // ---- выбор активного устройства (adb-уровень) ----
    // Записывает серийник в ~/.phone_active_serial, затем обновляет состояние.
    // SSH/Wi-Fi-операции (mount-wifi, stream, upload, download) НЕ затрагиваются —
    // они идут на SSH-сервер по закэшированному IP независимо от этого выбора.
    @objc func deviceRowClicked(_ sender: NSButton) {
        let i = sender.tag
        guard i >= 0 && i < deviceRows.count else { return }
        let model = deviceRows[i].model
        let devs = state.devices
        // СНАЧАЛА сохраняем выбор СИНХРОННО — чтобы active_ip ниже резолвил уже НОВОЕ устройство
        let activeModelPath = NSString(string: "~/.phone_active_model").expandingTildeInPath
        try? model.write(toFile: activeModelPath, atomically: true, encoding: .utf8)
        state.activeModel = model
        state.model = model
        state.usbAdb  = devs.contains { $0.model == model && $0.kind == "USB" }
        state.wd5555  = devs.contains { $0.model == model && $0.serial.contains(":5555") }
        state.wdMdns  = devs.contains { $0.model == model && $0.kind == "Wi-Fi" && !$0.serial.contains(":5555") }
        // SSH/sshOK НЕЛЬЗЯ доверять старым значениям (они от прошлого устройства) → всё серое,
        // пока асинхронная проверка реального устройства не подтвердит. БЕЗ этого меню на один
        // цикл показало бы Upload/Download/Mount доступными для устройства без sshd.
        state.wifiSshRaw = false
        state.wifiSsh = false
        state.sshOK = false
        // перестроить меню под выбранное устройство вживую (меню остаётся открытым)
        if let m = statusItem.menu { menuNeedsUpdate(m) }
        // АСИНХРОННО: реальная доступность SSH именно НОВОГО устройства
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let wifiok = self.wifiSshOn()      // для индикатора канала «Wi-Fi SSH»
            let sshok  = self.sshOkActive()    // для гейтинга mount/upload/download (Wi-Fi ИЛИ USB)
            DispatchQueue.main.async {
                guard self.state.activeModel == model else { return }   // не перетереть, если уже переключили дальше
                self.state.wifiSshRaw = wifiok
                self.state.sshOK = sshok
                self.state.wifiSsh = wifiok && self.state.devices.contains { $0.model == model && $0.kind == "Wi-Fi" }
                self.refreshChannelItems()
                // SSH-зависимые пункты могли поменять доступность → перерисовать меню
                if let m = self.statusItem.menu { self.menuNeedsUpdate(m) }
            }
        }
        scheduleBackgroundRefresh()
    }

    // FIX #2: serial passed as positional $1 to avoid shell injection
    @objc func mirror() {
        guard let scr = scrcpyPath() else {
            let a = NSAlert(); a.messageText = "scrcpy not installed"
            a.informativeText = "Screen mirroring uses scrcpy. Install it via Homebrew?"
            a.addButton(withTitle: "Install (brew)"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn {
                runCmd("export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; brew install scrcpy") { [weak self] code, out in
                    guard let self = self else { return }
                    self.alert(code == 0 ? "scrcpy installed" : "Install failed",
                               code == 0 ? "Done — click \"Screen mirror\" again." : out)
                }
            }
            return
        }
        guard let serial = pickDeviceSerial() else {
            alert("Phone not connected", "Connect your phone first (USB or Wi-Fi)."); return
        }
        // FIX #2: use $1 for serial, $2 for scrcpy path — no shell interpolation of untrusted values
        let t = Process(); t.launchPath = "/bin/bash"
        t.arguments = ["-c", "ADB=\"$1\" \"$2\" -s \"$3\" >/dev/null 2>&1 &", "phonestream", adb, scr, serial]
        try? t.run()
    }

    // ---- clear cache ----
    // FIX #2: serial passed as positional $1 to avoid shell injection
    @objc func clearCache() {
        let a = NSAlert(); a.messageText = "Clear all app caches on the phone?"
        a.informativeText = "Frees space by clearing every app's cache. Caches rebuild automatically when you use the apps. Your files and data are NOT touched."
        a.addButton(withTitle: "Clear cache"); a.addButton(withTitle: "Cancel")
        if a.runModal() != .alertFirstButtonReturn { return }
        guard let serial = pickDeviceSerial() else {
            alert("Phone not connected", "Connect your phone first (USB or Wi-Fi)."); return
        }
        // FIX #2: serial as $1, adb path interpolated (trusted constant)
        runCmd("\(adb) -s \"$1\" shell pm trim-caches 9999999999999", [serial]) { [weak self] code, out in
            guard let self = self else { return }
            self.alert(code == 0 ? "Cache cleared" : "Failed",
                       code == 0 ? "App caches cleared on the phone." : out)
        }
    }

    // ---- open our Python browser ADBFileExplorer ----
    // FIX #2: path passed as $1 — no shell interpolation of path
    @objc func openAdbExplorer() {
        let runsh = NSHomeDirectory() + "/PhoneAsExtStorage/ADBFileExplorer/run.sh"
        if FileManager.default.fileExists(atPath: runsh) {
            let t = Process(); t.launchPath = "/bin/bash"
            // FIX #2: pass runsh as positional $1
            t.arguments = ["-lc", "cd \"$(dirname \"$1\")\" && nohup bash run.sh >/tmp/adbfe.log 2>&1 &", "phonestream", runsh]
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
    // FIX #3: uses busyCount; FIX #6: [weak self]
    func sshReport(_ title: String, _ cmd: String) {
        busyCount += 1
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let out = self.sh(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.busyCount -= 1
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
        channelItems.append((key: key, text: text, item: it))
    }

    // стиль кнопки устройства: активный — белый+жирный с ✓, остальные — приглушённые
    func styleDeviceButton(_ b: NSButton, _ display: String, _ active: Bool) {
        let color: NSColor = active ? .labelColor : .secondaryLabelColor
        let font = active ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                          : NSFont.menuFont(ofSize: 0)
        let title = (active ? "✓ " : "     ") + display
        b.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color, .font: font])
    }

    func channelWorking(_ key: String) -> Bool {
        switch key {
        case "usb":     return state.usbAdb
        case "ssh":     return state.wifiSsh
        case "wdmdns":  return state.wdMdns
        case "tcp5555": return state.wd5555
        default:        return false
        }
    }
    // перерисовать точки каналов в УЖЕ ОТКРЫТОМ меню (после смены устройства)
    func refreshChannelItems() {
        for c in channelItems {
            let working = channelWorking(c.key)
            let dot = working ? "🟢" : (failed.contains(c.key) ? "🔴" : "⚪️")
            let title = "  \(dot) \(c.text)"
            if !working && failed.contains(c.key) {
                c.item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
            } else {
                c.item.attributedTitle = nil
                c.item.title = title
            }
        }
    }

    // ---- channel toggles: touch ONLY their own channel, never the working ones ----
    @objc func toggleUSB() {
        if state.usbAdb { return }   // working — leave it
        runCmd("\(adb) reconnect offline >/dev/null 2>&1; sleep 1; \(adb) devices -l | grep -q usb: && echo OK") { [weak self] _, out in
            guard let self = self else { return }
            if out.contains("OK") { self.failed.remove("usb") }
            else { self.failed.insert("usb"); self.alert("USB didn't come up", "The port seems suspended. Replug the DATA cable (not charge-only) or try another port — software can't wake it.") }
        }
    }
    @objc func toggleSSH() {
        if state.wifiSsh { alert("Wi-Fi SSH", "Working (port 8022). This is the phone's server channel — no need to turn it off here."); return }
        runCmd("IP=$(source \"\(cfgPath)\" 2>/dev/null; active_ip); KEY=$HOME/.ssh/id_ed25519_phone; ssh -i \"$KEY\" -p 8022 -o StrictHostKeyChecking=no -o ConnectTimeout=6 u0_a520@\"$IP\" 'pgrep -x sshd >/dev/null || sshd' 2>/dev/null; sleep 1; nc -z -G2 \"$IP\" 8022 && echo OK") { [weak self] _, out in
            guard let self = self else { return }
            if out.contains("OK") { self.failed.remove("ssh") }
            else { self.failed.insert("ssh"); self.alert("SSH not responding", "Phone unreachable over SSH. Launch the \"Start-SSHD\" widget on the phone, or wait — the watchdog will bring it up.") }
        }
    }
    @objc func toggleWDmdns() {
        if state.wdMdns {  // off: disconnect the mDNS entry/entries, without touching 5555/USB
            runCmd("for d in $(\(adb) devices | awk '/device$/{print $1}' | grep -E '_adb-tls|:[0-9]+' | grep -v ':5555'); do \(adb) disconnect \"$d\" >/dev/null 2>&1; done; echo done") { _, _ in }
        } else {        // on: warm up mDNS (no kill-server, to avoid dropping others) + connect
            runCmd("\(adb) mdns services >/dev/null 2>&1; sleep 1; EP=$(\(adb) mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}'); [ -n \"$EP\" ] && \(adb) connect \"$EP\" >/dev/null 2>&1; sleep 1; \(adb) devices | awk '/device$/{print $1}' | grep -E '_adb-tls|:[0-9]+' | grep -v ':5555' | grep -q . && echo OK") { [weak self] _, out in
                guard let self = self else { return }
                if out.contains("OK") { self.failed.remove("wdmdns") }
                else { self.failed.insert("wdmdns"); self.alert("Wireless-debug didn't connect", "Enable the Wireless Debugging toggle on the phone (Settings → Developer options). It can't be enabled remotely. If it's on but not seen, click \"Connect everything\" (restarts the adb server).") }
            }
        }
    }
    @objc func toggle5555() {
        if state.wd5555 {
            runCmd("IP=$(source \"\(cfgPath)\" 2>/dev/null; active_ip); \(adb) disconnect \"$IP:5555\" >/dev/null 2>&1; echo done") { _, _ in }
        } else {
            runCmd("IP=$(source \"\(cfgPath)\" 2>/dev/null; active_ip); nc -z -G1 \"$IP\" 5555 && \(adb) connect \"$IP:5555\" >/dev/null 2>&1; sleep 1; \(adb) devices | grep ':5555' | grep -wq device && echo OK") { [weak self] _, out in
                guard let self = self else { return }
                if out.contains("OK") { self.failed.remove("tcp5555") }
                else { self.failed.insert("tcp5555"); self.alert("5555 unavailable", "adbd isn't listening on 5555 (it disappears after a phone reboot). Bring the phone up via USB or Wireless-debug first.") }
            }
        }
    }
    // FIX #5: IP from ~/.phone_wifi_ip (no hardcode 192.168.1.202 in checkAll)
    @objc func checkAll() {
        sshReport("All channels status", """
ADB=\(adb); IP=$(source \"\(cfgPath)\" 2>/dev/null; active_ip)
if [ -z "$IP" ]; then echo "Phone IP unknown — connect once over USB to cache it."; IP="(unknown)"; fi
echo "CHANNELS (can be used in parallel):"
U=$("$ADB" devices -l 2>/dev/null | grep 'usb:' | awk '{print $1}')
[ -n "$U" ] && echo "  🟢 USB (cable, adb) — $U  [files push/pull, commands]" || echo "  ⚪️ USB (cable) — none (cable/port)"
WC=$("$ADB" devices 2>/dev/null | grep -E ':[0-9]+|_adb-tls' | grep -c device)
[ "$WC" -gt 0 ] && echo "  🟢 Wi-Fi adb / Wireless-debug — $WC entr(y/ies)  [admin: scrcpy, pm, logcat]" || echo "  ⚪️ Wi-Fi adb / Wireless-debug — none"
if [ "$IP" != "(unknown)" ] && nc -z -G2 "$IP" 8022 >/dev/null 2>&1; then echo "  🟢 Wi-Fi SSH (8022) — $IP  [files/streaming, no cable; NOT shown in adb apps]"; else echo "  ⚪️ Wi-Fi SSH (8022) — none"; fi
echo ""
echo "FOLDERS in Finder (mount):"
/sbin/mount | grep -q Phone-USB  && echo "  🟢 USB folder ~/Phone-USB"   || echo "  ⚪️ USB folder not mounted"
/sbin/mount | grep -q Phone-WiFi && echo "  🟢 Wi-Fi folder ~/Phone-WiFi (over SSH)" || echo "  ⚪️ Wi-Fi folder not mounted"
""")
    }
    @objc func checkSSH() {
        sshReport("Check SSH channel", """
IP=$(source \"\(cfgPath)\" 2>/dev/null; active_ip); KEY=$HOME/.ssh/id_ed25519_phone
echo "Phone IP: ${IP:-unknown (connect once over USB)}"
[ -n "$IP" ] && { ping -c1 -t2 "$IP" >/dev/null 2>&1 && echo "ping: OK" || echo "ping: FAIL (phone not on the network)"; }
[ -n "$IP" ] && { nc -z -G2 "$IP" 8022 >/dev/null 2>&1 && echo "sshd:8022: open" || echo "sshd:8022: closed"; }
[ -n "$IP" ] && ssh -i "$KEY" -p 8022 -o StrictHostKeyChecking=no -o ConnectTimeout=5 u0_a520@"$IP" "echo 'SSH login: OK'; echo -n 'model: '; getprop ro.product.model" 2>/dev/null
""")
    }
    @objc func restartSSH() {
        sshReport("Restart SSH on phone", """
IP=$(source \"\(cfgPath)\" 2>/dev/null; active_ip); KEY=$HOME/.ssh/id_ed25519_phone
[ -z "$IP" ] && { echo "Phone IP unknown. Connect once over USB to cache it."; exit 0; }
ssh -i "$KEY" -p 8022 -o StrictHostKeyChecking=no -o ConnectTimeout=6 u0_a520@"$IP" 'pgrep -x sshd >/dev/null || sshd; nohup sh ~/sshd-watchdog.sh >/dev/null 2>&1 & sleep 1; echo "sshd pid: $(pgrep -x sshd | tr "\\n" " ")"; echo "watchdog: started"' 2>/dev/null
""")
    }

    @objc func quit() { stopKeepalive(); stopWatchdog(); NSApp.terminate(nil) }
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
