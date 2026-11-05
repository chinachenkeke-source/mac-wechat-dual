import Cocoa

// ============================================================
//  微信分身管理 · 开发者：ckk
//  新建分身（1~4个）/ 重建分身（保留或清理缓存）
//  采用手写坐标布局（稳定显示），内容区分模式切换
// ============================================================

let ORIG_PATH = "/Applications/WeChat.app"

// ---- shell 执行：返回 (退出码, 输出) ----
func shell(_ script: String) -> (Int32, String) {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", script]
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "启动失败: \(error)") }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func instanceScript(n: Int, clearCache: Bool) -> String {
    let D = "/Applications/WeChat\(n).app"
    let ID = "com.tencent.xinWeChat\(n)"
    var s = """
    ORIG="\(ORIG_PATH)"; D="\(D)"; ID="\(ID)"
    if [ ! -d "$ORIG" ]; then echo "[错误] 未找到原版微信 \(ORIG_PATH)，请先安装微信"; exit 1; fi
    if pgrep -f "WeChat\(n).app/Contents/MacOS/WeChat" >/dev/null 2>&1; then echo "[错误] WeChat\(n) 正在运行，请先完全退出它"; exit 1; fi
    chflags -R nouchg "$D" 2>/dev/null
    if [ -d "$D" ]; then rm -rf "$D"; fi
    ditto "$ORIG" "$D" || { echo "[错误] 复制失败"; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$D/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :SUAutomaticallyUpdate false" "$D/Contents/Info.plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$D/Contents/Info.plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Set :SUAllowsAutomaticUpdates false" "$D/Contents/Info.plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Set :SUEnableInstallerLauncherService false" "$D/Contents/Info.plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool false" "$D/Contents/Info.plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$D/Contents/Info.plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Add :SUAllowsAutomaticUpdates bool false" "$D/Contents/Info.plist" 2>/dev/null
    find "$D" -type f ! -perm -u+w -exec chmod u+w {} \\; 2>/dev/null
    xattr -cr "$D" 2>/dev/null
    codesign --force --deep --sign - "$D" 2>/dev/null
    defaults write "$ID" SUAutomaticallyUpdate -bool NO
    defaults write "$ID" SUEnableAutomaticChecks -bool NO
    defaults write "$ID" SUAllowsAutomaticUpdates -bool NO
    V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$D/Contents/Info.plist" 2>/dev/null)
    if [ "$V" != "$ID" ]; then echo "[错误] Bundle ID 校验失败: $V"; exit 1; fi
    if ! codesign -v "$D" 2>/dev/null; then echo "[错误] 签名校验失败"; exit 1; fi
    chflags -R uchg "$D" 2>/dev/null; echo "[保护] 已锁定该分身，防止被微信更新覆盖"
    """
    if clearCache {
        s += """

        if [ -d "$HOME/Library/Containers/\(ID)" ]; then rm -rf "$HOME/Library/Containers/\(ID)"; echo "[缓存] 已清理该分身的缓存与登录数据"; else echo "[缓存] 未发现该分身容器数据"; fi
        """
    }
    s += "\necho \"[完成] WeChat\(n) 就绪 (BundleID: $ID)\""
    return s
}

