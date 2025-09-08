//
//  NeonMetalView.swift
//  NeonLightsTestApp
//
//  Created by Aleksandr Tiulpanov on 02/09/2025.
//

import SwiftUI
import MetalKit

/// A SwiftUI wrapper around ``MTKView`` that keeps its drawable size in sync
/// with SwiftUI layout changes and delegates rendering to ``NeonRenderer``.
public struct NeonMetalView: UIViewRepresentable {
    /// The renderer responsible for drawing into the view.
    public let renderer: NeonRenderer

    /// Create a new Metal-backed view using the provided renderer.
    public init(renderer: NeonRenderer) {
        self.renderer = renderer
    }

    public func makeUIView(context: Context) -> MTKView {
        // Construct the MTKView with the renderer's device so all Metal
        // resources are compatible.
        let view = MTKView(frame: .zero, device: renderer.device)
        renderer.configure(view: view)
        return view
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        // Propagate SwiftUI layout changes to the drawable size. MTKView only
        // updates its internal textures when `drawableSize` changes, so we
        // compute the scaled size explicitly and inform the renderer.
        let scale = uiView.contentScaleFactor
        let size = CGSize(width: uiView.bounds.width * scale,
                          height: uiView.bounds.height * scale)
        uiView.drawableSize = size
        // Immediately notify the renderer so it can resize its buffers before
        // the next draw call. Relying solely on MTKView's delegate callback can
        // result in a black frame during rapid layout updates.
        renderer.mtkView(uiView, drawableSizeWillChange: size)
        print("📐 updateUIView -> drawableSize: \(size)")
    }
}

