// Stillpaper: shows a web page as the desktop background, built to stay cheap.
// A page's cost as a wallpaper is mostly its continuous animations, so this freezes them by
// default, can drop the live page for a periodic still (snapshot mode), and tears the page down
// while nobody can see it. Build and usage: README.md.

import AppKit
import WebKit

let bundleID = "com.ivdezine.stillpaper"
// Shown before the page draws, and as the whole wallpaper until a page is chosen.
let screenColor = NSColor(white: 0.07, alpha: 1)

// Same rule the page applies under prefers-reduced-motion, widened to every element. CSS does not
// reach SVG <animate>/<animateMotion>, so every SVG is paused too, including ones drawn later.
let freezeScript = """
(function () {
  var s = document.createElement('style');
  s.id = 'stillpaper-freeze';
  s.textContent = '*,*::before,*::after{animation:none!important;transition:none!important}';
  (document.head || document.documentElement).appendChild(s);
  function pause() {
    document.querySelectorAll('svg').forEach(function (svg) {
      if (svg.pauseAnimations && !svg.animationsPaused()) svg.pauseAnimations();
    });
  }
  pause();
  new MutationObserver(pause).observe(document.documentElement, { childList: true, subtree: true });
})();
"""

enum Mode: String { case live, snapshot }

// Settings live in UserDefaults; any key can be overridden for one run with `-key value` on the
// command line (for example `-url http://localhost:8080/`). There is no default page: until one is
// chosen the wallpaper is plain and the menu asks for an address.
enum Settings {
  static let d = UserDefaults.standard
  static var url: String? {
    get { d.string(forKey: "url").flatMap { $0.isEmpty ? nil : $0 } }
    set { d.set(newValue, forKey: "url") }
  }
  static var pageURL: URL? {
    guard let s = url, let u = URL(string: s), u.scheme?.hasPrefix("http") == true else { return nil }
    return u
  }
  static var mode: Mode {
    get { Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .live }
    set { d.set(newValue.rawValue, forKey: "mode") }
  }
  static var motion: Bool {
    get { d.bool(forKey: "motion") }
    set { d.set(newValue, forKey: "motion") }
  }
  static var allDisplays: Bool {
    get { d.bool(forKey: "allDisplays") }
    set { d.set(newValue, forKey: "allDisplays") }
  }
  static var snapshotMinutes: Int {
    get { let v = d.integer(forKey: "snapshotMinutes"); return v > 0 ? v : 5 }
    set { d.set(newValue, forKey: "snapshotMinutes") }
  }
}

final class WallpaperWindow: NSWindow {
  init(screen: NSScreen) {
    super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    setFrame(screen.frame, display: false)
    level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    ignoresMouseEvents = true
    isOpaque = true
    hasShadow = false
    backgroundColor = screenColor
    isReleasedWhenClosed = false
  }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// One wallpaper window on one screen. `still` holds the last captured frame; in live mode the page
// sits on top of it once loaded, in snapshot mode the page renders behind it and is then torn down.
// `hint` is the only thing drawn while no page is set.
final class Display: NSObject, WKNavigationDelegate {
  let window: WallpaperWindow
  let still = NSImageView()
  let hint = NSTextField(labelWithString: "No page yet. Choose Page address… from the Stillpaper menu bar icon.")
  var web: WKWebView?
  var timer: Timer?
  var settle: DispatchWorkItem?
  var running = false
  var needsSignIn = false
  var lastSnapshot: Date?

  init(screen: NSScreen) {
    window = WallpaperWindow(screen: screen)
    super.init()
    let content = window.contentView!
    still.frame = content.bounds
    still.autoresizingMask = [.width, .height]
    still.imageScaling = .scaleProportionallyUpOrDown
    content.addSubview(still)
    hint.font = .systemFont(ofSize: 15)
    hint.textColor = NSColor(white: 1, alpha: 0.55)
    hint.alignment = .center
    hint.sizeToFit()
    let b = content.bounds
    hint.frame.origin = NSPoint(x: (b.width - hint.frame.width) / 2, y: (b.height - hint.frame.height) / 2)
    hint.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
    hint.isHidden = Settings.pageURL != nil
    content.addSubview(hint)
    window.orderFront(nil)
  }

  func resume() {
    guard !running, Settings.pageURL != nil else { return }
    running = true
    switch Settings.mode {
    case .live:
      load()
      // A long-lived page slowly gathers memory; a reload every six hours starts it fresh.
      timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.web?.reload() }
    case .snapshot:
      load()
      timer = Timer.scheduledTimer(withTimeInterval: Double(Settings.snapshotMinutes * 60), repeats: true) { [weak self] _ in self?.load() }
    }
  }

  // Keep the last frame on screen, then drop the page so it costs nothing while hidden.
  func suspend() {
    guard running else { return }
    running = false
    timer?.invalidate(); timer = nil
    guard let w = web else { return }
    w.takeSnapshot(with: nil) { [weak self] img, _ in
      guard let self = self else { return }
      if let img = img { self.still.image = img }
      self.still.isHidden = false
      if !self.running { self.teardown() }
    }
  }

