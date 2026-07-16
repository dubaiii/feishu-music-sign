import SwiftUI
import AppKit
import WebKit
import ApplicationServices
import Foundation

// MARK: - Models

struct Track: Equatable {
    var title: String
    var artist: String
    var playing: Bool
    var source: String   // "MediaRemote" / "Spotify" / "Apple Music" / ""
    static let none = Track(title: "", artist: "", playing: false, source: "")
}

func appSupportDir() -> URL {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let dir = base.appendingPathComponent("MusicSign", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Now Playing service

final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()
    @Published var track = Track.none
    @Published var diagnostics = ""
    private var timer: Timer?
    private var lastRaw = ""
    private var mrDisabled = false  // set true once the MediaRemote helper crashes (macOS 26 locks it)

    func start() {
        guard timer == nil else { return }
        poll()
        // 10s cadence: keeps now-playing detection responsive without hammering
        // the Feishu API on rapid track/pause toggles (changes are dedup'd upstream).
        let t = Timer(timeInterval: 10.0, repeats: true) { _ in self.poll() }
        t.tolerance = 1.0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The track text pushed into the signature, e.g. "我好想你 - 蘇打綠".
    /// Prefix/suffix wrapping is applied by FeishuService.composeSignature.
    var signatureText: String {
        let t = track
        if t.title.isEmpty { return "" }
        if t.artist.isEmpty { return t.title }
        return "\(t.title) - \(t.artist)"
    }

    private func poll() {
        // System-wide Now Playing via MediaRemote. The dylib is loaded into
        // /usr/bin/perl (Apple-signed), which passes macOS 15.4+/26's caller check.
        // Covers ALL players (汽水音乐/Spotify/QQ音乐/网易云/酷狗…). No app-layer reading.
        if let t = runMRHelper(), !t.title.isEmpty {
            commit(t, "MediaRemote"); return
        }
        commit(Track.none, "")
    }

    private func commit(_ t: Track, _ src: String) {
        let v = Track(title: t.title, artist: t.artist, playing: t.playing, source: src.isEmpty ? t.source : src)
        DispatchQueue.main.async {
            let changed = self.track != v
            self.track = v
            if changed {
                FeishuService.shared.syncFromState(playing: v.playing, trackText: self.signatureText)
            }
        }
    }

    private func runMRHelper() -> Track? {
        // Spawn: /usr/bin/perl <Resources>/loader.pl <Resources>/libmr_adapter.dylib get
        // perl is Apple-signed -> MediaRemote permits the call; dylib prints JSON.
        guard let loader = Bundle.main.path(forResource: "loader", ofType: "pl"),
              let dylib = Bundle.main.path(forResource: "libmr_adapter", ofType: "dylib")
        else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [loader, dylib, "get"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw == "null" { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        let title = (obj["title"] as? String) ?? ""
        let artist = (obj["artist"] as? String) ?? ""
        let playing = (obj["playing"] as? Bool) ?? false
        return Track(title: title, artist: artist, playing: playing, source: "MediaRemote")
    }

    private func appleScriptNowPlaying() -> Track? {
        let src = """
        tell application "System Events" to set procs to name of processes
        if "Spotify" is in procs then
          try
            tell application "Spotify"
              set t to name of current track
              set ar to artist of current track
              set pst to player state
              return t & tab & ar & tab & (pst as string) & tab & "Spotify"
            end tell
          end try
        end if
        if "Music" is in procs then
          try
            tell application "Music"
              set t to name of current track
              set ar to artist of current track
              set pst to player state
              return t & tab & ar & tab & (pst as string) & tab & "Apple Music"
            end tell
          end try
        end if
        return ""
        """
        var err: NSDictionary?
        guard let script = NSAppleScript(source: src) else { return nil }
        let res = script.executeAndReturnError(&err)
        if err != nil { return nil }
        let raw = res.stringValue ?? ""
        guard !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "\t")
        guard parts.count >= 3 else { return nil }
        let title = parts[0], artist = parts[1], state = parts[2]
        let source = parts.count > 3 ? parts[3] : "AppleScript"
        return Track(title: title, artist: artist, playing: state == "playing", source: source)
    }

    // MARK: Accessibility fallback (QQ音乐/网易云/酷狗 etc. — no AppleScript dict)
    private var axPrompted = false
    private var axDebuggedOK = false
    private let axDebugLog = appSupportDir().appendingPathComponent("ax_debug.log")
    private let axApps = ["汽水音乐", "QQ音乐", "网易云音乐", "酷狗音乐",
                          "QQMusic", "NeteaseMusic", "NeteaseMusicForMac", "kugou", "KuGou", "xiami"]

    /// Dump what the AX layer sees for each known music app, so we can see where the
    /// song lives (window title? a child element?) and tune parsing. Writes ax_debug.log.
    private func axDebugDump() {
        if !axPrompted {
            axPrompted = true
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        guard !axDebuggedOK else { return }
        var lines: [String] = []
        for name in axApps {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                ($0.localizedName == name) || (($0.bundleIdentifier ?? "").lowercased().contains(name.lowercased()))
            }) else { continue }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            var winsVal: CFTypeRef?
            AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &winsVal)
            let wins = (winsVal as? [AXUIElement]) ?? []
            for (i, w) in wins.prefix(3).enumerated() {
                var t: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
                let title = (t as? String) ?? "(no title)"
                lines.append("\(name) win[\(i)] title=\"\(title)\"")
                var kids: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXChildrenAttribute as CFString, &kids)
                for c in (kids as? [AXUIElement]) ?? [] {
                    var ct: CFTypeRef?; var cr: CFTypeRef?
                    AXUIElementCopyAttributeValue(c, kAXTitleAttribute as CFString, &ct)
                    AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &cr)
                    let s = (ct as? String) ?? ""
                    if !s.isEmpty { lines.append("   child role=\(cr as? String ?? "?") title=\"\(s)\"") }
                }
            }
        }
        if !lines.isEmpty { axDebuggedOK = true }
        try? lines.joined(separator: "\n").data(using: .utf8)?.write(to: axDebugLog)
    }

    private func axNowPlaying() -> Track? {
        if !axPrompted {
            axPrompted = true
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        for name in axApps {
            guard let title = axWindowTitle(name), !title.isEmpty else { continue }
            var s = title
            for a in axApps {
                s = s.replacingOccurrences(of: " - \(a)", with: "")
                     .replacingOccurrences(of: "(\(a))", with: "")
            }
            let parts = s.components(separatedBy: " - ")
            if parts.count >= 2 {
                return Track(title: parts[0], artist: parts[1], playing: true, source: name)
            }
            if !s.isEmpty { return Track(title: s, artist: "", playing: true, source: name) }
        }
        return nil
    }

    private func axWindowTitle(_ appName: String) -> String? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName == appName) || (($0.bundleIdentifier ?? "").contains(appName))
        }) else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var windowsVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windowsVal) == .success,
              let wins = windowsVal as? [AXUIElement], let w = wins.first else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
        return title as? String
    }
}

