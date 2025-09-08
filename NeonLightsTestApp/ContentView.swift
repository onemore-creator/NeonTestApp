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
        let device = MTLCreateSystemDefaultDevice()!
        let renderer = NeonRenderer(device: device)
        _vm = StateObject(wrappedValue: NeonViewModel(renderer: renderer))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            NeonView(renderer: vm.renderer)
                .background(.black)
                .ignoresSafeArea()
                .onAppear { vm.loadSVG() }

            ControlsView(vm: vm)
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
