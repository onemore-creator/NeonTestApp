//
//  ContentView.swift
//  NeonLightsTestApp
//
//  Created by Aleksandr Tiulpanov on 02/09/2025.
//

import SwiftUI
import NeonEngine

struct ContentView: View {
    @StateObject private var vm: NeonViewModel

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("❌ No Metal device available")
        }
        print("📱 Using device: \(device.name)")

        let renderer = NeonRenderer(device: device)
        print("🛠 Renderer created")

        let viewModel = NeonViewModel(renderer: renderer)
        print("📦 ViewModel initialized")
        _vm = StateObject(wrappedValue: viewModel)

        // Preload the SVG so the renderer has geometry before the view appears.
        print("📥 Preloading SVG")
        viewModel.loadSVG()
    }

    var body: some View {
        VStack {
            NeonMetalView(renderer: vm.renderer)
              .background(.black)
              .frame(maxWidth: .infinity, maxHeight: .infinity)  // <— important
        }
    }
}

struct ControlsView: View {
    @ObservedObject var vm: NeonViewModel

    var body: some View {
        HStack(spacing: 16) {
            ColorPicker("Color",
                        selection: $vm.color,
                        supportsOpacity: false)
                .labelsHidden()
                .onChange(of: vm.color) { _ in
                    vm.apply()
                }

            Button("Reload SVG") {
                vm.loadSVG()
                vm.apply()
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

#Preview {
    ContentView()
}