// MARK: - Feishu: login + cookie capture, direct signature API

final class FeishuService: ObservableObject {
    static let shared = FeishuService()
    @Published var loggedIn = false
    @Published var status = "未登录"
    @Published var syncEnabled = false

    @Published var prefix: String {
        didSet { UserDefaults.standard.set(prefix, forKey: "feishu.prefix") }
    }
    @Published var suffix: String {
        didSet { UserDefaults.standard.set(suffix, forKey: "feishu.suffix") }
    }
    /// Signature pushed when playback is paused or no track. Empty = clear the signature.
    @Published var pausedSignature: String {
        didSet { UserDefaults.standard.set(pausedSignature, forKey: "feishu.pausedSignature") }
    }
    /// Append the project repo link to the (playing) signature so Feishu renders it
    /// as a clickable hyperlink. Feishu auto-linkifies URLs/domains in the signature.
    @Published var linkEnabled: Bool {
        didSet {
            UserDefaults.standard.set(linkEnabled, forKey: "feishu.linkEnabled")
            scheduleEditSync()
        }
    }
    let projectLink = "github.com/dubaiii/feishu-music-sign"

    let cookieFile = appSupportDir().appendingPathComponent("feishu_cookies.json")
    let loginURL = URL(string: "https://feishu.cn/next/messenger")!
    // Desktop Chrome UA — Feishu's /next/messenger UA-sniffs and rejects Safari/WebKit.
    let chromeUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private var lastSynced = ""

