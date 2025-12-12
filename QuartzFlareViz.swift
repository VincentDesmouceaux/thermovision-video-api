import Foundation
import AVFoundation
import CoreImage
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct FlareHit { let t: Double; let x: Double; let y: Double; let r: Double; let B: Double }

enum Geo {
    static func area(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<pts.count {
            let p = pts[i], q = pts[(i+1)%pts.count]
            a += Double(p.x*q.y - q.x*p.y)
        }
        return abs(a) * 0.5
    }
    static func perim(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 2 else { return 0 }
        var p = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i+1)%pts.count]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            p += (dx*dx + dy*dy).squareRoot()
        }
        return p
    }
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(), n = s.count
        return (n%2==1) ? s[n/2] : 0.5*(s[n/2-1]+s[n/2])
    }
}

enum FlareCore {
    static func sampleTimes(duration: CMTime, count: Int) -> [CMTime] {
        let T = CMTimeGetSeconds(duration)
        guard T.isFinite, T > 0 else { return [CMTime(seconds: 0, preferredTimescale: 600)] }
        return (1...count).map { i in CMTime(seconds: (Double(i)/Double(count+1))*T, preferredTimescale: 600) }
    }
    static func brightness(ci: CIImage, rect: CGRect, ctx: CIContext) -> Double {
        guard let f = CIFilter(name: "CIAreaAverage") else { return 0 }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
        guard let out = f.outputImage else { return 0 }
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x:0,y:0,width:1,height:1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let r = Double(px[0]), g = Double(px[1]), b = Double(px[2])
        return 0.2126*r + 0.7152*g + 0.0722*b
    }
    static func flatten(_ roots: [VNContour]) -> [VNContour] {
        var out: [VNContour] = []
        func rec(_ c: VNContour) { out.append(c); c.childContours.forEach(rec) }
        roots.forEach(rec); return out
    }
    static func detect(cg: CGImage, t: Double, ctx: CIContext) -> [FlareHit] {
        let w = cg.width, h = cg.height
        let ci = CIImage(cgImage: cg)
        let maxDim = max(w,h)
        let s = maxDim > 1024 ? CGFloat(1024)/CGFloat(maxDim) : 1
        let scaled = (s<1) ? ci.transformed(by: CGAffineTransform(scaleX: s, y: s)) : ci
        guard let sCG = ctx.createCGImage(scaled, from: scaled.extent) else { return [] }

        let req = VNDetectContoursRequest()
        req.contrastAdjustment = 1; req.detectsDarkOnLight = false; req.maximumImageDimension = 1024
        let handler = VNImageRequestHandler(cgImage: sCG, options: [:]); try? handler.perform([req])
        guard let obs = req.results?.first as? VNContoursObservation else { return [] }
        let contours = flatten(obs.topLevelContours)

        var hits: [FlareHit] = []
        for c in contours {
            let ptsN = c.normalizedPoints; if ptsN.count < 6 { continue }
            var pts: [CGPoint] = []; pts.reserveCapacity(ptsN.count)
            for p in ptsN {
                let x = CGFloat(p.x) * CGFloat(w)
                let y = (1 - CGFloat(p.y)) * CGFloat(h)
                pts.append(CGPoint(x:x,y:y))
            }
            let a = Geo.area(pts); if a < Double(w*h)*0.00001 || a > Double(w*h)*0.25 { continue }
            let per = Geo.perim(pts); if per <= 0 { continue }
            let circ = 4.0*Double.pi*a/(per*per); if circ < 0.70 { continue }
            var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
            for p in pts { minX=min(minX,p.x); maxX=max(maxX,p.x); minY=min(minY,p.y); maxY=max(maxY,p.y) }
            let bbox = CGRect(x: minX, y: minY, width: max(1, maxX-minX), height: max(1, maxY-minY))
            let cx = Double((minX+maxX)*0.5), cy = Double((minY+maxY)*0.5)
            let r  = 0.25 * Double((bbox.width + bbox.height)) * 0.5
            let B  = brightness(ci: ci, rect: bbox, ctx: ctx)
            hits.append(FlareHit(t: t, x: cx, y: cy, r: r, B: B))
        }
        hits.sort{ $0.B > $1.B }
        return Array(hits.prefix(3))
    }
    static func aggregate(_ hits: [FlareHit], w: Int, h: Int) -> (Double?,Double?,Double?,Double?) {
        guard !hits.isEmpty else { return (nil,nil,nil,nil) }
        let cx0 = Double(w)/2, cy0 = Double(h)/2
        var bestByT: [Double:FlareHit] = [:]
        for hit in hits { if let cur = bestByT[hit.t] { if hit.B > cur.B { bestByT[hit.t]=hit } } else { bestByT[hit.t]=hit } }
        let best = Array(bestByT.values)
        let mx = Geo.median(best.map{$0.x}), my = Geo.median(best.map{$0.y}), mr = Geo.median(best.map{$0.r})
        let angs = best.map{ (hit) -> Double in
            var a = atan2(hit.y - cy0, hit.x - cx0) * 180.0 / .pi
            if a < 0 { a += 360 }; return a
        }
        let ma = Geo.median(angs)
        return (mx,my,mr,ma)
    }
}

