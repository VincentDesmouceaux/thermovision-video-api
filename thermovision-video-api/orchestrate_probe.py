#!/usr/bin/env python3
# Orchestrateur multi-dossiers pour VideoDeepProbe (C#)
# - Accepte plusieurs chemins: fichiers et/ou dossiers
# - Recherche récursive (*.mp4, *.mov) dans chaque dossier
# - Par défaut (si aucun argument): scanne assets/ et cvassets/
# - Exécute le probe C# (.NET 9) et exporte JSON (complet) + CSV (aplati)

import os
import sys
import json
import csv
import subprocess
from pathlib import Path
from datetime import datetime

CS_PROJ_DIR = Path.cwd()           # dossier contenant VideoDeepProbe.csproj
OUT_DIR = Path("outputs")
OUT_DIR.mkdir(exist_ok=True)

VIDEO_EXTS = {".mp4", ".mov"}


def run_probe(mp4_path: Path) -> dict:
    """Lance le binaire C# (net9.0) et retourne le JSON stdout."""
    cmd = ["dotnet", "run", "--project",
           str(CS_PROJ_DIR), "--framework", "net9.0", "--", str(mp4_path)]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            f"Probe failed ({proc.returncode}) for {mp4_path}:\n{proc.stderr}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"Invalid JSON from probe for {mp4_path}:\n{proc.stdout[:4000]}") from e


def iter_videos_in_dir(d: Path):
    """Itère récursivement les vidéos dans un dossier."""
    for p in d.rglob("*"):
        if p.is_file() and p.suffix.lower() in VIDEO_EXTS:
            yield p


def gather_targets_from_args(args: list[Path]) -> list[Path]:
    """Construit la liste des cibles depuis les arguments (fichiers/dossiers)."""
    found = []
    for a in args:
        if a.is_file():
            found.append(a)
        elif a.is_dir():
            found.extend(iter_videos_in_dir(a))
        else:
            print(f"[!] Chemin introuvable: {a}", file=sys.stderr)
    # unicité + tri stable par chemin
    uniq = sorted({p.resolve() for p in found})
    return uniq


def gather_default_targets() -> list[Path]:
    """Si aucun argument: cherche dans assets/ et cvassets/ récursivement."""
    candidates = [Path("assets"), Path("cvassets")]
    found = []
    for d in candidates:
        if d.exists() and d.is_dir():
            found.extend(iter_videos_in_dir(d))
    uniq = sorted({p.resolve() for p in found})
    return uniq


def flatten_row(j: dict) -> dict:
    """Aplatis le JSON pour le CSV."""
    ftyp = j.get("ftyp", {}) or {}
    audio = j.get("audio", {}) or {}
    infer = j.get("inference", {}) or {}
    sigs = j.get("signatures", {}) or {}

    return {
        "file": Path(j.get("file", "")).name,
        "ftyp_major": ftyp.get("major"),
        "ftyp_brands": "|".join(ftyp.get("brands", []) or []),
        "title": j.get("title"),
        "title_ansi_hex": j.get("title_ansi_hex"),
        "generator": j.get("generator"),
        "generator_ansi_hex": j.get("generator_ansi_hex"),
        "audio_codec": audio.get("codec"),
        "audio_channels": audio.get("channels"),
        "audio_samplerate_hz": audio.get("samplerate_hz"),
        "aac_profile": audio.get("aac_profile"),
        "asc_sr_idx": audio.get("asc_sr_idx"),
        "asc_ch": audio.get("asc_ch"),
        "audio_duration_s": audio.get("duration_s"),
        "audio_packets_per_sec": audio.get("packets_per_sec"),
        "audio_bitrate_kbps": audio.get("bitrate_kbps"),
        "stsz_samples": audio.get("stsz_samples"),
        "stsz_total_bytes": audio.get("stsz_total_bytes"),
        "stsz_min": audio.get("stsz_min"),
        "stsz_max": audio.get("stsz_max"),
        "stsz_std": audio.get("stsz_std"),
        "exif_present": sigs.get("exif"),
        "xmp_present": sigs.get("xmp"),
        "iso6709_present": sigs.get("iso6709"),
        "os_inferred": infer.get("os"),
        "os_score": infer.get("os_score"),
        "lens_model": infer.get("lens_model"),
        "lens_make": infer.get("lens_make"),
        "focal_mm": infer.get("focal_mm"),
        "focus_m": infer.get("focus_m"),
        "exposure_s": infer.get("exposure_s"),
        "lens_reason": infer.get("lens_reason"),
    }


def main():
    args = [Path(a) for a in sys.argv[1:]]
    if args:
        targets = gather_targets_from_args(args)
    else:
        targets = gather_default_targets()

    if not targets:
        print("Aucune vidéo trouvée.\n"
              "- Passe des chemins (fichiers/dossiers), ex:\n"
              "  python3 orchestrate_probe.py cvassets \"assets/Ma vidéo.mp4\"\n"
              "- Ou place des vidéos dans ./assets/ ou ./cvassets/.", file=sys.stderr)
        sys.exit(2)

    print(f"[i] Vidéos à traiter: {len(targets)}")
    rows, results = [], []
    for i, mp4 in enumerate(targets, 1):
        print(f"[{i}/{len(targets)}] Probing: {mp4}")
        try:
            j = run_probe(mp4)
        except Exception as e:
            print(f"[!] Erreur: {e}", file=sys.stderr)
            continue
        results.append(j)
        rows.append(flatten_row(j))

    if not rows:
        print(
            "[!] Aucune sortie exploitable (erreurs sur toutes les vidéos ?).", file=sys.stderr)
        sys.exit(3)

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    json_path = OUT_DIR / f"probe_results_{stamp}.json"
    csv_path = OUT_DIR / f"probe_results_{stamp}.csv"

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)

    fieldnames = list(rows[0].keys())
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(r)

    print(f"\nOK.\nJSON: {json_path}\nCSV : {csv_path}")


if __name__ == "__main__":
    main()