    /// Known Feishu endpoint for reading/updating the user profile signature.
    private let detailsURL = URL(string: "https://internal-api-lark-api.feishu.cn/passport/users/details/")!
    private let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    private init() {
        prefix = UserDefaults.standard.string(forKey: "feishu.prefix") ?? ""
        suffix = UserDefaults.standard.string(forKey: "feishu.suffix") ?? ""
        pausedSignature = UserDefaults.standard.string(forKey: "feishu.pausedSignature") ?? ""
        // Defaults to true so the project link shows up out of the box.
        linkEnabled = (UserDefaults.standard.object(forKey: "feishu.linkEnabled") as? Bool) ?? true
    }

    let syncLog = appSupportDir().appendingPathComponent("sync.log")
    func appendSync(_ line: String) {
        var s = (try? String(contentsOf: syncLog, encoding: .utf8)) ?? ""
        s += line + "\n"
        if s.count > 20000 { s = String(s.suffix(20000)) }
        try? s.data(using: .utf8)?.write(to: syncLog)
    }

    func openLogin() {
        FeishuLoginWindow.shared.show { [weak self] ok in
            DispatchQueue.main.async {
                self?.loggedIn = ok
                self?.status = ok ? "已登录飞书 ✓" : "未登录"
            }
        }
    }

