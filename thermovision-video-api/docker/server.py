import os
import io
import base64
import tempfile
import pathlib
import logging
from flask import Flask, request, jsonify, send_from_directory
import paramiko

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__, static_folder='static', static_url_path='')

# Required environment variables (set these as secrets on Northflank)
MAC_HOST = os.environ.get('MAC_HOST')
MAC_PORT = int(os.environ.get('MAC_PORT', '22'))
MAC_USER = os.environ.get('MAC_USER')
# Private key must be provided base64-encoded in MAC_SSH_KEY_BASE64 (no newlines)
MAC_SSH_KEY_BASE64 = os.environ.get('MAC_SSH_KEY_BASE64')
REMOTE_WORKDIR = os.environ.get('REMOTE_WORKDIR', '/tmp/thermo_uploads')
# Post-process command template executed on macOS. Use {path} where the uploaded file path should be substituted.
POST_PROCESS_CMD = os.environ.get('POST_PROCESS_CMD', 'echo processing {path}')


def load_ssh_key_from_base64(b64: str):
    if not b64:
        raise RuntimeError('MAC_SSH_KEY_BASE64 not set')
    key_bytes = base64.b64decode(b64)
    key_str = key_bytes.decode('utf-8')
    return io.StringIO(key_str)


def sftp_and_exec(local_path: str, filename: str):
    key_stream = load_ssh_key_from_base64(MAC_SSH_KEY_BASE64)
    priv_key = None
    try:
        priv_key = paramiko.RSAKey.from_private_key(key_stream)
    except Exception:
        key_stream.seek(0)
        try:
            priv_key = paramiko.Ed25519Key.from_private_key(key_stream)
        except Exception as e:
            raise RuntimeError('Failed to parse private key: ' + str(e))

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(MAC_HOST, port=MAC_PORT, username=MAC_USER,
                pkey=priv_key, timeout=30)
    sftp = ssh.open_sftp()
    try:
        # Ensure remote workdir exists
        try:
            sftp.stat(REMOTE_WORKDIR)
        except IOError:
            ssh.exec_command(f'mkdir -p {REMOTE_WORKDIR}')

        remote_path = f"{REMOTE_WORKDIR.rstrip('/')}/{filename}"
        sftp.put(local_path, remote_path)

        cmd = POST_PROCESS_CMD.replace('{path}', remote_path)
        stdin, stdout, stderr = ssh.exec_command(cmd)
        out = stdout.read().decode('utf-8', errors='ignore')
        err = stderr.read().decode('utf-8', errors='ignore')
        return {'remote_path': remote_path, 'stdout': out, 'stderr': err}
    finally:
        try:
            sftp.close()
        except Exception:
            pass
        ssh.close()


@app.route('/health', methods=['GET'])
def health():
    return 'ok', 200


@app.route('/', methods=['GET'])
def index():
    # serve the frontend index
    return app.send_static_file('index.html')


@app.route('/upload', methods=['POST'])
def upload():
    if 'file' not in request.files:
        return jsonify({'error': 'file field required'}), 400
    f = request.files['file']
    filename = f.filename or 'upload.bin'
    tmpdir = pathlib.Path('/tmp/uploads')
    tmpdir.mkdir(parents=True, exist_ok=True)
    local_path = str(tmpdir / filename)
    f.save(local_path)

    try:
        result = sftp_and_exec(local_path, filename)
    except Exception as e:
        logger.exception('sftp/exec failed')
        return jsonify({'error': str(e)}), 500

    return jsonify({'status': 'ok', **result})


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
