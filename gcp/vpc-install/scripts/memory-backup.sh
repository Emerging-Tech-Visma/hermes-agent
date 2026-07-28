#!/usr/bin/env bash
# Back up durable Hermes state to GCS. Run ON THE VM (hourly via systemd timer).
#
#   memory-backup.sh <source-dir> <gs://bucket>
#
# What this does NOT cover: Honcho's Postgres data lives in a Docker volume, not
# in ~/.hermes. For full coverage snapshot the VM disk as well — see
# OPS-NOTES.md §6.
set -euo pipefail

SRC="${1:-${HOME}/.hermes}"
BUCKET="${2:?usage: memory-backup.sh <source-dir> <gs://bucket>}"

[ -d "${SRC}" ] || { echo "source ${SRC} does not exist"; exit 0; }

# Excludes: secrets, caches, and runtime lock/state files. .env holds the
# dashboard password and Honcho keys and must never leave the VM.
gcloud storage rsync --recursive --delete-unmatched-destination-objects \
  --exclude='.*\.env$' \
  --exclude='.*/logs/.*' \
  --exclude='.*/cache/.*' \
  --exclude='.*/audio_cache/.*' \
  --exclude='.*/image_cache/.*' \
  --exclude='.*/bootstrap-cache/.*' \
  --exclude='.*/node_modules/.*' \
  --exclude='.*/hermes-agent/.*' \
  --exclude='.*/__pycache__/.*' \
  --exclude='.*gateway\.lock$' \
  --exclude='.*gateway\.pid$' \
  --exclude='.*auth\.lock$' \
  "${SRC}" "${BUCKET}/hermes-state"

echo "Backed up ${SRC} -> ${BUCKET}/hermes-state at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
