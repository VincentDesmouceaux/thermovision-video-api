import Foundation
public enum DBG {
  private static let t0 = CFAbsoluteTimeGetCurrent()
  public static let level: Int = {
    let e = ProcessInfo.processInfo.environment
    if e["THERMO_TRACE"] != nil { return 2 }
    if e["THERMO_DEBUG"] != nil { return 1 }
    return 0
  }()
  @inline(__always) static func stamp() -> String {
    let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    return "[Thermo \(ms)ms]"
  }
  public static func d(_ msg: @autoclosure () -> String) {
    if level >= 1 { fputs("\(stamp()) \(msg())\n", stderr) }
  }
  public static func t(_ msg: @autoclosure () -> String) {
    if level >= 2 { fputs("\(stamp()) \(msg())\n", stderr) }
  }
  public static func checkpoint(_ name: String, _ extra: [String: Any] = [:]) {
    if level == 0 { return }
    let tail = extra.map { "\($0)=\($1)" }.joined(separator: " ")
    d("CHK \(name) \(tail)")
  }
  public final class Scope {
    let name: String; let t0 = CFAbsoluteTimeGetCurrent()
    public init(_ name: String) { self.name = name; DBG.t("▶︎ \(name)") }
    deinit { DBG.t("◀︎ \(name) \(Int((CFAbsoluteTimeGetCurrent()-t0)*1000))ms") }
  }
  @discardableResult public static func scope(_ name: String) -> Scope { Scope(name) }
}
