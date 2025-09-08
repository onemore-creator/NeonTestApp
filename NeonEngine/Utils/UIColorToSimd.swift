//
//  UIColorToSimd.swift
//  NeonLightsTestApp
//
//  Created by Aleksandr Tiulpanov on 08/09/2025.
//
import SwiftUI
import simd

public extension Color {
    /// Returns RGB floats (0...1) in sRGB space if representable
    func toSIMD3() -> SIMD3<Float> {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
        #elseif canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.white
        return SIMD3(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent))
        #else
        return SIMD3(1,1,1) // fallback
        #endif
    }
}
