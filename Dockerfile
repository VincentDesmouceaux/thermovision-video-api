FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 \
    ffmpeg \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .

RUN python -m pip install --no-cache-dir --upgrade "pip<26" "setuptools<82" wheel \
    && python -m pip install --no-cache-dir -r requirements.txt

# App web + fallback Python
COPY app.py thermal_processor.py ./
COPY static ./static

# Binaire Swift compilé en amont
COPY ThermalHeatmap /app/ThermalHeatmap
RUN chmod +x /app/ThermalHeatmap

RUN mkdir -p /app/data

ENV PYTHONUNBUFFERED=1
ENV PORT=8080
ENV THERMAL_BIN=/app/ThermalHeatmap
ENV THERMAL_PY=/app/thermal_processor.py

EXPOSE 8080

# ✅ 1 worker pour garder JOBS en-memory cohérent
CMD ["sh", "-c", "gunicorn -w 1 -k gthread --threads 4 -b 0.0.0.0:${PORT:-8080} app:app"]
