#!/usr/bin/env python3
"""
thermal_processor.py (v2.5 – dynamic)
-------------------------------------
Thermal-like heatmap overlay (Python/OpenCV version) + hotspots + summary.

⚠️ Version "dynamic only":
- Pas d'accumulation dans le temps (stat=max n'affecte plus l'overlay).
- Pas d'EMA temporel : chaque frame est traitée indépendamment.
- Smoothing spatial léger uniquement (blur 5x5).

Exemples :

  # simple
  ./thermal_processor.py input.mp4 output.mp4

  # avec réglages de normalisation + résumé JSON
  ./thermal_processor.py input.mp4 output.mp4 \
      --pLow 0.80 --pHigh 0.98 --gamma 1.2 --alpha 0.6 --stat avg \
      --ambient 22 --maxC 120 \
      --summary-json summary.json

  # avec aperçu des hotspots (bounding boxes + température)
  ./thermal_processor.py input.mp4 output.mp4 \
      --preview --summary-json summary.json

  # vidéo brute + bounding boxes (pas de heatmap)
  ./thermal_processor.py input.mp4 output.mp4 \
      --no-overlay --preview --summary-json summary.json
"""

import argparse
import os
import sys
import json

try:
    import cv2
except Exception:
    print(
        "[thermal_processor] Missing dependency: OpenCV (cv2). "
        "Install with: pip install opencv-python",
        file=sys.stderr,
    )
    sys.exit(3)

import numpy as np


# -----------------------------------------------------------
# CLI
# -----------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Thermal-like heatmap overlay (Python/OpenCV version, dynamic-only)"
    )
    parser.add_argument("input", help="Input video path")
    parser.add_argument("output", help="Output video path")

    # Normalisation intensité
    parser.add_argument(
        "--pLow",
        type=float,
        default=0.80,
        help="Low percentile in [0,1] for normalization (default 0.80)",
    )
    parser.add_argument(
        "--pHigh",
        type=float,
        default=0.98,
        help="High percentile in [0,1] for normalization (default 0.98)",
    )
    parser.add_argument(
        "--gamma",
        type=float,
        default=1.2,
        help="Gamma for non-linear contrast on normalized heat (default 1.2)",
    )
    parser.add_argument(
        "--alpha",
        type=float,
        default=0.6,
        help="Maximum overlay opacity in [0,1] (default 0.6)",
    )

    # Stat conservée pour la métadonnée summary, mais n'affecte plus l'overlay
    parser.add_argument(
        "--stat",
        choices=["avg", "max"],
        default="avg",
        help="Meta stat for summary only. Overlay is always per-frame dynamic.",
    )

    # Paramètres “physiques” (mapping score -> °C)
    parser.add_argument(
        "--ambient",
        type=float,
        default=22.0,
        help="Approx. ambient temperature in °C (default 22)",
    )
    parser.add_argument(
        "--maxC",
        type=float,
        default=120.0,
        help="Max simulated temperature in °C for score=1 (default 120)",
    )

    # Lissage temporel EMA – param conservé, mais ignoré pour l’overlay
    parser.add_argument(
        "--ema",
        type=float,
        default=0.0,
        help="(Ignored in v2.5) Kept for CLI compatibility.",
    )

    # résumé JSON global (hotspots)
    parser.add_argument(
        "--summary-json",
        type=str,
        default=None,
        help="If set, writes a JSON summary with hotspots & meta",
    )

    # mode preview : dessine les bounding boxes + tempC sur la vidéo
    parser.add_argument(
        "--preview",
        action="store_true",
        help="Draw hotspot bounding boxes and temp info on output video (debug)",
    )

    # désactiver l’overlay heatmap : on garde la vidéo brute
    parser.add_argument(
        "--no-overlay",
        action="store_true",
        help="Disable heatmap overlay (keeps original video, still allows --preview)",
    )

    args, _ = parser.parse_known_args()

    # sécurisation
    args.pLow = float(np.clip(args.pLow, 0.0, 0.999))
    args.pHigh = float(np.clip(args.pHigh, 0.0, 0.999))
    if args.pHigh <= args.pLow:
        args.pHigh = min(args.pLow + 0.01, 0.999)

    args.alpha = float(np.clip(args.alpha, 0.0, 1.0))
    # ema ignoré, mais on force un clamp propre
    args.ema = float(np.clip(args.ema, 0.0, 1.0))

    return args


