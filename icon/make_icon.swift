// Draws the app icon. Run: swift icon/make_icon.swift  (writes icon/AppIcon.png, 1024x1024)
import AppKit
import SwiftUI

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS icon shape: rounded square inset from the 1024 canvas
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 0.96),
                                              Color(red: 0.93, green: 0.29, blue: 0.60),
                                              Color(red: 0.99, green: 0.62, blue: 0.25)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(  // soft top shine
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 12)

            // glowing circle behind the owl
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.95), .white.opacity(0.0)], center: .center, startRadius: 40, endRadius: 330))
                .frame(width: 640, height: 640)
                .offset(y: 30)

            Text("🦉").font(.system(size: 430)).offset(y: 70)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 14)
            Text("🎓").font(.system(size: 250)).rotationEffect(.degrees(-12)).offset(x: -5, y: -178)

            Text("✨").font(.system(size: 120)).offset(x: 285, y: -275)
            Text("✏️").font(.system(size: 150)).rotationEffect(.degrees(10)).offset(x: -280, y: 255)

            // "11+" badge
            Text("11+")
                .font(.system(size: 92, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.2, blue: 0.85))
                .frame(width: 210, height: 210)
                .background(Circle().fill(Color(red: 1, green: 0.84, blue: 0.2)))
                .overlay(Circle().stroke(.white, lineWidth: 14))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                .rotationEffect(.degrees(-10))
                .offset(x: 270, y: 265)
        }
        .frame(width: 1024, height: 1024)
    }
}

MainActor.assumeIsolated {
    let r = ImageRenderer(content: Icon())
    r.scale = 1
    guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { fatalError("render failed") }
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icon/AppIcon.png")
    try! png.write(to: out)
    print("wrote \(out.path)")
}