    func loadCookies() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: cookieFile),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr
    }

    func cookieHeader() -> String {
        let pairs = loadCookies().compactMap { c -> String? in
            guard let n = c["name"] as? String, let v = c["value"] as? String else { return nil }
            return "\(n)=\(v)"
        }
        return pairs.joined(separator: "; ")
    }

    /// Compose the final signature: `${prefix} ${track}${suffix ? ' '+suffix : ''}${link}`.trim()
    /// The project link is appended so Feishu auto-linkifies it into a clickable URL.
    func composeSignature(_ track: String) -> String {
        guard !track.isEmpty else { return "" }
        let p = prefix.trimmingCharacters(in: .whitespaces)
        let s = suffix.trimmingCharacters(in: .whitespaces)
        var sig = track
        if !p.isEmpty { sig = p + " " + sig }
        if !s.isEmpty { sig = sig + " " + s }
        if linkEnabled { sig = sig + " · " + projectLink }
        return sig.trimmingCharacters(in: .whitespaces)
    }

    /// What the popover preview shows — same logic as syncFromState.
    func previewSignature(playing: Bool, trackText: String) -> String {
        if playing && !trackText.isEmpty {
            return composeSignature(trackText)
        }
        let p = pausedSignature.trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? "(清空签名)" : p
    }

    /// Called by NowPlayingService when the track or playing-state changes.
    /// Playing (with a track) → song signature (prefix/track/suffix).
    /// Paused or no track → the user's `pausedSignature` (restore default).
    func syncFromState(playing: Bool, trackText: String) {
        guard syncEnabled, loggedIn else { return }
        let sig: String
        if playing && !trackText.isEmpty {
            sig = composeSignature(trackText)
        } else {
            sig = pausedSignature.trimmingCharacters(in: .whitespaces)
        }
        guard sig != lastSynced else { return }
        lastSynced = sig
        throttledUpdate(sig)
    }

    /// Manual trigger for debugging — forces one sync now, bypassing the throttle.
    func forceSync() {
        let np = NowPlayingService.shared
        let sig = (np.track.playing && !np.signatureText.isEmpty)
            ? composeSignature(np.signatureText)
            : pausedSignature.trimmingCharacters(in: .whitespaces)
        lastSynced = sig
        throttledUpdate(sig, force: true)
    }

    /// Debounced sync triggered when a text field loses focus (user finished editing).
    /// Waits `editDebounce` so that moving between fields / rapid blurs don't spam the
    /// API; then pushes the current signature immediately (force, bypassing the 10s
    /// track-sync throttle — this is an explicit user action).
    private var editWork: DispatchWorkItem?
    private let editDebounce: TimeInterval = 0.6
    func scheduleEditSync() {
        guard syncEnabled, loggedIn else { return }
        editWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let np = NowPlayingService.shared
            let sig = (np.track.playing && !np.signatureText.isEmpty)
                ? self.composeSignature(np.signatureText)
                : self.pausedSignature.trimmingCharacters(in: .whitespaces)
            guard !sig.isEmpty else { return }
            self.lastSynced = sig
            self.throttledUpdate(sig, force: true)
        }
        editWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + editDebounce, execute: work)
    }

    // MARK: Throttle — at most one Feishu API call per `minInterval` (10s).
    // Coalesces bursts (rapid skip/pause/resume) into the latest signature.
    private let minInterval: TimeInterval = 10
    private var lastSyncAt: Date = .distantPast
    private var pending: DispatchWorkItem?

    private func throttledUpdate(_ sig: String, force: Bool = false) {
        let elapsed = Date().timeIntervalSince(lastSyncAt)
        if force || elapsed >= minInterval {
            pending?.cancel()
            pending = nil
            lastSyncAt = Date()
            updateSignature(sig)
            return
        }
        // Defer the latest sig until the cooldown elapses; a newer call replaces it.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lastSyncAt = Date()
            self.updateSignature(sig)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (minInterval - elapsed), execute: work)
    }

    private func updateSignature(_ signature: String) {
        let cookie = cookieHeader()
        guard !cookie.isEmpty else { status = "未登录飞书"; return }
        var req = URLRequest(url: detailsURL)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://feishu.cn/", forHTTPHeaderField: "Referer")
        req.setValue("https://feishu.cn", forHTTPHeaderField: "Origin")
        let body: [String: Any] = ["description": signature, "descriptionType": 0]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        status = "同步中…"
        let cookieN = cookie.components(separatedBy: "; ").count
        appendSync("=== sync ===\n[PUT] url=\(detailsURL.absoluteString)\nreq-body=\(body)\ncookies=\(cookieN)")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let bodyStr = String(data: data ?? Data(), encoding: .utf8) ?? ""
            var biz = ""
            if let d = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] {
                if let c = d["code"] { biz += "code=\(c) " }
                if let m = d["msg"] as? String { biz += "msg=\(m)" }
            }
            let ok = code == 200 && (biz.isEmpty || biz.hasPrefix("code=0"))
            DispatchQueue.main.async {
                guard let self = self else { return }
                if ok {
                    self.status = "已同步 ✓ \(biz)"
                } else if code >= 400 && code < 500 {
                    // Cookie likely expired — drop the cache so the next attempt
                    // re-prompts login, mirroring the reference extension's behavior.
                    try? FileManager.default.removeItem(at: self.cookieFile)
                    self.loggedIn = false
                    self.status = "登录已过期,请重新登录飞书 (HTTP\(code))"
                } else {
                    self.status = "失败 HTTP\(code) \(biz) body=\(bodyStr.prefix(200))"
                }
            }
            self?.appendSync("-> HTTP\(code) \(biz)\nresp-body=\(bodyStr)\n")
        }.resume()
    }

    /// Read the current signature back (helper; not required for the sync flow).
    func getCurrentSignature(_ completion: @escaping (String?) -> Void) {
        let cookie = cookieHeader()
        guard !cookie.isEmpty else { completion(nil); return }
        var req = URLRequest(url: detailsURL)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://feishu.cn/", forHTTPHeaderField: "Referer")
        req.setValue("https://feishu.cn", forHTTPHeaderField: "Origin")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let d = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
            else { completion(nil); return }
            let desc = (d["description"] as? String)
                ?? ((d["data"] as? [String: Any])?["description"] as? String)
            completion(desc)
        }.resume()
    }
}

// MARK: - Feishu login window (WKWebView) + cookie capture

final class FeishuLoginWindow: NSWindow, WKNavigationDelegate, NSWindowDelegate {
    static let shared: FeishuLoginWindow = {
        let w = FeishuLoginWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "登录飞书"
        w.isReleasedWhenClosed = false
        w.delegate = w
        return w
    }()

