import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Speech
import SwiftUI

// MARK: - Camera (MacBook webcam with software bird's-eye view, or iPhone Desk View)

/// Where the paper's four corners are in the raw webcam picture (0…1, origin top-left).
/// The webcam looks across the desk from the top of the screen, so the paper shows up as a
/// trapezoid in the bottom of the frame; warping this quad to a rectangle gives a top-down view.
struct Quad: Codable, Equatable {
    var tl, tr, br, bl: CGPoint
    static let corners: [WritableKeyPath<Quad, CGPoint>] = [\.tl, \.tr, \.br, \.bl]
    // Rough guess for a screen tilted ~10° forward; fine-tune with "Adjust view".
    static let standard = Quad(tl: .init(x: 0.25, y: 0.50), tr: .init(x: 0.75, y: 0.50),
                               br: .init(x: 0.97, y: 0.98), bl: .init(x: 0.03, y: 0.98))
    /// Each camera has its own corners (different mount, angle and lens).
    static func load(for camera: String) -> Quad {
        let d = UserDefaults.standard
        let data = d.data(forKey: "paperQuad.\(camera)") ?? d.data(forKey: "paperQuad")   // older single setting
        return data.flatMap { try? JSONDecoder().decode(Quad.self, from: $0) } ?? .standard
    }
    func save(for camera: String) { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "paperQuad.\(camera)") }

    /// Perspective-corrects the quad into an upright A4-shaped page, then turns it round 180°
    /// so the writing faces the right way (the camera sees the paper from the far side).
    func birdsEye(_ img: CIImage, width: CGFloat) -> CIImage {
        let w = img.extent.width, h = img.extent.height
        func p(_ q: CGPoint) -> CGPoint { CGPoint(x: img.extent.minX + q.x * w, y: img.extent.minY + (1 - q.y) * h) }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = img
        f.topLeft = p(tl); f.topRight = p(tr); f.bottomRight = p(br); f.bottomLeft = p(bl)
        guard var out = f.outputImage, out.extent.width > 1, out.extent.height > 1 else { return img }
        out = out.transformed(by: .init(translationX: -out.extent.minX, y: -out.extent.minY))
        out = out.transformed(by: .init(scaleX: width / out.extent.width, y: width * 1.414 / out.extent.height))
        return out.oriented(.down)
    }
}

