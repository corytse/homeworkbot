import AVFoundation
import CoreImage
import Speech
import SwiftUI

// MARK: - Camera (Continuity Camera / Desk View)

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private(set) var deviceName = "No camera"
    var onDevice: (String, Bool) -> Void = { _, _ in }   // (name, isDeskView), on main

    static func devices() -> [AVCaptureDevice] { discovery().devices }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        .init(deviceTypes: [.deskViewCamera, .continuityCamera, .external, .builtInWideAngleCamera],
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

    /// Picks the saved camera, else iPhone Desk View (top-down view of the table), else iPhone camera, else anything.
    func start(preferredID: String) {
        let all = Self.devices()
        let device = all.first { $0.uniqueID == preferredID }
            ?? all.first { $0.deviceType == .deskViewCamera }
            ?? all.first { $0.deviceType == .continuityCamera }
            ?? all.first
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
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            let name = deviceName, isDesk = device?.deviceType == .deskViewCamera
            DispatchQueue.main.async { self.onDevice(name, isDesk) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = buf; lock.unlock()
    }

    /// Latest frame as JPEG, longest side capped at 1600px to keep API uploads small.
    func snapshotJPEG() -> Data? {
        lock.lock(); let buf = latest; lock.unlock()
        guard let buf else { return nil }
        var img = CIImage(cvPixelBuffer: buf)
        let scale = min(1, 1600 / max(img.extent.width, img.extent.height))
        img = img.transformed(by: .init(scaleX: scale, y: scale))
        return CIContext().jpegRepresentation(of: img, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect   // show the whole frame: what she sees is what gets scanned
        layer.backgroundColor = NSColor.black.cgColor
        layer.cornerRadius = 20
        layer.masksToBounds = true
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Listener (continuous mic → text, one utterance at a time)

final class Listener {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var text = ""
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
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); return }
        request = req
        text = ""
        active = true
        session += 1
        let mine = session
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                // Late results from an earlier (stopped) session must not leak into this one.
                guard let self, self.active, self.session == mine else { return }
                if let result {
                    self.text = result.bestTranscription.formattedString
                    self.onPartial(self.text)
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceSeconds, repeats: false) { _ in self.finish() }
                }
                if error != nil, result == nil {
                    // Recognizer timed out / hiccupped with nothing heard: just listen again.
                    self.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
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
        request?.endAudio()
        task?.cancel()
        request = nil
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
