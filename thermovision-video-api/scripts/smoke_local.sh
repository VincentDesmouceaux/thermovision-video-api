#!/usr/bin/env bash
# smoke_local.sh - safe multi-stack smoke test for ~/video-like repos
# Default: light checks only (no installs, no heavy builds)
# Optional flags enable dependency installs and builds.

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

# ---------- Flags ----------
INSTALL_PY=0
INSTALL_NODE=0
BUILD_SWIFT=0
BUILD_DOTNET=0
RUN_PY_HELP=1
RUN_NODE_CHECK=1

for arg in "$@"; do
  case "$arg" in
    --install-python-deps) INSTALL_PY=1 ;;
    --install-node-deps) INSTALL_NODE=1 ;;
    --build-swift) BUILD_SWIFT=1 ;;
    --build-dotnet) BUILD_DOTNET=1 ;;
    --no-py-help) RUN_PY_HELP=0 ;;
    --no-node-check) RUN_NODE_CHECK=0 ;;
    -h|--help)
      cat <<'USAGE'
Usage: scripts/smoke_local.sh [options]

Default behavior:
  - Runs light, non-destructive checks for Python/Node/Swift/.NET if detected.
  - Does NOT install deps and does NOT build heavy targets.

Options:
  --install-python-deps   Install Python deps from requirements.txt (if present)
  --install-node-deps     npm install (if package.json present)
  --build-swift           swift build (if Package.swift present)
  --build-dotnet          dotnet build (if *.sln present)
  --no-py-help            Skip running --help on known python entry scripts
  --no-node-check         Skip node --check on processor-server.js (if present)

Examples:
  scripts/smoke_local.sh
  scripts/smoke_local.sh --install-python-deps --install-node-deps
  scripts/smoke_local.sh --build-swift --build-dotnet
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      echo "Run with --help to see available options."
      exit 1
      ;;
  esac
done

# ---------- Helpers ----------
PASS=0
FAIL=0
SKIP=0

hr() { echo "------------------------------------------------------------"; }

have() { command -v "$1" >/dev/null 2>&1; }

ok() { echo "✅ $*"; PASS=$((PASS+1)); }
bad() { echo "❌ $*"; FAIL=$((FAIL+1)); }
skip() { echo "⏭️  $*"; SKIP=$((SKIP+1)); }

run_step() {
  local title="$1"; shift
  echo
  hr
  echo "🔎 $title"
  hr
  "$@"
}

run_cmd_soft() {
  # Runs a command, reports pass/fail, but doesn't stop the script.
  local label="$1"; shift
  if "$@"; then
    ok "$label"
    return 0
  else
    bad "$label"
    return 1
  fi
}

# ---------- Repo overview ----------
run_step "Repo overview" bash -c '
  echo "Root: '"$ROOT_DIR"'"
  echo "Git branch (if any):"
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "  (not a git repo or git missing)"
  echo
  echo "Top-level files:"
  ls -1
'

# ---------- Python ----------
run_step "Python checks" bash -c '
  set -u
  ROOT="'"$ROOT_DIR"'"
  cd "$ROOT" || exit 0

  if command -v python3 >/dev/null 2>&1; then
    echo "System python3: $(python3 --version 2>/dev/null || true)"
  else
    echo "python3 not found"
  fi

  if [ -d ".venv" ] && [ -f ".venv/bin/activate" ]; then
    echo ".venv detected."
  else
    echo "No .venv detected."
  fi
'

# If .venv exists, do deeper checks inside it (safe)
if [ -f ".venv/bin/activate" ]; then
  run_step "Python venv smoke" bash -c '
    set -u
    cd "'"$ROOT_DIR"'" || exit 1
    # shellcheck disable=SC1091
    source .venv/bin/activate

    echo "Venv python: $(which python)"
    python --version

    python -c "import sys, json, pathlib; print(\"basic import ok\")"
  '
  if [ "$INSTALL_PY" -eq 1 ]; then
    if [ -f "requirements.txt" ]; then
      run_step "Install Python deps (requirements.txt)" bash -c '
        set -u
        cd "'"$ROOT_DIR"'" || exit 1
        # shellcheck disable=SC1091
        source .venv/bin/activate
        python -m pip install -U pip wheel
        pip install -r requirements.txt
        pip check || true
      '
    else
      skip "requirements.txt not found; skipping Python deps install"
    fi
  else
    if [ -f "requirements.txt" ]; then
      skip "Python deps install not requested (use --install-python-deps)"
    fi
  fi

  if [ "$RUN_PY_HELP" -eq 1 ]; then
    # Lightweight help checks for likely entrypoints
    for f in app.py thermal_processor.py orchestrate_probe.py; do
      if [ -f "$f" ]; then
        run_step "Python help check: $f" bash -c '
          set -u
          cd "'"$ROOT_DIR"'" || exit 1
          # shellcheck disable=SC1091
          source .venv/bin/activate
          python "'"$f"'" --help >/dev/null 2>&1 && echo "help ok" || echo "help not supported (non-fatal)"
        '
      fi
    done
  fi
