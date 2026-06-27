import Cocoa

// Меню-бар приложение: телефон как диск (no-copy rclone-mount).
// Пункты: статус, Подключить/Отключить, Открыть папку, Выход.
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let upScript   = "/Users/v/PhoneAsExtStorage/adbfs-rootless/phone-stream-up.sh"
    let downScript = "/Users/v/PhoneAsExtStorage/adbfs-rootless/phone-stream-down.sh"
    let mountPoint = NSString(string: "~/PhoneStream").expandingTildeInPath
    var busy = false

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let path = Bundle.main.resourcePath,
           let img = NSImage(contentsOfFile: path + "/menubar.png") {
            img.isTemplate = false   // цветная иконка как есть (не силуэт)
            img.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "📱"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func isMounted() -> Bool {
        let t = Process()
        t.launchPath = "/bin/bash"
        t.arguments = ["-c", "/sbin/mount | grep -q PhoneStream"]
        t.launch(); t.waitUntilExit()
        return t.terminationStatus == 0
    }

    // обновляем меню каждый раз при открытии
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if busy {
            let b = NSMenuItem(title: "⏳ Работаю…", action: nil, keyEquivalent: ""); b.isEnabled = false
            menu.addItem(b)
            menu.addItem(.separator())
            menu.addItem(item("Выход", #selector(quit), "q"))
            return
        }
        let mounted = isMounted()
        let st = NSMenuItem(title: mounted ? "● Подключён  (~/PhoneStream)" : "○ Не подключён", action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        menu.addItem(.separator())
        if mounted {
            menu.addItem(item("Открыть папку", #selector(openFolder), "o"))
            menu.addItem(item("Отключить", #selector(unmount), "u"))
        } else {
            menu.addItem(item("Подключить", #selector(mount), "m"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Выход", #selector(quit), "q"))
    }

    func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    func run(_ script: String, _ done: @escaping (Int32, String) -> Void) {
        busy = true
        DispatchQueue.global().async {
            let t = Process()
            t.launchPath = "/bin/bash"
            t.arguments = [script]
            let pipe = Pipe()
            t.standardOutput = pipe; t.standardError = pipe
            t.launch(); t.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self.busy = false; done(t.terminationStatus, out) }
        }
    }

    @objc func mount() {
        run(upScript) { code, out in
            if code == 0 { self.openFolder() }
            else { self.alert("Не удалось подключить телефон", out) }
        }
    }
    @objc func unmount() { run(downScript) { _, _ in } }
    @objc func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint)) }
    @objc func quit() { NSApp.terminate(nil) }

    func alert(_ title: String, _ msg: String) {
        let a = NSAlert(); a.messageText = title
        a.informativeText = msg.isEmpty ? "Проверь, что телефон подключён и sshd запущен в Termux." : msg
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // только в меню-баре, без иконки в доке
app.run()
