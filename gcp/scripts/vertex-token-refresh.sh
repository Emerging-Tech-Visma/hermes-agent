#!/usr/bin/env bash
# Refreshes the Vertex OAuth access token used by OpenViking's VLM (OpenAI-compatible
# endpoint). Vertex tokens expire after ~1h, so a systemd timer runs this every 45 min.
# Token comes from the VM metadata server (attached service account) — no gcloud needed.
#
# Usage: vertex-token-refresh.sh [--no-restart]
set -euo pipefail

CONF="${HOME}/.openviking/ov.conf"

TOKEN=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

python3 - "$CONF" "$TOKEN" <<'PY'
import json, sys
conf_path, token = sys.argv[1], sys.argv[2]
with open(conf_path) as f:
    conf = json.load(f)
conf.setdefault("vlm", {})["api_key"] = token
with open(conf_path, "w") as f:
    json.dump(conf, f, indent=2)
PY

if [[ "${1:-}" != "--no-restart" ]]; then
  # OpenViking reads the config at startup, so pick up the new token via restart.
  systemctl --user try-restart openviking.service || true
fi
echo "Vertex token refreshed in ${CONF}"
