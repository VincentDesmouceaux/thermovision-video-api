# ThermoVision video API
# ThermoVision — Video API ⚡️🎥

Quartz 🪟 + Metal 🧲 + Swift 🧠 + Python 🐍 + Docker 🐳 + Northflank ☁️
= **The new stack for microservices control** 😈

---

## 🧭 What this repo does

* 🔥 **Thermal / heatmap overlay** video processing
* 🧲 **GPU compute** via Metal kernels
* 🧠 **Swift tooling** (SwiftPM executables)
* 🐍 **Python orchestration** (batch runs, helpers)
* 🐳 **Dockerised API** for reproducible runs

---

## 📦 Repo structure (quick map)

* `HeatKernel.metal` 🧲 — Metal kernel(s)
* `Package.swift` 🧠 — SwiftPM manifest
* `Sources/` / `src/` — Swift code / entrypoints
* `thermal_processor.py` 🐍 — processing logic
* `orchestrate_probe.py` 🧪 — orchestration / automation
* `docker/` 🐳 — minimal server + static UI assets
* `scripts/` 🛠️ — wrappers / smoke tests
* `NORTHFLANK.md` ☁️ — deploy notes

---

## ✅ Prereqs

* macOS (for Metal/Quartz parts) 🍏
* Python 3.x 🐍
* Docker Desktop 🐳
* (optional) Swift toolchain 🧠

---

## 🐍 Python — venv setup

```bash
source /Users/vincentdesmouceaux/video/.venv/bin/activate
pip install -r requirements.txt
```

---

## 🧠 Swift — build & run (macOS)

```bash
swift build
swift run --help
# examples (depending on your executables)
# swift run ThermalHeatmapMain --help
# swift run ThermalVideoMain --help
```

---

## 🐳 Docker — build

### Build image

```bash
docker build -t video-api:latest .
```

### ✅ Exécution de la tâche (VSCode / CLI)

```bash
docker run --rm -d -p 8080:8080/tcp video-api:latest
```

---

## 🚨 If you get: “Bind for 0.0.0.0:8080 failed: port is already allocated” 😤

That means **something is already using port 8080** (often another container).

### 1) Find who’s using 8080 🔎

```bash
docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Ports}}"
lsof -nP -iTCP:8080 -sTCP:LISTEN
```

### 2) Option A — stop the container using 8080 🛑

```bash
docker ps
docker stop <CONTAINER_ID>
```

### 2) Option B — run on another port ✅ (recommended)

Host port **8081** → container port **8080**

```bash
docker run --rm -d -p 8081:8080/tcp video-api:latest
```

Then open:

* http://localhost:8081 🌍

### 2) Option C — kill the local process using 8080 💀

(Only if you know it’s safe)

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
kill -9 <PID>
```

---

## 🧼 Clean / Git hygiene (big files)

This repo generates big outputs — keep them out of git 🧹

Ignored or should be ignored:

* `data/` 📁
* `outputs/` 📁
* `out/` 📁
* `*.mp4 *.mov` 🎞️
* `.build/ .swiftpm/ bin/ obj/` 🧱
* `.venv/` 🐍

---

## 🧪 Useful commands

### Check container logs 📜

```bash
docker logs -f <CONTAINER_ID>
```

### Remove stopped containers 🧽

```bash
docker container prune
```

---

## 🗺️ Roadmap (vibes)

* 🔥 Better palettes & intensity curves
* 🧲 Faster GPU kernels / batching
* 🌐 Single clean HTTP API (one entrypoint)
* 📊 Bench + profiling scripts

---

## 🪪 License

Pick your poison ☠️✅

* MIT
* Apache-2.0

Tell me which one and I’ll generate the `LICENSE` file.
