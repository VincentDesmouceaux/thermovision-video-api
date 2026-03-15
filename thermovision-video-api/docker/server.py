import base64
import binascii
import io
import logging
import os
import pathlib
import shlex
from typing import Optional

import paramiko
from flask import Flask, jsonify, request
from werkzeug.utils import secure_filename

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__, static_folder="/app/static", static_url_path="")

MAC_HOST = os.environ.get("MAC_HOST")
MAC_PORT = int(os.environ.get("MAC_PORT", "22"))
MAC_USER = os.environ.get("MAC_USER")
MAC_SSH_KEY_BASE64 = os.environ.get("MAC_SSH_KEY_BASE64")
REMOTE_WORKDIR = os.environ.get("REMOTE_WORKDIR", "/tmp/thermo_uploads")
POST_PROCESS_CMD = os.environ.get(
    "POST_PROCESS_CMD", 'echo processing "{path}"')


def config_missing() -> list[str]:
    missing: list[str] = []
    if not MAC_HOST:
        missing.append("MAC_HOST")
    if not MAC_USER:
        missing.append("MAC_USER")
    if not MAC_SSH_KEY_BASE64:
        missing.append("MAC_SSH_KEY_BASE64")
    return missing


def load_ssh_key_from_base64(b64: Optional[str]) -> paramiko.PKey:
    if not b64:
        raise RuntimeError("MAC_SSH_KEY_BASE64 not set")

    normalized = "".join(b64.strip().split())

    try:
        key_bytes = base64.b64decode(normalized, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise RuntimeError(
            "MAC_SSH_KEY_BASE64 is not valid base64. Put only the base64 string, without quotes or extra text."
        ) from exc

    key_str = key_bytes.decode("utf-8")

    parsers = (
        paramiko.Ed25519Key.from_private_key,
        paramiko.RSAKey.from_private_key,
        paramiko.ECDSAKey.from_private_key,
    )
    last_error: Optional[Exception] = None

    for parser in parsers:
        stream = io.StringIO(key_str)
        try:
            return parser(stream)
        except Exception as exc:
            last_error = exc

    raise RuntimeError(f"Failed to parse SSH private key: {last_error}")


def sftp_and_exec(local_path: str, filename: str) -> dict:
    missing = config_missing()
    if missing:
        raise RuntimeError(
            "Missing required environment variables: " + ", ".join(missing))

    priv_key = load_ssh_key_from_base64(MAC_SSH_KEY_BASE64)

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(
        hostname=MAC_HOST,
        port=MAC_PORT,
        username=MAC_USER,
        pkey=priv_key,
        timeout=30,
    )

    sftp = ssh.open_sftp()
    try:
        remote_dir_cmd = f"mkdir -p {shlex.quote(REMOTE_WORKDIR)}"
        stdin, stdout, stderr = ssh.exec_command(remote_dir_cmd)
        mkdir_exit = stdout.channel.recv_exit_status()
        mkdir_err = stderr.read().decode("utf-8", errors="ignore")
        if mkdir_exit != 0:
            raise RuntimeError(
                f"Failed to prepare remote directory: {mkdir_err or 'unknown error'}")

        remote_path = f"{REMOTE_WORKDIR.rstrip('/')}/{filename}"
        sftp.put(local_path, remote_path)

        cmd = POST_PROCESS_CMD.replace("{path}", shlex.quote(remote_path))
        stdin, stdout, stderr = ssh.exec_command(cmd)
        exit_code = stdout.channel.recv_exit_status()
        out = stdout.read().decode("utf-8", errors="ignore")
        err = stderr.read().decode("utf-8", errors="ignore")

        return {
            "remote_path": remote_path,
            "command": cmd,
            "exit_code": exit_code,
            "stdout": out,
            "stderr": err,
        }
    finally:
        try:
            sftp.close()
        except Exception:
            pass
        ssh.close()


@app.route("/health", methods=["GET"])
@app.route("/api/health", methods=["GET"])
def health():
    missing = config_missing()
    return jsonify({
        "ok": len(missing) == 0,
        "service": "thermo-upload-forwarder",
        "missing": missing,
    }), 200


@app.route("/", methods=["GET"])
def index():
    return app.send_static_file("index.html")


@app.route("/upload", methods=["POST"])
@app.route("/api/upload", methods=["POST"])
def upload():
    if "file" in request.files:
        uploaded = request.files["file"]
    elif "video" in request.files:
        uploaded = request.files["video"]
    else:
        return jsonify({"error": "file field required (use 'file' or 'video')"}), 400

    if uploaded.filename is None or uploaded.filename.strip() == "":
        return jsonify({"error": "empty filename"}), 400

    safe_filename = secure_filename(uploaded.filename) or "upload.bin"
    tmpdir = pathlib.Path("/tmp/uploads")
    tmpdir.mkdir(parents=True, exist_ok=True)
    local_path = str(tmpdir / safe_filename)
    uploaded.save(local_path)

    try:
        result = sftp_and_exec(local_path, safe_filename)
    except Exception as exc:
        logger.exception("sftp/exec failed")
        return jsonify({"error": str(exc)}), 500

    return jsonify({"status": "ok", **result}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(
        os.environ.get("PORT", "8080")), debug=False)
