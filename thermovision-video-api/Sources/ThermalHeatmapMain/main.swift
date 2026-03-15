import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
import MetalKit
import AppKit

// --------- Modèles ----------
struct HotBox: Codable { let rect: CGRect; let pixels: Int; let meanScore: Float; let tempC: Float }
struct Summary: Codable {
    let file: String
    let width: Int
    let height: Int
    let framesUsed: Int
    let stat: String
    let percentileLow: Float
    let percentileHigh: Float
    let ambientC: Float
    let maxC: Float
    let gamma: Float
    let hotspots: [HotBox]
}

// --------- Utils ----------
@inline(__always) func clamp<T: Comparable>(_ v: T, _ a: T, _ b: T) -> T { min(max(v,a), b) }

func percentile(_ xs: [Float], p: Float) -> Float {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    let q = clamp(p, 0, 1)
    let idx = max(0, min(s.count - 1, Int(round(Float(s.count - 1) * q))))
    return s[idx]
}

func blur5x5(_ src: [Float], w: Int, h: Int) -> [Float] {
    var tmp = [Float](repeating: 0, count: w*h)
    var dst = [Float](repeating: 0, count: w*h)
    let div: Float = 5
    // Horizontal
    for y in 0..<h {
        for x in 0..<w {
            let xm2 = max(0, x-2), xp2 = min(w-1, x+2)
            var acc: Float = 0
            for xx in xm2...xp2 { acc += src[y*w + xx] }
            tmp[y*w + x] = acc/div
        }
    }
    // Vertical
    for x in 0..<w {
        for y in 0..<h {
            let ym2 = max(0, y-2), yp2 = min(h-1, y+2)
            var acc: Float = 0
            for yy in ym2...yp2 { acc += tmp[yy*w + x] }
            dst[y*w + x] = acc/div
        }
    }
    return dst
}

func components(from mask: [UInt8], w: Int, h: Int, minPix: Int, score: [Float]) -> [HotBox] {
    var visited = [Bool](repeating: false, count: w*h)
    var boxes: [HotBox] = []
    let dirs = [(-1,0),(1,0),(0,1),(0,-1)]
    @inline(__always) func idx(_ x:Int,_ y:Int)->Int { y*w + x }

    for y in 0..<h {
        for x in 0..<w {
            let i = idx(x,y)
            if visited[i] || mask[i] == 0 { continue }
            var stack = [(x,y)]
            visited[i] = true
            var minx=x, maxx=x, miny=y, maxy=y
            var pix=0
            var sumScore: Float = 0
            while let (cx,cy) = stack.popLast() {
                pix += 1
                sumScore += score[idx(cx,cy)]
                minx=min(minx,cx); maxx=max(maxx,cx)
                miny=min(miny,cy); maxy=max(maxy,cy)
                for (dx,dy) in dirs {
                    let nx=cx+dx, ny=cy+dy
                    if nx<0||ny<0||nx>=w||ny>=h { continue }
                    let ni = idx(nx,ny)
                    if !visited[ni] && mask[ni] != 0 {
                        visited[ni] = true
                        stack.append((nx,ny))
                    }
                }
            }
            if pix >= minPix {
                let rect = CGRect(x: minx, y: miny, width: max(1, maxx-minx+1), height: max(1, maxy-miny+1))
                let meanS = sumScore / Float(pix)
                boxes.append(HotBox(rect: rect, pixels: pix, meanScore: meanS, tempC: 0))
            }
        }
    }
    return boxes.sorted { $0.pixels > $1.pixels }
}

// Dégradé bleu→cyan→jaune→rouge
@inline(__always)
func heatColor(_ t: Float) -> (r: UInt8,g: UInt8,b: UInt8) {
    let x = clamp(t, 0, 1)
    let r: Float, g: Float, b: Float
    if x < 0.33 {
        let u = x/0.33; r = 0; g = u; b = 1
    } else if x < 0.66 {
        let u = (x-0.33)/0.33; r = u; g = 1; b = 1 - u
    } else {
        let u = (x-0.66)/0.34; r = 1; g = 1 - u; b = 0
    }
    return (UInt8(clamp(Int(r*255),0,255)),
            UInt8(clamp(Int(g*255),0,255)),
            UInt8(clamp(Int(b*255),0,255)))
}