# -----------------------------------------------------------
# Modèle thermique
# -----------------------------------------------------------

def heat_score(frame_bgr: np.ndarray) -> np.ndarray:
    """
    Heuristique chaleur:
      luma + dominance rouge + saturation, clampée entre 0 et 1.

    frame_bgr: BGR uint8 [0,255]
    return: score float32 ∈ [0,1], shape (H, W)
    """
    f = frame_bgr.astype(np.float32) / 255.0
    b = f[:, :, 0]
    g = f[:, :, 1]
    r = f[:, :, 2]

    luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    red_dom = r / (g + b + 1e-4)
    warm_boost = np.maximum(r - np.maximum(g, b), 0.0)
    cmax = np.maximum(np.maximum(r, g), b)
    cmin = np.minimum(np.minimum(r, g), b)
    sat = (cmax - cmin) / (cmax + 1e-6)

    score = (
        luma
        * (0.5 + 0.5 * sat)
        * (0.5 + 0.5 * red_dom)
        + warm_boost
    )
    return np.clip(score, 0.0, 1.0)


def score_to_temp(score, ambient: float, maxC: float, gamma: float):
    """
    Mapping heuristique score -> °C
      sc = (score_clamp)^gamma
      T  = ambient + (maxC - ambient) * sc

    Accepte soit un scalaire, soit un tableau.
    """
    score_arr = np.asarray(score, dtype=np.float32)
    sc = np.clip(score_arr, 0.0, 1.0) ** float(gamma)
    temp = float(ambient) + (float(maxC) - float(ambient)) * sc
    return temp


# -----------------------------------------------------------
# Colormap
# -----------------------------------------------------------

def build_colormap(t: np.ndarray, gamma: float, alpha_max: float):
    """
    t in [0,1] -> RGB + alpha, palette:
      bleu -> cyan -> jaune -> rouge
    """
    tg = np.clip(t, 0.0, 1.0) ** float(gamma)

    r = np.zeros_like(tg, dtype=np.float32)
    g = np.zeros_like(tg, dtype=np.float32)
    b = np.zeros_like(tg, dtype=np.float32)

    seg1 = tg < 0.33
    seg2 = (tg >= 0.33) & (tg < 0.66)
    seg3 = tg >= 0.66

    # bleu -> cyan
    if np.any(seg1):
        u1 = tg[seg1] / 0.33
        r[seg1] = 0.0
        g[seg1] = u1
        b[seg1] = 1.0

    # cyan -> jaune
    if np.any(seg2):
        u2 = (tg[seg2] - 0.33) / 0.33
        r[seg2] = u2
        g[seg2] = 1.0
        b[seg2] = 1.0 - u2

    # jaune -> rouge
    if np.any(seg3):
        u3 = (tg[seg3] - 0.66) / 0.34
        r[seg3] = 1.0
        g[seg3] = 1.0 - u3
        b[seg3] = 0.0

    alpha = np.clip(alpha_max * tg, 0.0, 1.0)

    return r, g, b, alpha


def ensure_output_dir(path: str):
    """
    Crée le dossier parent du chemin donné, si besoin.
    """
    directory = os.path.dirname(os.path.abspath(path))
    if directory and not os.path.exists(directory):
        os.makedirs(directory, exist_ok=True)


# -----------------------------------------------------------
# Hotspots (connected components)
# -----------------------------------------------------------

def find_hotspots_from_thr(heat_map: np.ndarray,
                           thr: float,
                           ambient: float,
                           maxC: float,
                           gamma: float,
                           min_frac: float = 1e-4,
                           max_frac: float = 0.25,
                           max_boxes: int = 20):
    """
    heat_map: float32 (H,W), scores ∈ [0,1]
    thr     : seuil de score pour mask (typiquement percentile pHigh)
    Retourne une liste de dicts hotspots.
    """
    H, W = heat_map.shape
    mask = (heat_map >= float(thr)).astype(np.uint8)
    if np.count_nonzero(mask) == 0:
        return []

    num_labels, labels, stats, centroids = cv2.connectedComponentsWithStats(
        mask, connectivity=8
    )

    total = H * W
    min_area = max(1, int(total * min_frac))
    max_area = max(min_area, int(total * max_frac))

    hotspots = []
    for label in range(1, num_labels):
        x, y, w, h, area = stats[label]
        if area < min_area or area > max_area:
            continue

        comp_scores = heat_map[labels == label]
        if comp_scores.size == 0:
            continue

        mean_score = float(comp_scores.mean())
        temp_val = score_to_temp(mean_score, ambient, maxC, gamma)
        mean_temp = float(np.asarray(temp_val).mean())

        hotspots.append(
            {
                "x": int(x),
                "y": int(y),
                "w": int(w),
                "h": int(h),
                "pixels": int(area),
                "meanScore": mean_score,
                "tempC": mean_temp,
            }
        )

    hotspots.sort(key=lambda b: b["pixels"], reverse=True)
    return hotspots[:max_boxes]


