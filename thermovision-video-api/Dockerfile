FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY docker/requirements.txt /app/requirements.txt
RUN python -m pip install --no-cache-dir --upgrade "pip<26" "setuptools<82" wheel \
    && python -m pip install --no-cache-dir -r /app/requirements.txt

COPY docker/server.py /app/server.py
COPY static /app/static

ENV PYTHONUNBUFFERED=1
ENV PORT=8080

EXPOSE 8080

CMD ["sh", "-c", "exec gunicorn -w 1 -k gthread --threads 4 -b 0.0.0.0:${PORT:-8080} server:app"]