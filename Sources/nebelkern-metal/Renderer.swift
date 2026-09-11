// ─────────────────────────────────────────────────────────────────────────────
// Renderer.swift — Metal Render & Compute Pipeline Engine for nebelkern-metal
//
// - Apple Silicon Unified Memory Architecture (zero CPU-to-GPU transfer)
// - Native MSL compute shader for 3D curl noise particle advection
// - HDR / Extended Dynamic Range (EDR) rendering with peak luminance > 1.0
// - Additive blending with Gaussian optical glow
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import Metal
import MetalKit
import simd

public final class MetalRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    // Pipeline states
    private var computePipelineState: MTLComputePipelineState!
    private var renderPipelineState:  MTLRenderPipelineState!

    // GPU Buffers (Apple Silicon Shared Storage)
    private var particleBuffer: MTLBuffer!
    private var uniformsBuffer: MTLBuffer!

    // Configuration state
    public var particleCount: Int = 20000 {
        didSet {
            setupParticleBuffer()
        }
    }
    public var uniforms = Uniforms()
    public var currentPalette: MetalPalette = .cosmicBlue {
        didSet {
            uniforms.colorCore  = currentPalette.core
            uniforms.colorMid   = currentPalette.mid
            uniforms.colorOuter = currentPalette.outer
        }
    }

    private var startTime: Date = Date()

    public init?(metalView: MTKView) {
        guard let device = metalView.device ?? MTLCreateSystemDefaultDevice() else {
            return nil
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue
        super.init()

        // Configure MTKView for EDR/HDR rendering
        metalView.device = device
        metalView.colorPixelFormat = .rgba16Float // 16-bit float enables >1.0 HDR luminances
        metalView.clearColor = MTLClearColor(red: 0.02, green: 0.05, blue: 0.08, alpha: 1.0)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60

        // Enable Apple Silicon Liquid Retina Extended Dynamic Range
        if let layer = metalView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }

        setupPipelines()
        setupParticleBuffer()
        setupUniformsBuffer()
    }

    private func setupPipelines() {
        // Load shader source from package resources or bundle
        let shaderSource: String
        if let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            shaderSource = content
        } else {
            fatalError("Could not locate Shaders.metal in bundle")
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            fatalError("Failed to compile Shaders.metal at runtime: \(error)")
        }

        // 1. Setup Compute Pipeline for Particle Advection
        guard let computeFunc = library.makeFunction(name: "updateParticles") else {
            fatalError("Compute function 'updateParticles' not found")
        }
        do {
            self.computePipelineState = try device.makeComputePipelineState(function: computeFunc)
        } catch {
            fatalError("Failed to create compute pipeline state: \(error)")
        }

        // 2. Setup Render Pipeline for Gaussian Glow Points
        guard let vertexFunc = library.makeFunction(name: "particleVertex"),
              let fragmentFunc = library.makeFunction(name: "particleFragment") else {
            fatalError("Vertex or Fragment functions not found in library")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Particle Render Pipeline"
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float

        // Additive blending: particles accumulate optical brightness
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        do {
            self.renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create render pipeline state: \(error)")
        }
    }

    private func setupParticleBuffer() {
        let particles = generateSilhouetteParticles(count: particleCount)
        let size = MemoryLayout<Particle>.stride * particleCount
        // .storageModeShared: Unified Memory on Apple Silicon (zero CPU-GPU copy)
        particleBuffer = device.makeBuffer(bytes: particles, length: size, options: .storageModeShared)
    }

    private func setupUniformsBuffer() {
        let size = MemoryLayout<Uniforms>.stride
        uniformsBuffer = device.makeBuffer(length: size, options: .storageModeShared)
    }

    // ── MTKViewDelegate Callbacks ────────────────────────────────────────────

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        uniforms.viewportSize = simd_float2(Float(size.width), Float(size.height))
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // Update uniforms
        let elapsed = Float(Date().timeIntervalSince(startTime))
        uniforms.time = elapsed
        uniforms.viewportSize = simd_float2(Float(view.drawableSize.width), Float(view.drawableSize.height))

        // Update clear color to match current palette background
        let bg = currentPalette.bg
        view.clearColor = MTLClearColor(red: Double(bg.0), green: Double(bg.1), blue: Double(bg.2), alpha: 1.0)

        // Copy uniforms into GPU buffer
        uniformsBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)

        // ── Step 1: Compute Pass (Curl Noise GPU Advection) ──
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            computeEncoder.label = "Particle Physics Kernel"
            computeEncoder.setComputePipelineState(computePipelineState)
            computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            computeEncoder.setBuffer(uniformsBuffer, offset: 0, index: 1)

            let threadsPerGrid = MTLSize(width: particleCount, height: 1, depth: 1)
            let maxThreads = computePipelineState.maxTotalThreadsPerThreadgroup
            let threadsPerGroup = MTLSize(width: min(particleCount, maxThreads), height: 1, depth: 1)
            computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            computeEncoder.endEncoding()
        }

        // ── Step 2: Render Pass (Gaussian Optical Glow Points) ──
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) {
            renderEncoder.label = "Particle Gaussian Glow Draw"
            renderEncoder.setRenderPipelineState(renderPipelineState)
            renderEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
            renderEncoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 1)

            renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
            renderEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