func drawOverlay(base cg: CGImage, hits: [FlareHit], outURL: URL) throws {
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "draw", code: 1) }

    // fond = frame
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    // centre image (croix)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 0.9))
    ctx.setLineWidth(2)
    ctx.move(to: CGPoint(x: CGFloat(w)/2, y: 0))
    ctx.addLine(to: CGPoint(x: CGFloat(w)/2, y: CGFloat(h)))
    ctx.move(to: CGPoint(x: 0, y: CGFloat(h)/2))
    ctx.addLine(to: CGPoint(x: CGFloat(w), y: CGFloat(h)/2))
    ctx.strokePath()

    // meilleurs hits (un par temps)
    var bestByT: [Double:FlareHit] = [:]
    for hit in hits { if let cur = bestByT[hit.t] { if hit.B > cur.B { bestByT[hit.t]=hit } } else { bestByT[hit.t]=hit } }

    for hit in bestByT.values {
        // cercle rouge
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.9))
        ctx.setLineWidth(3)
        ctx.addEllipse(in: CGRect(x: CGFloat(hit.x - hit.r),
                                  y: CGFloat(hit.y - hit.r),
                                  width: CGFloat(hit.r*2),
                                  height: CGFloat(hit.r*2)))
        ctx.strokePath()

        // segment centre → reflet (cyan)
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 0.9))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: CGFloat(w)/2, y: CGFloat(h)/2))
        ctx.addLine(to: CGPoint(x: CGFloat(hit.x), y: CGFloat(hit.y)))
        ctx.strokePath()

        // point vert au centre du reflet
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.9))
        ctx.addEllipse(in: CGRect(x: CGFloat(hit.x)-3, y: CGFloat(hit.y)-3, width: 6, height: 6))
        ctx.fillPath()
    }

    // export PNG (UTType moderne)
    let pngUTI = UTType.png.identifier as CFString
    guard let outCG = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(outURL as CFURL, pngUTI, 1, nil)
    else { throw NSError(domain: "imgio", code: 2) }
    CGImageDestinationAddImage(dest, outCG, nil)
    CGImageDestinationFinalize(dest)
}

@main
struct App {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            fputs("Usage: QuartzFlareViz <video> [output.png]\n", stderr); exit(2)
        }
        let videoPath = CommandLine.arguments[1]
        let outPath = (CommandLine.arguments.count >= 3) ? CommandLine.arguments[2] : "flare_overlay.png"

        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceAfter  = .zero
        gen.requestedTimeToleranceBefore = .zero

        // détection sur 3 frames + frame centrale pour fond
        let duration = asset.duration
        let times = FlareCore.sampleTimes(duration: duration, count: 3)
        let mid = CMTime(seconds: CMTimeGetSeconds(duration)/2, preferredTimescale: 600)

        let ciCtx = CIContext(options: nil)
        var hits: [FlareHit] = []
        for t in times {
            if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
                hits.append(contentsOf: FlareCore.detect(cg: cg, t: CMTimeGetSeconds(t), ctx: ciCtx))
            }
        }
        guard let frameMid = try? gen.copyCGImage(at: mid, actualTime: nil) else {
            fputs("Impossible de générer la frame centrale.\n", stderr); exit(3)
        }
        do {
            try drawOverlay(base: frameMid, hits: hits, outURL: URL(fileURLWithPath: outPath))
            print("OK → \(outPath)")
        } catch {
            fputs("Erreur rendu overlay: \(error)\n", stderr); exit(4)
        }
    }
}
