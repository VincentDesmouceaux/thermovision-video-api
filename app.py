#!/usr/bin/env python3
import os
import sys
import threading
import time
import uuid
import subprocess
import math
from typing import Dict, Any, List, Optional

from flask import (
    Flask,
    request,
    jsonify,
    send_file,
    Response,
    send_from_directory,
)

# -----------------------------
# Paths
# -----------------------------
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
STATIC_DIR = os.path.join(BASE_DIR, "static")

os.makedirs(DATA_DIR, exist_ok=True)

# IMPORTANT: static_folder pointe vers un chemin absolu non-optional
app = Flask(__name__, static_folder=STATIC_DIR, static_url_path="/static")

# -----------------------------
# Jobs in-memory
# -----------------------------
# NOTE: Cette implémentation suppose 1 seul worker gunicorn
# et 1 seule replica (sinon sortir JOBS vers Redis/volume).
JOBS: Dict[str, Dict[str, Any]] = {}
JOBS_LOCK = threading.Lock()


def _as_float(value, default: float) -> float:
    try:
        v = float(value)
        if not math.isfinite(v):
            return default
        return v
    except Exception:
        return default


def _clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


def _as_choice(value: Optional[str], allowed: List[str], default: str) -> str:
    if not value:
        return default
    v = str(value).strip().lower()
    return v if v in allowed else default


def run_job(job_id: str) -> None:
    """
    Lance thermal_processor.py pour un job, capture les logs et met
    à jour le statut dans JOBS.
    """
    # Snapshot sous lock
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if not job:
            return

        job["status"] = "running"
        job["started_at"] = time.time()

        input_path = job["input_path"]
        output_path = job["output_path"]
        cli_args: List[str] = list(job.get("cli_args", []))

    processor_path = os.path.join(BASE_DIR, "thermal_processor.py")
    if not os.path.exists(processor_path):
        with JOBS_LOCK:
            job = JOBS.get(job_id)
            if job:
                job["status"] = "error"
                job["error"] = "thermal_processor.py not found"
                job["finished_at"] = time.time()
        return

    cmd = [
        sys.executable,
        processor_path,
        input_path,
        output_path,
        *cli_args,
    ]

    rc = -1

    try:
        # Capture stdout + stderr ensemble
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except Exception as e:
        with JOBS_LOCK:
            job = JOBS.get(job_id)
            if job:
                job["status"] = "error"
                job["error"] = f"Failed to start thermal_processor: {e}"
                job["finished_at"] = time.time()
        return

    try:
        if proc.stdout:
            for line in proc.stdout:
                line = line.rstrip("\n")
                with JOBS_LOCK:
                    job = JOBS.get(job_id)
                    if not job:
                        break
                    job["log"].append(line)

        proc.wait()
        rc = proc.returncode
    finally:
        try:
            if proc.stdout:
                proc.stdout.close()
        except Exception:
            pass

    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if not job:
            return

        job["finished_at"] = time.time()

        if rc == 0:
            job["status"] = "done"
        else:
            job["status"] = "error"
            job["error"] = f"thermal_processor exited with code {rc}"


# -----------------------------
# Front routes
# -----------------------------
@app.route("/")
def index():
    return send_from_directory(STATIC_DIR, "index.html")


@app.route("/favicon.ico")
def favicon():
    fav_path = os.path.join(STATIC_DIR, "favicon.ico")
    if os.path.exists(fav_path):
        return send_from_directory(STATIC_DIR, "favicon.ico")
    return ("", 204)


