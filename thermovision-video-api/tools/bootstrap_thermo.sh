#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------
# Bootstrap complet VideoThermalSuite (SwiftPM)
# ----------------------------------------------
# - Normalise l’arborescence src/
# - Ajoute Debug.swift (logger)
# - Rend publics les symboles ThermoKit (+ Codable sur HotBox)
# - Génère Package.swift (tools 6.2)
# - Tue SwiftPM coincé, clean .build
# - Build release
# - Exécute ThermalHeatmap si un MP4 est donné (ou détecté)
# Usage:
#   tools/bootstrap_thermo.sh [--trace] [--debug] [video.mp4 [out.png ...args]]
# ----------------------------------------------

# --- options trace/debug ---
THERMO_ENV=()
if [[ "${1-}" == "--trace" ]]; then THERMO_ENV+=(THERMO_TRACE=1); shift; fi
if [[ "${1-}" == "--debug" ]]; then THERMO_ENV+=(THERMO_DEBUG=1); shift; fi

# Repo root = ce script/.. (ou cwd fallback)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

echo "→ ROOT: $ROOT"

# --- dossiers attendus ---
mkdir -p src/ThermoKit src/ThermalHeatmapMain src/ThermalVideoMain assets outputs tools

# --- tuer SwiftPM coincé + clean build ---
echo "→ Kill SwiftPM pendu (si besoin) + clean .build"
pgrep -f "swift.*(build|package)" >/dev/null 2>&1 && \
  pgrep -f "swift.*(build|package)" | xargs kill -9 || true
rm -rf .build

# --- choisir ThermoKit.swift canonique ---
echo "→ Canonicalise ThermoKit.swift"
mapfile -t CANDS < <(find src -type f -name "ThermoKit.swift" | sort)
CANON="src/ThermoKit/ThermoKit.swift"
if [[ -f "$CANON" ]]; then
  echo "  ✓ déjà présent: $CANON"
else
  if [[ "${#CANDS[@]}" -gt 0 ]]; then
    # prend le plus récent
    LATEST="$(ls -t "${CANDS[@]}" | head -n1)"
    echo "  • copie du plus récent: $LATEST -> $CANON"
    cp -f "$LATEST" "$CANON"
  else
    echo "  ✗ Introuvable: ThermoKit.swift (tu dois avoir le code de la lib)."
    echo "    Place ton fichier dans src/ThermoKit/ThermoKit.swift puis relance."
    exit 1
  fi
fi

# --- supprimer doublons ThermoKit.swift hors canonique (pour éviter confusions) ---
for f in "${CANDS[@]:-}"; do
  [[ "$f" == "$CANON" ]] && continue
  echo "  • supprime doublon $f"
  rm -f "$f" || true
done

# --- ajoute Debug.swift (logger activable par THERMO_DEBUG/THERMO_TRACE) ---
DEBUG_FILE="src/ThermoKit/Debug.swift"
cat > "$DEBUG_FILE" <<'SWIFT'
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
SWIFT