/// Latest preview frame, kept apart from the rest of the UI so 15 fps doesn't redraw the chat.
final class FrameStore: ObservableObject { @Published var image: CGImage? }

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera")
    private let ctx = CIContext()
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var quad = Quad.standard
    private var deviceID = ""
    private var warping = false      // true for the MacBook webcam
    private var showRaw = false      // true while she's dragging the corners
    private var lastPreview = 0.0
    private(set) var deviceName = "No camera"
    var onDevice: (_ name: String, _ seesDesk: Bool, _ warping: Bool) -> Void = { _, _, _ in }   // on main
    var onFrame: (CGImage) -> Void = { _ in }                                                    // on main

    static func devices() -> [AVCaptureDevice] { discovery().devices }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        .init(deviceTypes: [.builtInWideAngleCamera, .deskViewCamera, .continuityCamera, .external],
              mediaType: .video, position: .unspecified)
    }

    // The iPhone connects wirelessly a few seconds after an app starts looking for it, so keep a
    // live discovery session and react whenever its device list changes.
    private let live = Camera.discovery()
    private var kvo: NSKeyValueObservation?
    func watch(_ onChange: @escaping ([AVCaptureDevice]) -> Void) {
        kvo = live.observe(\.devices, options: [.initial, .new]) { d, _ in
            DispatchQueue.main.async { onChange(d.devices) }
        }
    }

    func currentQuad() -> Quad { lock.lock(); defer { lock.unlock() }; return quad }
    func setQuad(_ q: Quad) {
        lock.lock(); quad = q; let id = deviceID; lock.unlock()
        q.save(for: id)
    }
    func setShowRaw(_ on: Bool) { lock.lock(); showRaw = on; lock.unlock() }

    /// Picks the saved camera, else iPhone Desk View, else a USB webcam, else the MacBook webcam, else anything.
    /// USB and MacBook webcams get the software bird's-eye view.
    /// Called again whenever cameras come or go, so it follows the iPhone connecting and dropping out.
    func start(preferredID: String) {
        let all = Self.devices()
        let device = all.first { $0.uniqueID == preferredID }
            ?? all.first { $0.deviceType == .deskViewCamera }
            ?? all.first { $0.deviceType == .external }
            ?? all.first { $0.deviceType == .builtInWideAngleCamera }
            ?? all.first
        let warp = device?.deviceType == .builtInWideAngleCamera || device?.deviceType == .external
        queue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                deviceName = device.localizedName
            }
            if session.outputs.isEmpty {
                output.setSampleBufferDelegate(self, queue: queue)
                output.alwaysDiscardsLateVideoFrames = true
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            // Highest resolution the webcam offers: the paper is only part of the picture.
            let presets: [AVCaptureSession.Preset] = warp ? [.hd4K3840x2160, .hd1920x1080, .high] : [.high]
            if let p = presets.first(where: session.canSetSessionPreset) { session.sessionPreset = p }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            let id = device?.uniqueID ?? ""
            lock.lock(); warping = warp; deviceID = id; quad = Quad.load(for: id); lock.unlock()
            let name = deviceName, desk = device?.deviceType == .deskViewCamera
            DispatchQueue.main.async { self.onDevice(name, desk || warp, warp) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = buf; let q = quad, warp = warping && !showRaw; lock.unlock()
        let now = CACurrentMediaTime()
        guard now - lastPreview > 1.0 / 15 else { return }   // ponytail: 15 fps preview is plenty for paper
        lastPreview = now
        var img = CIImage(cvPixelBuffer: buf)
        img = img.transformed(by: .init(scaleX: 960 / img.extent.width, y: 960 / img.extent.width))
        if warp { img = q.birdsEye(img, width: 700) }
        guard let cg = ctx.createCGImage(img, from: img.extent) else { return }
        DispatchQueue.main.async { self.onFrame(cg) }
    }

    /// Latest frame as JPEG (bird's-eye for the webcam), longest side capped at 1600px for the API.
    func snapshotJPEG() -> Data? {
        lock.lock(); let buf = latest, q = quad, warp = warping; lock.unlock()
        guard let buf else { return nil }
        var img = CIImage(cvPixelBuffer: buf)
        if warp {
            img = q.birdsEye(img, width: 1130)   // 1130 × 1600
        } else {
            let scale = min(1, 1600 / max(img.extent.width, img.extent.height))
            img = img.transformed(by: .init(scaleX: scale, y: scale))
        }
        return ctx.jpegRepresentation(of: img, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
    }
}

/// Live camera picture. While `editing` is set, shows the raw webcam view with four draggable
/// corner dots to mark where the paper is.
struct LivePreview: View {
    @ObservedObject var store: FrameStore
    var editing: Binding<Quad>?

    var body: some View {
        ZStack {
            Color.black
            if let cg = store.image {
                Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fit)
                if let editing { CornerEditor(imageSize: CGSize(width: cg.width, height: cg.height), quad: editing) }
            } else {
                ProgressView().tint(.white)
            }
        }
    }
}

