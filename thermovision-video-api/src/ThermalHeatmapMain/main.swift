import Foundation
import AVFoundation



// CLI: ThermalHeatmap <video> [out.png] [--frames N] [--stat avg|max] [--pLow 0.80] [--pHigh 0.98] [--ambient 22] [--maxC 120] [--gamma 1.2] [--alpha 0.6]

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

@main
struct ThermalHeatmapMain {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("Usage: ThermalHeatmap <video> [out.png] [--frames N] [--stat avg|max] [--pLow 0.80] [--pHigh 0.98] [--ambient 22] [--maxC 120] [--gamma 1.2] [--alpha 0.6]\n", stderr)
            exit(2)
        }
        let videoPath = args[1]
        let outPath = (args.count >= 3 && !args[2].hasPrefix("--")) ? args[2] : "heatmap_overlay.png"

        func readVal(_ k: String) -> String? {
            if let i = args.firstIndex(of: k), i+1 < args.count { return args[i+1] }
            return nil
        }

        var cfg = HeatConfig()
        if let s = readVal("--frames"),   let v = Int(s)   { cfg.frames = max(1, v) }
        if let s = readVal("--stat")                      { cfg.stat = (s=="max") ? "max" : "avg" }
        if let s = readVal("--pLow"),     let v = Float(s) { cfg.pLow = max(0, min(0.999, v)) }
        if let s = readVal("--pHigh"),    let v = Float(s) { cfg.pHigh = max(0, min(0.999, v)) }
        if let s = readVal("--ambient"),  let v = Float(s) { cfg.ambientC = v }
        if let s = readVal("--maxC"),     let v = Float(s) { cfg.maxC = v }
        if let s = readVal("--gamma"),    let v = Float(s) { cfg.gamma = max(0.1, v) }
        if let s = readVal("--alpha"),    let v = Float(s) { cfg.alphaMax = max(0, min(1, v)) }

        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceAfter  = .zero
        gen.requestedTimeToleranceBefore = .zero

        // Échantillonnage temps
        let durSec = max(0.0, CMTimeGetSeconds(asset.duration))
        var times: [Double] = []
        if durSec == 0 || cfg.frames == 1 { times = [0.0] }
        else {
            for i in 0..<cfg.frames { times.append(durSec * (Double(i)+0.5)/Double(cfg.frames)) }
        }

        // Frame centrale pour fond
        let mid = CMTime(seconds: (times.count==1 ? 0.0 : durSec*0.5), preferredTimescale: 600)
        guard let frameMid = try? gen.copyCGImage(at: mid, actualTime: nil) else {
            fputs("Impossible d’extraire la frame centrale.\n", stderr); exit(3)
        }
        let W = frameMid.width, H = frameMid.height

        // GPU
        let gpu: ThermalGPU
        do { gpu = try ThermalGPU() } catch { fputs("Metal indisponible: \(error)\n", stderr); exit(4) }

        // Fusion des heat-scores
        var acc = [Float](repeating: 0, count: W*H)
        for ts in times {
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: ts, preferredTimescale: 600), actualTime: nil) else { continue }
            guard let tex = try? gpu.heatTexture(from: cg) else { continue }
            let arr = gpu.readFloatArray(from: tex)
            if cfg.stat == "max" {
                for i in 0..<acc.count { acc[i] = max(acc[i], arr[i]) }
            } else {
                for i in 0..<acc.count { acc[i] += arr[i] }
            }
        }
        if cfg.stat == "avg" && !times.isEmpty {
            let inv = 1.0 / Float(times.count)
            for i in 0..<acc.count { acc[i] *= inv }
        }

        // Lissage + overlay
        let smooth = blur5x5(acc, w: W, h: H)
        var (overlay, boxes) = ThermoRenderer.buildOverlay(from: smooth, W: W, H: H,
                                                           pLow: cfg.pLow, pHigh: cfg.pHigh,
                                                           gamma: cfg.gamma, alphaMax: cfg.alphaMax)
        let outURL = URL(fileURLWithPath: outPath)
        do {
            try ThermoRenderer.composeOverlayPNG(frameMid: frameMid, overlay: overlay, W: W, H: H,
                                                 config: cfg, boxes: &boxes, outURL: outURL)
        } catch {
            fputs("Export PNG fail: \(error)\n", stderr); exit(6)
        }

        // Résumé JSON
        let jsonPath = (outPath as NSString).deletingPathExtension + "_summary.json"
        let summary = Summary(file: videoPath, width: W, height: H, framesUsed: times.count, stat: cfg.stat,
                              percentileLow: cfg.pLow, percentileHigh: cfg.pHigh,
                              ambientC: cfg.ambientC, maxC: cfg.maxC, gamma: cfg.gamma, hotspots: boxes)
        if let data = try? JSONEncoder().encode(summary) {
            try? data.write(to: URL(fileURLWithPath: jsonPath))
        }

        print("OK (heatmap continue, \(boxes.count) hotspots) → \(outPath)")
    }
}
