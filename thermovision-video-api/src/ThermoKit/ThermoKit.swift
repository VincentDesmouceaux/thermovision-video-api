import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
import MetalKit
import AppKit

// MARK: - Types publics

public struct HotBox: Codable, Sendable {
    public let rect: CGRect
    public let pixels: Int
    public let meanScore: Float
    public let tempC: Float
    public init(rect: CGRect, pixels: Int, meanScore: Float, tempC: Float) {
        self.rect = rect; self.pixels = pixels; self.meanScore = meanScore; self.tempC = tempC
    }
}

public struct HeatConfig: Sendable {
    public var frames: Int = 9
    public var stat: String = "avg"     // "avg" ou "max"
    public var pLow: Float = 0.80
    public var pHigh: Float = 0.98
    public var ambientC: Float = 22
    public var maxC: Float = 120
    public var gamma: Float = 1.2
    public var alphaMax: Float = 0.6
    public init() {}
}

@inline(__always) func clamp<T: Comparable>(_ v: T, _ a: T, _ b: T) -> T { min(max(v,a), b) }

func percentile(_ xs: [Float], p: Float) -> Float {
    guard !xs.isEmpty else { return 1.0 }
    let s = xs.sorted()
    let idx = max(0, min(s.count-1, Int(round(Float(s.count-1) * p))))
    return s[idx]
}

// MARK: - GPU (public)

