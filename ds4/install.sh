#!/usr/bin/env bash
#
# Build ds4-server (DwarfStar) and install it as a systemd service.
#
# The ds4 source is cloned from REPO into SRC if absent (GitHub is the source of
# truth); an existing checkout is reused as-is. Run as a normal user (NOT root);
# privileged steps call sudo themselves so the CUDA/make build does not run as
# root. Override any setting via environment, e.g.
#   SRC=/path/to/ds4 MAKE_TARGET=cuda-generic ./install.sh
#
# Models: a GGUF under $HOME (typically 0750) is unreadable to the service user,
# so the main model and the optional MTP draft are placed in /var/lib/ds4/models.
# Copy by default; MODEL_MOVE=1 relocates instead (instant on the same
# filesystem) and leaves a symlink at the source so the ds4 CLI keeps working.
set -euo pipefail

# --- configuration ------------------------------------------------------------
REPO="${REPO:-https://github.com/antirez/ds4.git}"       # upstream source of truth
SRC="${SRC:-$HOME/ghq/github.com/antirez/ds4}"           # local checkout (cloned if absent)
PREFIX="${PREFIX:-/opt/ds4}"
SVC_USER="${SVC_USER:-ds4}"
STATE="${STATE:-/var/lib/ds4}"
MODELS="${MODELS:-$STATE/models}"
MAKE_TARGET="${MAKE_TARGET:-cuda-spark}"        # cuda-spark | cuda-generic | cpu
MODEL_SRC="${MODEL_SRC:-$SRC/ds4flash.gguf}"
GGUF_DIR="${GGUF_DIR:-$SRC/gguf}"               # where download_model.sh writes
MTP_SRC="${MTP_SRC:-}"                          # optional; auto-detected if unset

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run as a normal user, not root (sudo is used per-step)"

# Clone the upstream source of truth if the checkout is missing. An existing
# $SRC is left untouched (pull/update is the user's call, not the installer's).
if [[ ! -d "$SRC" ]]; then
    say "Cloning $REPO -> $SRC"
    git clone "$REPO" "$SRC"
fi
[[ -f "$SRC/Makefile" ]] || die "ds4 source not found at SRC=$SRC (clone of $REPO failed?)"

# Relocate a GGUF into $MODELS and echo its final path (progress -> stderr).
relocate_model() {
    local src="$1" real target
    [[ -e "$src" ]] || return 1
    real="$(readlink -f "$src")"
    target="$MODELS/$(basename "$real")"
    if [[ "$real" != "$target" ]]; then
        if [[ -n "${MODEL_MOVE:-}" ]]; then
            say "moving $(basename "$real") -> $MODELS" >&2
            sudo mv -n "$real" "$target"
            ln -sfn "$target" "$src"   # source is user-owned; keep the CLI path working
        elif [[ ! -e "$target" ]]; then
            say "copying $(basename "$real") -> $MODELS (MODEL_MOVE=1 to move)" >&2
            sudo cp "$real" "$target"
        fi
    fi
    sudo chown "$SVC_USER:$SVC_USER" "$target"
    printf '%s\n' "$target"
}

# --- 1. build -----------------------------------------------------------------
if [[ -z "${NO_BUILD:-}" ]]; then
    say "Building ds4-server ($MAKE_TARGET) in $SRC"
    make -C "$SRC" "$MAKE_TARGET"
fi
[[ -x "$SRC/ds4-server" ]] || die "$SRC/ds4-server not found; build it or unset NO_BUILD"

# --- 2. service account -------------------------------------------------------
if ! id -u "$SVC_USER" >/dev/null 2>&1; then
    say "Creating system user '$SVC_USER'"
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
fi

# --- 3. install binary --------------------------------------------------------
say "Installing binary to $PREFIX"
sudo install -d -m 0755 -o "$SVC_USER" -g "$SVC_USER" "$PREFIX"
sudo install -m 0755 "$SRC/ds4-server" "$PREFIX/ds4-server"

# --- 4. state tree ------------------------------------------------------------
# $STATE/models is 0755 so the ds4 CLI (run as a normal user) can read the model
# too; kv holds runtime cache state and stays private to the service user.
say "Preparing $STATE/{models,kv}"
sudo install -d -m 0755 -o "$SVC_USER" -g "$SVC_USER" "$STATE" "$MODELS"
sudo install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$STATE/kv"

# --- 5. main model ------------------------------------------------------------
orig_model_dir=""
[[ -e "$MODEL_SRC" ]] && orig_model_dir="$(dirname "$(readlink -f "$MODEL_SRC")")"
if main_target="$(relocate_model "$MODEL_SRC")"; then
    # Stable alias so the env file's -m path does not depend on the real filename.
    sudo ln -sfn "$main_target" "$MODELS/ds4flash.gguf"
    sudo chown -h "$SVC_USER:$SVC_USER" "$MODELS/ds4flash.gguf"
    say "Linked $MODELS/ds4flash.gguf -> $main_target"
else
    say "WARNING: model $MODEL_SRC not found; set -m in the env file"
fi

# --- 6. optional MTP draft model ----------------------------------------------
# download_model.sh writes it into $GGUF_DIR under the name in its MTP_FILE var;
# use that as the single source of truth.
mtp_src="$MTP_SRC"
if [[ -z "$mtp_src" ]]; then
    mtp_name="$(sed -n 's/^MTP_FILE="\(.*\)"/\1/p' "$SRC/download_model.sh" 2>/dev/null)"
    for d in "$GGUF_DIR" "$orig_model_dir"; do
        if [[ -n "$d" && -n "$mtp_name" && -e "$d/$mtp_name" ]]; then
            mtp_src="$d/$mtp_name"
            break
        fi
    done
fi
mtp_target=""
if [[ -n "$mtp_src" ]] && mtp_target="$(relocate_model "$mtp_src")"; then
    say "MTP model ready: $mtp_target"
fi

sudo chown -R "$SVC_USER:$SVC_USER" "$PREFIX"

# --- 7. systemd unit + env ----------------------------------------------------
say "Installing systemd unit and env template"
sed \
    -e "s#/opt/ds4#$PREFIX#g" \
    -e "s#^User=ds4#User=$SVC_USER#" \
    -e "s#^Group=ds4#Group=$SVC_USER#" \
    "$HERE/ds4-server.service" | sudo tee /etc/systemd/system/ds4-server.service >/dev/null
sudo install -d -m 0755 /etc/ds4
if [[ ! -f /etc/ds4/ds4-server.env ]]; then
    sudo install -m 0644 "$HERE/ds4-server.env.example" /etc/ds4/ds4-server.env
    say "Wrote /etc/ds4/ds4-server.env — review host/port/ctx/model before starting"
else
    say "/etc/ds4/ds4-server.env already exists; leaving it untouched"
fi
sudo systemctl daemon-reload

cat <<EOF

$(say "Done.")
Binary : $PREFIX/ds4-server
Model  : ${main_target:-<not set>}
$( [[ -n "$mtp_target" ]] && echo "MTP    : $mtp_target  (enable with --mtp <path> --mtp-draft 2)" )
State  : $STATE/models (GGUFs), $STATE/kv (kv-disk)

Next:
  1. Edit  /etc/ds4/ds4-server.env   (set host/port/ctx; add --mtp to enable MTP)
  2. sudo systemctl enable --now ds4-server
  3. journalctl -u ds4-server -f
EOF
