#!/bin/sh
# -----------------------------------------------------------------------------
# easy-ffmpeg installer.
#
# Modes:
#   --cpu    Download the prebuilt CPU-only binary from GitHub releases
#            (default). Works on macOS and Linux without Docker or CUDA.
#   --gpu    Build the NVIDIA-accelerated Docker image and install the
#            wrapper script. Linux / WSL2 with NVIDIA GPU only.
#
# When invoked without --cpu / --gpu on a TTY, the script asks interactively.
# Run unattended (e.g. `curl ... | sh`) without a TTY → defaults to --cpu.
# -----------------------------------------------------------------------------
set -e

REPO="akitaonrails/easy-ffmpeg"
IMAGE="easy-ffmpeg:cuda"

c_cyan()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
c_dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

usage() {
  cat <<EOF
Usage: install.sh [--cpu | --gpu] [--help]

  --cpu    Install the prebuilt CPU-only binary (default).
  --gpu    Build the CUDA Docker image and install the wrapper.
  --help   Show this help.

With no flag and an interactive terminal, asks which mode to install.
EOF
}

if [ -z "${INSTALL_DIR:-}" ]; then
  if [ "$(id -u)" = "0" ]; then
    INSTALL_DIR="/usr/local/bin"
  else
    INSTALL_DIR="${HOME}/.local/bin"
  fi
fi

MODE=""
for arg in "$@"; do
  case "$arg" in
    --cpu) MODE=cpu ;;
    --gpu) MODE=gpu ;;
    -h|--help) usage; exit 0 ;;
    *) c_red "unknown option: $arg"; usage; exit 1 ;;
  esac
done

if [ -z "$MODE" ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    c_cyan "easy-ffmpeg installer"
    echo "  1) CPU only (prebuilt binary — macOS, Linux, no Docker required)"
    echo "  2) NVIDIA GPU acceleration (builds the CUDA Docker image)"
    printf "Pick [1/2] (default: 1): "
    read -r answer || answer=1
    case "$answer" in
      2|gpu|GPU) MODE=gpu ;;
      *)         MODE=cpu ;;
    esac
    echo ""
  else
    MODE=cpu  # non-interactive (curl | sh)
  fi
fi

install_cpu() {
  c_cyan "Installing easy-ffmpeg (CPU-only)"

  case "$(uname -s)" in
    Linux*)  OS=linux ;;
    Darwin*) OS=darwin ;;
    *) c_red "unsupported OS: $(uname -s)"; exit 1 ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64)   ARCH=amd64 ;;
    aarch64|arm64)  ARCH=arm64 ;;
    *) c_red "unsupported architecture: $(uname -m)"; exit 1 ;;
  esac

  BINARY="easy-ffmpeg-${OS}-${ARCH}"
  API_URL="https://api.github.com/repos/${REPO}/releases/latest"
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  mkdir -p "$INSTALL_DIR"

  # Resolve the exact release tag first so the install is explicit.
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$API_URL" -o "${TMPDIR}/release.json"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${TMPDIR}/release.json" "$API_URL"
  else
    c_red "curl or wget is required"; exit 1
  fi

  RELEASE_TAG=$(sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)",$/\1/p' "${TMPDIR}/release.json" | head -n 1)
  if [ -z "$RELEASE_TAG" ]; then
    c_red "failed to resolve the latest release tag"; exit 1
  fi

  URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${BINARY}"
  CHECKSUMS_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/SHA256SUMS.txt"

  echo "Downloading easy-ffmpeg ${RELEASE_TAG} (${OS}/${ARCH})..."

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "${TMPDIR}/${BINARY}"
    curl -fsSL "$CHECKSUMS_URL" -o "${TMPDIR}/SHA256SUMS.txt"
  else
    wget -qO "${TMPDIR}/${BINARY}" "$URL"
    wget -qO "${TMPDIR}/SHA256SUMS.txt" "$CHECKSUMS_URL"
  fi

  echo "Verifying checksum..."
  EXPECTED=$(grep "${BINARY}" "${TMPDIR}/SHA256SUMS.txt" | awk '{print $1}')
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "${TMPDIR}/${BINARY}" | awk '{print $1}')
  else
    ACTUAL=$(shasum -a 256 "${TMPDIR}/${BINARY}" | awk '{print $1}')
  fi

  if [ "$EXPECTED" != "$ACTUAL" ]; then
    c_red "checksum verification failed"
    echo "  expected: ${EXPECTED}" >&2
    echo "  got:      ${ACTUAL}" >&2
    exit 1
  fi

  mv "${TMPDIR}/${BINARY}" "${INSTALL_DIR}/easy-ffmpeg"
  chmod +x "${INSTALL_DIR}/easy-ffmpeg"

  if [ "$OS" = darwin ]; then
    xattr -d com.apple.quarantine "${INSTALL_DIR}/easy-ffmpeg" 2>/dev/null || true
  fi

  c_green "Installed easy-ffmpeg to ${INSTALL_DIR}/easy-ffmpeg"
  hint_path
}

