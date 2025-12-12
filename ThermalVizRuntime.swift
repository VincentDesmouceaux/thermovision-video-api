import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
import MetalKit
import AppKit   // pour NSFont / NSColor (labels overlay)

struct HotBox { let rect: CGRect; let score: Float; let pixels: Int }

@inline(__always)
func percentile(_ xs: [Float], p: Float) -> Float {
    guard !xs.isEmpty else { return 1.0 }
    let s = xs.sorted()
    let idx = max(0, min(s.count-1, Int(round(Float(s.count-1) * p))))
    return s[idx]
}

func components(from mask: [UInt8], w: Int, h: Int, minPix: Int = 64) -> [HotBox] {
    var visited = [Bool](repeating: false, count: w*h)
    var boxes: [HotBox] = []
    let dirs = [(-1,0),(1,0),(0,1),(0,-1)]
    @inline(__always) func idx(_ x: Int,_ y: Int) -> Int { y*w + x }

    for y in 0..<h {
        for x in 0..<w {
            let i = idx(x,y)
            if visited[i] || mask[i] == 0 { continue }
            var stack: [(Int,Int)] = [(x,y)]
            visited[i] = true
            var minx=x, maxx=x, miny=y, maxy=y, pix=0
            while let (cx,cy) = stack.popLast() {
                pix += 1
                minx=min(minx,cx); maxx=max(maxx,cx)
                miny=min(miny,cy); maxy=max(maxy,cy)
                for (dx,dy) in dirs {
                    let nx=cx+dx, ny=cy+dy
                    if nx<0 || ny<0 || nx>=w || ny>=h { continue }
                    let ni = idx(nx,ny)
                    if !visited[ni] && mask[ni] != 0 {
                        visited[ni] = true
                        stack.append((nx,ny))
                    }
                }
            }
            if pix >= minPix {
                let rect = CGRect(x: minx, y: miny,
                                  width: max(1, maxx-minx+1),
                                  height: max(1, maxy-miny+1))
                let score = Float(pix) / Float(w*h)
                boxes.append(HotBox(rect: rect, score: score, pixels: pix))
            }
        }
    }
    boxes.sort { $0.pixels > $1.pixels }
    return boxes
}

func drawOverlay(base cg: CGImage, boxes: [HotBox], outURL: URL) throws {
    let W = cg.width, H = cg.height
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "draw", code: 1) }

    // Fond
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

    // Boîtes + labels
    for (k, b) in boxes.enumerated() {
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.95))
        ctx.setLineWidth(3)
        ctx.stroke(b.rect)

        let label = "HOT#\(k+1) • pix=\(b.pixels)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0
        ]
        let text = NSAttributedString(string: label, attributes: attrs)
        let size = text.size()
        var tx = b.rect.origin.x
        var ty = b.rect.origin.y - size.height - 2
        if ty < 0 { ty = b.rect.maxY + 2 }
        text.draw(at: CGPoint(x: tx, y: ty))
    }

    // Export PNG (UTType moderne)
    guard let outCG = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "imgio", code: 2) }
    CGImageDestinationAddImage(dest, outCG, nil)
    CGImageDestinationFinalize(dest)
}

// MSL compilé à l’exécution → pas besoin de `metal` CLI
let heatMSL = #"""
#include <metal_stdlib>
using namespace metal;

