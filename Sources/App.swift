import AVFoundation
import Speech
import SwiftUI
import WebKit

@main
struct HomeworkHelperApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var tutor = Tutor()

    init() {
        if CommandLine.arguments.contains("--selftest") { AI.selfTest(); Troubleshooter.selfTest(); exit(0) }
        if let i = CommandLine.arguments.firstIndex(of: "--ask-gemini"), i + 1 < CommandLine.arguments.count {
            // Connection test using the app's own Gemini code and saved settings.
            // Optional 3rd arg: a JPEG, sent like a scanned homework photo.
            let q = CommandLine.arguments[i + 1], d = UserDefaults.standard
            let img = CommandLine.arguments.dropFirst(i + 2).first.flatMap { FileManager.default.contents(atPath: $0) }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let start = Date()
                do {
                    let r = try await AI.gemini(history: [Turn(role: .kid, text: q, image: img)], key: d.string(forKey: "geminiKey") ?? "",
                                                model: d.string(forKey: "geminiModel") ?? "gemini-3.6-flash")
                    print("OK in \(Int(Date().timeIntervalSince(start)))s:\n\(r)")
                } catch { print("FAILED: \(error.localizedDescription)") }
                done.signal()
            }
            done.wait()
            exit(0)
        }
        if CommandLine.arguments.contains("--camera-check") {   // same report as the 🩺 button, in Terminal
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                for f in await Troubleshooter.run(currentCamera: "") { print("[\(f.level)] \(f.title)\n    \(f.detail)") }
                done.signal()
            }
            done.wait()
            exit(0)
        }
        if CommandLine.arguments.contains("--cameras") {
            Camera.devices().forEach { print($0.localizedName, "|", $0.deviceType.rawValue, "|", $0.uniqueID) }
            exit(0)
        }
    }

    var body: some Scene {
        Window("Homework Helper", id: "main") { ContentView().environmentObject(tutor) }
            .defaultSize(width: 1300, height: 820)
            .windowStyle(.hiddenTitleBar)
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ n: Notification) {
        // The Dock caches app icons by bundle and can keep showing a blank one; set it directly.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: url)
        }
    }
}

// MARK: - Tutor: wires camera, mic, AI and voice together