else
  skip "No .venv found; skipping venv-specific Python checks"
fi

# ---------- Node ----------
run_step "Node checks" bash -c '
  set -u
  cd "'"$ROOT_DIR"'" || exit 1

  if command -v node >/dev/null 2>&1; then
    echo "node: $(node -v)"
  else
    echo "node not found"
  fi

  if command -v npm >/dev/null 2>&1; then
    echo "npm:  $(npm -v)"
  else
    echo "npm not found"
  fi

  if [ -f "package.json" ]; then
    echo "package.json detected."
  else
    echo "No package.json."
  fi
'

if [ -f "package.json" ]; then
  if [ "$INSTALL_NODE" -eq 1 ]; then
    run_step "Install Node deps (npm install)" bash -c '
      set -u
      cd "'"$ROOT_DIR"'" || exit 1
      npm install
    '
  else
    skip "Node deps install not requested (use --install-node-deps)"
  fi

  if [ "$RUN_NODE_CHECK" -eq 1 ] && have node; then
    if [ -f "processor-server.js" ]; then
      # node --check validates syntax without running the server
      run_step "Node syntax check: processor-server.js" bash -c '
        set -u
        cd "'"$ROOT_DIR"'" || exit 1
        node --check processor-server.js
      '
    fi
  fi
else
  skip "No package.json; skipping Node project checks"
fi

# ---------- Swift / Metal ----------
run_step "Swift checks" bash -c '
  set -u
  cd "'"$ROOT_DIR"'" || exit 1

  if command -v swift >/dev/null 2>&1; then
    echo "swift: $(swift --version | head -n 1)"
  else
    echo "swift not found"
  fi

  if [ -f "Package.swift" ]; then
    echo "Package.swift detected."
  else
    echo "No Package.swift."
  fi
'

if [ -f "Package.swift" ] && have swift; then
  run_step "Swift package describe (safe)" bash -c '
    set -u
    cd "'"$ROOT_DIR"'" || exit 1
    swift package describe >/dev/null 2>&1 && echo "package describe ok" || echo "package describe failed (non-fatal)"
  '

  if [ "$BUILD_SWIFT" -eq 1 ]; then
    run_step "Swift build" bash -c '
      set -u
      cd "'"$ROOT_DIR"'" || exit 1
      swift build
    '
  else
    skip "Swift build not requested (use --build-swift)"
  fi
else
  if [ -f "Package.swift" ]; then
    skip "Swift not available; skipping Swift build/describe"
  fi
fi

# ---------- .NET ----------
run_step ".NET checks" bash -c '
  set -u
  cd "'"$ROOT_DIR"'" || exit 1

  if command -v dotnet >/dev/null 2>&1; then
    echo "dotnet: $(dotnet --version)"
  else
    echo "dotnet not found"
  fi

  ls -1 *.sln 2>/dev/null || echo "No .sln found."
'

if have dotnet && ls *.sln >/dev/null 2>&1; then
  if [ "$BUILD_DOTNET" -eq 1 ]; then
    # Build solution(s)
    for sln in *.sln; do
      run_step ".NET build: $sln" bash -c '
        set -u
        cd "'"$ROOT_DIR"'" || exit 1
        dotnet build "'"$sln"'"
      '
    done
  else
    skip ".NET build not requested (use --build-dotnet)"
  fi
else
  if ls *.sln >/dev/null 2>&1; then
    skip "dotnet not available; skipping .NET build"
  fi
fi

# ---------- Media files presence ----------
run_step "Media presence quick check" bash -c '
  set -u
  cd "'"$ROOT_DIR"'" || exit 1
  for f in foret.mp4 in_qt.mov out.mp4; do
    if [ -f "$f" ]; then
      echo "Found $f ($(stat -f%z "$f" 2>/dev/null || echo "?") bytes)"
    fi
  done
'

# ---------- Summary ----------
echo
hr
echo "✅ SMOKE TEST SUMMARY"
hr
echo "Pass: $PASS"
echo "Fail: $FAIL"
echo "Skip: $SKIP"
echo

if [ "$FAIL" -ne 0 ]; then
  echo "Some checks failed. This is expected for a multi-stack repo without all deps installed."
  echo "You can re-run with:"
  echo "  scripts/smoke_local.sh --install-python-deps --install-node-deps"
  echo "  scripts/smoke_local.sh --build-swift --build-dotnet"
  exit 1
fi

exit 0
