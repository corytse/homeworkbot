import AVFoundation
import SwiftUI

/// Works out why the iPhone (Continuity Camera) isn't showing up, from what macOS itself reports:
/// the camera list, the Continuity Camera service log, and who else is logged in.
/// Skips the obvious (same Apple Account, Wi-Fi/Bluetooth on, setting enabled).
enum Troubleshooter {
    struct Finding: Identifiable {
        enum Level { case ok, warn, bad, info }
        let id = UUID()
        let level: Level
        let title: String
        let detail: String
    }

    /// One iPhone as last reported by the ContinuityCaptureAgent log.
    struct PhoneState: Equatable {
        var name, model, version: String
        var wired, nearby, magic, capabilities: Bool
    }

    static func run(currentCamera: String) async -> [Finding] {
        var f: [Finding] = []
        let cams = Camera.devices()
        let desk = cams.first { $0.deviceType == .deskViewCamera }
        let phoneCam = cams.first { $0.deviceType == .continuityCamera }

        // 1. What the app can actually use right now.
        if let desk {
            let using = currentCamera == desk.localizedName
            f.append(.init(level: .ok, title: "\(desk.localizedName) is available",
                           detail: using || currentCamera.isEmpty ? "The app can use it." :
                            "The app is showing \(currentCamera). Choose “Auto” or this camera in the camera menu."))
        } else if let phoneCam {
            f.append(.init(level: .warn, title: "\(phoneCam.localizedName) is connected, but without Desk View",
                           detail: "Desk View needs the phone mounted sideways (landscape) with its back cameras uncovered. Turn it to landscape, or press Reset below if it stays missing."))
        } else {
            f.append(.init(level: .bad, title: "macOS isn't offering the iPhone camera to any app",
                           detail: "Details below show what's blocking it."))
        }
        if let cam = desk ?? phoneCam, cam.isInUseByAnotherApplication {
            f.append(.init(level: .warn, title: "Another app is using the iPhone camera",
                           detail: "Quit FaceTime, Zoom, Teams, Photo Booth or a browser video call, then Check again."))
        }

        // 2. What the Continuity Camera service says about each iPhone (only needed when it's missing:
        //    a phone can show "not in webcam mode" while macOS still offers its camera).
        if desk == nil, let log = await shell("/usr/bin/log", ["show", "--last", "3m", "--style", "compact",
                                                  "--predicate", "process == \"ContinuityCaptureAgent\""]) {
            let phones = parsePhones(log)
            let macMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            if phones.isEmpty && desk == nil && phoneCam == nil {
                f.append(.init(level: .bad, title: "The Mac hasn't heard from any iPhone in the last 3 minutes",
                               detail: "• If the iPhone restarted or updated, unlock it once with its passcode: Continuity stays off until then.\n• The Mac's Continuity link can get stuck: press Reset below, or turn the Mac's Bluetooth off and on."))
            }
            if phones.count > 1 {
                f.append(.init(level: .info, title: "\(phones.count) iPhones are nearby",
                               detail: phones.map { "\($0.name) (iOS \($0.version))" }.joined(separator: ", ") + ". Check the one on the clip is the one listed as ready."))
            }
            for p in phones {
                let who = "\(p.name) · iOS \(p.version)"
                if let major = Int(p.version.split(separator: ".").first ?? ""), major != macMajor {
                    f.append(.init(level: .bad, title: "\(who): iOS \(major) vs macOS \(macMajor)",
                                   detail: "Continuity Camera needs matching major versions. Update whichever one is behind."))
                }
                if !p.nearby {
                    f.append(.init(level: .bad, title: "\(who) is out of Bluetooth range",
                                   detail: "It must be right by the Mac. A phone in a bag, another room, or behind a metal stand won't count."))
                } else if !p.capabilities {
                    f.append(.init(level: .warn, title: "\(who) didn't send its camera details",
                                   detail: "Its camera is busy or the phone is mid-update. Close the Camera app, FaceTime or video calls on the iPhone (or another Mac using it), lock it, and wait 10 seconds."))
                } else if p.wired {
                    f.append(.init(level: .info, title: "\(who) is connected by cable",
                                   detail: "If nothing appears, unlock the phone and tap “Trust” on its screen."))
                } else if !p.magic {
                    f.append(.init(level: .warn, title: "\(who) is nearby but not in webcam mode",
                                   detail: "It only switches on when the phone is locked with the screen off, upright on the clip in landscape, back cameras facing you, and still for a few seconds. Things that quietly stop it: StandBy (charging on its side showing the clock), lying flat, a notification waking the screen, or a case covering the cameras."))
                } else {
                    f.append(.init(level: .ok, title: "\(who) is mounted and ready",
                                   detail: desk == nil ? "macOS is still setting it up. Wait 10 seconds and Check again, or press Reset." : "All good."))
                }
            }
        } else if desk == nil {
            f.append(.init(level: .info, title: "Couldn't read the Continuity Camera log",
                           detail: "This Mac account may not be an administrator, so only the camera list was checked."))
        }

        // 3. Another account logged in on this Mac can grab its owner's iPhone.
        if desk == nil, let ps = await shell("/bin/ps", ["-axo", "user=,comm="]) {
            let others = Set(ps.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[1].hasSuffix("ContinuityCaptureAgent"), parts[0] != NSUserName() else { return nil }
                return parts[0]
            })
            if !others.isEmpty {
                f.append(.init(level: .warn, title: "Also logged in on this Mac: \(others.sorted().joined(separator: ", "))",
                               detail: "An iPhone signed in to that person's Apple Account connects to their session, not this one. Log that account out (Apple menu › Log Out) or use the app from that account."))
            }
        }
        return f
    }

    /// Restarts this account's Continuity services; macOS relaunches them straight away.
    static func reset() async { _ = await shell("/usr/bin/killall", ["ContinuityCaptureAgent", "rapportd"]) }

    /// Latest state of each iPhone in the ContinuityCaptureAgent log.
    static func parsePhones(_ log: String) -> [PhoneState] {
        let re = try! NSRegularExpression(pattern:
            #"Name:(.+?) Model:(\S+) Wired:(\d) Wireless:\d Magic:(\d) Nearby:(\d) Capabilities:(\d) Version:([\d.]+)"#)
        var latest: [String: PhoneState] = [:], order: [String] = []
        for line in log.split(separator: "\n") where line.contains("Client Device Identifier") {
            let s = String(line)
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            let g = { (i: Int) in String(s[Range(m.range(at: i), in: s)!]) }
            guard g(2).hasPrefix("iPhone") else { continue }
            let p = PhoneState(name: g(1), model: g(2), version: g(7), wired: g(3) == "1",
                               nearby: g(5) == "1", magic: g(4) == "1", capabilities: g(6) == "1")
            if latest[p.name] == nil { order.append(p.name) }
            latest[p.name] = p
        }
        return order.compactMap { latest[$0] }
    }

    static func selfTest() {
        let log = """
        x Client Device Identifier:AB Name:Cory’s iPhone Model:iPhone17,4 Wired:0 Wireless:1 Magic:0 Nearby:1 Capabilities:1 Version:27.2 status 1
        x Client Device Identifier:CD Name:CORY’s iPad Model:iPad11,6 Wired:0 Wireless:1 Magic:0 Nearby:0 Capabilities:1 Version:26.5 status 2
        x Client Device Identifier:AB Name:Cory’s iPhone Model:iPhone17,4 Wired:0 Wireless:1 Magic:1 Nearby:1 Capabilities:1 Version:27.2 status 3
        """
        let p = parsePhones(log)
        precondition(p.count == 1 && p[0].name == "Cory’s iPhone" && p[0].magic && p[0].version == "27.2", "parsePhones")
    }

    private static func shell(_ exe: String, _ args: [String]) async -> String? {
        await Task.detached {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 || exe.hasSuffix("killall") ? String(data: d, encoding: .utf8) : nil
        }.value
    }
}