  func close() {
    running = false
    timer?.invalidate(); timer = nil
    teardown()
    window.orderOut(nil)
    window.close()
  }

  func load() {
    guard let url = Settings.pageURL else { return }
    let w = web ?? makeWeb()
    w.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    if Settings.mode == .snapshot { scheduleCapture(after: 90) } // backstop if the load never finishes
  }

  func makeWeb() -> WKWebView {
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = .default()
    cfg.suppressesIncrementalRendering = true
    if !Settings.motion {
      cfg.userContentController.addUserScript(
        WKUserScript(source: freezeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
    let content = window.contentView!
    let w = WKWebView(frame: content.bounds, configuration: cfg)
    w.autoresizingMask = [.width, .height]
    w.navigationDelegate = self
    content.addSubview(w, positioned: .below, relativeTo: still)
    web = w
    return w
  }

  func teardown() {
    settle?.cancel(); settle = nil
    guard let w = web else { return }
    w.navigationDelegate = nil
    w.stopLoading()
    w.removeFromSuperview()
    web = nil
  }

  func scheduleCapture(after seconds: Double) {
    settle?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.capture() }
    settle = work
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
  }

  func capture() {
    guard let w = web else { return }
    w.takeSnapshot(with: nil) { [weak self] img, _ in
      guard let self = self else { return }
      if let img = img { self.still.image = img; self.lastSnapshot = Date() }
      self.still.isHidden = false
      self.teardown()
    }
  }

  // Pages behind Cloudflare Access are spotted by the redirect to its login host. Any other login
  // wall still works through Sign in…, the menu just cannot say it is needed.
  func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
    needsSignIn = (w.url?.host ?? "").hasSuffix("cloudflareaccess.com")
    switch Settings.mode {
    case .live: still.isHidden = true
    case .snapshot: scheduleCapture(after: 12) // time for the page's data fetches and fit pass
    }
  }

  func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed() }
  func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed() }

  // Offline or the page is down: keep whatever is on screen and try again shortly.
  func failed() {
    switch Settings.mode {
    case .live:
      DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
        guard let self = self, self.running else { return }
        self.load()
      }
    case .snapshot: teardown()
    }
  }

  func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
    if running && Settings.mode == .live { w.reload() }
  }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
  var displays: [Display] = []
  var status: NSStatusItem!
  var signInWindow: NSWindow?
  var locked = false, asleep = false, away = false
  var idle: Bool { locked || asleep || away }

  func applicationDidFinishLaunching(_ n: Notification) {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty { NSApp.terminate(nil); return }

    NSApp.setActivationPolicy(.accessory)
    NSApp.mainMenu = editMenu()
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    status.button?.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Stillpaper")
    let menu = NSMenu()
    menu.delegate = self
    status.menu = menu

    NotificationCenter.default.addObserver(self, selector: #selector(rebuild),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(self, selector: #selector(onSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
    ws.addObserver(self, selector: #selector(onWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    ws.addObserver(self, selector: #selector(onAway), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    ws.addObserver(self, selector: #selector(onBack), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    let dnc = DistributedNotificationCenter.default()
    dnc.addObserver(self, selector: #selector(onLock), name: .init("com.apple.screenIsLocked"), object: nil)
    dnc.addObserver(self, selector: #selector(onUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)

    rebuild()
    // First run: nothing to show yet, so ask for the page straight away.
    if Settings.pageURL == nil { DispatchQueue.main.async { self.editURL() } }
  }

  @objc func onSleep() { asleep = true; applyActivity() }
  @objc func onWake() { asleep = false; applyActivity() }
  @objc func onAway() { away = true; applyActivity() }
  @objc func onBack() { away = false; applyActivity() }
  @objc func onLock() { locked = true; applyActivity() }
  @objc func onUnlock() { locked = false; applyActivity() }

  func applyActivity() {
    for d in displays { idle ? d.suspend() : d.resume() }
  }

  @objc func rebuild() {
    displays.forEach { $0.close() }
    let screens = Settings.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
    displays = screens.map { Display(screen: $0) }
    applyActivity()
  }

  // MARK: menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let info = Bundle.main.infoDictionary ?? [:]
    let version = "Version \(info["CFBundleShortVersionString"] ?? "dev") · build \(info["CFBundleVersion"] ?? "0") (\(info["GitCommit"] ?? "unknown"))"
    menu.addItem(label(version))
    menu.addItem(label(statusLine()))
    menu.addItem(.separator())

    menu.addItem(item("Reload now", #selector(reloadNow), key: "r"))

    let modes = NSMenu()
    for (title, mode) in [("Live", Mode.live), ("Snapshot", Mode.snapshot)] {
      let i = item(title, #selector(setMode(_:)))
      i.representedObject = mode.rawValue
      i.state = Settings.mode == mode ? .on : .off
      modes.addItem(i)
    }
    menu.addItem(submenu("Mode", modes))

    let every = NSMenu()
    for m in [1, 5, 15, 30, 60] {
      let i = item("\(m) min", #selector(setInterval(_:)))
      i.representedObject = m
      i.state = Settings.snapshotMinutes == m ? .on : .off
      every.addItem(i)
    }
    menu.addItem(submenu("Snapshot every", every))

    let motion = item("Motion", #selector(toggleMotion))
    motion.state = Settings.motion ? .on : .off
    menu.addItem(motion)
    let all = item("Show on all displays", #selector(toggleAllDisplays))
    all.state = Settings.allDisplays ? .on : .off
    menu.addItem(all)
    menu.addItem(.separator())

    menu.addItem(item("Sign in…", #selector(signIn)))
    menu.addItem(item("Page address…", #selector(editURL)))
    let login = item("Open at login", #selector(toggleLogin))
    login.state = FileManager.default.fileExists(atPath: agentURL.path) ? .on : .off
    menu.addItem(login)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Stillpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
  }

  func statusLine() -> String {
    if Settings.pageURL == nil { return "No page set: use Page address…" }
    if displays.contains(where: { $0.needsSignIn }) { return "Sign-in needed: use Sign in…" }
    if idle { return "Paused while the screen is locked or asleep" }
    switch Settings.mode {
    case .live: return Settings.motion ? "Live, motion on" : "Live, motion off"
    case .snapshot:
      let f = DateFormatter(); f.dateFormat = "HH:mm"
      let last = displays.compactMap { $0.lastSnapshot }.max().map { f.string(from: $0) } ?? "pending"
      return "Snapshot every \(Settings.snapshotMinutes) min, last \(last)"
    }
  }

  func label(_ s: String) -> NSMenuItem { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
  func item(_ s: String, _ a: Selector, key: String = "") -> NSMenuItem { let i = NSMenuItem(title: s, action: a, keyEquivalent: key); i.target = self; return i }
  func submenu(_ s: String, _ m: NSMenu) -> NSMenuItem { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.submenu = m; return i }

  @objc func reloadNow() { rebuild() }
  @objc func setMode(_ i: NSMenuItem) { Settings.mode = Mode(rawValue: i.representedObject as? String ?? "") ?? .live; rebuild() }
  @objc func setInterval(_ i: NSMenuItem) { Settings.snapshotMinutes = i.representedObject as? Int ?? 5; rebuild() }
  @objc func toggleMotion() { Settings.motion.toggle(); rebuild() }
  @objc func toggleAllDisplays() { Settings.allDisplays.toggle(); rebuild() }

  @objc func editURL() {
    let alert = NSAlert()
    alert.messageText = "Page address"
    alert.informativeText = "The web page shown as your desktop background, starting with http:// or https://."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
    field.stringValue = Settings.url ?? ""
    field.placeholderString = "https://"
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let s = field.stringValue.trimmingCharacters(in: .whitespaces)
    guard URL(string: s)?.scheme?.hasPrefix("http") == true else { return }
    Settings.url = s
    rebuild()
  }

  // For a page behind a login. Signing in here stores the site's cookies in the app's own web data
  // store, which every wallpaper window shares, and is separate from Safari's.
  @objc func signIn() {
    if let w = signInWindow { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
    guard let url = Settings.pageURL else { editURL(); return }
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = .default()
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780), configuration: cfg)
    let w = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    w.title = "Sign in to the page, then close this window"
    w.contentView = web
    w.isReleasedWhenClosed = false
    w.delegate = self
    w.center()
    web.load(URLRequest(url: url))
    signInWindow = w
    NSApp.activate(ignoringOtherApps: true)
    w.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ n: Notification) {
    guard let w = n.object as? NSWindow, w === signInWindow else { return }
    (w.contentView as? WKWebView)?.stopLoading()
    signInWindow = nil
    rebuild()
  }

  var agentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
  }

  func launchctl(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
  }

  // A plist that is written but never loaded does nothing until the next login, and launchd has no
  // record of it until then, so the toggle loads and unloads the job as well as the file. Loading
  // runs the job once (RunAtLoad); that copy finds this one running and quits, leaving the job
  // loaded for next login.
  @objc func toggleLogin() {
    let fm = FileManager.default
    let domain = "gui/\(getuid())"
    if fm.fileExists(atPath: agentURL.path) {
      // Unloading a job stops its process, so when launchd started this copy the job is left to
      // lapse at logout instead; with the plist gone it never comes back.
      if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != bundleID {
        launchctl(["bootout", "\(domain)/\(bundleID)"])
      }
      try? fm.removeItem(at: agentURL)
      return
    }
    guard let exe = Bundle.main.executablePath else { return }
    let plist: [String: Any] = [
      "Label": bundleID,
      "ProgramArguments": [exe],
      "RunAtLoad": true,
      "ProcessType": "Interactive",
      "LimitLoadToSessionType": "Aqua",
    ]
    try? fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
      try? data.write(to: agentURL)
      launchctl(["bootstrap", domain, agentURL.path])
    }
  }

  // An accessory app has no visible menu bar, but key equivalents still route through the main
  // menu, so this is what makes paste (a one-time code, say) and Cmd-W work in the sign-in window.
  func editMenu() -> NSMenu {
    let main = NSMenu()
    let holder = NSMenuItem()
    main.addItem(holder)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    holder.submenu = edit
    return main
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
