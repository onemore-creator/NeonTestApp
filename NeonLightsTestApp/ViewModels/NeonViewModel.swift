//
//  NeonViewModel.swift
//  NeonLightsTestApp
//
//  Created by Aleksandr Tiulpanov on 02/09/2025.
//

import SwiftUI
import NeonEngine
import SwiftSVG       // mchoe/SwiftSVG
import simd
import UIKit          // for UIColor bridge

@MainActor
final class NeonViewModel: ObservableObject {
    @Published var color: Color = .cyan
    let renderer: NeonRenderer

    init(renderer: NeonRenderer) { self.renderer = renderer }

    // Push SwiftUI state into the Metal renderer
    func apply() {
        var s = NeonSettings()
        s.color = color.toSIMD3()
        renderer.update(settings: s)
    }

    /// Load an SVG file, parse with SwiftSVG, extract paths and tessellate to a stroke mesh.
    /// - Parameter name: Resource name (without extension) inside the app bundle.
    func loadSVG(named name: String = "cloud") {
        let data: Data
        if let url = Bundle.main.url(forResource: name, withExtension: "svg"),
           let file = try? Data(contentsOf: url) {
            data = file
        } else {
            // Fallback to an inline SVG so the demo still works if the file is missing.
            let svgText = """
            <?xml version=\"1.0\" encoding=\"utf-8\"?>
            <svg width=\"800px\" height=\"800px\" viewBox=\"0 0 24 24\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\">
              <path d=\"M3 18H7M10 18H21M5 21H12M16 21H19M8.8 15C6.14903 15 4 12.9466 4 10.4137C4 8.31435 5.6 6.375 8 6C8.75283 4.27403 10.5346 3 12.6127 3C15.2747 3 17.4504 4.99072 17.6 7.5C19.0127 8.09561 20 9.55741 20 11.1402C20 13.2719 18.2091 15 16 15L8.8 15Z\"
                    stroke=\"#000000\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>
            </svg>
            """
            guard let inline = svgText.data(using: .utf8) else {
                print("❌ Could not load SVG data")
                return
            }
            data = inline
        }

        // Parse async into an SVGLayer (SwiftSVG completion runs on main)
        let targetSize = CGSize(width: 512, height: 512)
        _ = CALayer(SVGData: data) { svgLayer in
            // Outline-only; scale to a convenient pixel space for our pipeline
            svgLayer.fillColor = UIColor.clear.cgColor
            svgLayer.resizeToFit(CGRect(origin: .zero, size: targetSize))

            // 1) Collect paths
            let paths = parseSVGPaths(from: svgLayer)
            guard !paths.isEmpty else {
                print("⚠️ No CAShapeLayer paths found in SVG")
                return
            }

            // 2) Compute original content bounds (for centering/upscaling in renderer)
            var minP = SIMD2<Float>( Float.greatestFiniteMagnitude,  Float.greatestFiniteMagnitude)
            var maxP = SIMD2<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
            for path in paths {
                let pts = flattenPath(path, tolerance: 0.75)
                for cg in pts {
                    let p = SIMD2<Float>(Float(cg.x), Float(cg.y))
                    minP = SIMD2<Float>(min(minP.x, p.x), min(minP.y, p.y))
                    maxP = SIMD2<Float>(max(maxP.x, p.x), max(maxP.y, p.y))
                }
            }

            // 3) Tessellate to a simple quad-strip stroke mesh
            let result = tessellatePaths(paths, halfWidth: 2.0, tolerance: 0.75)
            print("✅ Mesh uploaded: \(result.vertices.count) verts, \(result.indices.count) indices")

            // 4) Upload geometry and bounds; then apply current color
            self.renderer.updateMesh(vertices: result.vertices, indices: result.indices)
            // Requires you added: public func updateContentBounds(min:max:)
            self.renderer.updateContentBounds(min: minP, max: maxP)
            self.apply()
        }
    }
}

// MARK: - Parsing / Tessellation

private func parseSVGPaths(from root: CALayer) -> [CGPath] {
    var paths: [CGPath] = []
    collectPaths(from: root, into: &paths)
    return paths
}