# -----------------------------------------------------------
# Utils couleurs pour les bounding boxes
# -----------------------------------------------------------

def temp_to_bgr(tempC: float, ambient: float, maxC: float):
    """
    Convertit une température en couleur BGR:
    - proche ambiante -> vert
    - proche maxC     -> rouge
    """
    if maxC <= ambient:
        frac = 1.0
    else:
        frac = (tempC - ambient) / (maxC - ambient)
    frac = float(np.clip(frac, 0.0, 1.0))

    # gradient vert -> rouge
    # B = 0, G = 255*(1-frac), R = 255*frac
    g = int(255 * (1.0 - frac))
    r = int(255 * frac)
    return (0, g, r)


# -----------------------------------------------------------
# Traitement vidéo principal
# -----------------------------------------------------------

def process_video(args) -> int:
    if not os.path.exists(args.input):
        print(
            f"[thermal_processor] ERROR input_not_found {args.input}",
            file=sys.stderr,
        )
        return 3

    cap = cv2.VideoCapture(args.input)
    if not cap.isOpened():
        print(
            f"[thermal_processor] ERROR cannot_open_input {args.input}",
            file=sys.stderr,
        )
        return 3

    fps = cap.get(cv2.CAP_PROP_FPS)
    if fps <= 0:
        fps = 25.0

    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    approx_duration_sec = total_frames / fps if total_frames > 0 else 0.0

    print(
        f"[thermal_processor] meta width={width} height={height} "
        f"fps={fps:.3f} frames={total_frames} "
        f"approxDuration={approx_duration_sec:.3f}s",
        file=sys.stderr,
    )

    ensure_output_dir(args.output)

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    out = cv2.VideoWriter(args.output, fourcc, fps, (width, height))

    if not out.isOpened():
        print(
            f"[thermal_processor] ERROR cannot_open_output {args.output}",
            file=sys.stderr,
        )
        cap.release()
        return 3

    all_hotspots = []   # pour summary global
    frame_idx = 0

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        # score dynamique frame par frame (aucune accumulation temporelle)
        score = heat_score(frame)

        # base = score direct
        base = score

        # flou spatial 5x5 (pour lisser le bruit)
        heat_used = cv2.blur(base, (5, 5))

        # percentiles sur heat_used
        flat = heat_used.reshape(-1).astype(np.float32)
        if flat.size > 0:
            flat_sorted = np.sort(flat)
            idx_low = int(args.pLow * (flat_sorted.size - 1))
            idx_high = int(args.pHigh * (flat_sorted.size - 1))
            idx_low = max(0, min(idx_low, flat_sorted.size - 1))
            idx_high = max(0, min(idx_high, flat_sorted.size - 1))
            p_low_val = float(flat_sorted[idx_low])
            p_high_val = float(flat_sorted[idx_high])
        else:
            p_low_val = 0.0
            p_high_val = 1.0

        if p_high_val <= p_low_val:
            p_high_val = p_low_val + 1e-6

        # hotspots (pour summary & preview)
        hotspots = find_hotspots_from_thr(
            heat_used,
            p_high_val,
            ambient=args.ambient,
            maxC=args.maxC,
            gamma=args.gamma,
        )

        # normalisation [pLow, pHigh] -> [0,1] pour la heatmap
        t = np.clip(
            (heat_used - p_low_val) / (p_high_val - p_low_val),
            0.0,
            1.0,
        )
        r_h, g_h, b_h, alpha = build_colormap(t, args.gamma, args.alpha)

        # frame flottante
        frame_f = frame.astype(np.float32) / 255.0

        # overlay ou non selon --no-overlay
        if args.no_overlay:
            out_frame = frame_f.copy()
        else:
            heat_rgb = np.stack([r_h, g_h, b_h], axis=2)  # RGB
            a = alpha[..., None]  # (H, W, 1)
            heat_bgr = heat_rgb[:, :, ::-1]  # RGB -> BGR
            out_frame = frame_f * (1.0 - a) + heat_bgr * a

        out_frame_u8 = np.clip(out_frame * 255.0, 0, 255).astype(np.uint8)

        # preview : dessin des bounding boxes + tempC
        if args.preview and hotspots:
            for h in hotspots:
                x = h["x"]
                y = h["y"]
                w = h["w"]
                hgt = h["h"]
                tempC = h["tempC"]

                color = temp_to_bgr(tempC, args.ambient, args.maxC)

                cv2.rectangle(
                    out_frame_u8,
                    (x, y),
                    (x + w, y + hgt),
                    color,
                    2,
                )

                label = f"{tempC:.1f}°C"
                label_pos = (x, max(0, y - 5))
                cv2.putText(
                    out_frame_u8,
                    label,
                    label_pos,
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.4,
                    color,
                    1,
                    cv2.LINE_AA,
                )

        out.write(out_frame_u8)

        # hotspots (ajout pour summary global, avec temps)
        for h in hotspots:
            h2 = dict(h)
            h2["frameIdx"] = int(frame_idx)
            h2["tSec"] = float(frame_idx / fps)
            all_hotspots.append(h2)

        frame_idx += 1

        # logs de progression
        if total_frames > 0:
            if frame_idx % 30 == 0 or frame_idx == total_frames:
                pct = (frame_idx / total_frames) * 100.0
                print(
                    f"[thermal_processor] progress "
                    f"{frame_idx}/{total_frames} ({pct:.1f}%)",
                    file=sys.stderr,
                )
        else:
            if frame_idx % 30 == 0:
                print(
                    f"[thermal_processor] progress {frame_idx}/?",
                    file=sys.stderr,
                )

    cap.release()
    out.release()

    duration_sec = frame_idx / fps if fps > 0 else 0.0

    print(
        f"[thermal_processor] done OK frames={frame_idx} "
        f"realDuration={duration_sec:.3f}s",
        file=sys.stderr,
    )

    # Summary JSON optionnel
    if args.summary_json is not None:
        ensure_output_dir(args.summary_json)

        summary = build_summary(
            args=args,
            width=width,
            height=height,
            frames_used=frame_idx,
            duration_sec=duration_sec,
            hotspots=all_hotspots,
        )
        try:
            with open(args.summary_json, "w", encoding="utf-8") as f:
                json.dump(summary, f, ensure_ascii=False, indent=2)
            print(
                f"[thermal_processor] summary written to {args.summary_json}",
                file=sys.stderr,
            )
        except Exception as e:
            print(
                f"[thermal_processor] WARNING: cannot write summary_json: {e}",
                file=sys.stderr,
            )

    return 0


