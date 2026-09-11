// ─────────────────────────────────────────────────────────────────────────────
// main.swift — Native macOS AppKit Entry Point for nebelkern-metal
//
// Features:
// - MTKView Metal Render Loop backed by Apple Silicon GPU
// - True HDR / Extended Dynamic Range (EDR) rendering
// - Wallpaper Mode: renders behind desktop icons via NSWindow.Level.belowNormal
// - Floating translucent HUD control panel
// ─────────────────────────────────────────────────────────────────────────────

import Cocoa
import MetalKit
import SwiftUI

// ── SwiftUI Control HUD ──────────────────────────────────────────────────────

struct ControlHUDView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("✦ nebelkern [metal]")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.58, green: 0.77, blue: 1.0))
                Spacer()
                Button(action: { state.isWallpaperMode.toggle() }) {
                    Text(state.isWallpaperMode ? "Desktop Mode" : "Window Mode")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(state.isWallpaperMode ? Color.blue.opacity(0.3) : Color.white.opacity(0.1))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            Divider().background(Color.white.opacity(0.1))

            // Dispersion
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Dispersion")
                    Spacer()
                    Text(String(format: "%.2f", state.dispersion))
                        .foregroundColor(.blue)
                }
                .font(.system(size: 11, design: .monospaced))
                Slider(value: $state.dispersion, in: 0.0...3.0)
            }

            // Curl Noise Scale
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Noise Scale")
                    Spacer()
                    Text(String(format: "%.2f", state.noiseScale))
                        .foregroundColor(.blue)
                }
                .font(.system(size: 11, design: .monospaced))
                Slider(value: $state.noiseScale, in: 0.2...4.0)
            }

            // Curl Noise Speed
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Noise Speed")
                    Spacer()
                    Text(String(format: "%.2f", state.noiseSpeed))
                        .foregroundColor(.blue)
                }
                .font(.system(size: 11, design: .monospaced))
                Slider(value: $state.noiseSpeed, in: 0.0...3.0)
            }

            // HDR / EDR Peak Luminance (Apple Silicon Liquid Retina XDR)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("HDR EDR Luminance")
                    Spacer()
                    Text(String(format: "%.1fx", state.peakLuminance))
                        .foregroundColor(.yellow)
                }
                .font(.system(size: 11, design: .monospaced))
                Slider(value: $state.peakLuminance, in: 1.0...3.0)
            }

            // Particle Count Picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Particle Density")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Picker("", selection: $state.particleCount) {
                    Text("10k").tag(10000)
                    Text("20k").tag(20000)
                    Text("40k").tag(40000)
                }
                .pickerStyle(.segmented)
            }

            // Palettes
            VStack(alignment: .leading, spacing: 6) {
                Text("Palette")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    ForEach(MetalPalette.all) { palette in
                        Button(action: { state.currentPalette = palette }) {
                            Text(palette.name)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(
                                    state.currentPalette.name == palette.name
                                        ? Color.white.opacity(0.2)
                                        : Color.white.opacity(0.05)
                                )
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(
                                            state.currentPalette.name == palette.name
                                                ? Color.blue.opacity(0.8)
                                                : Color.clear,
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 290)
        .background(VisualEffectView().ignoresSafeArea())
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.6), radius: 24, x: 0, y: 12)
    }
}

final class AppState: ObservableObject {
    @Published var dispersion: Float = 1.0
    @Published var noiseScale: Float = 1.2
    @Published var noiseSpeed: Float = 0.5
    @Published var peakLuminance: Float = 1.8
    @Published var particleCount: Int = 20000
    @Published var currentPalette: MetalPalette = .cosmicBlue
    @Published var isWallpaperMode: Bool = false
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// ── Application Delegate & Window Setup ──────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var hudWindow: NSWindow!
    var mtkView: MTKView!
    var renderer: MetalRenderer!
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Setup Metal Render Window
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let windowStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: windowStyle,
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "✦ nebelkern [Metal Engine]"
        window.backgroundColor = .black

        // Setup MTKView
        mtkView = MTKView(frame: window.contentView!.bounds)
        mtkView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(mtkView)

        guard let r = MetalRenderer(metalView: mtkView) else {
            fatalError("Metal is not supported on this device")
        }
        self.renderer = r

        // 2. Setup Floating HUD Window
        let hudView = ControlHUDView(state: state)
        let hostingController = NSHostingController(rootView: hudView)

        hudWindow = NSWindow(contentViewController: hostingController)
        hudWindow.styleMask = [.borderless, .nonactivatingPanel]
        hudWindow.isOpaque = false
        hudWindow.backgroundColor = .clear
        hudWindow.level = .floating
        hudWindow.setFrameOrigin(NSPoint(x: window.frame.maxX - 320, y: window.frame.maxY - 460))
        hudWindow.orderFront(nil)

        // 3. Bind State to Renderer
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.renderer.uniforms.dispersion = self.state.dispersion
            self.renderer.uniforms.noiseScale = self.state.noiseScale
            self.renderer.uniforms.noiseSpeed = self.state.noiseSpeed
            self.renderer.uniforms.peakLuminance = self.state.peakLuminance
            if self.renderer.particleCount != self.state.particleCount {
                self.renderer.particleCount = self.state.particleCount
            }
            if self.renderer.currentPalette.name != self.state.currentPalette.name {
                self.renderer.currentPalette = self.state.currentPalette
            }

            // Handle Wallpaper Mode Toggle
            if self.state.isWallpaperMode {
                self.window.level = .init(Int(CGWindowLevelForKey(.desktopWindow)))
                self.window.styleMask = [.borderless]
                self.window.setFrame(NSScreen.main?.frame ?? screenRect, display: true)
            } else {
                self.window.level = .normal
                self.window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// ── Entry Point ──────────────────────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