private func tessellatePaths(_ paths: [CGPath],
                             halfWidth: Float,
                             tolerance: CGFloat) -> (vertices: [StrokeVertex], indices: [UInt16]) {
    var vertices: [StrokeVertex] = []
    var indices:  [UInt16] = []
    var idx: UInt16 = 0

    for path in paths {
        let pts = flattenPath(path, tolerance: tolerance)
        guard pts.count >= 2 else { continue }

        for i in 0..<(pts.count - 1) {
            let p0cg = pts[i]
            let p1cg = pts[i + 1]

            let p0 = SIMD2<Float>(Float(p0cg.x), Float(p0cg.y))
            let p1 = SIMD2<Float>(Float(p1cg.x), Float(p1cg.y))

            let quad = makeQuadStrip(p0: p0, p1: p1, halfWidth: halfWidth)

            vertices.append(quad.v0)
            vertices.append(quad.v1)
            vertices.append(quad.v2)
            vertices.append(quad.v3)

            indices.append(idx + 0)
            indices.append(idx + 1)
            indices.append(idx + 2)
            indices.append(idx + 2)
            indices.append(idx + 1)
            indices.append(idx + 3)
            idx &+= 4
        }
    }

    return (vertices, indices)
}

private struct Quad {
    let v0: StrokeVertex
    let v1: StrokeVertex
    let v2: StrokeVertex
    let v3: StrokeVertex
}

private func makeQuadStrip(p0: SIMD2<Float>, p1: SIMD2<Float>, halfWidth: Float) -> Quad {
    // Direction (p0->p1)
    let dx = p1.x - p0.x
    let dy = p1.y - p0.y
    let len = max(1e-6 as Float, sqrtf(dx*dx + dy*dy))
    let ux = dx / len
    let uy = dy / len

    // Left normal = (-uy, ux)
    let nx = -uy * halfWidth
    let ny =  ux * halfWidth

    // Offset positions
    let p0Left  = SIMD2<Float>(p0.x + nx, p0.y + ny)
    let p0Right = SIMD2<Float>(p0.x - nx, p0.y - ny)
    let p1Left  = SIMD2<Float>(p1.x + nx, p1.y + ny)
    let p1Right = SIMD2<Float>(p1.x - nx, p1.y - ny)

    // edgeDist kept for potential AA shaping later (0 near centerline, 1 at outer edge)
    let v0 = StrokeVertex(p0Left,  edgeDist: 0)
    let v1 = StrokeVertex(p0Right, edgeDist: 1)
    let v2 = StrokeVertex(p1Left,  edgeDist: 0)
    let v3 = StrokeVertex(p1Right, edgeDist: 1)

    return Quad(v0: v0, v1: v1, v2: v2, v3: v3)
}

// MARK: - Layer traversal / path flatten

private func collectPaths(from layer: CALayer, into out: inout [CGPath]) {
    if let shape = layer as? CAShapeLayer, let p = shape.path {
        out.append(p)
    }
    layer.sublayers?.forEach { collectPaths(from: $0, into: &out) }
}

private func flattenPath(_ path: CGPath, tolerance: CGFloat) -> [CGPoint] {
    var pts: [CGPoint] = []
    var current: CGPoint = .zero

    path.applyWithBlock { ep in
        let e = ep.pointee
        switch e.type {
        case .moveToPoint:
            let p = e.points[0]
            current = p
            pts.append(p)

        case .addLineToPoint:
            let p = e.points[0]
            current = p
            pts.append(p)

        case .addQuadCurveToPoint:
            let c   = e.points[0]
            let end = e.points[1]
            let dx = end.x - current.x
            let dy = end.y - current.y
            let segLen = CGFloat(hypot(dx, dy))
            let steps = max(2, Int(segLen / tolerance))

            var i = 1
            while i <= steps {
                let t = CGFloat(i) / CGFloat(steps)
                let u = 1 - t
                let x = u*u*current.x + 2*u*t*c.x + t*t*end.x
                let y = u*u*current.y + 2*u*t*c.y + t*t*end.y
                pts.append(CGPoint(x: x, y: y))
                i += 1
            }
            current = end

        case .addCurveToPoint:
            let c1  = e.points[0]
            let c2  = e.points[1]
            let end = e.points[2]
            let dx = end.x - current.x
            let dy = end.y - current.y
            let segLen = CGFloat(hypot(dx, dy))
            let steps = max(3, Int(segLen / tolerance))

            var i = 1
            while i <= steps {
                let t = CGFloat(i) / CGFloat(steps)
                let u = 1 - t
                let x =
                    u*u*u*current.x +
                    3*u*u*t*c1.x   +
                    3*u*t*t*c2.x   +
                    t*t*t*end.x
                let y =
                    u*u*u*current.y +
                    3*u*u*t*c1.y   +
                    3*u*t*t*c2.y   +
                    t*t*t*end.y
                pts.append(CGPoint(x: x, y: y))
                i += 1
            }
            current = end

        case .closeSubpath:
            break

        @unknown default:
            break
        }
    }

    return pts
}

// MARK: - Color helper

private extension Color {
    /// Convert SwiftUI Color to SIMD3<Float> (sRGB 0...1)
    func toSIMD3() -> SIMD3<Float> {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
    }
}