def build_summary(args,
                  width: int,
                  height: int,
                  frames_used: int,
                  duration_sec: float,
                  hotspots):
    """
    Summary global : file, width, height, framesUsed, durationSec, stat, pLow, pHigh,
    ambientC, maxC, gamma, hotspots...
    """
    hotspots_sorted = sorted(hotspots, key=lambda h: h["pixels"], reverse=True)
    top_hotspots = hotspots_sorted[:40]

    if hotspots:
        temps = [float(h.get("tempC", 0.0)) for h in hotspots]
        min_temp = float(min(temps))
        max_temp = float(max(temps))
    else:
        min_temp = None
        max_temp = None

    return {
        "file": os.path.basename(args.input),
        "width": width,
        "height": height,
        "framesUsed": frames_used,
        "durationSec": float(duration_sec),
        "stat": args.stat,
        "percentileLow": float(args.pLow),
        "percentileHigh": float(args.pHigh),
        "ambientC": float(args.ambient),
        "maxC": float(args.maxC),
        "gamma": float(args.gamma),
        "minHotspotTempC": min_temp,
        "maxHotspotTempC": max_temp,
        "hotspots": top_hotspots,
    }


# -----------------------------------------------------------
# Entrypoint
# -----------------------------------------------------------

def main():
    args = parse_args()
    code = process_video(args)
    sys.exit(code)


if __name__ == "__main__":
    main()