struct TroubleshooterView: View {
    let currentCamera: String
    @Environment(\.dismiss) private var dismiss
    @State private var findings: [Troubleshooter.Finding] = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("🩺 iPhone camera check").font(Theme.rounded(24, .heavy)).foregroundStyle(Theme.purple)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if busy && findings.isEmpty {
                        HStack { ProgressView(); Text("Checking…") }.padding()
                    }
                    ForEach(findings) { f in
                        HStack(alignment: .top, spacing: 10) {
                            Text(icon(f.level)).font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.title).font(Theme.rounded(16, .bold)).foregroundStyle(Theme.ink)
                                Text(f.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            HStack {
                Button("↻  Check again") { Task { await check() } }
                    .buttonStyle(FunButton(colors: [Theme.sky, Theme.purple], size: 15))
                Button("🔄  Reset Continuity Camera") {
                    Task { busy = true; await Troubleshooter.reset(); try? await Task.sleep(for: .seconds(8)); await check() }
                }
                .buttonStyle(FunButton(colors: [Theme.orange, Theme.pink], size: 15))
                .help("Restarts this account's Continuity services. macOS starts them again by itself.")
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(FunButton(colors: [.gray, .gray.opacity(0.8)], size: 15))
            }
            .disabled(busy)
        }
        .padding(22)
        .frame(width: 620, height: 560)
        .background(Theme.background)
        .task { await check() }
    }

    private func check() async {
        busy = true
        findings = await Troubleshooter.run(currentCamera: currentCamera)
        busy = false
    }

    private func icon(_ l: Troubleshooter.Finding.Level) -> String {
        switch l { case .ok: "✅"; case .warn: "⚠️"; case .bad: "❌"; case .info: "ℹ️" }
    }
}
