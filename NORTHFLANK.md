# Deploying the upload-forwarder to Northflank

This service accepts video uploads and forwards them to a macOS host via SSH for processing by your `ThermalHeatmap` binary.

Important constraints
- `ThermalHeatmap` depends on macOS frameworks (Metal, AVFoundation). It cannot run inside a Linux container. This service only receives uploads and transfers them to a macOS machine.
- You must provide a reachable macOS host with SSH enabled and an account that can run the processing command.

Environment variables (set as secrets in Northflank)
- `MAC_HOST`: hostname or IP of the macOS machine
- `MAC_PORT`: SSH port (default 22)
- `MAC_USER`: SSH username
- `MAC_SSH_KEY_BASE64`: base64-encoded private key (PEM) for `MAC_USER` — **do not** store the raw key in the repo
- `REMOTE_WORKDIR`: directory on macOS where uploads will be placed (default `/tmp/thermo_uploads`)
- `POST_PROCESS_CMD`: command to run on macOS after the upload; use `{path}` to inject the uploaded file path. Example:

  POST_PROCESS_CMD="/usr/local/bin/ThermalHeatmap -i {path} -o {path}.heatmap.png && echo done"

Build & deploy (Northflank)
1. Build and push image to your container registry (Northflank can build from repo or you can push to DockerHub/Harbor):

```bash
docker build -t ghcr.io/youruser/thermo-uploader:latest .
docker push ghcr.io/youruser/thermo-uploader:latest
```

2. On Northflank, create a new service with that image, expose port `8080`, and add the environment variables/secrets listed above.

3. Configure health checks and a persistent volume if you want to keep uploads locally for inspection.

Using the service

Upload example (curl):

```bash
curl -F "file=@/path/to/video.mp4" https://<your-service>.northflank.app/upload
```

The response will contain `remote_path` and command stdout/stderr.

macOS-side helper

On your macOS target, prepare a wrapper script in `REMOTE_WORKDIR` or ensure `POST_PROCESS_CMD` can run directly. Example of a simple wrapper that runs ThermalHeatmap and moves outputs to an accessible folder:

```bash
#!/bin/bash
INPUT="$1"
OUTDIR="$HOME/thermo_results"
mkdir -p "$OUTDIR"
/usr/local/bin/ThermalHeatmap -i "$INPUT" -o "$OUTDIR/$(basename "$INPUT").heatmap.png"
echo "done"
```

Security notes
- Provide only a key with limited rights (dedicated account) and restrict SSH access to the Northflank IP ranges if possible.
- Rotate keys regularly and keep `MAC_SSH_KEY_BASE64` in Northflank secrets.
