#!/usr/bin/env bash
#
# Install vllm-server (vLLM OpenAI API) as a systemd service backed by the
# NVIDIA NGC container nvcr.io/nvidia/vllm.
#
# No build: the container is pre-built for DGX Spark / GB10 (aarch64, sm_121).
# This installs the systemd unit + env template and pre-creates the HF cache.
# Run as a normal user (NOT root); privileged steps call sudo themselves.
#
#   ./install.sh                 # install unit + env, prepare cache, daemon-reload
#   sudoedit /etc/vllm/vllm-server.env
#   sudo systemctl enable --now vllm-server
#
# Override defaults via environment, e.g.  PREFIX=/etc/vllm STATE=/srv/vllm ./install.sh
set -euo pipefail

# --- configuration ------------------------------------------------------------
CONF="${CONF:-/etc/vllm}"
STATE="${STATE:-/var/lib/vllm}"
CACHE="${CACHE:-$STATE/cache}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run as a normal user, not root (sudo is used per-step)"

# --- 1. prerequisites ---------------------------------------------------------
# The unit runs `docker run --gpus all`; both docker and the NVIDIA container
# toolkit must be working before the service can start.
command -v docker >/dev/null || die "docker not found; install Docker first"
if ! docker info 2>/dev/null | grep -qiE 'nvidia|cdi: nvidia'; then
    say "WARNING: NVIDIA container runtime not detected in 'docker info'."
    say "         Install nvidia-container-toolkit, or the service will fail at start."
fi

# --- 2. HF cache --------------------------------------------------------------
# Bind-mounted into the container as HF_HOME; weights download here on first run.
# 0755 so a host-side huggingface-cli can read/pre-seed it. docker runs the
# container as root, so root owns files written inside — that is fine here.
say "Preparing $CACHE"
sudo install -d -m 0755 "$STATE" "$CACHE"

# --- 3. systemd unit + env ----------------------------------------------------
say "Installing systemd unit and env template"
sudo install -m 0644 "$HERE/vllm-server.service" /etc/systemd/system/vllm-server.service
sudo install -d -m 0755 "$CONF"
if [[ ! -f "$CONF/vllm-server.env" ]]; then
    # 0640: the env file may carry HF_TOKEN. Keep it unreadable to other users.
    sudo install -m 0640 "$HERE/vllm-server.env.example" "$CONF/vllm-server.env"
    say "Wrote $CONF/vllm-server.env — EDIT IT (image tag, model) before starting"
else
    say "$CONF/vllm-server.env already exists; leaving it untouched"
fi
sudo systemctl daemon-reload

cat <<EOF

$(say "Done.")
Image  : pulled on first start (set VLLM_IMAGE in the env file)
Cache  : $CACHE  (bind-mounted as HF_HOME; weights land here)
Config : $CONF/vllm-server.env

NOTE: ON-DEMAND service — do NOT 'enable' it. This box runs llama-server
      resident on the shared 128GB pool, leaving no room for both. The unit's
      Conflicts=llama-server.service stops llama-server when vLLM starts and
      lets it run high; 'start llama-server' hands memory back. See README.md.

Next:
  1. Edit  $CONF/vllm-server.env   (pin VLLM_IMAGE tag, set VLLM_MODEL)
  2. sudo systemctl start vllm-server   # stops llama-server; do NOT 'enable'
  3. journalctl -u vllm-server -f       # watch image pull + model load
  4. curl http://127.0.0.1:8000/v1/models
  5. sudo systemctl start llama-server  # done — restore the llama.cpp router
EOF
