#!/usr/bin/env bash
# LabLink custom startup script: install SLEAP in the client container.
# Runs every container start — must be idempotent.
#
# Context provided by client/start.sh:
#   user         = client (passwordless sudo)
#   venv         = /home/client/.venv (activated)
#   base image   = nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04
#   uv           = on PATH (baked into the image)
#   nvidia-smi   = present iff `--gpus all` was passed at docker run

set -euo pipefail

echo "==> install-sleap: starting"

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -L || true
else
  echo "    nvidia-smi not found — uv will install the CPU torch backend"
fi

# start.sh runs non-interactively, so ~/.profile's PATH munging hasn't
# happened. Add ~/.local/bin (uv-tool shim dir) so the idempotency check
# and any post-install commands resolve.
export PATH="$HOME/.local/bin:$PATH"

if uv tool list 2>/dev/null | grep -q '^sleap '; then
  echo "==> install-sleap: already installed — skipping"
  uv tool list | grep '^sleap '
  exit 0
fi

# Exact command from https://docs.sleap.ai/latest/installation/ (uv path).
# Installs sleap into an isolated uv tool env with its own Python 3.13;
# --torch-backend auto detects CUDA and picks cu128 wheels on this image.
uv tool install \
  --python 3.13 \
  "sleap[nn]==1.6.3" \
  --with "sleap-io==0.7.0" \
  --with "sleap-nn==0.2.0" \
  --torch-backend auto

echo "==> install-sleap: done"
uv tool list | grep '^sleap '
