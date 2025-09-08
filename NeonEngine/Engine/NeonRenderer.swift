//
//  NeonRenderer.swift
//  NeonLightsTestApp
//

import Metal
import MetalKit
import simd

public struct StrokeVertex {
    public var pos: SIMD2<Float>   // pixel-space positions from SwiftSVG
    public var edgeDist: Float
    public init(_ pos: SIMD2<Float>, edgeDist: Float) {
        self.pos = pos; self.edgeDist = edgeDist
    }
}

public struct NeonSettings {
    public var color: SIMD3<Float> = SIMD3(0, 1, 1)   // cyan
    public init() {}
}

// Must match the struct used in your Metal vertex shader
struct ViewUniforms {
    var vpSize: SIMD2<Float>   // viewport size in pixels
    var offset: SIMD2<Float>   // pixel offset AFTER scaling
    var scale: Float
    var _pad: Float = 0
}

public final class NeonRenderer: NSObject, MTKViewDelegate {

    // MARK: Metal objects
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var library: MTLLibrary!

    // Pipelines
    private var strokePSO: MTLRenderPipelineState!          // stroke -> RGBA16F offscreen
    private var strokeToScreenPSO: MTLRenderPipelineState!  // debug: stroke -> screen
    private var compositePSO: MTLRenderPipelineState!       // fullscreen composite
    private var blurCS: MTLComputePipelineState!            // simple blur (optional)

    // Mesh
    private var vbuf: MTLBuffer?
    private var ibuf: MTLBuffer?
    private var indexCount = 0

    // Offscreen textures
    private var strokeTex: MTLTexture!
    private var glowTex: MTLTexture!

    // Settings
    private var settings = NeonSettings()

    // Formats
    private var screenPixelFormat: MTLPixelFormat = .bgra8Unorm

    // Debug toggles
    private let DEBUG_BYPASS_COMPOSITE = false     // true → draw stroke directly to screen
    // When false the stroke is blurred and composited to create a glow
    private let DEBUG_SKIP_BLUR = false            // true → composite stroke directly (no blur)

    // Content bounds (in pixel space of incoming geometry)
    private var contentMin = SIMD2<Float>(0, 0)
    private var contentMax = SIMD2<Float>(1, 1)
    private var userScale: Float = 1.0   // expose later for zoom if you want

    public func updateContentBounds(min: SIMD2<Float>, max: SIMD2<Float>) {
        contentMin = min
        contentMax = max
    }

    // MARK: Init