// On lit une texture couleur via "sample" (coordonnées en pixels)
kernel void heatScore(
    texture2d<float, access::sample>  inTex [[texture(0)]],
    texture2d<float, access::write>   outTex[[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
){
    uint W = outTex.get_width();
    uint H = outTex.get_height();
    if (gid.x >= W || gid.y >= H) return;

    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);

    // NB: si la texture source est BGRA8Unorm, l’ordre des canaux est BGRA.
    float4 c = inTex.sample(s, float2(gid) + 0.5);
    float b = c.x;
    float g = c.y;
    float r = c.z;

    // Luma Rec.709
    float luma = dot(float3(r,g,b), float3(0.2126, 0.7152, 0.0722));
    // dominance du rouge
    float redDom = r / (g + b + 1e-4);
    // boost "chaud" (rouge nettement > vert/bleu)
    float warmBoost = max(r - max(g,b), 0.0);
    // saturation simple
    float cmax = max(r, max(g,b));
    float cmin = min(r, min(g,b));
    float sat  = (cmax - cmin) / (cmax + 1e-6);

    float score = luma * (0.5 + 0.5*sat) * (0.5 + 0.5*redDom) + warmBoost;
    outTex.write(clamp(score, 0.0, 1.0), gid);
}
"""#

@main
struct App {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            fputs("Usage: ThermalViz <video> [output.png]\n", stderr); exit(2)
        }
        let videoPath = CommandLine.arguments[1]
        let outPath = (CommandLine.arguments.count >= 3) ? CommandLine.arguments[2] : "heat_overlay.png"

        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceAfter  = .zero
        gen.requestedTimeToleranceBefore = .zero

        // Frames à analyser (3 positions) + frame centrale pour affichage
        let dur = CMTimeGetSeconds(asset.duration)
        let timesSec = (dur.isFinite && dur > 0) ? [dur*0.25, dur*0.5, dur*0.75] : [0.0]
        let mid = CMTime(seconds: (timesSec.count==1 ? 0.0 : dur*0.5), preferredTimescale: 600)

        guard let frameMid = try? gen.copyCGImage(at: mid, actualTime: nil) else {
            fputs("Impossible d’extraire la frame centrale.\n", stderr); exit(3)
        }
        let W = frameMid.width, H = frameMid.height

        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("Metal indisponible.\n", stderr); exit(4)
        }
        let queue = device.makeCommandQueue()!

        // Compile le shader Metal à l’exécution
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: heatMSL, options: nil)
        } catch {
            fputs("Échec compilation MSL runtime: \(error)\n", stderr); exit(5)
        }
        let funcHeat = library.makeFunction(name: "heatScore")!
        let pipeline = try! device.makeComputePipelineState(function: funcHeat)

        let loader = MTKTextureLoader(device: device)
        var acc = [Float](repeating: 0, count: W*H)

        // Traite 3 frames et moyenne les scores
        for ts in timesSec {
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: ts, preferredTimescale: 600), actualTime: nil) else { continue }

            let inTex = try! loader.newTexture(cgImage: cg, options: [
                MTKTextureLoader.Option.SRGB : false,
                MTKTextureLoader.Option.textureUsage : NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ])

            let desc = MTLTextureDescriptor()
            desc.pixelFormat = .r32Float
            desc.width = W; desc.height = H
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .shared
            let outTex = device.makeTexture(descriptor: desc)!

            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pipeline)
            enc.setTexture(inTex, index: 0)
            enc.setTexture(outTex, index: 1)

            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: (W + 15)/16*16, height: (H + 15)/16*16, depth: 1)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()
            cmd.commit(); cmd.waitUntilCompleted()

            var heat = [Float](repeating: 0, count: W*H)
            heat.withUnsafeMutableBytes { buf in
                outTex.getBytes(buf.baseAddress!, bytesPerRow: W*MemoryLayout<Float>.size,
                                from: MTLRegionMake2D(0,0,W,H), mipmapLevel: 0)
            }
            for i in 0..<acc.count { acc[i] += heat[i] }
        }
        let inv = 1.0 / Float(timesSec.count)
        for i in 0..<acc.count { acc[i] *= inv }

        // Seuil adaptatif (percentile 97%)
        let thr = percentile(acc, p: 0.97)
        var mask = [UInt8](repeating: 0, count: W*H)
        for i in 0..<acc.count { mask[i] = (acc[i] >= thr) ? 255 : 0 }

        let boxes = components(from: mask, w: W, h: H, minPix: max(32, (W*H)/2000))
        do {
            try drawOverlay(base: frameMid, boxes: boxes, outURL: URL(fileURLWithPath: outPath))
            print("OK (sources chaudes visuelles: \(boxes.count)) → \(outPath)")
        } catch {
            fputs("Erreur overlay: \(error)\n", stderr); exit(6)
        }
    }
}
