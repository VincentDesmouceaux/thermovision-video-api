https://tinyurl.com/7djxm9ux

# ThermoVision Video API

**ThermoVision** is a Python/OpenCV video processing API with a lightweight web interface for generating pseudo-thermal heatmaps, detecting hotspots, and downloading processed video clips.

The project is designed to run locally, inside Docker, and on cloud platforms such as **Northflank**.

---

## Overview

ThermoVision transforms standard video input into visual thermal-style renderings using computer vision techniques.  
It provides a simple browser-based interface and backend processing pipeline for:

- pseudo-thermal heatmap generation;
- hotspot detection;
- video upload and processing;
- downloadable processed clips;
- containerized deployment with Docker;
- cloud deployment through Northflank.

---

## Tech Stack

- **Python**
- **OpenCV**
- **Flask / Gunicorn**
- **HTML / CSS / JavaScript**
- **Docker**
- **Northflank**

---

## Project Structure

```text
thermovision-video-api/
├── thermovision-video-api/
│   ├── server.py
│   ├── Dockerfile
│   └── ...
├── requirements.txt
├── .dockerignore
├── .gitignore
└── README.md
````

---

## Main Features

### Video Processing

ThermoVision applies image processing techniques to video frames in order to create a thermal-style visualization.

### Hotspot Detection

The application can identify visually intense zones and highlight potential hotspots in the processed output.

### Web Interface

The project includes a simple web UI that allows users to interact with the processor from a browser.

### Downloadable Results

Processed videos can be generated and downloaded after analysis.

### Docker Deployment

The application is containerized and ready to be deployed as a cloud service.

---

## Local Installation

Clone the repository:

```bash
git clone https://github.com/VincentDesmouceaux/thermovision-video-api.git
cd thermovision-video-api
```

Create a virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Install dependencies:

```bash
pip install -r requirements.txt
```

Run the application locally:

```bash
cd thermovision-video-api
gunicorn -w 1 -k gthread --threads 4 -b 0.0.0.0:${PORT:-8080} server:app
```

The application will be available at:

```text
http://127.0.0.1:8080
```

---

## Health Check

The service exposes a health check endpoint for cloud platforms:

```text
GET /healthz
```

Expected response:

```text
OK
```

You can test it with Python:

```bash
python3 - <<'PY'
import urllib.request

url = "http://127.0.0.1:8080/healthz"

try:
    with urllib.request.urlopen(url, timeout=5) as r:
        print("STATUS:", r.status)
        print(r.read().decode(errors="ignore"))
except Exception as e:
    print("ERROR:", repr(e))
PY
```

---

## Docker Usage

Build the image:

```bash
docker build -t thermovision-video-api -f thermovision-video-api/Dockerfile .
```

Run the container:

```bash
docker run --rm -p 8080:8080 thermovision-video-api
```

Open the app:

```text
http://127.0.0.1:8080
```

---

## Northflank Deployment

The project is configured to run on **Northflank** using Docker.

Recommended service configuration:

```text
Port: 8080
Protocol: HTTP
Health check path: /healthz
```

If the health check route is unavailable during testing, use `/` temporarily as the readiness path.

Recommended readiness probe:

```text
Type: HTTP
Port: 8080
Path: /healthz
```

The Docker command starts the application with Gunicorn:

```bash
gunicorn -w 1 -k gthread --threads 4 -b 0.0.0.0:${PORT:-8080} server:app
```

---

## Environment Variables

| Variable | Default | Description                 |
| -------- | ------: | --------------------------- |
| `PORT`   |  `8080` | Port used by the web server |

---

## Git Hygiene

Generated files and local build artifacts should not be committed.

Ignored examples:

```text
.build/
obj/
bin/
__pycache__/
*.pyc
.venv/
.env
outputs/
tmp/
*.mp4
*.mov
*.avi
```

---

## Repository

```text
VincentDesmouceaux/thermovision-video-api
```

---

## Author

**Vincent Desmouceaux**

Data Science, Machine Learning, Computer Vision and Full Stack development.

---

## License

No license has been specified yet.

````

Ensuite commit + push :

```bash
git add README.md
git commit -m "Add clean project README"
git push origin main
````


