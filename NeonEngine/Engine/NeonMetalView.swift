//
//  NeonMetalView.swift
//  NeonLightsTestApp
//
//  Created by Aleksandr Tiulpanov on 02/09/2025.
//

import SwiftUI
import MetalKit

struct NeonMetalView: UIViewRepresentable {
    func updateUIView(_ uiView: MTKView, context: Context) {
        
    }
    
    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.colorPixelFormat = .rgba16Float
        v.framebufferOnly = false
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.preferredFramesPerSecond = 120
//        v.delegate = context.coordinator.renderer
        return v
    }

}
