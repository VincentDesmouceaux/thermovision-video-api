FROM python:3.12-slim

# Dépendances système utiles à OpenCV + vidéo
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Installer deps Python
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copier uniquement ce qui est nécessaire au service
COPY app.py thermal_processor.py ./
COPY static ./static

# dossier data créé au runtime (ou monté en volume)
RUN mkdir -p /app/data

ENV PYTHONUNBUFFERED=1

EXPOSE 8080

# ✅ 1 worker pour garder JOBS en-memory cohérent
CMD ["sh", "-c", "gunicorn -w 1 -k gthread --threads 4 -b 0.0.0.0:${PORT:-8080} app:app"]
