// ThermalHeatmapStandalone.swift — QuickTime-stable (macOS 13–15)
// + Hand Mask & CSV + EMA two-up (neg)
// + Hand Calibration via hex (outil .NET/C++ externe accepté) + DataLake POST API
// + Hand Landmarks from external source (API/JSON/Demo)
//
// Build :
//   xcrun swiftc -O ThermalHeatmapStandalone.swift \
//     -o ThermalHeatmap \
//     -framework Metal -framework MetalKit -framework AVFoundation -framework CoreMedia \
//     -framework CoreGraphics -framework ImageIO -framework CoreImage -framework AppKit \
//     -framework Vision -framework CoreVideo
//
// Run :
//   ./ThermalHeatmap "<videoIn>" out.mov  [--cpu] [--stat avg|max] [--pLow 0.80] [--pHigh 0.98] \
//                    [--ambient 22] [--maxC 120] [--gamma 1.2] [--alpha 0.6] [--handOnly] [--csv path.csv] \
//                    [--ema 0.2] [--twoUp] [--negEMA] \
//                    [--calibHex 0x...|--calibHexFile path|--calibCmd "dotnet run ..."] \
//                    [--postURL https://api.example.com/ingest] [--postBearer token123] \
//                    [--postHeader "X-Org: Unit42"] [--postEvery 30] \
//                    [--handAPI https://... | --handJSON path | --handDemo open|pinch|fist] \
//                    [--handAPIEvery 5] [--handAPINormalized] [--handPreferAPI|--handPreferVision]
//   ./ThermalHeatmap "<videoIn>" out.mp4  [mêmes options]
//   ./ThermalHeatmap "<videoIn>" out.png  [mêmes options, image unique (frame centrale); CSV non écrit]

import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreImage
import ImageIO
import Metal
import MetalKit
import AppKit
import Vision
import CoreVideo

// MARK: - Utils
@inline(__always) func clamp<T: Comparable>(_ v: T, _ a: T, _ b: T) -> T { min(max(v,a), b) }
@inline(__always) func even(_ n: Int) -> Int { n & ~1 }
func percentile(_ xs: [Float], p: Float) -> Float {
    guard !xs.isEmpty else { return 1.0 }
    let s = xs.sorted()
    let idx = max(0, min(s.count-1, Int(round(Float(s.count-1) * p))))
    return s[idx]
}
func orientedExtent(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
    let rect = CGRect(origin: .zero, size: size).applying(transform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
}
func isVideoPath(_ p: String) -> Bool {
    let lower = p.lowercased()
    return lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".m4v")
}

// Supprime le fichier de sortie s'il existe et crée le dossier parent si besoin
func prepareOutputFile(_ url: URL) throws {
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent()
    if !fm.fileExists(atPath: dir.path) {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    if fm.fileExists(atPath: url.path) {
        do { try fm.removeItem(at: url) }
        catch {
            throw NSError(domain: "ThermalHeatmap", code: 11,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "Impossible d’écraser le fichier de sortie (verrouillé ?): \(url.path)\nCause: \(error)"])
        }
    }
}

// MARK: - Modèles
struct HotBox: Codable {
    let rect: CGRect
    let pixels: Int
    let meanScore: Float
    let tempC: Float
}

struct HandCalibration: Codable {
    let gain: Float     // mult sur le score^gamma
    let offset: Float   // °C additif
    let version: Int
    let rawHex: String
}

struct HeatConfig {
    var stat: String = "avg"      // "avg" ou "max"
    var pLow: Float = 0.80
    var pHigh: Float = 0.98
    var ambientC: Float = 22
    var maxC: Float = 120
    var gamma: Float = 1.2
    var alphaMax: Float = 0.6

    var handOnly: Bool = false
    var csvPath: String? = nil

    // EMA + two-up
    var emaAlpha: Float? = nil
    var twoUp: Bool = false
    var negEMA: Bool = false

    // Calibration “main”
    var handCalib: HandCalibration? = nil

    // DataLake
    var postURL: URL? = nil
    var postBearer: String? = nil
    var postHeaderKV: (String,String)? = nil
    var postEvery: Int = 30

    // Hand external provider / demo
    var handAPIURL: URL? = nil          // --handAPI https://... (JSON)
    var handJSONPath: String? = nil     // --handJSON /chemin/points.json
    var handAPIEvery: Int = 5           // --handAPIEvery 5   (toutes les N frames)
    var handAPINormalized: Bool = true  // --handAPINormalized (x,y dans [0,1])
    var handDemo: String? = nil         // --handDemo open|pinch|fist
    var handPreferAPI: Bool = true      // --handPreferAPI (sinon fallback Vision d'abord)
}

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
    let handCalib: HandCalibration?
    let hotspots: [HotBox]
}

// MARK: - Calibration: hex helpers (outil .NET/C++ externe accepté)
private func hexToBytes(_ hex: String) -> [UInt8]? {
    let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "0x", with: "")
        .replacingOccurrences(of: "0X", with: "")
        .replacingOccurrences(of: " ", with: "")
    guard s.count % 2 == 0, !s.isEmpty else { return nil }
    var out = [UInt8]()
    out.reserveCapacity(s.count/2)
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        let byteStr = s[i..<j]
        if let b = UInt8(byteStr, radix: 16) {
            out.append(b)
        } else { return nil }
        i = j
    }
    return out
}
private func readFloatLE(_ bytes: [UInt8], _ ofs: Int) -> Float? {
    guard ofs+3 < bytes.count else { return nil }
    let v = UInt32(bytes[ofs]) |
            (UInt32(bytes[ofs+1]) << 8) |
            (UInt32(bytes[ofs+2]) << 16) |
            (UInt32(bytes[ofs+3]) << 24)
    var f = Float.zero
    withUnsafeMutableBytes(of: &f) { $0.copyBytes(from: withUnsafeBytes(of: v) { Data($0) }) }
    return f
}
private func parseCalibrationHex(_ hex: String) -> HandCalibration? {
    guard let bytes = hexToBytes(hex) else { return nil }
    guard let g = readFloatLE(bytes, 0), let o = readFloatLE(bytes, 4) else { return nil }
    let ver = (bytes.count > 8) ? Int(bytes[8]) : 1
    return HandCalibration(gain: g, offset: o, version: ver, rawHex: hex)
}

// Exécute un outil externe (ex: .NET/C++) et récupère un hex sur stdout
private func fetchCalibHexFromCommand(_ commandLine: String) -> String? {
    let comps = ["bash","-lc", commandLine]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = comps
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError  = Pipe()
    do {
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: data, encoding: .utf8) {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    } catch { }
    return nil
}

// MARK: - Provider externe de landmarks (API/JSON/Démo)
private let MEDIAPIPE_HAND_INDEX: [Int:String] = [
    0:"wrist",
    1:"thumbCMC", 2:"thumbMP", 3:"thumbIP", 4:"thumbTip",
    5:"indexMCP", 6:"indexPIP", 7:"indexDIP", 8:"indexTip",
    9:"middleMCP",10:"middlePIP",11:"middleDIP",12:"middleTip",
    13:"ringMCP", 14:"ringPIP", 15:"ringDIP", 16:"ringTip",
    17:"littleMCP",18:"littlePIP",19:"littleDIP",20:"littleTip"
]

