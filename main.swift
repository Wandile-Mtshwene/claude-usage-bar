// Claude Usage Bar — a tiny macOS menu-bar widget showing your Claude
// subscription usage (5-hour session window + 7-day weekly window).
//
// Data source: the same endpoint the Claude usage page uses:
//   GET https://api.anthropic.com/api/oauth/usage
// Auth: your Claude Code OAuth token, read live from the macOS Keychain
// (item "Claude Code-credentials"). Claude Code keeps that token fresh,
// so we simply re-read it on every poll — no refresh logic needed.

import AppKit
import SwiftUI
import Combine
import ServiceManagement

// MARK: - Model

struct UsageWindow {
    var utilization: Double   // 0...100
    var resetsAt: Date?
}

final class UsageModel: ObservableObject {
    @Published var session: UsageWindow?
    @Published var week: UsageWindow?
    @Published var breakdown: [(name: String, percent: Double)] = []
    @Published var lastUpdated: Date?
    @Published var errorText: String?
    @Published var isAuthError = false     // token missing/expired — the only actionable state
    private var lastAttempt: Date?
    @Published var showText: Bool = UserDefaults.standard.object(forKey: "showText") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showText, forKey: "showText"); onUpdate?() }
    }
    @Published var showResetInBar: Bool = UserDefaults.standard.object(forKey: "showResetInBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showResetInBar, forKey: "showResetInBar"); onUpdate?() }
    }
    @Published var refreshInterval: Double = UserDefaults.standard.object(forKey: "refreshInterval") as? Double ?? 60 {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval"); onReschedule?() }
    }
    @Published var warnThreshold: Double = UserDefaults.standard.object(forKey: "warnThreshold") as? Double ?? 90 {
        didSet {
            UserDefaults.standard.set(warnThreshold, forKey: "warnThreshold")
            gWarnThreshold = warnThreshold
            onUpdate?()
        }
    }
    @Published var launchAtLogin: Bool = false

    var onUpdate: (() -> Void)?
    var onReschedule: (() -> Void)?

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Reads the OAuth access token from the login Keychain.
    private func accessToken() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    /// `force` bypasses the debounce (used by the manual Refresh button).
    func refresh(force: Bool = false) {
        // Debounce: avoid stacking timer ticks + popover-open refreshes into the
        // rate limit. Skip if we attempted within the last 20s.
        if !force, let la = lastAttempt, Date().timeIntervalSince(la) < 20 { return }
        lastAttempt = Date()

        guard let token = accessToken() else {
            DispatchQueue.main.async {
                self.isAuthError = true
                self.errorText = "No Claude token in Keychain. Open Claude Code once to sign in."
                self.onUpdate?()
            }
            return
        }
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            DispatchQueue.main.async {
                // On any transient failure, keep the last-known numbers on screen.
                if err != nil {
                    self.errorText = "Network error — retrying"
                    self.onUpdate?(); return
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 {
                    self.isAuthError = true
                    self.errorText = "Token expired. Run any Claude Code command to refresh."
                    self.onUpdate?(); return
                }
                if code == 429 {
                    self.errorText = "Rate limited — backing off"
                    self.onUpdate?(); return
                }
                if code != 200 {
                    self.errorText = "Usage API error (HTTP \(code))"
                    self.onUpdate?(); return
                }
                guard let data = data,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      root["five_hour"] != nil else {
                    self.errorText = "Unexpected response"
                    self.onUpdate?(); return
                }
                self.isAuthError = false
                self.errorText = nil
                self.session = Self.parseWindow(root["five_hour"])
                self.week = Self.parseWindow(root["seven_day"])
                if let bd = root["seven_day_breakdown"] as? [String: Any],
                   let rows = bd["rows"] as? [[String: Any]] {
                    self.breakdown = rows.compactMap {
                        guard let name = $0["display_name"] as? String,
                              let pct = ($0["percent"] as? NSNumber)?.doubleValue else { return nil }
                        return (name, pct)
                    }.filter { $0.1 > 0 }
                }
                self.lastUpdated = Date()
                self.onUpdate?()
            }
        }.resume()
    }

    private static func parseWindow(_ any: Any?) -> UsageWindow? {
        guard let d = any as? [String: Any],
              let util = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return UsageWindow(utilization: util, resetsAt: parseDate(d["resets_at"] as? String))
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Fall back: trim fractional seconds if the microsecond form isn't parsed.
        if let dot = s.firstIndex(of: "."),
           let plus = s.lastIndex(where: { $0 == "+" || $0 == "-" }), plus > dot {
            let trimmed = String(s[s.startIndex..<dot]) + String(s[plus...])
            let f2 = ISO8601DateFormatter()
            return f2.date(from: trimmed)
        }
        return nil
    }
}

