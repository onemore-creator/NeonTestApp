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
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        // Configure the MTKView and attach the renderer
        renderer.configure(view: view)
        return view
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        // Nothing needed — updates flow through NeonViewModel -> renderer.update(...)
    }
}
