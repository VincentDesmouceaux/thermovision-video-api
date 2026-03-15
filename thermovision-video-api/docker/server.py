import os
import io
import base64
import pathlib
import logging
import shlex

from flask import Flask, request, jsonify
import paramiko

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__, static_folder="static", static_url_path="")


def get_required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"{name} is missing")
    return value


# Required environment variables
MAC_HOST = get_required_env("MAC_HOST")
MAC_PORT = int(os.getenv("MAC_PORT", "22"))
MAC_USER = get_required_env("MAC_USER")
MAC_SSH_KEY_BASE64 = get_required_env("MAC_SSH_KEY_BASE64")

REMOTE_WORKDIR = os.getenv("REMOTE_WORKDIR", "/tmp/thermo_uploads")
POST_PROCESS_CMD = os.getenv("POST_PROCESS_CMD", "echo processing {path}")


def load_ssh_key_from_base64(b64: str) -> paramiko.PKey:
    key_bytes = base64.b64decode(b64)
    key_str = key_bytes.decode("utf-8")
    key_stream = io.StringIO(key_str)

    # Essaie plusieurs formats de clé
    for key_cls in (paramiko.RSAKey, paramiko.Ed25519Key, paramiko.ECDSAKey):
        key_stream.seek(0)
        try:
            return key_cls.from_private_key(key_stream)
        except Exception:
            continue

    raise RuntimeError("Failed to parse private key")


def sftp_and_exec(local_path: str, filename: str) -> dict:
    priv_key = load_ssh_key_from_base64(MAC_SSH_KEY_BASE64)

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    logger.info("Connecting to macOS host %s:%s as %s",
                MAC_HOST, MAC_PORT, MAC_USER)
    ssh.connect(
        hostname=MAC_HOST,
        port=MAC_PORT,
        username=MAC_USER,
        pkey=priv_key,
        timeout=30,
    )

    sftp = ssh.open_sftp()
    try:
        # Crée le dossier distant
        mkdir_cmd = f"mkdir -p {shlex.quote(REMOTE_WORKDIR)}"
        stdin, stdout, stderr = ssh.exec_command(mkdir_cmd)
        _ = stdout.read()
        mkdir_err = stderr.read().decode("utf-8", errors="ignore").strip()
        if mkdir_err:
            logger.warning("Remote mkdir stderr: %s", mkdir_err)

        safe_filename = pathlib.Path(filename).name
        remote_path = f"{REMOTE_WORKDIR.rstrip('/')}/{safe_filename}"

        logger.info("Uploading %s -> %s", local_path, remote_path)
        sftp.put(local_path, remote_path)

        cmd = POST_PROCESS_CMD.replace("{path}", shlex.quote(remote_path))
        logger.info("Executing remote command: %s", cmd)

        stdin, stdout, stderr = ssh.exec_command(cmd)
        exit_status = stdout.channel.recv_exit_status()
        out = stdout.read().decode("utf-8", errors="ignore")
        err = stderr.read().decode("utf-8", errors="ignore")

        return {
            "remote_path": remote_path,
            "exit_status": exit_status,
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
def health():
    return jsonify({"ok": True, "status": "ok"}), 200


@app.route("/", methods=["GET"])
def index():
    return app.send_static_file("index.html")


@app.route("/upload", methods=["POST"])
def upload():
    if "file" not in request.files:
        return jsonify({"error": "file field required"}), 400

    f = request.files["file"]
    filename = f.filename or "upload.bin"

    tmpdir = pathlib.Path("/tmp/uploads")
    tmpdir.mkdir(parents=True, exist_ok=True)

    safe_filename = pathlib.Path(filename).name
    local_path = str(tmpdir / safe_filename)

    try:
        f.save(local_path)
    except Exception as e:
        logger.exception("failed to save upload")
        return jsonify({"error": f"failed to save upload: {e}"}), 500

    try:
        result = sftp_and_exec(local_path, safe_filename)
    except Exception as e:
        logger.exception("sftp/exec failed")
        return jsonify({"error": str(e)}), 500

    status_code = 200 if result["exit_status"] == 0 else 500
    return jsonify({"status": "ok" if result["exit_status"] == 0 else "error", **result}), status_code


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
