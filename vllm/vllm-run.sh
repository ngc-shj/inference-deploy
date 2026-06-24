#!/usr/bin/env bash
# Launch wrapper for vllm-server.service.
#
# Why a wrapper instead of inlining `docker run` in ExecStart:
#   vLLM flags like --speculative-config take a JSON value ('{"method":"mtp",...}').
#   systemd's EnvironmentFile strips the double-quotes (and then word-splits),
#   so a JSON passed through $VLLM_SERVE_ARGS reaches vLLM as {method:mtp,...} and
#   `json.loads` rejects it. A shell, by contrast, preserves quoting correctly.
#   So the unit runs THIS script; the shell — not systemd — builds the argv.
#
# Reads the same /etc/vllm/vllm-server.env the unit used to inline. All the
# vLLM serve flags live in $VLLM_SERVE_ARGS; the JSON-valued speculative config
# is kept in its OWN var $VLLM_SPEC_CONFIG so the shell can quote it as one arg.
set -euo pipefail

: "${VLLM_IMAGE:?VLLM_IMAGE not set}"
: "${VLLM_MODEL:?VLLM_MODEL not set}"
VLLM_HOST="${VLLM_HOST:-127.0.0.1}"
VLLM_PORT="${VLLM_PORT:-8000}"

# Base argv. --entrypoint vllm normalizes NGC vs Docker-Hub images (the latter
# bakes `vllm serve` into ENTRYPOINT; forcing `vllm` + `serve` works for both).
args=(
  run --rm --name vllm-server
  --entrypoint vllm
  --gpus all
  --shm-size=8g
  -p "${VLLM_HOST}:${VLLM_PORT}:8000"
  -v /var/lib/vllm/cache:/root/.cache/huggingface
  -e HF_HOME=/root/.cache/huggingface
  -e "HF_TOKEN=${HF_TOKEN:-}"
  "${VLLM_IMAGE}"
  serve "${VLLM_MODEL}"
  --host 0.0.0.0 --port 8000
)

# $VLLM_SERVE_ARGS is a plain flag string (no JSON) — safe to word-split here.
if [[ -n "${VLLM_SERVE_ARGS:-}" ]]; then
  # shellcheck disable=SC2206  # intentional word-split of a flat flag list
  args+=( ${VLLM_SERVE_ARGS} )
fi

# JSON-valued flag kept whole. The shell preserves the inner double-quotes that
# systemd's env handling would have eaten.
if [[ -n "${VLLM_SPEC_CONFIG:-}" ]]; then
  args+=( --speculative-config "${VLLM_SPEC_CONFIG}" )
fi

exec /usr/bin/docker "${args[@]}"