final class ManagerApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var modeControl: NSSegmentedControl!
    var contentBox: NSView!
    var newModeView: NSView!
    var rebuildModeView: NSView!
    var countPopup: NSPopUpButton!
    var cachePopup: NSPopUpButton!
    var rebuildChecks: [NSButton] = []
    var runButton: NSButton!
    var logView: NSTextView!
    var statusLabel: NSTextField!
    var busy = false

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 微信分身管理", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 微信分身管理", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, frame: NSRect) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.frame = frame
        return l
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "微信分身管理"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 700))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = root

        // ---- 标题区 ----
        root.addSubview(makeLabel("微信分身管理", size: 22, weight: .bold, color: .labelColor, frame: NSRect(x: 24, y: 700-56, width: 300, height: 30)))
        root.addSubview(makeLabel("基于官方微信创建独立分身 · 一键新建 / 重建", size: 12, weight: .regular, color: .secondaryLabelColor, frame: NSRect(x: 24, y: 700-80, width: 420, height: 20)))

        // ---- 模式切换 ----
        modeControl = NSSegmentedControl(labels: ["新建分身", "重建分身"], trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        modeControl.selectedSegment = 0
        modeControl.frame = NSRect(x: 24, y: 700-118, width: 300, height: 30)
        root.addSubview(modeControl)

        // ---- 内容区 ----
        contentBox = NSView(frame: NSRect(x: 24, y: 700-330, width: 422, height: 200))
        contentBox.wantsLayer = true
        contentBox.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        contentBox.layer?.cornerRadius = 10
        contentBox.layer?.borderColor = NSColor.separatorColor.cgColor
        contentBox.layer?.borderWidth = 1
        root.addSubview(contentBox)

        buildNewMode()
        buildRebuildMode()
        contentBox.addSubview(newModeView)
        contentBox.addSubview(rebuildModeView)
        showMode(0)

        // ---- 运行按钮 ----
        runButton = NSButton(title: "开 始 执 行", target: self, action: #selector(runPressed))
        runButton.bezelStyle = .rounded
        runButton.controlSize = .large
        runButton.isBordered = true
        runButton.wantsLayer = true
        runButton.layer?.cornerRadius = 10
        runButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        runButton.contentTintColor = .white
        runButton.font = .systemFont(ofSize: 15, weight: .semibold)
        runButton.frame = NSRect(x: 24, y: 700-386, width: 422, height: 44)
        root.addSubview(runButton)

        // ---- 状态 ----
        statusLabel = makeLabel("就绪", size: 13, weight: .medium, color: .secondaryLabelColor, frame: NSRect(x: 24, y: 286, width: 420, height: 20))
        root.addSubview(statusLabel)

        // ---- 日志 ----
        root.addSubview(makeLabel("运行日志", size: 13, weight: .semibold, color: .secondaryLabelColor, frame: NSRect(x: 24, y: 258, width: 200, height: 18)))

        let scroll = NSScrollView(frame: NSRect(x: 24, y: 56, width: 422, height: 194))
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.layer?.borderWidth = 1
        logView = NSTextView(frame: NSRect(x: 0, y: 0, width: 422, height: 206))
        logView.isEditable = false
        logView.isRichText = false
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.textColor = .labelColor
        logView.backgroundColor = .textBackgroundColor
        logView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        root.addSubview(scroll)

        // ---- 开发者 ----
        let footer = makeLabel("开发者：ckk", size: 12, weight: .medium, color: .tertiaryLabelColor, frame: NSRect(x: 24, y: 22, width: 422, height: 18))
        footer.alignment = .center
        root.addSubview(footer)
    }

    // 新建模式
    func buildNewMode() {
        newModeView = NSView(frame: NSRect(x: 12, y: 8, width: 398, height: 184))
        newModeView.addSubview(makeLabel("要创建几个分身？", size: 14, weight: .semibold, color: .labelColor, frame: NSRect(x: 0, y: 184-24, width: 380, height: 22)))

        countPopup = NSPopUpButton(frame: NSRect(x: 0, y: 118, width: 310, height: 26), pullsDown: false)
        countPopup.addItems(withTitles: ["1 个  →  生成 WeChat2", "2 个  →  生成 WeChat2 / WeChat3", "3 个  →  生成 WeChat2 ~ WeChat4", "4 个  →  生成 WeChat2 ~ WeChat5"])
        countPopup.selectItem(at: 0)
        newModeView.addSubview(countPopup)

        newModeView.addSubview(makeLabel("基于 /Applications/WeChat.app 创建，各分身独立登录、互不影响。", size: 11, weight: .regular, color: .secondaryLabelColor, frame: NSRect(x: 0, y: 80, width: 396, height: 18)))
        newModeView.addSubview(makeLabel("已有同名分身会被删除重建；系统请求权限时点“允许”。", size: 11, weight: .regular, color: .tertiaryLabelColor, frame: NSRect(x: 0, y: 56, width: 396, height: 18)))
    }

    // 重建模式
    func buildRebuildMode() {
        rebuildModeView = NSView(frame: NSRect(x: 12, y: 8, width: 398, height: 184))
        rebuildModeView.addSubview(makeLabel("选择要重建的分身", size: 14, weight: .semibold, color: .labelColor, frame: NSRect(x: 0, y: 184-24, width: 380, height: 22)))

        rebuildChecks.removeAll()
        var y: CGFloat = 138
        for i in 0..<4 {
            let n = i + 2
            let b = NSButton(checkboxWithTitle: "WeChat\(n)  ·  com.tencent.xinWeChat\(n)", target: nil, action: nil)
            b.frame = NSRect(x: 0, y: y, width: 360, height: 20)
            b.tag = n
            rebuildChecks.append(b)
            rebuildModeView.addSubview(b)
            y -= 28
        }

        rebuildModeView.addSubview(makeLabel("缓存处理", size: 13, weight: .semibold, color: .labelColor, frame: NSRect(x: 0, y: 22, width: 90, height: 24)))
        cachePopup = NSPopUpButton(frame: NSRect(x: 100, y: 22, width: 296, height: 26), pullsDown: false)
        cachePopup.addItems(withTitles: ["保留缓存（保留登录状态与聊天数据，推荐）", "清理缓存（需重新登录，清空该分身数据）"])
        cachePopup.selectItem(at: 0)
        rebuildModeView.addSubview(cachePopup)
    }

    @objc func modeChanged() { showMode(modeControl.selectedSegment) }

    func showMode(_ idx: Int) {
        newModeView.isHidden = (idx != 0)
        rebuildModeView.isHidden = (idx != 1)
    }

    @objc func runPressed() {
        guard !busy else { return }
        let mode = modeControl.selectedSegment
        var tasks: [(String, String)] = []

        if mode == 0 {
            let c = countPopup.indexOfSelectedItem + 1
            for n in 2...(c + 1) { tasks.append(("创建 WeChat\(n)", instanceScript(n: n, clearCache: false))) }
        } else {
            let clear = cachePopup.indexOfSelectedItem == 1
            if clear {
                let a = NSAlert()
                a.messageText = "确认清理缓存？"
                a.informativeText = "清理缓存会删除所选分身的登录状态和聊天记录，需重新登录。确定继续？"
                a.addButton(withTitle: "继续清理")
                a.addButton(withTitle: "取消")
                a.alertStyle = .warning
                if a.runModal() != .alertFirstButtonReturn { return }
            }
            for b in rebuildChecks where b.state == .on {
                let n = b.tag
                tasks.append(("重建 WeChat\(n)（\(clear ? "清理缓存" : "保留缓存")）", instanceScript(n: n, clearCache: clear)))
            }
            if tasks.isEmpty {
                let a = NSAlert(); a.messageText = "未选择分身"; a.informativeText = "请至少勾选一个要重建的分身。"; a.alertStyle = .warning; a.runModal(); return
            }
        }

        busy = true
        runButton.isEnabled = false
        logClear()
        status("执行中…")
        log("[开始] 共 \(tasks.count) 个任务")

        let q = DispatchQueue(label: "work", qos: .userInitiated)
        q.async {
            var ok = true
            for (title, script) in tasks {
                DispatchQueue.main.async { self.log("▶ \(title)") }
                let (code, out) = shell(script)
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { DispatchQueue.main.async { self.log(trimmed) } }
                if code != 0 {
                    ok = false
                    DispatchQueue.main.async { self.log("✖ \(title)：失败（退出码 \(code)）") }
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.runButton.isEnabled = true
                if ok {
                    self.status("全部完成 ✅")
                    self.log("[完成] 全部任务成功")
                    let a = NSAlert(); a.messageText = "全部完成 ✅"; a.informativeText = "分身已就绪，请到 访达 > 应用程序 打开对应的 WeChat 登录。"; a.alertStyle = .informational; a.runModal()
                } else {
                    self.status("有步骤失败，详见日志")
                    let a = NSAlert(); a.messageText = "部分失败"; a.informativeText = "有步骤未成功，请查看运行日志。"; a.alertStyle = .warning; a.runModal()
                }
            }
        }
    }

    func log(_ line: String) {
        logView.textStorage?.append(NSAttributedString(string: line + "\n", attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
        logView.scrollToEndOfDocument(nil)
    }
    func logClear() { logView.string = "" }
    func status(_ s: String) { statusLabel.stringValue = s }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = ManagerApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