struct CornerEditor: View {
    let imageSize: CGSize
    @Binding var quad: Quad

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width / imageSize.width, g.size.height / imageSize.height)
            let r = CGRect(x: (g.size.width - imageSize.width * s) / 2, y: (g.size.height - imageSize.height * s) / 2,
                           width: imageSize.width * s, height: imageSize.height * s)
            let pt = { (p: CGPoint) in CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height) }
            ZStack {
                Path { $0.addLines(Quad.corners.map { pt(quad[keyPath: $0]) }); $0.closeSubpath() }
                    .fill(Color.pink.opacity(0.15))
                    .overlay(Path { $0.addLines(Quad.corners.map { pt(quad[keyPath: $0]) }); $0.closeSubpath() }
                        .stroke(Color.pink, style: StrokeStyle(lineWidth: 3, dash: [9, 6])))
                ForEach(0..<4, id: \.self) { i in
                    let k = Quad.corners[i]
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(Color.pink, lineWidth: 4))
                        .frame(width: 28, height: 28)
                        .shadow(radius: 3)
                        .position(pt(quad[keyPath: k]))
                        .gesture(DragGesture(coordinateSpace: .named("editor")).onChanged { v in
                            quad[keyPath: k] = CGPoint(x: min(max((v.location.x - r.minX) / r.width, 0), 1),
                                                       y: min(max((v.location.y - r.minY) / r.height, 0), 1))
                        })
                }
            }
        }
        .coordinateSpace(name: "editor")
    }
}

// MARK: - Listener (continuous mic → text, one utterance at a time)

final class Listener {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var text = ""
    private var committed = ""      // words from earlier segments of the current sentence
    private let reqLock = NSLock()  // `request` is read on the audio thread
    private var active = false
    private var session = 0
    /// Seconds of silence that end a question. Raise it if she gets cut off mid-sentence.
    var silenceSeconds = 1.6
    var onPartial: (String) -> Void = { _ in }
    var onUtterance: (String) -> Void = { _ in }

    init() {
        // Mic input changed (e.g. iPhone mic connects): the engine stops silently, so restart it.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            if self?.active == true { self?.start() }
        }
    }

    func start() {
        stop()
        guard let recognizer, recognizer.isAvailable else { return }
        let input = engine.inputNode
        // The tap feeds whichever recognition request is current (segments swap it, see below).
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buf, _ in
            guard let self else { return }
            self.reqLock.lock(); let r = self.request; self.reqLock.unlock()
            r?.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); return }
        text = ""
        committed = ""
        active = true
        beginSegment()
    }

    /// On-device recognition ends a "result" at short pauses ("Hey Hoot, … what is…"). Rather than
    /// losing the rest, keep the words so far and carry on in a fresh segment; the sentence only ends
    /// after `silenceSeconds` of quiet.
    private func beginSegment() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.contextualStrings = ["Hey Hoot", "Hoot"]   // helps it hear the wake word
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        task?.cancel()
        reqLock.lock(); request = req; reqLock.unlock()
        session += 1
        let mine = session
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                // Late results from an earlier segment or stopped session must not leak in.
                guard let self, self.active, self.session == mine else { return }
                if let result {
                    let seg = result.bestTranscription.formattedString
                    self.text = [self.committed, seg].filter { !$0.isEmpty }.joined(separator: " ")
                    self.onPartial(self.text)
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceSeconds, repeats: false) { _ in self.finish() }
                    if result.isFinal { self.committed = self.text; self.beginSegment() }
                } else if error != nil {
                    if self.text.isEmpty {
                        // Timed out / hiccupped with nothing heard: just listen again.
                        self.stop()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
                    } else {
                        self.committed = self.text
                        self.beginSegment()
                    }
                }
            }
        }
    }

    private func finish() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        // Ignore one-word noise ("yeah", "um") picked up from the room; real questions are longer.
        if t.split(separator: " ").count < 2 { start() } else { onUtterance(t) }
    }

    func stop() {
        active = false
        silenceTimer?.invalidate()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        reqLock.lock(); request?.endAudio(); request = nil; reqLock.unlock()
        task?.cancel()
        task = nil
    }
}

// MARK: - Voice

enum Voices {
    static func english() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { ($0.name, $0.quality.rawValue) < ($1.name, $1.quality.rawValue) }
    }

    static func resolve(_ id: String) -> AVSpeechSynthesisVoice? {
        if let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let serena = english().filter { $0.name.hasPrefix("Serena") }
        return serena.first { $0.quality == .premium } ?? serena.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let q = [AVSpeechSynthesisVoiceQuality.premium: "Premium", .enhanced: "Enhanced"][v.quality] ?? "Default"
        return "\(v.name) (\(q)) – \(v.language)"
    }
}