func drawLegend(ctx: CGContext, at rect: CGRect, ambient: Float, maxC: Float) {
    let steps = 100
    for i in 0..<steps {
        let t = Float(i)/Float(steps-1)
        let (r,g,b) = heatColor(t)
        ctx.setFillColor(CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1))
        let y = rect.minY + CGFloat(i) * rect.height/CGFloat(steps)
        ctx.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height/CGFloat(steps)))
    }
    let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    let ticks = max(6, Int((maxC - ambient)/5))
    for k in 0...ticks {
        let deg = ambient + (maxC - ambient) * Float(k) / Float(ticks)
        let t = (deg - ambient) / max(1e-6, (maxC - ambient))
        let y = rect.minY + CGFloat(t) * rect.height
        let str = NSAttributedString(string: String(format: " %.0f°C", deg),
                                     attributes: [.font: font, .foregroundColor: NSColor.white,
                                                  .strokeColor: NSColor.black, .strokeWidth: -3.0])
        str.draw(at: CGPoint(x: rect.maxX + 4, y: y-6))
    }
}

// --------- Metal shader (runtime) ----------
let heatMSL = #"""
#include <metal_stdlib>
using namespace metal;

// Lit l'image en float normalisé via sampler pixel
kernel void heatScore(
    texture2d<float, access::sample>   inTex [[texture(0)]],
    texture2d<float, access::write>    outTex[[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
){
    uint W = outTex.get_width(), H = outTex.get_height();
    if (gid.x >= W || gid.y >= H) return;
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    float4 c = inTex.sample(s, float2(gid) + 0.5); // BGRA sur mac
    float b = c.x, g = c.y, r = c.z;

    float luma = dot(float3(r,g,b), float3(0.2126, 0.7152, 0.0722));
    float redDom = r / (g + b + 1e-4);
    float warmBoost = max(r - max(g,b), 0.0);
    float cmax = max(r, max(g,b));
    float cmin = min(r, min(g,b));
    float sat  = (cmax - cmin) / (cmax + 1e-6);

    float score = luma * (0.5 + 0.5*sat) * (0.5 + 0.5*redDom) + warmBoost;
    outTex.write(clamp(score, 0.0, 1.0), gid);
}
"""#

// --------- Programme principal ----------
@main
struct App {
    static func main() {
        // ThermalHeatmap <video> [out.png]
        //   --frames N     (par défaut 9)
        //   --stat avg|max (par défaut avg)
        //   --pLow  0.80   --pHigh 0.98
        //   --ambient 22   --maxC 120
        //   --gamma 1.2    --alpha 0.6
        //   --minPix <int> (taille min d’un hotspot)
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("Usage: ThermalHeatmap <video> [out.png] [--frames N] [--stat avg|max] [--pLow 0.80] [--pHigh 0.98] [--ambient 22] [--maxC 120] [--gamma 1.2] [--alpha 0.6] [--minPix 64]\n", stderr)
            exit(2)
        }
        let videoPath = args[1]
        let outPath  = (args.count >= 3 && !args[2].hasPrefix("--")) ? args[2] : "heatmap_overlay.png"

        var framesN = 9
        var stat = "avg"
        var pLow: Float = 0.80
        var pHigh: Float = 0.98
        var ambient: Float = 22
        var maxC: Float = 120
        var gamma: Float = 1.2
        var alphaMax: Float = 0.6
        var minPixCLI: Int? = nil

        func readVal(_ k: String) -> String? {
            if let i = args.firstIndex(of: k), i+1 < args.count { return args[i+1] }
            return nil
        }
        if let s = readVal("--frames"), let v = Int(s) { framesN = max(1, v) }
        if let s = readVal("--stat") { stat = (s == "max") ? "max" : "avg" }
        if let s = readVal("--pLow"), let v = Float(s) { pLow = clamp(v, 0, 0.999) }
        if let s = readVal("--pHigh"), let v = Float(s) { pHigh = clamp(v, 0, 0.999) }
        if let s = readVal("--ambient"), let v = Float(s) { ambient = v }
        if let s = readVal("--maxC"), let v = Float(s) { maxC = v }
        if let s = readVal("--gamma"), let v = Float(s) { gamma = max(0.1, v) }
        if let s = readVal("--alpha"), let v = Float(s) { alphaMax = clamp(v, 0, 1) }
        if let s = readVal("--minPix"), let v = Int(s) { minPixCLI = max(1, v) }

        // Sanity sur percentiles
        if pHigh <= pLow {
            if pHigh < pLow { swap(&pLow, &pHigh) }
            else { pLow = max(0.0, pLow - 0.05); pHigh = min(0.999, pHigh + 0.05) }
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceAfter  = .zero
        gen.requestedTimeToleranceBefore = .zero

        let durSec = max(0.0, CMTimeGetSeconds(asset.duration))
        var times: [Double] = []
        if durSec == 0 || framesN == 1 { times = [0.0] }
        else {
            for i in 0..<framesN { times.append(durSec * (Double(i)+0.5)/Double(framesN)) }
        }

        let mid = CMTime(seconds: (times.count==1 ? 0.0 : durSec*0.5), preferredTimescale: 600)
        guard let frameMid = try? gen.copyCGImage(at: mid, actualTime: nil) else {
            fputs("Impossible d’extraire la frame centrale.\n", stderr); exit(3)
        }
        let W = frameMid.width, H = frameMid.height

        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("Metal indisponible.\n", stderr); exit(4)
        }
        let queue = device.makeCommandQueue()!
        let library = try! device.makeLibrary(source: heatMSL, options: nil)
        let funcHeat = library.makeFunction(name: "heatScore")!
        let pipeline = try! device.makeComputePipelineState(function: funcHeat)
        let loader = MTKTextureLoader(device: device)

        // Accumulateur (corrigé: Float explicite)
        var acc = [Float](repeating: 0.0, count: W*H)

        // Dispatch size Metal robuste
        let threadWidth  = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        let tg = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let grid = MTLSize(width: W, height: H, depth: 1)

        // --- GPU compute sur N frames ---
        for ts in times {
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: ts, preferredTimescale: 600), actualTime: nil) else { continue }
            let inTex = try! loader.newTexture(cgImage: cg, options: [
                MTKTextureLoader.Option.SRGB : false,
                MTKTextureLoader.Option.textureUsage : NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ])
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: W, height: H, mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .shared
            let outTex = device.makeTexture(descriptor: desc)!

            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pipeline)
            enc.setTexture(inTex, index: 0)
            enc.setTexture(outTex, index: 1)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()
            cmd.commit(); cmd.waitUntilCompleted()

            var heat = [Float](repeating: 0, count: W*H)
            heat.withUnsafeMutableBytes { buf in
                outTex.getBytes(buf.baseAddress!, bytesPerRow: W*MemoryLayout<Float>.size,
                                from: MTLRegionMake2D(0,0,W,H), mipmapLevel: 0)
            }
            if stat == "max" {
                for i in 0..<acc.count { acc[i] = max(acc[i], heat[i]) }
            } else {
                for i in 0..<acc.count { acc[i] += heat[i] }
            }
        }
        if stat == "avg", times.count > 0 {
            let inv = 1.0 / Float(times.count)
            for i in 0..<acc.count { acc[i] *= inv }
        }

        // --- Lissage & seuils adaptatifs ---
        let smooth = blur5x5(acc, w: W, h: H)
        let thrLow  = percentile(smooth, p: pLow)
        let thrHigh = percentile(smooth, p: pHigh)

        // Hotspots (mask sur thrHigh)
        var mask = [UInt8](repeating: 0, count: W*H)
        for i in 0..<smooth.count { mask[i] = (smooth[i] >= thrHigh) ? 255 : 0 }
        let minPix = minPixCLI ?? max(48, (W*H)/2000)
        var boxes = components(from: mask, w: W, h: H, minPix: minPix, score: smooth)

        // --- Overlay colorisé + alpha progressif ---
        var overlay = [UInt8](repeating: 0, count: W*H*4)
        for y in 0..<H {
            for x in 0..<W {
                let i = y*W + x
                let s = smooth[i]
                let t = clamp((s - thrLow) / max(1e-6, (thrHigh - thrLow)), 0, 1)
                let tg = powf(t, gamma)
                let (r,g,b) = heatColor(tg)
                let a = UInt8(clamp(Int(Float(255) * alphaMax * tg), 0, 255))
                let j = i*4
                overlay[j+0] = r
                overlay[j+1] = g
                overlay[j+2] = b
                overlay[j+3] = a
            }
        }

        // Compose sur frame centrale
        guard let ctx = CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fputs("CGContext fail\n", stderr); exit(5) }

        ctx.draw(frameMid, in: CGRect(x: 0, y: 0, width: W, height: H))

        // dessine overlay (corrigé: pas d’accès chevauché)
        let overlaySize = overlay.count
        overlay.withUnsafeBytes { ptr in
            let base = ptr.bindMemory(to: UInt8.self).baseAddress!
            let cfData = CFDataCreate(nil, base, overlaySize)!
            let provider = CGDataProvider(data: cfData)!
            let overCG = CGImage(
                width: W, height: H,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W*4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )!
            ctx.draw(overCG, in: CGRect(x: 0, y: 0, width: W, height: H))
        }

        // Légende
        let legendW = max(10, W/60)
        let legendH = max(60, H/3)
        let legendRect = CGRect(x: 10, y: 10, width: legendW, height: legendH)
        drawLegend(ctx: ctx, at: legendRect, ambient: ambient, maxC: maxC)

        // Calibrage °C (affichage top-5)
        func scoreToC(_ s: Float) -> Float {
            let u = powf(clamp(s, 0.0, 1.0), gamma)
            return ambient + (maxC - ambient) * u
        }
        let font = NSFont.boldSystemFont(ofSize: 14)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black, .strokeWidth: -3.0
        ]
        for (k, b) in boxes.prefix(5).enumerated() {
            let rect = b.rect
            let meanT = scoreToC(b.meanScore)
            let label = String(format: "HOT#%d  ~%.0f°C", k+1, meanT)
            // cadre
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.4, blue: 0, alpha: 0.95))
            ctx.setLineWidth(2.5)
            ctx.stroke(rect)
            // texte
            let str = NSAttributedString(string: label, attributes: textAttrs)
            let tx = rect.origin.x
            var ty = rect.origin.y - str.size().height - 2
            if ty < 0 { ty = rect.maxY + 2 }
            str.draw(at: CGPoint(x: tx, y: ty))
            // maj tempC
            boxes[k] = HotBox(rect: rect, pixels: b.pixels, meanScore: b.meanScore, tempC: meanT)
        }

        // Export PNG
        guard let outCG = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { fputs("Export PNG fail\n", stderr); exit(6) }
        CGImageDestinationAddImage(dest, outCG, nil)
        CGImageDestinationFinalize(dest)

        // Export JSON
        let jsonPath = (outPath as NSString).deletingPathExtension + "_summary.json"
        let summary = Summary(file: videoPath, width: W, height: H, framesUsed: times.count, stat: stat,
                              percentileLow: pLow, percentileHigh: pHigh,
                              ambientC: ambient, maxC: maxC, gamma: gamma, hotspots: boxes)
        if let data = try? JSONEncoder().encode(summary) {
            try? data.write(to: URL(fileURLWithPath: jsonPath))
        }

        print("OK (heatmap continue, \(boxes.count) hotspots) → \(outPath)")
    }
}