// MARK: - Color helper

// Claude brand palette
let claudeCoral   = Color(red: 0.851, green: 0.463, blue: 0.341)   // #D97757
let claudeCream   = Color(red: 0.980, green: 0.976, blue: 0.961)   // #FAF9F5
let claudeCoralNS = NSColor(red: 0.851, green: 0.463, blue: 0.341, alpha: 1)
let claudeCreamNS = NSColor(red: 0.980, green: 0.976, blue: 0.961, alpha: 1)
let warnRedNS     = NSColor(red: 0.80,  green: 0.24,  blue: 0.20,  alpha: 1)

// Coral by default (on-brand); deepen to red once past the warning threshold.
var gWarnThreshold: Double = UserDefaults.standard.object(forKey: "warnThreshold") as? Double ?? 90
func color(for pct: Double) -> Color {
    pct >= gWarnThreshold ? Color(red: 0.80, green: 0.24, blue: 0.20) : claudeCoral
}
func nsColor(for pct: Double) -> NSColor {
    pct >= gWarnThreshold ? warnRedNS : claudeCoralNS
}

/// Rounded coral "pill" image drawn for the menu-bar button.
func pillImage(text: String, bg: NSColor, fg: NSColor) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
    let ts = (text as NSString).size(withAttributes: attrs)
    let h: CGFloat = 16, padH: CGFloat = 7
    let w = ceil(ts.width) + padH * 2
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    let rect = NSRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
    NSBezierPath(roundedRect: rect, xRadius: (h - 1) / 2, yRadius: (h - 1) / 2).addClip()
    bg.setFill()
    rect.fill()
    (text as NSString).draw(at: NSPoint(x: padH, y: (h - ts.height) / 2), withAttributes: attrs)
    img.unlockFocus()
    img.isTemplate = false
    return img
}

/// Two-part pill: bold percent, a thin divider, then a lighter reset time.
func pillImageDual(pct: String, time: String, bg: NSColor, fg: NSColor) -> NSImage {
    let pctFont  = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    let dim = fg.withAlphaComponent(0.78)
    let pctAttrs:  [NSAttributedString.Key: Any] = [.font: pctFont,  .foregroundColor: fg]
    let timeAttrs: [NSAttributedString.Key: Any] = [.font: timeFont, .foregroundColor: dim]
    let pctSize  = (pct  as NSString).size(withAttributes: pctAttrs)
    let timeSize = (time as NSString).size(withAttributes: timeAttrs)
    let h: CGFloat = 16, padH: CGFloat = 7, gap: CGFloat = 6, divW: CGFloat = 1
    let w = ceil(pctSize.width + gap + divW + gap + timeSize.width) + padH * 2
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    let rect = NSRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
    NSBezierPath(roundedRect: rect, xRadius: (h - 1) / 2, yRadius: (h - 1) / 2).addClip()
    bg.setFill()
    rect.fill()
    var x = padH
    (pct as NSString).draw(at: NSPoint(x: x, y: (h - pctSize.height) / 2), withAttributes: pctAttrs)
    x += pctSize.width + gap
    fg.withAlphaComponent(0.45).setFill()
    NSRect(x: x, y: 4, width: divW, height: h - 8).fill()
    x += divW + gap
    (time as NSString).draw(at: NSPoint(x: x, y: (h - timeSize.height) / 2), withAttributes: timeAttrs)
    img.unlockFocus()
    img.isTemplate = false
    return img
}

/// Compact reset countdown for the menu bar, e.g. "2h 10m", "12m", "1d 4h".
func compactReset(_ date: Date?) -> String {
    guard let date = date else { return "" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "now" }
    let h = secs / 3600, m = (secs % 3600) / 60, d = h / 24
    if d >= 1 { return "\(d)d \(h % 24)h" }
    if h >= 1 { return "\(h)h \(m)m" }
    return "\(m)m"
}

/// Absolute reset clock-time, e.g. "Resets 3:20 PM" or "Resets Thu 12:00 PM".
func absoluteReset(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
    return "Resets \(f.string(from: date))"
}

/// Small coral dot for the collapsed (icon-only) state.
func dotImage(color: NSColor) -> NSImage {
    let d: CGFloat = 11
    let img = NSImage(size: NSSize(width: d, height: d))
    img.lockFocus()
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: d - 2, height: d - 2)).fill()
    img.unlockFocus()
    img.isTemplate = false
    return img
}

func resetString(_ date: Date?) -> String {
    guard let date = date else { return "" }
    let secs = date.timeIntervalSinceNow
    if secs <= 0 { return "resetting…" }
    let h = Int(secs) / 3600
    let m = (Int(secs) % 3600) / 60
    let d = h / 24
    if d >= 1 { return "resets in \(d)d \(h % 24)h" }
    if h >= 1 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

// MARK: - Popover UI

struct Bar: View {
    let pct: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(color(for: pct))
                    .frame(width: max(6, geo.size.width * min(pct, 100) / 100))
            }
        }
        .frame(height: 9)
    }
}

