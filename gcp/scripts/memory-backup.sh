#!/usr/bin/env bash
# Syncs the OpenViking workspace to the GCS backup bucket.
# Invoked hourly by memory-backup.timer; bucket/workspace passed as env by the unit.
set -euo pipefail

: "${MEMORY_BUCKET:?set by systemd unit}"
: "${WORKSPACE:?set by systemd unit}"

gcloud storage rsync --recursive --delete-unmatched-destination-objects \
  "${WORKSPACE}" "${MEMORY_BUCKET}/workspace"
echo "Backed up ${WORKSPACE} -> ${MEMORY_BUCKET}/workspace"