    private var webView: WKWebView!
    private var completion: ((Bool) -> Void)?
    private var captured = false

    func show(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        self.captured = false
        if webView == nil {
            let cfg = WKWebViewConfiguration()
            webView = WKWebView(frame: .zero, configuration: cfg)
            webView.navigationDelegate = self
            webView.autoresizingMask = [.width, .height]
            contentView = webView
        }
        webView.customUserAgent = FeishuService.shared.chromeUA
        webView.load(URLRequest(url: FeishuService.shared.loginURL))
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func capture(_ done: @escaping (Bool) -> Void) {
        guard !captured else { done(false); return }
        captured = true
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let keep = cookies.filter { c in
                let d = c.domain.lowercased()
                return d.contains("feishu") || d.contains("lark")
            }
            let arr: [[String: Any]] = keep.map {
                ["name": $0.name, "value": $0.value, "domain": $0.domain, "path": $0.path]
            }
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: .prettyPrinted) {
                try? data.write(to: FeishuService.shared.cookieFile)
            }
            DispatchQueue.main.async { done(!arr.isEmpty) }
        }
    }

    func webView(_ wv: WKWebView, didFinish: WKNavigation!) {
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let has = cookies.contains { c in
                let d = c.domain.lowercased()
                return (d.contains("feishu") || d.contains("lark")) && c.name.lowercased().contains("session")
            }
            DispatchQueue.main.async {
                self.title = has ? "登录飞书 ✓ 已检测到登录,关闭窗口即保存" : "登录飞书"
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        capture { ok in self.completion?(ok) }
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NowPlayingService.shared.start()
    }
}

@main
struct MusicSignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var np = NowPlayingService.shared
    var body: some View {
        Text(np.track.playing ? "🎵 \(np.track.title.prefix(20))" : "♪")
            .lineLimit(1)
    }
}

// MARK: - Vibrancy background

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = false
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Popover content

struct ContentView: View {
    @ObservedObject private var np = NowPlayingService.shared
    @ObservedObject private var feishu = FeishuService.shared
    private enum Field { case prefix, suffix, paused }
    @FocusState private var focused: Field?

    var body: some View {
        ZStack {
            VisualEffectView().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(np.track.playing ? "▶" : "⏸").font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(np.track.title.isEmpty ? "未在播放" : np.track.title)
                            .font(.headline)
                        Text(np.track.artist.isEmpty ? "—" : np.track.artist)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack {
                    Image(systemName: feishu.loggedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                    Text(feishu.status)
                    Spacer()
                }
                Button(feishu.loggedIn ? "重新登录飞书" : "登录飞书") { feishu.openLogin() }
                Toggle("同步到飞书签名", isOn: $feishu.syncEnabled)
                    .disabled(!feishu.loggedIn)
                HStack {
                    Text("前缀").font(.caption).foregroundStyle(.secondary)
                    TextField("如 🎵", text: $feishu.prefix)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .prefix)
                }
                HStack {
                    Text("后缀").font(.caption).foregroundStyle(.secondary)
                    TextField("如 (now)", text: $feishu.suffix)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .suffix)
                }
                HStack {
                    Text("暂停").font(.caption).foregroundStyle(.secondary)
                    TextField("暂停时的签名", text: $feishu.pausedSignature)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .paused)
                }
                Toggle("签名带项目链接", isOn: $feishu.linkEnabled)
                    .font(.caption)
                if feishu.syncEnabled {
                    Text("预览: \(feishu.previewSignature(playing: np.track.playing, trackText: np.signatureText))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Divider()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
            .padding(14)
            .frame(width: 300)
            // Tap on empty area (behind the fields) blurs the active field, which
            // (via onChange below) triggers a debounced sync. TextField taps still
            // focus normally — they're in front of this background.
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { focused = nil })
            .onChange(of: focused) { _, newFocus in
                // Losing focus entirely (clicked outside) → debounce-sync after the
                // user stops editing, so typing doesn't spam the Feishu API.
                if newFocus == nil { feishu.scheduleEditSync() }
            }
        }
    }
}