private func denorm(_ x: CGFloat, _ y: CGFloat, W: Int, H: Int) -> CGPoint {
    CGPoint(x: x * CGFloat(W), y: (1.0 - y) * CGFloat(H)) // convention Vision (y down)
}

// Format simple (recommandé) :
// {
//   "normalized": true,
//   "points":[ {"name":"wrist","x":0.42,"y":0.80}, ... ]
// }
private func parseSimpleHandJSON(_ data: Data, W: Int, H: Int, normalizedDefault: Bool) -> HandLandmarks? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
          let arr = obj["points"] as? [[String:Any]] else { return nil }
    let normalized = (obj["normalized"] as? Bool) ?? normalizedDefault
    var pts: [String:CGPoint] = [:]
    for it in arr {
        guard let name = it["name"] as? String,
              let x = (it["x"] as? NSNumber)?.doubleValue,
              let y = (it["y"] as? NSNumber)?.doubleValue else { continue }
        let p: CGPoint = normalized ? denorm(CGFloat(x), CGFloat(y), W: W, H: H)
                                    : CGPoint(x: CGFloat(x), y: CGFloat(y))
        pts[name] = p
    }
    guard !pts.isEmpty else { return nil }
    let hull = convexHull(Array(pts.values))
    return HandLandmarks(points: pts, hull: hull)
}

// MediaPipe NormalizedLandmarkList :
// {"landmarks":[{"x":0.1,"y":0.2,"z":...}, ... 21 points ...]}
private func parseMediaPipeHandJSON(_ data: Data, W: Int, H: Int) -> HandLandmarks? {
    func toPts(_ list: [[String:Any]]) -> HandLandmarks? {
        var pts: [String:CGPoint] = [:]
        for (i, lm) in list.enumerated() {
            guard let x = (lm["x"] as? NSNumber)?.doubleValue,
                  let y = (lm["y"] as? NSNumber)?.doubleValue else { continue }
            if let name = MEDIAPIPE_HAND_INDEX[i] {
                pts[name] = denorm(CGFloat(x), CGFloat(y), W: W, H: H)
            }
        }
        guard !pts.isEmpty else { return nil }
        return HandLandmarks(points: pts, hull: convexHull(Array(pts.values)))
    }

    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
       let arr = obj["landmarks"] as? [[String:Any]] {
        return toPts(arr)
    }
    // certains dumps sont un tableau direct de 21 points :
    if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String:Any]] {
        return toPts(arr)
    }
    return nil
}

// Démo hors-ligne : mains synthétiques (open / pinch / fist)
private func demoHand(_ name: String, W: Int, H: Int) -> HandLandmarks? {
    let n = name.lowercased()
    let cx = CGFloat(W) * 0.50, cy = CGFloat(H) * 0.55
    let scale: CGFloat = min(CGFloat(W), CGFloat(H)) * 0.18

    func P(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: cx + dx*scale, y: cy + dy*scale) }

    var pts: [String:CGPoint] = [:]
    // base "open" (doigts écartés)
    pts["wrist"] = P(0.00, 0.80)
    pts["thumbCMC"] = P(-0.35, 0.35); pts["thumbMP"] = P(-0.42, 0.20); pts["thumbIP"] = P(-0.46, 0.05); pts["thumbTip"] = P(-0.48, -0.08)
    pts["indexMCP"] = P(-0.18, 0.05); pts["indexPIP"] = P(-0.12, -0.20); pts["indexDIP"] = P(-0.08, -0.35); pts["indexTip"] = P(-0.04, -0.50)
    pts["middleMCP"] = P(0.00, 0.00); pts["middlePIP"] = P(0.00, -0.25); pts["middleDIP"] = P(0.00, -0.45); pts["middleTip"] = P(0.00, -0.65)
    pts["ringMCP"] = P(0.18, 0.05); pts["ringPIP"] = P(0.12, -0.18); pts["ringDIP"] = P(0.08, -0.32); pts["ringTip"] = P(0.05, -0.46)
    pts["littleMCP"] = P(0.32, 0.12); pts["littlePIP"] = P(0.26, -0.05); pts["littleDIP"] = P(0.22, -0.15); pts["littleTip"] = P(0.20, -0.26)

    if n == "pinch" {
        // pouce/index rapprochés
        pts["thumbTip"] = P(-0.06, -0.42)
        pts["indexTip"] = P(-0.06, -0.44)
    } else if n == "fist" {
        // fermer doigts vers paume
        ["index","middle","ring","little"].forEach { f in
            pts["\(f)PIP"] = P(0.0, 0.10)
            pts["\(f)DIP"] = P(0.0, 0.18)
            pts["\(f)Tip"] = P(0.0, 0.22)
        }
    }
    return HandLandmarks(points: pts, hull: convexHull(Array(pts.values)))
}

// Source combinée API/JSON/Démo
final class HandSource {
    let cfg: HeatConfig
    let W: Int, H: Int
    var last: HandLandmarks? = nil
    var fetchCount = 0

    init(cfg: HeatConfig, W: Int, H: Int) {
        self.cfg = cfg; self.W = W; self.H = H
    }

    private func fetchAPI() -> HandLandmarks? {
        guard let url = cfg.handAPIURL else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var dataOut: Data? = nil
        URLSession.shared.dataTask(with: url) { data,_,_ in dataOut = data; sem.signal() }.resume()
        sem.wait()
        guard let data = dataOut, !data.isEmpty else { return nil }
        // tente simple, sinon MediaPipe
        return parseSimpleHandJSON(data, W: W, H: H, normalizedDefault: cfg.handAPINormalized)
            ?? parseMediaPipeHandJSON(data, W: W, H: H)
    }

    private func fetchFile() -> HandLandmarks? {
        guard let p = cfg.handJSONPath else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return nil }
        return parseSimpleHandJSON(data, W: W, H: H, normalizedDefault: cfg.handAPINormalized)
            ?? parseMediaPipeHandJSON(data, W: W, H: H)
    }

    func next(frameIndex: Int) -> HandLandmarks? {
        // Démo prioritaire si demandée
        if let d = cfg.handDemo, let h = demoHand(d, W: W, H: H) { last = h; return h }

        // API/JSON périodique
        if (cfg.handAPIURL != nil || cfg.handJSONPath != nil) && (frameIndex % max(1, cfg.handAPIEvery) == 0) {
            if let h = fetchAPI() ?? fetchFile() { last = h; return h }
        }
        return last
    }
}