    public init(device: MTLDevice, screenPixelFormat: MTLPixelFormat = .bgra8Unorm) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.screenPixelFormat = screenPixelFormat
        super.init()
        self.library = try! NeonRenderer.loadMetalLibrary(device: device)
        buildPipelines()
    }

    public func configure(view: MTKView) {
        view.device = device
        view.colorPixelFormat = screenPixelFormat
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 120
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = self
    }

    // MARK: Public API

    public func updateMesh(vertices: [StrokeVertex], indices: [UInt16]) {
        indexCount = indices.count
        guard indexCount > 0, !vertices.isEmpty else {
            vbuf = nil; ibuf = nil; indexCount = 0
            print("⚠️ Empty mesh")
            return
        }

        vbuf = device.makeBuffer(bytes: vertices,
                                 length: MemoryLayout<StrokeVertex>.stride * vertices.count,
                                 options: .storageModeShared)

        ibuf = device.makeBuffer(bytes: indices,
                                 length: MemoryLayout<UInt16>.stride * indices.count,
                                 options: .storageModeShared)

        print("✅ Mesh uploaded: \(vertices.count) verts, \(indices.count) indices")
    }

    public func update(settings: NeonSettings) { self.settings = settings }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        allocateOffscreen(size: size)
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer()
        else { return }

        // Ensure offscreen targets exist and match drawable size
        let size = view.drawableSize
        if strokeTex == nil || glowTex == nil ||
            strokeTex.width != Int(size.width) || strokeTex.height != Int(size.height) {
            allocateOffscreen(size: size)
        }

        guard let vbuf, let ibuf, indexCount > 0 else {
            // Nothing to draw; just clear screen
            if let rpd = view.currentRenderPassDescriptor {
                let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
                enc.endEncoding()
            }
            cmd.present(drawable)
            cmd.commit()
            return
        }

        // Precompute uniforms (center + fit with margin) for both paths
        func makeUniforms(vpW: Float, vpH: Float) -> ViewUniforms {
            let sx = max(contentMax.x - contentMin.x, 1e-6)
            let sy = max(contentMax.y - contentMin.y, 1e-6)
            let contentSize = SIMD2<Float>(sx, sy)
            let scaleFit = min(vpW / contentSize.x, vpH / contentSize.y) * 0.9 // 90% to leave margin
            let scale = scaleFit * userScale
            let scaledSize = contentSize * scale
            let topLeft = SIMD2<Float>((vpW - scaledSize.x) * 0.5,
                                       (vpH - scaledSize.y) * 0.5) - contentMin * scale
            return ViewUniforms(vpSize: SIMD2<Float>(vpW, vpH),
                                offset: topLeft,
                                scale: scale,
                                _pad: 0)
        }

        // DEBUG: draw stroke straight to screen (skip offscreen/blur/composite)
        if DEBUG_BYPASS_COMPOSITE {
            if let rpd = view.currentRenderPassDescriptor {
                let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
                enc.setRenderPipelineState(strokeToScreenPSO)
                enc.setVertexBuffer(vbuf, offset: 0, index: 0)

                var U = makeUniforms(vpW: Float(size.width), vpH: Float(size.height))
                enc.setVertexBytes(&U, length: MemoryLayout<ViewUniforms>.stride, index: 1)

                var color = settings.color
                enc.setFragmentBytes(&color, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)

                enc.drawIndexedPrimitives(type: .triangle,
                                          indexCount: indexCount,
                                          indexType: .uint16,
                                          indexBuffer: ibuf,
                                          indexBufferOffset: 0)
                enc.endEncoding()
            }
            cmd.present(drawable)
            cmd.commit()
            return
        }

        // Pass 1: Stroke -> offscreen (RGBA16F)
        do {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = strokeTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

            let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
            enc.setRenderPipelineState(strokePSO)
            enc.setVertexBuffer(vbuf, offset: 0, index: 0)

            var U = makeUniforms(vpW: Float(strokeTex.width), vpH: Float(strokeTex.height))
            enc.setVertexBytes(&U, length: MemoryLayout<ViewUniforms>.stride, index: 1)

            var color = settings.color
            enc.setFragmentBytes(&color, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)

            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: indexCount,
                                      indexType: .uint16,
                                      indexBuffer: ibuf,
                                      indexBufferOffset: 0)
            enc.endEncoding()
        }

        // Pass 2: Blur strokeTex -> glowTex (optional)
        if !DEBUG_SKIP_BLUR {
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(blurCS)
            enc.setTexture(strokeTex, index: 0)
            enc.setTexture(glowTex,   index: 1)
            let w = blurCS.threadExecutionWidth
            let h = max(1, blurCS.maxTotalThreadsPerThreadgroup / w)
            let tg = MTLSize(width: w, height: h, depth: 1)
            let ng = MTLSize(width: (glowTex.width  + w - 1) / w,
                             height:(glowTex.height + h - 1) / h,
                             depth: 1)
            enc.dispatchThreadgroups(ng, threadsPerThreadgroup: tg)
            enc.endEncoding()
        } else {
            // Reuse stroke as glow to prove composite path works
            glowTex = strokeTex
        }

        // Pass 3: Composite -> screen
        if let rpd = view.currentRenderPassDescriptor {
            let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
            enc.setRenderPipelineState(compositePSO)
            enc.setFragmentTexture(strokeTex, index: 0)
            enc.setFragmentTexture(glowTex,   index: 1)
            // Fullscreen triangle (generated in fullscreen_vs)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: Private

    private func buildPipelines() {
        // Stroke -> offscreen RGBA16F
        let strokeDesc = MTLRenderPipelineDescriptor()
        strokeDesc.vertexFunction   = library.makeFunction(name: "stroke_vs")
        strokeDesc.fragmentFunction = library.makeFunction(name: "stroke_fs")
        strokeDesc.colorAttachments[0].pixelFormat = .rgba16Float
        let layout = MTLVertexDescriptor()
        layout.attributes[0].format = .float2
        layout.attributes[0].offset = 0
        layout.attributes[0].bufferIndex = 0
        layout.attributes[1].format = .float
        layout.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        layout.attributes[1].bufferIndex = 0
        layout.layouts[0].stride = MemoryLayout<StrokeVertex>.stride
        strokeDesc.vertexDescriptor = layout
        strokePSO = try! device.makeRenderPipelineState(descriptor: strokeDesc)

        // Stroke -> SCREEN (debug)
        let strokeScreen = MTLRenderPipelineDescriptor()
        strokeScreen.vertexFunction   = library.makeFunction(name: "stroke_vs")
        strokeScreen.fragmentFunction = library.makeFunction(name: "stroke_fs")
        strokeScreen.colorAttachments[0].pixelFormat = screenPixelFormat
        strokeScreen.vertexDescriptor = layout
        strokeToScreenPSO = try! device.makeRenderPipelineState(descriptor: strokeScreen)

        // Composite -> screen
        let compDesc = MTLRenderPipelineDescriptor()
        compDesc.vertexFunction   = library.makeFunction(name: "fullscreen_vs")
        compDesc.fragmentFunction = library.makeFunction(name: "composite_fs")
        compDesc.colorAttachments[0].pixelFormat = screenPixelFormat
        compositePSO = try! device.makeRenderPipelineState(descriptor: compDesc)

        // Simple blur
        blurCS = try! device.makeComputePipelineState(function: library.makeFunction(name: "blur_simple")!)

        // Sanity
        assert(library.makeFunction(name: "stroke_vs") != nil)
        assert(library.makeFunction(name: "composite_fs") != nil)
    }

    private func allocateOffscreen(size: CGSize) {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .private
        strokeTex = device.makeTexture(descriptor: desc)
        glowTex   = device.makeTexture(descriptor: desc)
        // Debug log
        print("🔧 Offscreen resized: \(w)x\(h)")
    }

    private static func loadMetalLibrary(device: MTLDevice) throws -> MTLLibrary {
        // Try the framework bundle first (if this class is in a framework)
        let bundle = Bundle(for: NeonRenderer.self)
        if let lib = try? device.makeDefaultLibrary(bundle: bundle),
           lib.makeFunction(name: "stroke_vs") != nil { return lib }
        // App bundle
        if let lib = try? device.makeDefaultLibrary(bundle: .main),
           lib.makeFunction(name: "stroke_vs") != nil { return lib }
        // Default
        if let lib = try? device.makeDefaultLibrary(),
           lib.makeFunction(name: "stroke_vs") != nil { return lib }
        fatalError("No Metal library with 'stroke_vs' found — check target membership of .metal file.")
    }
}