public final class ThermalGPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    let loader: MTKTextureLoader

    public init() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "ThermoKit", code: 1, userInfo: [NSLocalizedDescriptionKey:"Metal indisponible"])
        }
        device = dev
        queue = device.makeCommandQueue()!
        loader = MTKTextureLoader(device: device)

        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void heatScore(
          texture2d<float, access::sample> inTex [[texture(0)]],
          texture2d<float, access::write>  outTex[[texture(1)]],
          uint2 gid [[thread_position_in_grid]]
        ){
          uint W = outTex.get_width(), H = outTex.get_height();
          if (gid.x >= W || gid.y >= H) return;
          constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
          // les textures chargées via MTKTextureLoader en format RGBA8UNorm se lisent en [0,1]
          float4 c = inTex.sample(s, float2(gid)+0.5);
          float r = c.r, g = c.g, b = c.b;
          float luma = dot(float3(r,g,b), float3(0.2126, 0.7152, 0.0722));
          float redDom = r / (g + b + 1e-4);
          float warmBoost = max(r - max(g,b), 0.0);
          float cmax = max(r, max(g,b));
          float cmin = min(r, min(g,b));
          float sat  = (cmax - cmin) / (cmax + 1e-6);
          float score = luma * (0.5 + 0.5*sat) * (0.5 + 0.5*redDom) + warmBoost;
          outTex.write(clamp(score, 0.0, 1.0), gid);
        }
        """
        let lib = try device.makeLibrary(source: src, options: nil)
        let fn  = lib.makeFunction(name: "heatScore")!
        pipeline = try device.makeComputePipelineState(function: fn)
    }

    public func heatTexture(from cg: CGImage) throws -> MTLTexture {
        // Texture d'entrée
        let inTex = try loader.newTexture(cgImage: cg, options: [
            MTKTextureLoader.Option.SRGB : false,
            MTKTextureLoader.Option.textureUsage : NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ])
        // Texture de sortie r32Float
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: cg.width, height: cg.height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared
        let outTex = device.makeTexture(descriptor: desc)!

        // Compute
        let cmd = queue.makeCommandBuffer()!
        let enc = cmd.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pipeline)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(outTex, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: cg.width, height: cg.height, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()

        return outTex
    }

    public func readFloatArray(from tex: MTLTexture) -> [Float] {
        var arr = [Float](repeating: 0, count: tex.width * tex.height)
        arr.withUnsafeMutableBytes { buf in
            tex.getBytes(buf.baseAddress!,
                         bytesPerRow: tex.width * MemoryLayout<Float>.size,
                         from: MTLRegionMake2D(0, 0, tex.width, tex.height),
                         mipmapLevel: 0)
        }
        return arr
    }
}

// MARK: - Outils image (public)

public func blur5x5(_ src: [Float], w: Int, h: Int) -> [Float] {
    var tmp = [Float](repeating: 0, count: w*h)
    var dst = [Float](repeating: 0, count: w*h)
    for y in 0..<h {
        for x in 0..<w {
            let xm2 = max(0, x-2), xp2 = min(w-1, x+2)
            var acc: Float = 0
            for xx in xm2...xp2 { acc += src[y*w + xx] }
            tmp[y*w + x] = acc / 5
        }
    }
    for x in 0..<w {
        for y in 0..<h {
            let ym2 = max(0, y-2), yp2 = min(h-1, y+2)
            var acc: Float = 0
            for yy in ym2...yp2 { acc += tmp[yy*w + x] }
            dst[y*w + x] = acc / 5
        }
    }
    return dst
}

// Composantes connexes (interne au module)
func components(from mask: [UInt8], w: Int, h: Int, minPix: Int, score: [Float]) -> [HotBox] {
    var visited = [Bool](repeating: false, count: w*h)
    var boxes: [HotBox] = []
    let dirs = [(-1,0),(1,0),(0,1),(0,-1)]
    func id(_ x:Int,_ y:Int)->Int { y*w + x }

    for y in 0..<h {
        for x in 0..<w {
            let i = id(x,y)
            if visited[i] || mask[i] == 0 { continue }
            var stack = [(x,y)]
            visited[i] = true
            var minx=x, maxx=x, miny=y, maxy=y
            var pix=0
            var sum: Float = 0
            while let (cx,cy) = stack.popLast() {
                pix += 1
                sum += score[id(cx,cy)]
                minx=min(minx,cx); maxx=max(maxx,cx)
                miny=min(miny,cy); maxy=max(maxy,cy)
                for (dx,dy) in dirs {
                    let nx=cx+dx, ny=cy+dy
                    if nx<0||ny<0||nx>=w||ny>=h { continue }
                    let ni = id(nx,ny)
                    if !visited[ni] && mask[ni] != 0 {
                        visited[ni]=true; stack.append((nx,ny))
                    }
                }
            }
            if pix >= minPix {
                let rect = CGRect(x: minx, y: miny, width: max(1, maxx-minx+1), height: max(1, maxy-miny+1))
                boxes.append(HotBox(rect: rect, pixels: pix, meanScore: sum/Float(pix), tempC: 0))
            }
        }
    }
    return boxes.sorted { $0.pixels > $1.pixels }
}

// Dégradé couleur (interne)
@inline(__always)
func heatColor(_ t: Float) -> (r: UInt8,g: UInt8,b: UInt8) {
    let x = clamp(t, 0 as Float, 1 as Float)
    let r, g, b: Float
    if x < 0.33 {
        let u = x/0.33; r = 0; g = u; b = 1
    } else if x < 0.66 {
        let u = (x-0.33)/0.33; r = u; g = 1; b = 1-u
    } else {
        let u = (x-0.66)/0.34; r = 1; g = 1-u; b = 0
    }
    return (UInt8(clamp(Int(r*255),0,255)),
            UInt8(clamp(Int(g*255),0,255)),
            UInt8(clamp(Int(b*255),0,255)))
}

// MARK: - Rendu (public)

public enum ThermoRenderer {
    /// Construit l’overlay RGBA premultiplié + la liste de hotspots
    public static func buildOverlay(from smooth: [Float], W: Int, H: Int,
                                    pLow: Float, pHigh: Float,
                                    gamma: Float, alphaMax: Float) -> ([UInt8],[HotBox]) {
        precondition(smooth.count == W*H)
        let thrLow  = percentile(smooth, p: pLow)
        let thrHigh = percentile(smooth, p: pHigh)

        // hotspots au-dessus de thrHigh
        var mask = [UInt8](repeating: 0, count: W*H)
        for i in 0..<smooth.count { mask[i] = (smooth[i] >= thrHigh) ? 255 : 0 }
        let minPix = max(48, (W*H)/2000)
        let boxes = components(from: mask, w: W, h: H, minPix: minPix, score: smooth)

        // Overlay RGBA premultiplié
        var overlay = [UInt8](repeating: 0, count: W*H*4)
        for y in 0..<H {
            for x in 0..<W {
                let i = y*W + x
                let t = clamp((smooth[i] - thrLow) / max(1e-6, (thrHigh - thrLow)), 0 as Float, 1 as Float)
                let tg = powf(t, gamma)
                let (r8,g8,b8) = heatColor(tg)
                let a8 = UInt8(clamp(Int(Float(255)*alphaMax*tg), 0, 255))
                // premultiply
                let r = UInt8((UInt16(r8) * UInt16(a8)) / 255)
                let g = UInt8((UInt16(g8) * UInt16(a8)) / 255)
                let b = UInt8((UInt16(b8) * UInt16(a8)) / 255)
                let j = i*4
                overlay[j+0] = r
                overlay[j+1] = g
                overlay[j+2] = b
                overlay[j+3] = a8
            }
        }
        return (overlay, boxes)
    }

    /// Compose l’overlay sur une frame et exporte PNG avec annotations
    public static func composeOverlayPNG(frameMid: CGImage,
                                         overlay: [UInt8], W: Int, H: Int,
                                         config: HeatConfig,
                                         boxes: inout [HotBox],
                                         outURL: URL) throws {
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw NSError(domain:"ThermoKit", code:2, userInfo:[NSLocalizedDescriptionKey:"CGContext fail"]) }

        // Fond
        ctx.draw(frameMid, in: CGRect(x: 0, y: 0, width: W, height: H))

        // Overlay via Data -> CGImage (évite l’exclusivité qui plantait)
        let data = Data(overlay)
        let prov = CGDataProvider(data: data as CFData)!
        let overCG = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W*4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        ctx.draw(overCG, in: CGRect(x: 0, y: 0, width: W, height: H))

        // Légende
        drawLegend(ctx: ctx, ambient: config.ambientC, maxC: config.maxC, W: W, H: H)

        // Annotations hotspots (top 5) + maj tempC
        let font = NSFont.boldSystemFont(ofSize: 14)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black, .strokeWidth: -3.0
        ]
        func scoreToC(_ s: Float) -> Float {
            let u = powf(clamp(s, 0.0, 1.0), config.gamma)
            return config.ambientC + (config.maxC - config.ambientC) * u
        }
        for (k, b) in boxes.prefix(5).enumerated() {
            let rect = b.rect
            let meanT = scoreToC(b.meanScore)
            let label = String(format: "HOT#%d  ~%.0f°C", k+1, meanT)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.4, blue: 0, alpha: 0.95))
            ctx.setLineWidth(2.5)
            ctx.stroke(rect)
            let str = NSAttributedString(string: label, attributes: textAttrs)
            var tx = rect.origin.x
            var ty = rect.origin.y - str.size().height - 2
            if ty < 0 { ty = rect.maxY + 2 }
            str.draw(at: CGPoint(x: tx, y: ty))
            boxes[k] = HotBox(rect: rect, pixels: b.pixels, meanScore: b.meanScore, tempC: meanT)
        }

        // Export PNG
        guard let outCG = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain:"ThermoKit", code:3, userInfo:[NSLocalizedDescriptionKey:"Export PNG fail"]) }
        CGImageDestinationAddImage(dest, outCG, nil)
        CGImageDestinationFinalize(dest)
    }

    static func drawLegend(ctx: CGContext, ambient: Float, maxC: Float, W: Int, H: Int) {
        let legendW = max(10, W/60)
        let legendH = max(60, H/3)
        let rect = CGRect(x: 10, y: 10, width: legendW, height: legendH)
        let steps = 100
        for i in 0..<steps {
            let t = Float(i)/Float(steps-1)
            let (r,g,b) = heatColor(t)
            ctx.setFillColor(CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1))
            let y = rect.minY + CGFloat(i) * rect.height/CGFloat(steps)
            ctx.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height/CGFloat(steps)))
        }
        // ticks
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        for deg in stride(from: ambient, through: maxC, by: max(5, (maxC-ambient)/6)) {
            let t = (deg - ambient) / (maxC - ambient)
            let y = rect.minY + CGFloat(t) * rect.height
            let str = NSAttributedString(string: String(format: " %.0f°C", deg),
                                         attributes: [.font: font, .foregroundColor: NSColor.white,
                                                      .strokeColor: NSColor.black, .strokeWidth: -3.0])
            str.draw(at: CGPoint(x: rect.maxX + 4, y: y-6))
        }
    }
}