// MARK: - GPU compute
final class ThermalGPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    let loader: MTKTextureLoader

    init() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "ThermalHeatmap", code: 1, userInfo: [NSLocalizedDescriptionKey:"Metal indisponible"])
        }
        device = dev
        guard let q = dev.makeCommandQueue() else {
            throw NSError(domain: "ThermalHeatmap", code: 2, userInfo: [NSLocalizedDescriptionKey:"MTLCommandQueue fail"])
        }
        queue = q
        loader = MTKTextureLoader(device: dev)

        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void heatScore(texture2d<float, access::sample> inTex [[texture(0)]],
                              texture2d<float, access::write>  outTex[[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
            uint W = outTex.get_width(), H = outTex.get_height();
            if (gid.x >= W || gid.y >= H) return;
            constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
            float2 uv = float2(gid) + float2(0.5, 0.5);
            float4 c = inTex.sample(s, uv);
            float r=c.r, g=c.g, b=c.b;
            float luma = dot(float3(r,g,b), float3(0.2126,0.7152,0.0722));
            float redDom = r/(g+b+1e-4);
            float warmBoost = max(r-max(g,b),0.0);
            float cmax=max(r,max(g,b)), cmin=min(r,min(g,b));
            float sat=(cmax-cmin)/(cmax+1e-6);
            float score=luma*(0.5+0.5*sat)*(0.5+0.5*redDom)+warmBoost;
            outTex.write(clamp(score,0.0,1.0), gid);
        }
        """
        let lib = try dev.makeLibrary(source: src, options: nil)
        guard let fn = lib.makeFunction(name: "heatScore") else {
            throw NSError(domain: "ThermalHeatmap", code: 3, userInfo: [NSLocalizedDescriptionKey:"Metal fn missing"])
        }
        pipeline = try dev.makeComputePipelineState(function: fn)
    }

    func heatTexture(from cg: CGImage) throws -> MTLTexture {
        let texIn = try loader.newTexture(cgImage: cg, options: [
            MTKTextureLoader.Option.SRGB: false
        ])
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: cg.width, height: cg.height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        guard let texOut = device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "ThermalHeatmap", code: 4, userInfo: [NSLocalizedDescriptionKey:"Texture alloc fail"])
        }
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw NSError(domain: "ThermalHeatmap", code: 5, userInfo: [NSLocalizedDescriptionKey:"MTL encode fail"])
        }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texIn, index: 0)
        enc.setTexture(texOut, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: cg.width, height: cg.height, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        return texOut
    }

    func readFloatArray(from tex: MTLTexture) -> [Float] {
        var arr = [Float](repeating: 0, count: tex.width * tex.height)
        arr.withUnsafeMutableBytes { buf in
            tex.getBytes(buf.baseAddress!, bytesPerRow: tex.width*MemoryLayout<Float>.size,
                         from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
        }
        return arr
    }
}

// MARK: - Analyse CPU
func heatArrayCPU(from cg: CGImage) -> [Float] {
    let W = cg.width, H = cg.height
    var out = [Float](repeating: 0, count: W*H)
    var buf = [UInt8](repeating: 0, count: W * H * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    guard let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W*4, space: cs, bitmapInfo: info.rawValue) else { return out }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    for i in 0..<(W*H) {
        let j = i*4
        let r = Float(buf[j+0])/255.0, g = Float(buf[j+1])/255.0, b = Float(buf[j+2])/255.0
        let luma = 0.2126*r + 0.7152*g + 0.0722*b
        let redDom = r / (g + b + 1e-4)
        let warmBoost = max(r - max(g,b), 0.0)
        let cmax = max(r, max(g,b)), cmin = min(r, min(g,b))
        let sat = (cmax - cmin) / (cmax + 1e-6)
        let score = luma * (0.5 + 0.5*sat) * (0.5 + 0.5*redDom) + warmBoost
        out[i] = clamp(score, 0.0, 1.0)
    }
    return out
}

// MARK: - Blur 5x5
func blur5x5(_ src: [Float], w: Int, h: Int) -> [Float] {
    var tmp = [Float](repeating: 0, count: w*h)
    var dst = [Float](repeating: 0, count: w*h)
    for y in 0..<h {
        for x in 0..<w {
            var acc: Float = 0
            for xx in max(0, x-2)...min(w-1, x+2) { acc += src[y*w + xx] }
            tmp[y*w + x] = acc / 5
        }
    }
    for x in 0..<w {
        for y in 0..<h {
            var acc: Float = 0
            for yy in max(0, y-2)...min(h-1, y+2) { acc += tmp[yy*w + x] }
            dst[y*w + x] = acc / 5
        }
    }
    return dst
}

// MARK: - Connected components (hotspots)
private func components(from mask: [UInt8], w: Int, h: Int, minPix: Int, score: [Float]) -> [HotBox] {
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

// MARK: - Dégradé couleur
@inline(__always)
private func heatColor(_ t: Float) -> (r: UInt8,g: UInt8,b: UInt8) {
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

@inline(__always)
private func invertPremultipliedRGBA(_ overlay: inout [UInt8]) {
    // Inversion des couleurs en espace prémultiplié : c := a - c
    var i = 0
    let n = overlay.count / 4
    while i < n {
        let base = i*4
        let a = overlay[base+3]
        overlay[base+0] = a &- overlay[base+0]
        overlay[base+1] = a &- overlay[base+1]
        overlay[base+2] = a &- overlay[base+2]
        i += 1
    }
}

// MARK: - Conversion score -> °C (avec calibration si dispo)
@inline(__always)
private func scoreToC(_ s: Float, cfg: HeatConfig) -> Float {
    let sc = powf(clamp(s, 0, 1), cfg.gamma)
    if let c = cfg.handCalib {
        // Modèle étalonné: gain*score^gamma + offset
        return c.gain * sc + c.offset
    } else {
        // Modèle générique ambient->maxC
        return cfg.ambientC + (cfg.maxC - cfg.ambientC) * sc
    }
}

// MARK: - Rendu & annotation
enum ThermoRenderer {
    static func buildOverlay(from smooth: [Float], W: Int, H: Int,
                             pLow: Float, pHigh: Float,
                             gamma: Float, alphaMax: Float) -> ([UInt8],[HotBox]) {
        precondition(smooth.count == W*H)
        let thrLow  = percentile(smooth, p: pLow)
        let thrHigh = percentile(smooth, p: pHigh)

        var mask = [UInt8](repeating: 0, count: W*H)
        for i in 0..<smooth.count { mask[i] = (smooth[i] >= thrHigh) ? 255 : 0 }
        let minPix = max(48, (W*H)/2000)
        let boxes = components(from: mask, w: W, h: H, minPix: minPix, score: smooth)

        var overlay = [UInt8](repeating: 0, count: W*H*4)
        for i in 0..<W*H {
            let t = clamp((smooth[i] - thrLow) / max(1e-6, (thrHigh - thrLow)), 0 as Float, 1 as Float)
            let tg = powf(t, gamma)
            let (r8,g8,b8) = heatColor(tg)
            let a8 = UInt8(clamp(Int(Float(255)*alphaMax*tg), 0, 255))
            // premultiply
            overlay[i*4+0] = UInt8((UInt16(r8) * UInt16(a8)) / 255)
            overlay[i*4+1] = UInt8((UInt16(g8) * UInt16(a8)) / 255)
            overlay[i*4+2] = UInt8((UInt16(b8) * UInt16(a8)) / 255)
            overlay[i*4+3] = a8
        }
        return (overlay, boxes)
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

    static func composeOntoContext(ctx: CGContext,
                                   frame: CGImage,
                                   overlay: [UInt8], W: Int, H: Int,
                                   config: HeatConfig,
                                   boxes: inout [HotBox]) {
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: W, height: H))

        let data = Data(overlay)
        guard let prov = CGDataProvider(data: data as CFData) else { return }
        guard let overCG = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W*4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        ctx.draw(overCG, in: CGRect(x: 0, y: 0, width: W, height: H))

        drawLegend(ctx: ctx, ambient: config.ambientC, maxC: config.maxC, W: W, H: H)

        // annotations hotspots (top 5) + maj tempC (avec calibration si dispo)
        let font = NSFont.boldSystemFont(ofSize: 14)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black, .strokeWidth: -3.0
        ]
        for (k, b) in boxes.prefix(5).enumerated() {
            let rect = b.rect
            let meanT = scoreToC(b.meanScore, cfg: config)
            let label = String(format: "HOT#%d  ~%.0f°C", k+1, meanT)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.4, blue: 0, alpha: 0.95))
            ctx.setLineWidth(2.5)
            ctx.stroke(rect)
            let str = NSAttributedString(string: label, attributes: textAttrs)
            let tx = rect.origin.x
            var ty = rect.origin.y - str.size().height - 2
            if ty < 0 { ty = rect.maxY + 2 }
            str.draw(at: CGPoint(x: tx, y: ty))
            boxes[k] = HotBox(rect: rect, pixels: b.pixels, meanScore: b.meanScore, tempC: meanT)
        }
    }

    static func drawPanelTitle(ctx: CGContext, title: String, W: Int, H: Int) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 16),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0
        ]
        let str = NSAttributedString(string: title, attributes: attrs)
        str.draw(at: CGPoint(x: 12, y: CGFloat(H) - 28))
    }
}

// MARK: - Vision mains : landmarks, masque, métriques, CSV
struct HandLandmarks {
    let points: [String: CGPoint]
    let hull: [CGPoint]
}

func convexHull(_ pts: [CGPoint]) -> [CGPoint] {
    if pts.count <= 1 { return pts }
    let ptsSorted = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x)*(b.y - o.y) - (a.y - o.y)*(b.x - o.x)
    }
    var lower: [CGPoint] = []
    for p in ptsSorted {
        while lower.count >= 2 && cross(lower[lower.count-2], lower.last!, p) <= 0 { _ = lower.popLast() }
        lower.append(p)
    }
    var upper: [CGPoint] = []
    for p in ptsSorted.reversed() {
        while upper.count >= 2 && cross(upper[upper.count-2], upper.last!, p) <= 0 { _ = upper.popLast() }
        upper.append(p)
    }
    lower.removeLast(); upper.removeLast()
    return lower + upper
}

func detectHandLandmarks(in cg: CGImage) -> HandLandmarks? {
    let req = VNDetectHumanHandPoseRequest()
    req.maximumHandCount = 1

    let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
    do { try handler.perform([req]) } catch { return nil }
    guard let obs = req.results?.first else { return nil }

    typealias J = VNHumanHandPoseObservation.JointName
    let keys: [(J, String)] = [
        (.wrist, "wrist"),
        (.thumbTip, "thumbTip"), (.thumbIP, "thumbIP"), (.thumbMP, "thumbMP"), (.thumbCMC, "thumbCMC"),
        (.indexTip, "indexTip"), (.indexDIP, "indexDIP"), (.indexPIP, "indexPIP"), (.indexMCP, "indexMCP"),
        (.middleTip,"middleTip"), (.middleDIP,"middleDIP"), (.middlePIP,"middlePIP"), (.middleMCP,"middleMCP"),
        (.ringTip,  "ringTip"),   (.ringDIP,  "ringDIP"),  (.ringPIP,  "ringPIP"),  (.ringMCP,  "ringMCP"),
        (.littleTip,"littleTip"), (.littleDIP,"littleDIP"),(.littlePIP,"littlePIP"),(.littleMCP,"littleMCP")
    ]

    var pts: [String: CGPoint] = [:]
    let W = CGFloat(cg.width), H = CGFloat(cg.height)

    for (joint, name) in keys {
        if let p = try? obs.recognizedPoint(joint), p.confidence > 0.2 {
            let x = CGFloat(p.location.x) * W
            let y = (1 - CGFloat(p.location.y)) * H
            pts[name] = CGPoint(x: x, y: y)
        }
    }

    guard !pts.isEmpty else { return nil }
    let hull = convexHull(Array(pts.values))
    return HandLandmarks(points: pts, hull: hull)
}

func rasterizeMask(width: Int, height: Int, polygon: [CGPoint]) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: width*height)
    guard !polygon.isEmpty else { return buf }
    buf.withUnsafeMutableBytes { raw in
        if let base = raw.baseAddress {
            let cs = CGColorSpaceCreateDeviceGray()
            let ctx = CGContext(data: base, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width,
                                space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            let path = CGMutablePath()
            path.addLines(between: polygon)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }
    }
    return buf
}

func applyMaskToOverlay(overlay: inout [UInt8], W: Int, H: Int, mask: [UInt8]) {
    let n = W*H
    guard mask.count == n else { return }
    for i in 0..<n {
        let m = UInt16(mask[i])
        overlay[i*4+0] = UInt8((UInt16(overlay[i*4+0]) * m) / 255)
        overlay[i*4+1] = UInt8((UInt16(overlay[i*4+1]) * m) / 255)
        overlay[i*4+2] = UInt8((UInt16(overlay[i*4+2]) * m) / 255)
        overlay[i*4+3] = UInt8((UInt16(overlay[i*4+3]) * m) / 255)
    }
}

struct HandMetrics: Codable {
    let tSec: Double
    let palmWidth: Double
    let palmToMiddleTip: Double
    let indexToLittleSpread: Double
    let areaHullPx: Double
    let indexRel: Double
    let ringRel: Double
    let littleRel: Double
    let handMaskMeanScore: Double
    let estSkinTempC: Double
}

func polygonArea(_ poly: [CGPoint]) -> CGFloat {
    guard poly.count >= 3 else { return 0 }
    var s: CGFloat = 0
    for i in 0..<poly.count {
        let a = poly[i], b = poly[(i+1)%poly.count]
        s += (a.x*b.y - a.y*b.x)
    }
    return abs(s) * 0.5
}
func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

func computeHandMetrics(land: HandLandmarks, tSec: Double, smooth: [Float]?, W: Int, cfg: HeatConfig) -> HandMetrics {
    let p = land.points
    func L(_ k: String) -> CGPoint? { p[k] }
    let palmW = (L("indexMCP").flatMap { i in L("littleMCP").map { dist(i,$0) } }) ??
                (L("wrist").flatMap { w in L("middleMCP").map { dist(w,$0) } }) ?? 0
    let palm2Mid = (L("wrist").flatMap { w in L("middleTip").map { dist(w,$0) } }) ?? 0
    let spread = (L("indexMCP").flatMap { i in L("littleMCP").map { dist(i,$0) } }) ?? 0
    func fingerLen(mcp: String, tip: String) -> CGFloat {
        guard let a = L(mcp), let b = L(tip) else { return 0 }
        return dist(a,b)
    }
    let mid = fingerLen(mcp: "middleMCP", tip: "middleTip")
    let idx = fingerLen(mcp: "indexMCP", tip: "indexTip")
    let rng = fingerLen(mcp: "ringMCP",  tip: "ringTip")
    let ltt = fingerLen(mcp: "littleMCP",tip: "littleTip")
    let area = polygonArea(land.hull)

    var meanScore: Double = 0
    var skinC: Double = 0
    if let sm = smooth, W > 0, area > 0 {
        // simple raster (bounding box + point-in-poly)
        let H = sm.count / W
        let minx = Int(land.hull.map{$0.x}.min() ?? 0)
        let maxx = Int(land.hull.map{$0.x}.max() ?? CGFloat(W-1))
        let miny = Int(land.hull.map{$0.y}.min() ?? 0)
        let maxy = Int(land.hull.map{$0.y}.max() ?? CGFloat(H-1))
        func inside(_ pt: CGPoint, poly: [CGPoint]) -> Bool {
            var wn = 0
            for i in 0..<poly.count {
                let a = poly[i], b = poly[(i+1)%poly.count]
                if a.y <= pt.y {
                    if b.y > pt.y && ((b.x - a.x) * (pt.y - a.y) - (pt.x - a.x) * (b.y - a.y)) > 0 { wn += 1 }
                } else {
                    if b.y <= pt.y && ((b.x - a.x) * (pt.y - a.y) - (pt.x - a.x) * (b.y - a.y)) < 0 { wn -= 1 }
                }
            }
            return wn != 0
        }
        var sum: Double = 0
        var n: Int = 0
        for y in max(0,miny)...min(H-1,maxy) {
            for x in max(0,minx)...min(W-1,maxx) {
                if inside(CGPoint(x: x, y: y), poly: land.hull) {
                    sum += Double(sm[y*W + x])
                    n += 1
                }
            }
        }
        if n > 0 {
            meanScore = sum / Double(n)
            skinC = Double(scoreToC(Float(meanScore), cfg: cfg))
        }
    }

    return HandMetrics(
        tSec: tSec,
        palmWidth: Double(palmW),
        palmToMiddleTip: Double(palm2Mid),
        indexToLittleSpread: Double(spread),
        areaHullPx: Double(area),
        indexRel: mid > 0 ? Double(idx/mid) : 0,
        ringRel:  mid > 0 ? Double(rng/mid) : 0,
        littleRel:mid > 0 ? Double(ltt/mid) : 0,
        handMaskMeanScore: meanScore,
        estSkinTempC: skinC
    )
}

final class CSVWriter {
    let fh: FileHandle
    init?(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: path) else { return nil }
        self.fh = fh
        writeHeader()
    }
    func writeHeader() {
        writeLine("tSec,palmWidth,palmToMiddleTip,indexToLittleSpread,areaHullPx,indexRel,ringRel,littleRel,handMaskMeanScore,estSkinTempC\n")
    }
    func write(_ m: HandMetrics) {
        let line = String(format: "%.3f,%.3f,%.3f,%.3f,%.1f,%.3f,%.3f,%.3f,%.5f,%.3f\n",
                          m.tSec, m.palmWidth, m.palmToMiddleTip, m.indexToLittleSpread,
                          m.areaHullPx, m.indexRel, m.ringRel, m.littleRel, m.handMaskMeanScore, m.estSkinTempC)
        writeLine(line)
    }
    private func writeLine(_ s: String) {
        if let data = s.data(using: .utf8) { try? fh.write(contentsOf: data) }
    }
    deinit { try? fh.close() }
}

func drawHandSkeleton(ctx: CGContext, hand: HandLandmarks) {
    ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 1.0, blue: 0.2, alpha: 0.9))
    ctx.setLineWidth(2.0)
    func line(_ a: String, _ b: String) {
        if let p1 = hand.points[a], let p2 = hand.points[b] {
            ctx.beginPath(); ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
        }
    }
    ["index","middle","ring","little"].forEach { f in
        line("\(f)MCP","\(f)PIP"); line("\(f)PIP","\(f)DIP"); line("\(f)DIP","\(f)Tip")
    }
    line("thumbCMC","thumbMP"); line("thumbMP","thumbIP"); line("thumbIP","thumbTip")
    if let w = hand.points["wrist"], let mcp = hand.points["middleMCP"] {
        ctx.setStrokeColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.2, alpha: 0.9))
        ctx.beginPath(); ctx.move(to: w); ctx.addLine(to: mcp); ctx.strokePath()
    }
}

// MARK: - Writer
func makeWriter(outputURL: URL, width: Int, height: Int) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
    try prepareOutputFile(outputURL)

    let fileType: AVFileType = outputURL.pathExtension.lowercased() == "mov" ? .mov : .mp4
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: max(4_000_000, width*height*4),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
    guard writer.canAdd(input) else { throw NSError(domain: "ThermalHeatmap", code: 10, userInfo: [NSLocalizedDescriptionKey:"Writer input add fail"]) }
    writer.add(input)
    return (writer, input, adaptor)
}

func makeContextForPixelBuffer(_ pb: CVPixelBuffer) -> CGContext? {
    CVPixelBufferLockBaseAddress(pb, [])
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)) // BGRA
    let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs, bitmapInfo: info.rawValue)
    return ctx
}

// MARK: - Chargement bloquant
@discardableResult
func loadAssetBlocking(_ asset: AVURLAsset) -> Bool {
    let sem = DispatchSemaphore(value: 0)
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { sem.signal() }
    sem.wait()
    for k in ["tracks", "duration"] {
        var err: NSError?
        if asset.statusOfValue(forKey: k, error: &err) != .loaded {
            fputs("⚠️ load fail for key \(k): \(String(describing: err))\n", stderr)
            return false
        }
    }
    return true
}

// MARK: - Frame → smooth + overlay + boxes
func processFrame(cg: CGImage, cfg: HeatConfig, gpu: ThermalGPU?) -> (smooth: [Float], overlay: [UInt8], boxes: [HotBox]) {
    let W = cg.width, H = cg.height
    let scores: [Float]
    if let g = gpu, let tex = try? g.heatTexture(from: cg) {
        scores = g.readFloatArray(from: tex)
    } else {
        scores = heatArrayCPU(from: cg)
    }
    let smooth = blur5x5(scores, w: W, h: H)
    let (overlay, boxes) = ThermoRenderer.buildOverlay(from: smooth, W: W, H: H, pLow: cfg.pLow, pHigh: cfg.pHigh, gamma: cfg.gamma, alphaMax: cfg.alphaMax)
    return (smooth, overlay, boxes)
}

// MARK: - DataLake client
struct DataLakeEvent: Codable {
    let file: String
    let tSec: Double
    let width: Int
    let height: Int
    let handCalib: HandCalibration?
    let handMetrics: HandMetrics?
    let hotspots: [HotBox]
    let ema: Bool
    let negEMA: Bool
    let stat: String
    let percentileLow: Float
    let percentileHigh: Float
    let ambientC: Float
    let maxC: Float
    let gamma: Float
}
final class DataLakeClient {
    let url: URL
    let bearer: String?
    let headerKV: (String,String)?
    let session = URLSession(configuration: .default)
    init(url: URL, bearer: String?, headerKV: (String,String)?) {
        self.url = url; self.bearer = bearer; self.headerKV = headerKV
    }
    func post(event: DataLakeEvent) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = bearer { req.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        if let kv = headerKV { req.setValue(kv.1, forHTTPHeaderField: kv.0) }
        do {
            req.httpBody = try JSONEncoder().encode(event)
            let task = session.dataTask(with: req) { _,_,_ in /* best-effort */ }
            task.resume()
        } catch { /* ignore */ }
    }
}

// MARK: - Helpers panel offscreen
func renderPanelCG(frame: CGImage, overlay: [UInt8], W: Int, H: Int, cfg: HeatConfig, boxes: inout [HotBox], title: String, hand: HandLandmarks?) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ThermoRenderer.composeOntoContext(ctx: ctx, frame: frame, overlay: overlay, W: W, H: H, config: cfg, boxes: &boxes)
    if let h = hand { drawHandSkeleton(ctx: ctx, hand: h) }
    ThermoRenderer.drawPanelTitle(ctx: ctx, title: title, W: W, H: H)
    return ctx.makeImage()
}

// MARK: - PNG (image unique)
func exportSinglePNG(asset: AVAsset, inputPath: String, outPath: String, cfg: HeatConfig, forceCPU: Bool) -> Int32 {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceAfter  = .zero
    gen.requestedTimeToleranceBefore = .zero

    let durSec = max(0.0, CMTimeGetSeconds(asset.duration))
    let mid = CMTime(seconds: max(0.0, durSec * 0.5), preferredTimescale: 600)
    guard var frame = try? gen.copyCGImage(at: mid, actualTime: nil) else {
        fputs("Impossible d'extraire la frame centrale.\n", stderr); return 3
    }

    let W = even(frame.width), H = even(frame.height)
    if W != frame.width || H != frame.height, let f2 = frame.cropping(to: CGRect(x: 0, y: 0, width: W, height: H)) {
        frame = f2
    }

    var gpu: ThermalGPU? = nil
    if !forceCPU { gpu = try? ThermalGPU() }

    var (smooth, overlayBase, boxesBase) = processFrame(cg: frame, cfg: cfg, gpu: gpu)

    // Hand & masque (Vision ou Source externe)
    var hand: HandLandmarks? = nil
    if cfg.handDemo != nil || cfg.handAPIURL != nil || cfg.handJSONPath != nil {
        let hs = HandSource(cfg: cfg, W: W, H: H)
        // si préférence API/JSON/Démo
        hand = hs.next(frameIndex: 0)
        if hand == nil && !cfg.handPreferAPI {
            hand = detectHandLandmarks(in: frame)
        }
        if hand == nil && cfg.handPreferAPI {
            hand = detectHandLandmarks(in: frame)
        }
    } else if cfg.handOnly {
        hand = detectHandLandmarks(in: frame)
    }

    if cfg.handOnly, let h = hand {
        let mask = rasterizeMask(width: W, height: H, polygon: h.hull)
        applyMaskToOverlay(overlay: &overlayBase, W: W, H: H, mask: mask)
    }

    // EMA?
    let doTwoUp = cfg.twoUp || (cfg.emaAlpha != nil)
    var overlayEMA: [UInt8]? = nil
    if let a = cfg.emaAlpha {
        var ema = smooth
        for i in 0..<ema.count { ema[i] = a*smooth[i] + (1-a)*ema[i] }
        let (ov, _) = ThermoRenderer.buildOverlay(from: ema, W: W, H: H, pLow: cfg.pLow, pHigh: cfg.pHigh, gamma: cfg.gamma, alphaMax: cfg.alphaMax)
        var ov2 = ov
        if cfg.negEMA { invertPremultipliedRGBA(&ov2) }
        if cfg.handOnly, let h = hand {
            let mask = rasterizeMask(width: W, height: H, polygon: h.hull)
            applyMaskToOverlay(overlay: &ov2, W: W, H: H, mask: mask)
        }
        overlayEMA = ov2
    }

    if !doTwoUp {
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fputs("CGContext fail\n", stderr); return 2 }
        ThermoRenderer.composeOntoContext(ctx: ctx, frame: frame, overlay: overlayBase, W: W, H: H, config: cfg, boxes: &boxesBase)
        if let h = hand { drawHandSkeleton(ctx: ctx, hand: h) }
        guard let outCG = ctx.makeImage() else { fputs("Export PNG fail (image)\n", stderr); return 3 }

        let url = URL(fileURLWithPath: outPath)
        do { try prepareOutputFile(url) } catch { fputs("\(error.localizedDescription)\n", stderr); return 3 }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            fputs("Export PNG fail (dest)\n", stderr); return 3
        }
        CGImageDestinationAddImage(dest, outCG, nil)
        CGImageDestinationFinalize(dest)
    } else {
        let W2 = even(W*2)
        guard let ctx = CGContext(data: nil, width: W2, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fputs("CGContext fail\n", stderr); return 2
        }
        var bx = boxesBase
        if let left = renderPanelCG(frame: frame, overlay: overlayBase, W: W, H: H, cfg: cfg, boxes: &bx, title: "BASE", hand: hand) {
            ctx.draw(left, in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        if let ovEMA = overlayEMA {
            var bx2: [HotBox] = []
            if let right = renderPanelCG(frame: frame, overlay: ovEMA, W: W, H: H, cfg: cfg, boxes: &bx2, title: "EMA (neg)", hand: hand) {
                ctx.draw(right, in: CGRect(x: W, y: 0, width: W, height: H))
            }
        } else if let left = renderPanelCG(frame: frame, overlay: overlayBase, W: W, H: H, cfg: cfg, boxes: &boxesBase, title: "BASE", hand: hand) {
            ctx.draw(left, in: CGRect(x: W, y: 0, width: W, height: H))
        }
        guard let outCG = ctx.makeImage() else { fputs("Export PNG fail (image)\n", stderr); return 3 }
        let url = URL(fileURLWithPath: outPath)
        do { try prepareOutputFile(url) } catch { fputs("\(error.localizedDescription)\n", stderr); return 3 }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            fputs("Export PNG fail (dest)\n", stderr); return 3
        }
        CGImageDestinationAddImage(dest, outCG, nil)
        CGImageDestinationFinalize(dest)
    }

    // JSON résumé
    let jsonPath = (outPath as NSString).deletingPathExtension + "_summary.json"
    let summary = Summary(file: inputPath, width: W, height: H, framesUsed: 1, stat: cfg.stat,
                          percentileLow: cfg.pLow, percentileHigh: cfg.pHigh,
                          ambientC: cfg.ambientC, maxC: cfg.maxC, gamma: cfg.gamma,
                          handCalib: cfg.handCalib, hotspots: boxesBase)
    if let data = try? JSONEncoder().encode(summary) { try? data.write(to: URL(fileURLWithPath: jsonPath)) }

    print("OK (image unique\(doTwoUp ? " two-up" : ""), \(boxesBase.count) hotspots) → \(outPath)")
    return 0
}

// MARK: - Vidéo continue (QuickTime-friendly)
func exportVideoContinuous(asset: AVURLAsset, inputPath: String, outPath: String, cfg: HeatConfig, forceCPU: Bool) -> Int32 {
    guard loadAssetBlocking(asset),
          let videoTrack = asset.tracks(withMediaType: .video).first else {
        fputs("Aucune piste vidéo.\n", stderr); return 3
    }

    // Reader BGRA
    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) } catch { fputs("AVAssetReader fail: \(error)\n", stderr); return 3 }
    let readerOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    guard reader.canAdd(readerOut) else { fputs("Reader output add fail\n", stderr); return 3 }
    reader.add(readerOut)

    // Dimensions orientées (pair)
    let natural = videoTrack.naturalSize
    let transform = videoTrack.preferredTransform
    let oriented = orientedExtent(natural, transform: transform)
    let W = max(2, even(Int(oriented.width.rounded())))
    let H = max(2, even(Int(oriented.height.rounded())))

    // two-up ?
    let doTwoUp = cfg.twoUp || (cfg.emaAlpha != nil)
    let writerW = doTwoUp ? even(W*2) : W
    let writerH = H

    // Writer
    let outURL = URL(fileURLWithPath: outPath)
    let (writer, writerInput, adaptor): (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)
    do {
        (writer, writerInput, adaptor) = try makeWriter(outputURL: outURL, width: writerW, height: writerH)
    } catch {
        fputs("AVAssetWriter fail: \(error)\n", stderr); return 3
    }

    // Contexte & Metal
    let ciContext = CIContext()
    var gpu: ThermalGPU? = nil
    if !forceCPU { gpu = try? ThermalGPU() }

    // CSV & détection main (toutes les N frames)
    var lastHand: HandLandmarks? = nil
    let detectEvery = 3
    let csv = cfg.csvPath.flatMap { CSVWriter(path: $0) }

    // Source de mains externe (API/JSON/Démo)
    let handSource = HandSource(cfg: cfg, W: W, H: H)

    // Accumulation (stat max) & EMA
    var accumMax: [Float]? = nil
    var emaBuf: [Float]? = nil
    let emaAlpha = cfg.emaAlpha

    // DataLake
    let datalake = (cfg.postURL != nil) ? DataLakeClient(url: cfg.postURL!, bearer: cfg.postBearer, headerKV: cfg.postHeaderKV) : nil

    // Start
    guard reader.startReading() else { fputs("Reader start fail: \(String(describing: reader.error))\n", stderr); return 3 }
    guard writer.startWriting() else { fputs("Writer start fail: \(String(describing: writer.error))\n", stderr); return 3 }
    writer.startSession(atSourceTime: .zero)

    var lastBoxes: [HotBox] = []
    var count = 0
    let t0 = CFAbsoluteTimeGetCurrent()

    while let sbuf = readerOut.copyNextSampleBuffer() {
        autoreleasepool {
            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
            guard let pb = CMSampleBufferGetImageBuffer(sbuf) else { return }

            // Appliquer l'orientation + normaliser origine à (0,0)
            var ci = CIImage(cvPixelBuffer: pb).transformed(by: transform)
            let ext = ci.extent
            ci = ci.transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
            guard let cg = ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: W, height: H)) else { return }

            // Analyse thermique base
            var (smooth, overlayBase, boxesBase) = processFrame(cg: cg, cfg: cfg, gpu: gpu)

            // Détection main périodique + CSV
            if count % detectEvery == 0 {
                if cfg.handDemo != nil || cfg.handAPIURL != nil || cfg.handJSONPath != nil {
                    if cfg.handPreferAPI {
                        lastHand = handSource.next(frameIndex: count) ?? lastHand
                        if lastHand == nil { lastHand = detectHandLandmarks(in: cg) }
                    } else {
                        lastHand = detectHandLandmarks(in: cg) ?? lastHand
                        if lastHand == nil { lastHand = handSource.next(frameIndex: count) }
                    }
                } else {
                    lastHand = detectHandLandmarks(in: cg) ?? lastHand
                }

                if let csv = csv, let hand = lastHand {
                    let tSec = CMTimeGetSeconds(pts)
                    let m = computeHandMetrics(land: hand, tSec: tSec, smooth: smooth, W: W, cfg: cfg)
                    csv.write(m)
                }
            }

            // --stat max pour base
            if cfg.stat == "max" {
                if accumMax == nil { accumMax = smooth }
                if var acc = accumMax {
                    let n = min(acc.count, smooth.count)
                    var i = 0
                    while i < n { acc[i] = max(acc[i], smooth[i]); i += 1 }
                    accumMax = acc
                    let res = ThermoRenderer.buildOverlay(from: acc, W: W, H: H, pLow: cfg.pLow, pHigh: cfg.pHigh, gamma: cfg.gamma, alphaMax: cfg.alphaMax)
                    overlayBase = res.0; boxesBase = res.1
                }
            }

            // Masque main pour base si demandé
            if cfg.handOnly, let hand = lastHand {
                var mOverlay = overlayBase
                let mask = rasterizeMask(width: W, height: H, polygon: hand.hull)
                applyMaskToOverlay(overlay: &mOverlay, W: W, H: H, mask: mask)
                overlayBase = mOverlay
            }

            // Panneau EMA (droit)
            var overlayEMA: [UInt8]? = nil
            if let a = emaAlpha {
                if emaBuf == nil { emaBuf = smooth } // init
                if var ema = emaBuf {
                    let n = min(ema.count, smooth.count)
                    var i = 0
                    while i < n { ema[i] = a*smooth[i] + (1-a)*ema[i]; i += 1 }
                    emaBuf = ema
                    var (ov, _) = ThermoRenderer.buildOverlay(from: ema, W: W, H: H, pLow: cfg.pLow, pHigh: cfg.pHigh, gamma: cfg.gamma, alphaMax: cfg.alphaMax)
                    if cfg.negEMA { invertPremultipliedRGBA(&ov) }
                    if cfg.handOnly, let hand = lastHand {
                        let mask = rasterizeMask(width: W, height: H, polygon: hand.hull)
                        applyMaskToOverlay(overlay: &ov, W: W, H: H, mask: mask)
                    }
                    overlayEMA = ov
                }
            }

            // Écriture frame
            if writerInput.isReadyForMoreMediaData {
                var outPBOpt: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPBOpt)
                }
                guard let outPB = outPBOpt else { return }
                guard let ctx = makeContextForPixelBuffer(outPB) else { CVPixelBufferUnlockBaseAddress(outPB, []); return }

                // Deux panneaux offscreen pour compositing
                if !doTwoUp {
                    var bx = boxesBase
                    ThermoRenderer.composeOntoContext(ctx: ctx, frame: cg, overlay: overlayBase, W: writerW, H: writerH, config: cfg, boxes: &bx)
                    if let hand = lastHand { drawHandSkeleton(ctx: ctx, hand: hand) }
                    ThermoRenderer.drawPanelTitle(ctx: ctx, title: "BASE", W: writerW, H: writerH)
                    lastBoxes = bx
                } else {
                    if let left = renderPanelCG(frame: cg, overlay: overlayBase, W: W, H: H, cfg: cfg, boxes: &boxesBase, title: "BASE", hand: lastHand) {
                        ctx.draw(left, in: CGRect(x: 0, y: 0, width: W, height: H))
                    }
                    if let ovEMA = overlayEMA {
                        var bx2: [HotBox] = []
                        if let right = renderPanelCG(frame: cg, overlay: ovEMA, W: W, H: H, cfg: cfg, boxes: &bx2, title: "EMA (neg)", hand: lastHand) {
                            ctx.draw(right, in: CGRect(x: W, y: 0, width: W, height: H))
                        }
                    } else {
                        var bx2 = boxesBase
                        if let right = renderPanelCG(frame: cg, overlay: overlayBase, W: W, H: H, cfg: cfg, boxes: &bx2, title: "BASE", hand: lastHand) {
                            ctx.draw(right, in: CGRect(x: W, y: 0, width: W, height: H))
                        }
                    }
                    lastBoxes = boxesBase
                }

                ctx.flush()
                CVPixelBufferUnlockBaseAddress(outPB, [])

                if !adaptor.append(outPB, withPresentationTime: pts) {
                    fputs("Writer append fail: \(String(describing: writer.error))\n", stderr)
                } else {
                    count += 1
                    if count % 30 == 0 {
                        let dt = CFAbsoluteTimeGetCurrent() - t0
                        fputs(String(format: "\rFrames écrites: %d (%.1fs)", count, dt), stderr)
                    }
                }
            }

            // --- DataLake POST (toutes les N frames) ---
            if let dl = datalake, count % max(1, cfg.postEvery) == 0 {
                let tSec = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sbuf))
                let hm: HandMetrics? = lastHand.map { computeHandMetrics(land: $0, tSec: tSec, smooth: smooth, W: W, cfg: cfg) }
                let ev = DataLakeEvent(
                    file: inputPath, tSec: tSec, width: writerW, height: writerH,
                    handCalib: cfg.handCalib, handMetrics: hm, hotspots: boxesBase,
                    ema: cfg.emaAlpha != nil, negEMA: cfg.negEMA, stat: cfg.stat,
                    percentileLow: cfg.pLow, percentileHigh: cfg.pHigh,
                    ambientC: cfg.ambientC, maxC: cfg.maxC, gamma: cfg.gamma
                )
                dl.post(event: ev)
            }
        }
    }

    writerInput.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()

    if reader.status == .failed { fputs("Reader fail: \(String(describing: reader.error))\n", stderr); return 3 }
    if writer.status == .failed { fputs("Writer fail: \(String(describing: writer.error))\n", stderr); return 3 }

    // Summary JSON
    let jsonPath = (outPath as NSString).deletingPathExtension + "_summary.json"
    let summary = Summary(file: inputPath, width: writerW, height: writerH, framesUsed: count, stat: cfg.stat,
                          percentileLow: cfg.pLow, percentileHigh: cfg.pHigh,
                          ambientC: cfg.ambientC, maxC: cfg.maxC, gamma: cfg.gamma,
                          handCalib: cfg.handCalib, hotspots: lastBoxes)
    if let data = try? JSONEncoder().encode(summary) { try? data.write(to: URL(fileURLWithPath: jsonPath)) }

    print("\nOK (vidéo continue\(doTwoUp ? " two-up" : ""), \(count) frames) → \(outPath)")
    return 0
}

// MARK: - Main
func run() -> Int32 {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        fputs("Usage:\n", stderr)
        fputs("  ThermalHeatmap <videoIn> out.mov [--cpu] [--stat avg|max] [--pLow 0.80] [--pHigh 0.98] [--ambient 22] [--maxC 120] [--gamma 1.2] [--alpha 0.6] [--handOnly] [--csv path.csv] [--ema 0.2] [--twoUp] [--negEMA]\n", stderr)
        fputs("                                 [--calibHex 0x...] | [--calibHexFile path] | [--calibCmd \"cmd ...\"]\n", stderr)
        fputs("                                 [--postURL https://...] [--postBearer token] [--postHeader \"K: V\"] [--postEvery 30]\n", stderr)
        fputs("                                 [--handAPI https://... | --handJSON path | --handDemo open|pinch|fist]\n", stderr)
        fputs("                                 [--handAPIEvery 5] [--handAPINormalized] [--handPreferAPI|--handPreferVision]\n", stderr)
        fputs("  ThermalHeatmap <videoIn> out.png  [mêmes options]\n", stderr)
        return 2
    }
    let inputPath = args[1]
    let outPath   = (args.count >= 3 && !args[2].hasPrefix("--")) ? args[2] : "heatmap_out.mov"
    let fileManager = FileManager.default
if !fileManager.fileExists(atPath: inputPath) {
    fputs("Erreur: Le fichier d'entrée `\(inputPath)` n'existe pas.\n", stderr)
    return 3
}

    func readVal(_ k: String) -> String? {
        if let i = args.firstIndex(of: k), i+1 < args.count { return args[i+1] }
        return nil
    }

    // --- Config ---
    var cfg = HeatConfig()
    if let s = readVal("--stat")                      { cfg.stat = (s=="max") ? "max" : "avg" }
    if let s = readVal("--pLow"),     let v = Float(s){ cfg.pLow = max(0, min(0.999, v)) }
    if let s = readVal("--pHigh"),    let v = Float(s){ cfg.pHigh = max(0, min(0.999, v)) }
    if let s = readVal("--ambient"),  let v = Float(s){ cfg.ambientC = v }
    if let s = readVal("--maxC"),     let v = Float(s){ cfg.maxC = v }
    if let s = readVal("--gamma"),    let v = Float(s){ cfg.gamma = max(0.1, v) }
    if let s = readVal("--alpha"),    let v = Float(s){ cfg.alphaMax = max(0, min(1, v)) }
    if let s = readVal("--csv")                      { cfg.csvPath = s }
    cfg.handOnly = args.contains("--handOnly")
    if let s = readVal("--ema"), let v = Float(s), v > 0, v <= 1 { cfg.emaAlpha = v; cfg.negEMA = true }
    if args.contains("--twoUp") { cfg.twoUp = true }
    if args.contains("--negEMA") { cfg.negEMA = true }

    // Calibration main : hex direct, fichier, ou commande externe (.NET/C++)
    if let hx = readVal("--calibHex"), let calib = parseCalibrationHex(hx) {
        cfg.handCalib = calib
    } else if let hp = readVal("--calibHexFile") {
        if let data = try? String(contentsOfFile: hp, encoding: .utf8),
           let calib = parseCalibrationHex(data) {
            cfg.handCalib = calib
        }
    } else if let cmd = readVal("--calibCmd") {
        if let s = fetchCalibHexFromCommand(cmd), let calib = parseCalibrationHex(s) {
            cfg.handCalib = calib
        }
    }

    // DataLake
    if let u = readVal("--postURL"), let url = URL(string: u) { cfg.postURL = url }
    if let b = readVal("--postBearer") { cfg.postBearer = b }
    if let h = readVal("--postHeader") {
        if let colon = h.firstIndex(of: ":") {
            let k = String(h[..<colon]).trimmingCharacters(in: .whitespaces)
            let v = String(h[h.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { cfg.postHeaderKV = (k,v) }
        }
    }
    if let s = readVal("--postEvery"), let n = Int(s), n > 0 { cfg.postEvery = n }

    // --- Options Hand API/JSON/Démo ---
    if let s = readVal("--handAPI"), let u = URL(string: s) { cfg.handAPIURL = u }
    if let s = readVal("--handJSON") { cfg.handJSONPath = s }
    if let s = readVal("--handAPIEvery"), let n = Int(s), n > 0 { cfg.handAPIEvery = n }
    if args.contains("--handAPINormalized") { cfg.handAPINormalized = true }
    if let s = readVal("--handDemo") { cfg.handDemo = s }  // open|pinch|fist
    if args.contains("--handPreferAPI") { cfg.handPreferAPI = true }
    if args.contains("--handPreferVision") { cfg.handPreferAPI = false }

    let forceCPU = args.contains("--cpu")
    let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))

    if outPath.lowercased().hasSuffix(".png") {
        return exportSinglePNG(asset: asset, inputPath: inputPath, outPath: outPath, cfg: cfg, forceCPU: forceCPU)
    } else {
        let out = isVideoPath(outPath) ? outPath : (outPath + ".mov")
        return exportVideoContinuous(asset: asset as AVURLAsset, inputPath: inputPath, outPath: out, cfg: cfg, forceCPU: forceCPU)
    }
}

exit(run())