struct WindowRow: View {
    let title: String
    let window: UsageWindow?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(window != nil ? "\(Int(window!.utilization.rounded()))%" : "—")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(window != nil ? color(for: window!.utilization) : .secondary)
            }
            Bar(pct: window?.utilization ?? 0)
            if let r = window?.resetsAt {
                VStack(alignment: .leading, spacing: 1) {
                    Text(absoluteReset(r)).font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("in \(compactReset(r))").font(.system(size: 9.5))
                        .foregroundColor(Color.secondary.opacity(0.7))
                }
            }
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    var onToggleLogin: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 4).fill(claudeCoral).frame(width: 14, height: 14)
                Text("Claude Usage").font(.system(size: 13, weight: .bold)).foregroundColor(claudeCoral)
                Spacer()
                Button(action: { model.refresh(force: true) }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(claudeCoral)
                }.buttonStyle(.borderless).help("Refresh now")
            }

            if let err = model.errorText {
                Text(err).font(.system(size: 11)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            WindowRow(title: "Session (5h)", window: model.session)
            WindowRow(title: "Week (7d)", window: model.week)

            if !model.breakdown.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Weekly by product").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(model.breakdown, id: \.name) { row in
                        HStack {
                            Text(row.name).font(.system(size: 11))
                            Spacer()
                            Text("\(Int(row.percent.rounded()))%").font(.system(size: 11, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("Settings").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)

                Toggle("Show percent in menu bar", isOn: $model.showText)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Toggle("Show reset time in menu bar", isOn: $model.showResetInBar)
                    .toggleStyle(.checkbox).font(.system(size: 11)).disabled(!model.showText)
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin }, set: { onToggleLogin($0) }))
                    .toggleStyle(.checkbox).font(.system(size: 11))

                HStack {
                    Text("Refresh every").font(.system(size: 11))
                    Spacer()
                    Picker("", selection: $model.refreshInterval) {
                        Text("30s").tag(30.0); Text("1m").tag(60.0); Text("5m").tag(300.0)
                    }.labelsHidden().frame(width: 78).controlSize(.small).tint(claudeCoral)
                }
                HStack {
                    Text("Turn red at").font(.system(size: 11))
                    Spacer()
                    Picker("", selection: $model.warnThreshold) {
                        Text("70%").tag(70.0); Text("80%").tag(80.0); Text("90%").tag(90.0)
                    }.labelsHidden().frame(width: 78).controlSize(.small).tint(claudeCoral)
                }
            }

            HStack {
                if let t = model.lastUpdated {
                    Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 250)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = UsageModel()
    private var timer: Timer?
    private var displayTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        // Reflect current login-item state; enable by default on first launch.
        model.launchAtLogin = isLaunchAtLogin()
        if !UserDefaults.standard.bool(forKey: "loginConfigured") {
            UserDefaults.standard.set(true, forKey: "loginConfigured")
            setLaunchAtLogin(true)
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model,
                                  onToggleLogin: { [weak self] on in self?.setLaunchAtLogin(on) })
        )

        model.onUpdate = { [weak self] in self?.updateStatusTitle() }
        model.onReschedule = { [weak self] in self?.scheduleTimer() }
        updateStatusTitle()
        model.refresh()
        scheduleTimer()

        // Lightweight tick so the menu-bar countdown stays fresh between fetches.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: model.refreshInterval, repeats: true) { [weak self] _ in
            self?.model.refresh()
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly

        // Prefer the last-known session number. Transient errors (429, network)
        // keep showing it rather than blanking the pill.
        if let s = model.session?.utilization {
            if !model.showText {
                button.image = dotImage(color: nsColor(for: s))
                return
            }
            let pct = "\(Int(s.rounded()))%"
            let time = model.showResetInBar ? compactReset(model.session?.resetsAt) : ""
            button.image = time.isEmpty
                ? pillImage(text: pct, bg: nsColor(for: s), fg: claudeCreamNS)
                : pillImageDual(pct: pct, time: time, bg: nsColor(for: s), fg: claudeCreamNS)
            return
        }
        // No data yet: only surface an actionable auth problem; otherwise loading.
        if model.isAuthError {
            button.image = pillImage(text: "sign in", bg: warnRedNS, fg: claudeCreamNS)
        } else {
            button.image = pillImage(text: "…", bg: .systemGray, fg: .white)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: Login item

    private func isLaunchAtLogin() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    private func setLaunchAtLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("login item toggle failed: \(error)") }
            model.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
