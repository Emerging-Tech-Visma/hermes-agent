#!/usr/bin/env bash
# Run LOCALLY (your workstation, with gcloud authenticated as a project owner/editor).
# Provisions everything in GCP: APIs, service account, GCS bucket, and the VM.
set -euo pipefail
source "$(dirname "$0")/00-vars.sh"

echo "==> Setting project ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

echo "==> Enabling APIs"
gcloud services enable \
  aiplatform.googleapis.com \
  compute.googleapis.com \
  storage.googleapis.com

echo "==> Creating service account ${SA_EMAIL} (idempotent)"
gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="Hermes Agent VM" 2>/dev/null || echo "    already exists"

echo "==> Granting Vertex AI access"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/aiplatform.user" --condition=None >/dev/null

echo "==> Creating memory backup bucket ${MEMORY_BUCKET} (idempotent)"
gcloud storage buckets create "${MEMORY_BUCKET}" \
  --location="${REGION}" --uniform-bucket-level-access 2>/dev/null || echo "    already exists"
gcloud storage buckets add-iam-policy-binding "${MEMORY_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null

echo "==> Creating VM ${VM_NAME} in ${ZONE}"
gcloud compute instances create "${VM_NAME}" \
  --zone="${ZONE}" \
  --machine-type="${MACHINE_TYPE}" \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size="${BOOT_DISK_SIZE}" \
  --boot-disk-type=pd-balanced \
  --service-account="${SA_EMAIL}" \
  --scopes=cloud-platform

echo "==> Copying installation files to the VM"
gcloud compute scp --zone="${ZONE}" --recurse \
  "$(dirname "$0")" "${VM_NAME}:~/hermes-install"

cat <<EOF

Done. Next steps:
  gcloud compute ssh ${VM_NAME} --zone=${ZONE}
  bash ~/hermes-install/02-vm-install.sh
EOF
