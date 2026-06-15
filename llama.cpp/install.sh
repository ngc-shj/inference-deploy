#!/usr/bin/env bash
#
# Build llama.cpp with CUDA and install llama-server as a systemd service.
#
# Run as a normal user (NOT root); privileged steps call sudo themselves so the
# CUDA build does not run as root. Override any setting via environment, e.g.
#   SRC=/path/to/llama.cpp CUDA_ARCH=121 ./install.sh
#
set -euo pipefail

# --- configuration ------------------------------------------------------------
SRC="${SRC:-$HOME/ghq/github.com/ggerganov/llama.cpp}"
BUILD="${BUILD:-$SRC/build-cuda}"
PREFIX="${PREFIX:-/opt/llama}"
SVC_USER="${SVC_USER:-llama}"
CUDA_ARCH="${CUDA_ARCH:-121}"        # GB10 = sm_121
JOBS="${JOBS:-$(nproc)}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIPLET="$(uname -m)-linux-gnu"
# PKG_CONFIG_LIBDIR *replaces* pkg-config's built-in search path (PKG_CONFIG_PATH
# only prepends to it). The pkg-config on PATH is linuxbrew's, with brew dirs
# baked in and /usr absent, so prepending is not enough — openssl resolves to
# brew. Replacing the path makes pkg-config blind to brew entirely.
SYSTEM_PC="/usr/lib/${TRIPLET}/pkgconfig:/usr/share/pkgconfig"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run as a normal user, not root (sudo is used per-step)"
[[ -f "$SRC/CMakeLists.txt" ]] || die "llama.cpp source not found at SRC=$SRC"
[[ -x "$CUDA_HOME/bin/nvcc" ]] || die "nvcc not found at $CUDA_HOME/bin/nvcc"

# --- 1. system libcurl (so the binary does not depend on /home/linuxbrew) ------
if ! PKG_CONFIG_LIBDIR="$SYSTEM_PC" pkg-config --exists libcurl; then
    say "Installing system libcurl (apt)"
    sudo apt-get update
    sudo apt-get install -y libcurl4-openssl-dev
fi

# --- 2. configure, forcing system curl/openssl over linuxbrew -----------------
say "Configuring CUDA build (sm_${CUDA_ARCH}) -> $BUILD"
PATH="$CUDA_HOME/bin:$PATH" CUDACXX="$CUDA_HOME/bin/nvcc" \
PKG_CONFIG_LIBDIR="$SYSTEM_PC" \
cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
    -DLLAMA_CURL=ON \
    -DOPENSSL_ROOT_DIR=/usr \
    -DOPENSSL_INCLUDE_DIR=/usr/include \
    -DOPENSSL_CRYPTO_LIBRARY="/usr/lib/${TRIPLET}/libcrypto.so" \
    -DOPENSSL_SSL_LIBRARY="/usr/lib/${TRIPLET}/libssl.so" \
    -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib' \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"

# --- 3. build -----------------------------------------------------------------
# Build all default targets: `cmake --install` runs the full install manifest,
# so every installed artifact must exist or the install step fails. Tests and
# examples are already disabled at configure time.
say "Building (-j$JOBS)"
PATH="$CUDA_HOME/bin:$PATH" cmake --build "$BUILD" -j"$JOBS"

# --- 4. verify no linuxbrew dependency leaked in ------------------------------
# Only /home/linuxbrew matters: the project's own libs under $BUILD/bin also
# contain /home and are relocated to $PREFIX/lib by the install step.
say "Verifying the binary links no /home/linuxbrew library"
if ldd "$BUILD/bin/llama-server" | grep -q '/home/linuxbrew'; then
    ldd "$BUILD/bin/llama-server" | grep '/home/linuxbrew'
    die "binary still links a linuxbrew library; aborting before install"
fi

# --- 5. install to $PREFIX ----------------------------------------------------
say "Installing to $PREFIX"
sudo cmake --install "$BUILD"

# --- 6. service account -------------------------------------------------------
if ! id -u "$SVC_USER" >/dev/null 2>&1; then
    say "Creating system user '$SVC_USER'"
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
fi

# Pre-create the state tree so models can be dropped in before first start.
# 0755 so the llama-cli (run as a normal user) can read the models; the unit's
# StateDirectoryMode=0755 re-applies this on every service start.
say "Preparing /var/lib/llama/{models,cache}"
sudo install -d -m 0755 -o "$SVC_USER" -g "$SVC_USER" \
    /var/lib/llama /var/lib/llama/models /var/lib/llama/cache

# --- 7. systemd unit + env ----------------------------------------------------
say "Installing systemd unit and env template"
sudo install -m 0644 "$HERE/llama-server.service" /etc/systemd/system/llama-server.service
sudo install -d -m 0755 /etc/llama
if [[ ! -f /etc/llama/llama-server.env ]]; then
    sudo install -m 0644 "$HERE/llama-server.env.example" /etc/llama/llama-server.env
    say "Wrote /etc/llama/llama-server.env — EDIT IT to set your model before starting"
else
    say "/etc/llama/llama-server.env already exists; leaving it untouched"
fi
if [[ ! -f /etc/llama/models.ini ]]; then
    sudo install -m 0644 "$HERE/models.ini.example" /etc/llama/models.ini
    say "Wrote /etc/llama/models.ini — edit to define per-model router presets"
else
    say "/etc/llama/models.ini already exists; leaving it untouched"
fi
sudo systemctl daemon-reload

cat <<EOF

$(say "Done.")
Binaries : $PREFIX/bin/llama-server, $PREFIX/bin/llama-cli
Models   : put GGUF files in /var/lib/llama/models  (created on first start)
HF cache : /var/lib/llama/cache  (LLAMA_CACHE, for -hf downloads)

Next (router mode — clients pick the model per request):
  1. Cache each model once:
       sudo -u $SVC_USER LLAMA_CACHE=/var/lib/llama/cache \\
           $PREFIX/bin/llama-server -hf <repo>:<tag> -ngl 0   # Ctrl-C after "model loaded"
  2. Edit  /etc/llama/llama-server.env  and  /etc/llama/models.ini
  3. sudo systemctl enable --now llama-server
  4. journalctl -u llama-server -f
EOF
