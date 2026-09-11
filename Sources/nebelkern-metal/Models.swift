// ─────────────────────────────────────────────────────────────────────────────
// Models.swift — Swift data structures matching Metal Shading Language layout
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import simd

// Memory layout matches MSL Particle struct with 16-byte alignment
public struct Particle {
    public var position:     simd_float3  // 12 bytes
    public var basePosition: simd_float3  // 12 bytes
    public var velocity:     simd_float3  // 12 bytes
    public var scale:        Float        // 4 bytes
    public var luminance:    Float        // 4 bytes
    public var seed:         Float        // 4 bytes
    public var padding:      Float = 0    // 4 bytes to maintain clean alignment

    public init(
        position: simd_float3,
        basePosition: simd_float3,
        scale: Float,
        luminance: Float,
        seed: Float
    ) {
        self.position = position
        self.basePosition = basePosition
        self.velocity = simd_float3(0, 0, 0)
        self.scale = scale
        self.luminance = luminance
        self.seed = seed
    }
}

// Memory layout matches MSL Uniforms struct
public struct Uniforms {
    public var time:          Float
    public var dispersion:    Float
    public var noiseScale:    Float
    public var noiseSpeed:    Float
    public var trailDamp:     Float
    public var peakLuminance: Float
    public var colorCore:     simd_float3
    public var colorMid:      simd_float3
    public var colorOuter:    simd_float3
    public var viewportSize:  simd_float2

    public init(
        time: Float = 0,
        dispersion: Float = 1.0,
        noiseScale: Float = 1.2,
        noiseSpeed: Float = 0.5,
        trailDamp: Float = 0.88,
        peakLuminance: Float = 1.5,
        colorCore: simd_float3 = simd_float3(0.88, 0.94, 1.0),
        colorMid: simd_float3 = simd_float3(0.22, 0.74, 0.97),
        colorOuter: simd_float3 = simd_float3(0.12, 0.23, 0.54),
        viewportSize: simd_float2 = simd_float2(1920, 1080)
    ) {
        self.time = time
        self.dispersion = dispersion
        self.noiseScale = noiseScale
        self.noiseSpeed = noiseSpeed
        self.trailDamp = trailDamp
        self.peakLuminance = peakLuminance
        self.colorCore = colorCore
        self.colorMid = colorMid
        self.colorOuter = colorOuter
        self.viewportSize = viewportSize
    }
}

// ── Palettes ─────────────────────────────────────────────────────────────────

public struct MetalPalette: Identifiable {
    public var id: String { name }
    public let name: String
    public let core: simd_float3
    public let mid: simd_float3
    public let outer: simd_float3
    public let bg: (Float, Float, Float)

    public static let cosmicBlue = MetalPalette(
        name: "Cosmic Blue",
        core: simd_float3(0.88, 0.94, 1.00),
        mid: simd_float3(0.22, 0.74, 0.97),
        outer: simd_float3(0.12, 0.23, 0.54),
        bg: (0.02, 0.05, 0.08)
    )

    public static let etherealGold = MetalPalette(
        name: "Ethereal Gold",
        core: simd_float3(1.00, 0.98, 0.92),
        mid: simd_float3(0.98, 0.75, 0.14),
        outer: simd_float3(0.47, 0.21, 0.06),
        bg: (0.05, 0.03, 0.00)
    )

    public static let midnightViolet = MetalPalette(
        name: "Midnight Violet",
        core: simd_float3(0.99, 0.96, 1.00),
        mid: simd_float3(0.75, 0.52, 0.99),
        outer: simd_float3(0.23, 0.03, 0.39),
        bg: (0.03, 0.04, 0.07)
    )

    public static let aurora = MetalPalette(
        name: "Aurora",
        core: simd_float3(0.92, 0.99, 0.96),
        mid: simd_float3(0.20, 0.83, 0.60),
        outer: simd_float3(0.02, 0.31, 0.23),
        bg: (0.00, 0.05, 0.03)
    )

    public static let all: [MetalPalette] = [.cosmicBlue, .etherealGold, .midnightViolet, .aurora]
}

// ── Parametric Humanoid Silhouette Generator ─────────────────────────────────

public func generateSilhouetteParticles(count: Int) -> [Particle] {
    var particles = [Particle]()
    particles.reserveCapacity(count)

    for i in 0..<count {
        let u = Float.random(in: 0...1)
        var x: Float = 0
        var y: Float = 0

        if u < 0.12 { // Head
            let r = sqrt(Float.random(in: 0...1)) * 0.22
            let theta = Float.random(in: 0...(2 * .pi))
            x = r * cos(theta)
            y = 0.90 + r * sin(theta)
        } else if u < 0.15 { // Neck
            x = (Float.random(in: 0...1) - 0.5) * 0.12
            y = 0.65 + Float.random(in: 0...1) * 0.12
        } else if u < 0.40 { // Shoulders & Torso
            let h = Float.random(in: 0...1)
            let span = 0.45 * sin(h * .pi * 0.5 + .pi * 0.25)
            x = (Float.random(in: 0...1) - 0.5) * span * 2.0
            y = 0.30 + h * 0.35
        } else if u < 0.62 { // Hips
            let h = Float.random(in: 0...1)
            let span = 0.22 + h * 0.08
            x = (Float.random(in: 0...1) - 0.5) * span * 2.0
            y = -0.10 + h * 0.40
        } else if u < 0.76 { // Arms
            let side: Float = Bool.random() ? 1.0 : -1.0
            let prog = Float.random(in: 0...1)
            x = side * (0.40 + prog * 0.18)
            y = 0.45 - prog * 0.55
        } else { // Legs
            let leg: Float = Bool.random() ? 0.12 : -0.12
            let prog = Float.random(in: 0...1)
            let spread = 0.08 + prog * 0.15
            x = leg + (Float.random(in: 0...1) - 0.5) * spread
            y = -0.30 - prog * 0.75
        }

        let z = (Float.random(in: 0...1) - 0.5) * 0.08
        let dist = sqrt(x * x + y * y)
        let lum = max(0, 1.0 - dist * 1.2)
        let finalLum = lum * lum + Float.random(in: 0...0.15)
        let scale = 0.8 + finalLum * 1.8 + Float.random(in: 0...0.6)

        let p = Particle(
            position: simd_float3(x, y, z),
            basePosition: simd_float3(x, y, z),
            scale: scale,
            luminance: finalLum,
            seed: Float(i) / Float(count)
        )
        particles.append(p)
    }

    return particles
}