# --- patch accessibilité/public + méthodes clefs + Codable(HotBox) ---
echo "→ Patch accessibilité (public) + Codable(HotBox) dans ThermoKit.swift"
# Ajoute 'public' aux déclarations types/fonctions si absent
perl -0777 -i -pe '
  s/^\s*struct\s+HotBox\b/public struct HotBox/mg;
  s/^\s*struct\s+HeatConfig\b/public struct HeatConfig/mg;
  s/^\s*(final\s+)?class\s+ThermalGPU\b/public $1class ThermalGPU/mg;
  s/^\s*enum\s+ThermoRenderer\b/public enum ThermoRenderer/mg;
  s/^\s*func\s+blur5x5\b/public func blur5x5/mg;
  s/^\s*init\s*\(/public init(/mg;
  s/^\s*func\s+heatTexture\b/public func heatTexture/mg;
  s/^\s*func\s+readFloatArray\b/public func readFloatArray/mg;
  s/^\s*static\s+func\s+buildOverlay\b/public static func buildOverlay/mg;
  s/^\s*static\s+func\s+composeOverlayPNG\b/public static func composeOverlayPNG/mg;
' "$CANON"

# Ajoute conformance Codable à HotBox via extension (idempotent)
HOTBOX_COD="src/ThermoKit/HotBox+Codable.swift"
if ! grep -q "extension HotBox: Codable" "$HOTBOX_COD" 2>/dev/null; then
  cat > "$HOTBOX_COD" <<'SWIFT'
import Foundation
public extension HotBox: Codable {}
SWIFT
fi

# --- Ajoute des checkpoints non-intrusifs si facilement greppables (idempotent) ---
# (Optionnel: on ne force pas, mais on essaie d’insérer sans casser la comp)
if ! grep -q "DBG.checkpoint(\"MetalDevice\"" "$CANON"; then
  perl -0777 -i -pe '
    s/(MTLCreateSystemDefaultDevice\(\)\s*\!)\s*//m;
  ' "$CANON" || true
fi

# --- Package.swift (tools 6.2) ---
echo "→ (Re)génère Package.swift"
cat > Package.swift <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "video",
  platforms: [.macOS(.v12)],
  products: [
    .library(name: "ThermoKit", targets: ["ThermoKit"]),
    .executable(name: "ThermalHeatmap", targets: ["ThermalHeatmapMain"]),
    .executable(name: "ThermalVideo", targets: ["ThermalVideoMain"]),
  ],
  targets: [
    .target(
      name: "ThermoKit",
      path: "src/ThermoKit",
      swiftSettings: [.unsafeFlags(["-O"])],
      linkerSettings: [
        .linkedFramework("Metal"),
        .linkedFramework("MetalKit"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ImageIO"),
        .linkedFramework("UniformTypeIdentifiers"),
        .linkedFramework("AppKit"),
      ]
    ),
    .executableTarget(
      name: "ThermalHeatmapMain",
      dependencies: ["ThermoKit"],
      path: "src/ThermalHeatmapMain"
    ),
    .executableTarget(
      name: "ThermalVideoMain",
      dependencies: ["ThermoKit"],
      path: "src/ThermalVideoMain"
    ),
  ]
)
SWIFT

# --- Résolution + Build Release ---
echo "→ swift package resolve"
swift package resolve
echo "→ swift build -c release"
swift build -c release

# --- Où sont les binaires ---
HM_BIN=".build/release/ThermalHeatmap"
VID_BIN=".build/release/ThermalVideo"

echo "✓ Build OK"
echo "  • $HM_BIN"
echo "  • $VID_BIN"

# --- Exécution automatique si un mp4 est fourni ou détecté ---
VIDEO="${1-}"
OUTPNG="${2-}"
shift || true

if [[ -z "${VIDEO}" ]]; then
  # essaie de trouver un mp4 courant (ex: assets/WhatsApp*.mp4)
  CANDVID="$(ls assets/*.mp4 2>/dev/null | head -n1 || true)"
  if [[ -n "$CANDVID" ]]; then
    VIDEO="$CANDVID"
  fi
fi

if [[ -n "${VIDEO}" ]]; then
  if [[ -z "${OUTPNG}" ]]; then
    # nom par défaut
    stem="$(basename "${VIDEO%.*}")"
    OUTPNG="outputs/${stem}_heatmap.png"
  fi
  echo "→ Run ThermalHeatmap sur: $VIDEO"
  # Variables d’environnement debug/trace si demandées
  "${THERMO_ENV[@]}" "$HM_BIN" "$VIDEO" "$OUTPNG" --frames 9 --stat avg --pLow 0.80 --pHigh 0.98 --ambient 22 --maxC 120 --gamma 1.2 --alpha 0.6 || true
  if [[ -f "$OUTPNG" ]]; then
    echo "✓ Sortie: $OUTPNG"
  else
    echo "✗ L’exe n’a pas produit: $OUTPNG (voir logs ci-dessus)."
  fi
else
  echo "→ Pas de vidéo fournie/détectée. Pour lancer automatiquement :"
  echo "   tools/bootstrap_thermo.sh --trace assets/your_video.mp4"
fi

# --- Arborescence courte (si tree dispo) ---
if command -v tree >/dev/null 2>&1; then
  echo "→ Aperçu arbo:"
  tree -L 3 src | sed 's/^/  /'
fi