@MainActor
final class Tutor: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var turns: [Turn] = []
    @Published var heard = ""
    @Published var status = "Starting…"
    @Published var thinking = false
    @Published var cameraName = "No camera"
    @Published var isDeskView = false   // camera can see her desk (iPhone Desk View or webcam bird's-eye)
    @Published var isWarping = false    // MacBook webcam with software bird's-eye view
    let frames = FrameStore()
    @Published var devices: [AVCaptureDevice] = []
    @Published var paused = false
    @Published var queued: String?   // question asked while thinking, sent after the current answer

    let camera = Camera()
    private let listener = Listener()
    private let synth = AVSpeechSynthesizer()
    private var claudeSession: String?
    private var generation = 0   // bumps on "New question" so late replies are dropped
    private var started = false

    private var defaults: UserDefaults { .standard }

    func start() {
        guard !started else { return }
        started = true
        synth.delegate = self
        camera.onDevice = { [weak self] name, desk, warp in
            self?.cameraName = warp ? "MacBook camera – bird's-eye" : name
            self?.isDeskView = desk
            self?.isWarping = warp
        }
        camera.onFrame = { [frames] in frames.image = $0 }
        listener.onPartial = { [weak self] in self?.heard = $0 }
        listener.onUtterance = { [weak self] in self?.ask($0) }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // Space = scan homework, unless she's typing in a text field (e.g. Settings).
            // 49 = Space, 36 = Return, 76 = keypad Enter
            guard [49, 36, 76].contains(e.keyCode), !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
            self?.capture()
            return nil
        }
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { _ in c.resume() } }
            camera.watch { [weak self] list in
                self?.devices = list
                self?.startCamera()   // switches to the iPhone / Desk View as soon as it appears
            }
            listen()
        }
    }

    func startCamera() { camera.start(preferredID: defaults.string(forKey: "cameraID") ?? "") }

    /// A question she spoke or typed.
    func ask(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !paused else { return }
        if thinking {
            // Asked while the AI is still working: hold it and send right after the current answer.
            queued = [queued, text].compactMap { $0 }.joined(separator: " ")
            heard = ""
            listener.start()
        } else {
            send(Turn(role: .kid, text: text))
        }
    }

    static let scanText = "Here is a photo of my homework. Please help me with it."

    func capture() {
        guard !paused else { return }
        guard let jpg = camera.snapshotJPEG() else { status = "Camera not ready yet – is the iPhone connected?"; return }
        send(Turn(role: .kid, text: Self.scanText, image: jpg))
    }

    func newQuestion() {
        generation += 1
        turns = []
        claudeSession = nil
        thinking = false
        queued = nil
        synth.stopSpeaking(at: .immediate)
        listen()
    }

    func stopTalking() { synth.stopSpeaking(at: .immediate) }

    /// Stopped = mic off, no AI calls, no tokens spent. Camera preview keeps running (it's free).
    func toggleRunning() {
        paused.toggle()
        if paused {
            generation += 1        // drop any answer still on its way
            thinking = false
            queued = nil
            listener.stop()
            synth.stopSpeaking(at: .immediate)
        }
        listen()
    }

    private func send(_ turn: Turn) {
        if thinking { generation += 1 }   // new photo while waiting: it replaces the old request
        thinking = true            // set before stopping speech so didCancel doesn't restart the mic
        synth.stopSpeaking(at: .immediate)
        turns.append(turn)
        status = "Thinking… (you can keep talking)"
        heard = ""
        listener.start()           // keep listening while the AI works (nothing is speaking, so no echo)
        let gen = generation
        let history = turns
        let provider = Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .gemini
        Task {
            var turn = turn, history = history, reply = ""
            for attempt in 0..<2 {
                do {
                    switch provider {
                    case .gemini:
                        reply = try await AI.gemini(history: history,
                                                    key: defaults.string(forKey: "geminiKey") ?? "",
                                                    model: defaults.string(forKey: "geminiModel") ?? "gemini-3.6-flash")
                    case .claude:
                        let (r, s) = try await AI.claude(turn: turn, session: claudeSession,
                                                         path: defaults.string(forKey: "claudePath") ?? "")
                        reply = r
                        if gen == generation { claudeSession = s }
                    }
                } catch {
                    reply = "<speak>Oops, I couldn't get an answer. Please ask a grown-up to check.</speak><p><b>Error:</b> \(escape(error.localizedDescription))</p>"
                    break
                }
                guard gen == generation else { return }
                // Hoot asked to see her paper: photograph the desk and ask again with the photo (once only).
                guard attempt == 0, turn.image == nil, reply.contains("<look/>") else { break }
                // Only auto-photo the desk camera: never send a webcam picture of her face without a key press.
                if isDeskView, let jpg = camera.snapshotJPEG() {
                    turn.image = jpg
                    status = "📸 Looking at your paper…"
                } else {
                    turn.text += "\n(The camera can't see my paper right now.)"
                }
                guard let i = turns.firstIndex(where: { $0.id == turn.id }) else { return }
                turns[i] = turn
                history = Array(turns[...i])
            }
            if reply.contains("<look/>") {   // asked to look twice: don't loop, ask her instead
                reply = "<speak>I can't quite see it. Can you hold your paper flat under the camera, or read the question to me?</speak><p>📸 Hold your paper flat under the camera, or read the question out loud.</p>"
            }
            turns.append(Turn(role: .ai, text: reply))
            thinking = false
            if let q = queued {
                // She already asked something newer: show this answer, but go straight to her question.
                queued = nil
                send(Turn(role: .kid, text: q))
            } else {
                speak(AI.split(reply).speech)
            }
        }
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return listen() }
        listener.stop()            // mic off while talking so it doesn't hear itself
        heard = ""
        let u = AVSpeechUtterance(string: text)
        u.voice = Voices.resolve(defaults.string(forKey: "voiceID") ?? "")
        u.rate = Float(defaults.object(forKey: "rate") as? Double ?? 0.47)
        status = "Speaking…  (Stop talking to interrupt)"
        synth.speak(u)
    }

    private func listen() {
        heard = ""
        guard !paused else { status = "Stopped – press ▶️ Start when you need help"; return }
        status = "Listening… ask me a question, or press SPACE / RETURN to scan your homework"
        listener.start()
    }

    // Mic stays off while the tutor talks so it doesn't hear itself.
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        // Don't check synth.isSpeaking here: it can still read true inside this callback, which left the mic off.
        Task { @MainActor in if !self.thinking { self.listen() } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in if !self.thinking { self.listen() } }
    }
}