# -----------------------------
# API
# -----------------------------
@app.route("/api/upload", methods=["POST"])
def upload():
    """
    Reçoit la vidéo + les paramètres, crée un job et lance le traitement
    dans un thread.
    """
    if "video" not in request.files:
        return jsonify({"error": "Missing file field 'video'"}), 400

    f = request.files["video"]
    if not f or f.filename == "":
        return jsonify({"error": "Empty filename"}), 400

    job_id = uuid.uuid4().hex
    input_path = os.path.join(DATA_DIR, f"{job_id}_input.mp4")
    output_path = os.path.join(DATA_DIR, f"{job_id}_output.mp4")

    f.save(input_path)

    # -----------------------------
    # ✅ Params UI (FormData => request.form)
    # -----------------------------
    # pLow/pHigh doivent rester < 1.0 (le processor clamp aussi, mais on le fait propre ici)
    p_low = _clamp(_as_float(request.form.get(
        "pLow", "0.80"), 0.80), 0.0, 0.999)
    p_high = _clamp(_as_float(request.form.get(
        "pHigh", "0.98"), 0.98), 0.0, 0.999)

    # garantir pHigh > pLow (sinon l’overlay devient quasi identique / instable)
    if p_high <= p_low:
        p_high = min(p_low + 0.01, 0.999)

    # gamma: bornes raisonnables (évite NaN / extrêmes)
    gamma = _clamp(_as_float(request.form.get("gamma", "1.2"), 1.2), 0.1, 6.0)

    # alpha: [0..1]
    alpha = _clamp(_as_float(request.form.get("alpha", "0.6"), 0.6), 0.0, 1.0)

    # stat: ✅ whitelist (dans ton thermal_processor c’est meta-only, mais ok)
    stat = _as_choice(request.form.get("stat", "avg"), ["avg", "max"], "avg")

    cli_args: List[str] = [
        "--pLow", str(p_low),
        "--pHigh", str(p_high),
        "--gamma", str(gamma),
        "--alpha", str(alpha),
        "--stat", str(stat),
    ]

    with JOBS_LOCK:
        JOBS[job_id] = {
            "id": job_id,
            "status": "queued",
            "input_path": input_path,
            "output_path": output_path,
            "log": [
                f"[api] params pLow={p_low:.2f} pHigh={p_high:.2f} gamma={gamma:.2f} alpha={alpha:.2f} stat={stat}"
            ],
            "error": None,
            "cli_args": cli_args,
            "created_at": time.time(),
            "started_at": None,
            "finished_at": None,
        }

    t = threading.Thread(target=run_job, args=(job_id,), daemon=True)
    t.start()

    return jsonify({"jobId": job_id})


@app.route("/api/status/<job_id>")
def status(job_id: str):
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if not job:
            return jsonify({"error": "unknown_job"}), 404

        return jsonify(
            {
                "jobId": job_id,
                "status": job["status"],
                "error": job["error"],
                "createdAt": job.get("created_at"),
                "startedAt": job.get("started_at"),
                "finishedAt": job.get("finished_at"),
            }
        )


def sse_log_stream(job_id: str):
    last_index = 0
    while True:
        with JOBS_LOCK:
            job = JOBS.get(job_id)
            if not job:
                yield "event: error\ndata: unknown_job\n\n"
                break
            logs = job["log"]
            st = job["status"]

        while last_index < len(logs):
            line = logs[last_index]
            last_index += 1
            yield f"data: {line}\n\n"

        if st in ("done", "error"):
            yield f"event: done\ndata: {st}\n\n"
            break

        time.sleep(0.5)


@app.route("/api/logs/<job_id>")
def logs(job_id: str):
    headers = {
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
        "Connection": "keep-alive",
    }
    return Response(
        sse_log_stream(job_id),
        mimetype="text/event-stream",
        headers=headers,
    )


@app.route("/api/download/<job_id>")
def download(job_id: str):
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if not job:
            return jsonify({"error": "unknown_job"}), 404
        if job["status"] != "done":
            return jsonify({"error": "not_ready", "status": job["status"]}), 400
        output_path = job["output_path"]

    if not os.path.exists(output_path):
        return jsonify({"error": "file_missing"}), 500

    return send_file(
        output_path,
        as_attachment=True,
        download_name="thermal_output.mp4",
        mimetype="video/mp4",
    )


@app.route("/api/health")
def health():
    return jsonify({"ok": True})


# -----------------------------
# Entrypoint
# -----------------------------
if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8080"))
    app.run(host=host, port=port, debug=False)