install_gpu() {
  c_cyan "Installing easy-ffmpeg (NVIDIA GPU acceleration)"
  echo ""
  echo "This builds a CUDA Docker image (compiles FFmpeg from source, 10-20"
  echo "minutes the first time) and installs a wrapper script as 'easy-ffmpeg'"
  echo "that runs the image transparently."
  echo ""

  check_gpu_prereqs

  REPO_ROOT="$(locate_repo_root)"
  if [ -z "$REPO_ROOT" ]; then
    c_red "could not locate the easy-ffmpeg source (need Dockerfile + scripts/)."
    echo "  Clone the repo and re-run this script from inside it:"
    echo ""
    echo "    git clone https://github.com/${REPO}.git"
    echo "    cd easy-ffmpeg"
    echo "    ./install.sh --gpu"
    exit 1
  fi

  c_cyan "Building Docker image (this may take 10-20 minutes the first time)"
  (cd "$REPO_ROOT" && docker build -t "$IMAGE" -t "easy-ffmpeg:latest" .)
  c_green "Image built: ${IMAGE}"
  c_dim "  smoke-test the image with: scripts/docker-build.sh --skip-build"

  mkdir -p "$INSTALL_DIR"
  cp "$REPO_ROOT/scripts/easy-ffmpeg-docker.sh" "${INSTALL_DIR}/easy-ffmpeg"
  chmod +x "${INSTALL_DIR}/easy-ffmpeg"
  c_green "Installed wrapper to ${INSTALL_DIR}/easy-ffmpeg"

  echo ""
  c_cyan "Quick test"
  echo "  easy-ffmpeg --help"
  echo "  easy-ffmpeg -i ~/videos/movie.mkv -f mp4 --compress --gpu"

  hint_path
}

check_gpu_prereqs() {
  c_cyan "Checking prerequisites"
  ok=1

  if command -v docker >/dev/null 2>&1; then
    printf '  [\033[1;32m✓\033[0m] docker found: %s\n' "$(docker --version 2>/dev/null | head -1)"
  else
    printf '  [\033[1;31m✗\033[0m] docker not found\n'
    c_dim "      install: https://docs.docker.com/engine/install/"
    ok=0
  fi

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
    printf '  [\033[1;32m✓\033[0m] NVIDIA GPU detected: %s\n' "$gpu_name"
  else
    printf '  [\033[1;31m✗\033[0m] no NVIDIA GPU reachable via nvidia-smi\n'
    c_dim "      install the NVIDIA driver, or skip --gpu if you do not have one"
    ok=0
  fi

  if check_container_toolkit; then
    printf '  [\033[1;32m✓\033[0m] nvidia-container-toolkit is wired up\n'
  else
    printf '  [\033[1;31m✗\033[0m] nvidia-container-toolkit not installed or not wired into Docker\n'
    c_dim "      install: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
    ok=0
  fi

  if [ "$ok" -ne 1 ]; then
    echo ""
    c_red "GPU install cannot proceed — fix the items above and re-run."
    exit 1
  fi
  echo ""
}

check_container_toolkit() {
  command -v nvidia-ctk            >/dev/null 2>&1 && return 0
  command -v nvidia-container-cli  >/dev/null 2>&1 && return 0
  docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia' && return 0
  return 1
}

# Returns 0 + echoes the path when found, 0 + empty when not (so `set -e`
# in the caller doesn't fire — caller checks the captured value).
locate_repo_root() {
  for candidate in "$PWD" "$(dirname "$0")"; do
    if [ -f "$candidate/Dockerfile" ] && [ -f "$candidate/scripts/easy-ffmpeg-docker.sh" ]; then
      (cd "$candidate" && pwd)
      return 0
    fi
  done
  return 0
}

hint_path() {
  case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
      echo ""
      echo "Add ${INSTALL_DIR} to your PATH:"
      echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
      ;;
  esac
}

case "$MODE" in
  cpu) install_cpu ;;
  gpu) install_gpu ;;
esac