func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

// MARK: - Main window

enum Theme {
    static let purple = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let pink = Color(red: 0.93, green: 0.29, blue: 0.60)
    static let sunny = Color(red: 0.98, green: 0.75, blue: 0.14)
    static let orange = Color(red: 0.98, green: 0.55, blue: 0.24)
    static let mint = Color(red: 0.20, green: 0.80, blue: 0.60)
    static let coral = Color(red: 0.97, green: 0.44, blue: 0.44)
    static let sky = Color(red: 0.22, green: 0.69, blue: 0.97)
    static let ink = Color(red: 0.25, green: 0.16, blue: 0.40)
    static let background = LinearGradient(
        colors: [Color(red: 1.0, green: 0.91, blue: 0.95), Color(red: 0.92, green: 0.89, blue: 1.0), Color(red: 0.87, green: 0.95, blue: 1.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

/// Big, bouncy, colourful capsule button.
struct FunButton: ButtonStyle {
    var colors: [Color]
    var size: CGFloat = 17
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(size))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
            .shadow(color: (colors.last ?? .black).opacity(0.35), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct ContentView: View {
    @EnvironmentObject var tutor: Tutor
    @AppStorage("cameraID") private var cameraID = ""
    @State private var adjusting = false
    @State private var quad = Quad.load()
    @State private var typed = ""
    @State private var showHelp = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 16) {
            header
            HStack(alignment: .top, spacing: 20) {
                cameraColumn.frame(minWidth: 360, maxWidth: 560)
                VStack(spacing: 12) {
                    Conversation(html: page(tutor.turns, thinking: tutor.thinking, queued: tutor.queued), live: tutor.heard)
                        .background(.white, in: RoundedRectangle(cornerRadius: 26))
                        .shadow(color: Theme.purple.opacity(0.15), radius: 14, y: 6)
                    typingBox
                }
                .frame(minWidth: 440)
            }
            controls
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)        // room for the window's traffic-light buttons
        .padding(.bottom, 18)
        .background(Theme.background)
        .preferredColorScheme(.light)
        .onAppear { tutor.start() }
        .onChange(of: cameraID) { tutor.startCamera() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("🦉")
                .font(.system(size: 40))
                .frame(width: 62, height: 62)
                .background(.white, in: Circle())
                .shadow(color: Theme.purple.opacity(0.25), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Homework Helper")
                    .font(Theme.rounded(30, .heavy))
                    .foregroundStyle(LinearGradient(colors: [Theme.purple, Theme.pink], startPoint: .leading, endPoint: .trailing))
                Text("Hoot the owl · your 11+ study buddy ✨")
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.6))
            }
            Spacer()
            Menu {
                Picker("Camera", selection: $cameraID) {
                    Text("Auto – iPhone Desk View, else MacBook camera").tag("")
                    ForEach(tutor.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(tutor.cameraName, systemImage: "camera.fill").font(Theme.rounded(14, .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.white.opacity(0.8), in: Capsule())
            Button { showHelp = true } label: {
                Text("🩺").font(.system(size: 18)).frame(width: 38, height: 38).background(.white.opacity(0.8), in: Circle())
            }
            .buttonStyle(.plain)
            .help("iPhone camera check")
            .sheet(isPresented: $showHelp) { TroubleshooterView(currentCamera: tutor.cameraName) }
            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.purple)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.8), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Type a question instead of saying it. Return sends; focus then leaves the box so
    /// Space / Return scan the homework again.
    private var typingBox: some View {
        HStack(spacing: 10) {
            Text("✏️").font(.system(size: 22))
            TextField("Type your question here, then press Return…", text: $typed)
                .textFieldStyle(.plain)
                .font(Theme.rounded(19, .medium))
                .foregroundStyle(Theme.ink)
                .focused($typing)
                .onSubmit(sendTyped)
            Button(action: sendTyped) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(LinearGradient(colors: [Theme.purple, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(typed.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
        .background(.white, in: Capsule())
        .overlay(Capsule().stroke(typing ? Theme.pink : Theme.purple.opacity(0.2), lineWidth: 2))
        .shadow(color: Theme.purple.opacity(0.12), radius: 8, y: 3)
        .disabled(tutor.paused)
    }

    private func sendTyped() {
        tutor.ask(typed)
        typed = ""
        typing = false
    }

    private var cameraColumn: some View {
        VStack(spacing: 14) {
            LivePreview(store: tutor.frames, editing: adjusting ? $quad : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(6)
                .background(.white, in: RoundedRectangle(cornerRadius: 26))
                .shadow(color: Theme.purple.opacity(0.15), radius: 14, y: 6)
            if adjusting {
                Text("Drag the 4 pink dots onto the corners of your paper")
                    .font(Theme.rounded(15, .semibold)).foregroundStyle(Theme.pink)
            } else if !tutor.isDeskView {
                Label("This camera can't see your desk – pick MacBook camera in the menu", systemImage: "camera.badge.ellipsis")
                    .font(Theme.rounded(14, .semibold))
                    .foregroundStyle(Theme.orange)
            }
            if tutor.isWarping {
                HStack {
                    Button(adjusting ? "✅  Done" : "🎯  Adjust view") {
                        adjusting.toggle()
                        if !adjusting { quad.save(); tutor.camera.setQuad(quad) }
                        tutor.camera.setShowRaw(adjusting)
                    }
                    .buttonStyle(FunButton(colors: [Theme.pink, Theme.purple], size: 15))
                    if adjusting {
                        Button("↺  Reset") { quad = .standard }
                            .buttonStyle(FunButton(colors: [.gray, .gray.opacity(0.8)], size: 15))
                    }
                }
            }
            Button { tutor.capture() } label: {
                VStack(spacing: 2) {
                    Text("📸  Scan my homework").font(Theme.rounded(22, .heavy))
                    Text("or press Space / Return").font(Theme.rounded(13, .semibold)).opacity(0.85)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(FunButton(colors: [Theme.sunny, Theme.orange]))
            .disabled(tutor.paused || adjusting)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            statusPill
            Spacer()
            Button(tutor.paused ? "▶  Start" : "■  Take a break") { tutor.toggleRunning() }
                .buttonStyle(FunButton(colors: tutor.paused ? [Theme.mint, Color(red: 0.1, green: 0.65, blue: 0.5)]
                                                            : [Theme.coral, Color(red: 0.88, green: 0.3, blue: 0.4)]))
            Button("🤫  Stop talking") { tutor.stopTalking() }
                .buttonStyle(FunButton(colors: [Theme.sky, Color(red: 0.25, green: 0.5, blue: 0.95)]))
            Button("✨  New question") { tutor.newQuestion() }
                .buttonStyle(FunButton(colors: [Theme.purple, Theme.pink]))
        }
    }

    private var statusPill: some View {
        let s = tutor.status
        let (icon, color, text): (String, Color, String) =
            tutor.paused ? ("moon.zzz.fill", .gray, "Taking a break – press Start when you need me")
            : tutor.thinking && s.hasPrefix("📸") ? ("camera.fill", Theme.orange, "Let me look at your paper… 📸")
            : tutor.thinking ? ("sparkles", Theme.purple, "Hmm, let me think… (you can keep talking)")
            : s.hasPrefix("Speaking") ? ("speaker.wave.2.fill", Theme.sky, "Talking…")
            : s.hasPrefix("Listening") ? ("mic.fill", Theme.mint, "I'm listening! Ask me anything")
            : s.hasPrefix("Camera") ? ("exclamationmark.triangle.fill", Theme.orange, s)
            : ("hourglass", Theme.purple, "Getting ready…")
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(color, in: Circle())
                .symbolEffect(.pulse, isActive: !tutor.paused)
            Text(text)
                .font(Theme.rounded(16, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .padding(.leading, 6).padding(.trailing, 16).padding(.vertical, 6)
        .background(.white.opacity(0.85), in: Capsule())
    }

    private func page(_ turns: [Turn], thinking: Bool, queued: String?) -> String {
        func kid(_ inner: String, extra: String = "") -> String {
            "<div class='msg kid'><span class=av>👧</span><div class='b \(extra)'>\(inner)</div></div>"
        }
        func ai(_ inner: String) -> String { "<div class='msg ai'><span class=av>🦉</span><div class=b>\(inner)</div></div>" }
        var body = turns.map { t -> String in
            switch t.role {
            case .kid:
                if let img = t.image {
                    let caption = t.text == Tutor.scanText ? "📸 Here's my homework!" : escape(t.text)   // auto-photo keeps her words
                    return kid("\(caption)<br><img src=\"data:image/jpeg;base64,\(img.base64EncodedString())\">")
                }
                return kid(escape(t.text))
            case .ai:
                return ai(AI.split(t.text).html)
            }
        }.joined()
        if thinking { body += ai("<span class=dots><i></i><i></i><i></i></span>") }
        if let queued { body += kid("\(escape(queued))<div class=note>I'll answer this next…</div>") }
        if turns.isEmpty && !thinking {
            body = """
            <div class=hint><div class=owl>🦉</div><h1>Hi there! I'm Hoot!</h1>
            <p>Put your homework on the desk in front of the MacBook and press <kbd>Space</kbd> or <kbd>Return</kbd> 📸</p>
            <p>…or just ask me a question out loud! 🎤</p></div>
            """
        }
        return """
        <html><head><meta charset=utf-8><style>
        :root { color-scheme: light; }
        html, body { background: #fff; }
        body { font: 20px ui-rounded, -apple-system, sans-serif; line-height: 1.55; color: #3b2a5c; margin: 18px; padding-bottom: 30px; }
        .msg { display: flex; gap: 10px; align-items: flex-end; margin: 14px 0; }
        .msg.kid { flex-direction: row-reverse; margin-left: 12%; }
        .msg.ai { margin-right: 8%; }
        .av { font-size: 30px; width: 46px; height: 46px; flex: none; display: grid; place-items: center;
              border-radius: 50%; background: #fff; box-shadow: 0 2px 8px rgba(139,92,246,.25); }
        .b { border-radius: 22px; padding: 12px 18px; min-width: 40px; }
        .kid .b { background: linear-gradient(135deg, #ffe3f1, #ffd0e6); color: #5b1940; border-bottom-right-radius: 6px; }
        .ai .b { background: #f3eeff; border: 2px solid #e6dcff; border-bottom-left-radius: 6px; }
        .b img { display: block; max-width: 100%; max-height: 220px; border-radius: 14px; margin-top: 8px; }
        .ai h1, .ai h2, .ai h3 { color: #7c3aed; margin: 6px 0; }
        .ai b, .ai strong { color: #c026d3; }
        .ai li { margin: 4px 0; }
        .ai svg { background: #fff; border-radius: 14px; max-width: 100%; height: auto; display: block; margin: 10px 0; padding: 6px; }
        table { border-collapse: separate; border-spacing: 0; border-radius: 12px; overflow: hidden; border: 2px solid #e6dcff; background: #fff; }
        td, th { padding: 6px 12px; border-bottom: 1px solid #eee6ff; } th { background: #ebe2ff; color: #6d28d9; }
        blockquote { margin: 10px 0; padding: 8px 14px; background: #fff; border-left: 5px solid #f472b6; border-radius: 10px; font-style: italic; }
        mark { background: #fff1a8; color: inherit; padding: 0 4px; border-radius: 5px; }
        .note { font-size: 15px; font-style: italic; opacity: .7; }
        .live { font-style: italic; background: #fff !important; border: 2px dashed #f472b6; }
        .msg:has(#live:empty) { display: none; }
        .dots i { display: inline-block; width: 11px; height: 11px; margin: 4px 3px; border-radius: 50%; background: #a78bfa;
                  animation: bounce 1s infinite ease-in-out; }
        .dots i:nth-child(2) { animation-delay: .15s; background: #f472b6; } .dots i:nth-child(3) { animation-delay: .3s; background: #38bdf8; }
        @keyframes bounce { 0%, 80%, 100% { transform: translateY(0); } 40% { transform: translateY(-9px); } }
        .hint { text-align: center; margin-top: 12%; }
        .hint h1 { color: #7c3aed; font-size: 34px; margin: 8px 0 14px; }
        .hint p { font-size: 21px; color: #6b5a8e; margin: 8px; }
        .owl { font-size: 96px; animation: float 3s infinite ease-in-out; }
        @keyframes float { 0%, 100% { transform: translateY(0) rotate(-4deg); } 50% { transform: translateY(-12px) rotate(4deg); } }
        kbd { font: inherit; font-weight: 700; background: #fff7d6; border: 2px solid #fbbf24; border-radius: 8px; padding: 0 8px; color: #b45309; }
        </style></head><body>\(body)<div class='msg kid'><span class=av>🎤</span><div id=live class='b live'></div></div></body></html>
        """
    }
}

struct Conversation: NSViewRepresentable {
    let html: String
    let live: String   // words she's saying right now, updated in place (no page reload)

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false   // model output is untrusted
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.wantsLayer = true
        v.layer?.cornerRadius = 26
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        let c = context.coordinator
        c.live = live
        if c.last != html {
            c.last = html
            v.loadHTMLString(html, baseURL: nil)   // didFinish fills in the live text
        } else {
            c.showLive(v)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var last = ""
        var live = ""
        func showLive(_ w: WKWebView) {
            w.callAsyncJavaScript("document.getElementById('live').textContent = t; window.scrollTo(0, document.body.scrollHeight)",
                                  arguments: ["t": live], in: nil, in: .page)
        }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { showLive(w) }
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(a.navigationType == .other ? .allow : .cancel)   // no clicking away
        }
    }
}

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @AppStorage("provider") private var provider = Provider.gemini.rawValue
    @AppStorage("geminiKey") private var geminiKey = ""
    @AppStorage("geminiModel") private var geminiModel = "gemini-3.6-flash"
    @AppStorage("geminiFallbacks") private var geminiFallbacks = AI.defaultFallbacks
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("voiceID") private var voiceID = ""
    @AppStorage("rate") private var rate = 0.47
    @AppStorage("cameraID") private var cameraID = ""
    @State private var synth = AVSpeechSynthesizer()

    var body: some View {
        Form {
            Section("AI") {
                Picker("Provider", selection: $provider) {
                    ForEach(Provider.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                if provider == Provider.gemini.rawValue {
                    // ponytail: key kept in app preferences (user-only readable); move to Keychain if the Mac is shared.
                    SecureField("Gemini API key", text: $geminiKey)
                    TextField("Gemini model", text: $geminiModel)
                    TextField("Backup models", text: $geminiFallbacks)
                    Text("If the model is busy or slow (12 s), Hoot also asks the next backup and uses whichever answers first. Busy models are skipped for 10 minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("claude CLI path", text: $claudePath, prompt: Text(AI.findClaude() ?? "/path/to/claude"))
                    Text("Uses your Claude Code login. Leave empty to auto-detect.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Voice") {
                Picker("Voice", selection: $voiceID) {
                    Text("Default – Serena (Premium)").tag("")
                    ForEach(Voices.english(), id: \.identifier) { Text(Voices.label($0)).tag($0.identifier) }
                }
                Slider(value: $rate, in: 0.3...0.6) { Text("Speed") }
                Button("Test voice") {
                    let u = AVSpeechUtterance(string: "Hello! Let's work through this maths problem together, step by step.")
                    u.voice = Voices.resolve(voiceID)
                    u.rate = Float(rate)
                    synth.stopSpeaking(at: .immediate)
                    synth.speak(u)
                }
                Text("Premium voices: System Settings › Accessibility › Spoken Content › System Voice › Manage Voices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Camera") {
                Picker("Camera", selection: $cameraID) {
                    Text("Auto – iPhone Desk View, else MacBook camera").tag("")
                    ForEach(Camera.devices(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical)
    }
}
