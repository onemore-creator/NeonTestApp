//
//  NeonView.swift
//  NeonLightsTestApp
//
//  Created by Aleksandr Tiulpanov on 08/09/2025.
//


//
//  NeonView.swift
//  NeonLightsTestApp
//
//  Created by Aleksandr Tiulpanov on 08/09/2025.
//

import SwiftUI
import MetalKit
import NeonEngine

public struct NeonView: UIViewRepresentable {
    let renderer: NeonRenderer

    public func makeUIView(context: Context) -> MTKView {
        // Create the MTKView using the same device as the renderer to ensure
        // all Metal resources are compatible.
        print("🪟 Creating MTKView")
        let view = MTKView(frame: .zero, device: renderer.device)
        renderer.configure(view: view)
        return view
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        // Keep the drawable size in sync with SwiftUI layout changes so Metal
        // renders at the correct resolution and aspect ratio.
        let scale = uiView.contentScaleFactor
        let size = CGSize(width: uiView.bounds.width * scale,
                          height: uiView.bounds.height * scale)
        uiView.drawableSize = size
        print("📐 updateUIView -> drawableSize: \(size)")
    }
}
