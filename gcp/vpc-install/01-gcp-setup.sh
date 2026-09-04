#!/usr/bin/env bash
# Run LOCALLY (your workstation, gcloud authenticated as a project owner/editor).
#
# Provisions the private network and the VM:
#   custom VPC + subnet (Private Google Access)
#   Cloud Router + Cloud NAT      (egress for apt / GitHub / Docker / SearXNG)
#   firewall: ingress ONLY from Google's IAP range, on 22 + 9119
#   service account with Vertex + GCS access
#   VM with NO EXTERNAL IP
#   IAM so you may open IAP tunnels
#
# Idempotent — safe to re-run.
set -euo pipefail
source "$(dirname "$0")/00-vars.sh"

echo "==> Setting project ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

echo "==> Enabling APIs"
gcloud services enable \
  compute.googleapis.com \
  aiplatform.googleapis.com \
  storage.googleapis.com \
  iap.googleapis.com \
  oslogin.googleapis.com

# ---------------------------------------------------------------------------
# 1. Private VPC + subnet
# ---------------------------------------------------------------------------
echo "==> Creating VPC ${VPC_NAME} (idempotent)"
gcloud compute networks create "${VPC_NAME}" \
  --subnet-mode=custom \
  --bgp-routing-mode=regional 2>/dev/null || echo "    already exists"

echo "==> Creating subnet ${SUBNET_NAME} ${SUBNET_RANGE} in ${REGION}"
# --enable-private-ip-google-access lets the VM reach Vertex AI / GCS over
# Google's internal network even though it has no external IP.
gcloud compute networks subnets create "${SUBNET_NAME}" \
  --network="${VPC_NAME}" \
  --region="${REGION}" \
  --range="${SUBNET_RANGE}" \
  --enable-private-ip-google-access 2>/dev/null || {
    echo "    already exists — ensuring Private Google Access is on"
    gcloud compute networks subnets update "${SUBNET_NAME}" \
      --region="${REGION}" --enable-private-ip-google-access >/dev/null
  }

# ---------------------------------------------------------------------------
# 2. Cloud NAT — outbound internet WITHOUT giving the VM a public IP
# ---------------------------------------------------------------------------
# Mandatory. Without it: apt fails, the Hermes installer fails, Docker Hub
# fails, Playwright/Chrome downloads fail, and SearXNG cannot reach the
# upstream search engines it proxies.
echo "==> Creating Cloud Router ${ROUTER_NAME} (idempotent)"
gcloud compute routers create "${ROUTER_NAME}" \
  --network="${VPC_NAME}" --region="${REGION}" 2>/dev/null || echo "    already exists"

echo "==> Creating Cloud NAT ${NAT_NAME} (idempotent)"
gcloud compute routers nats create "${NAT_NAME}" \
  --router="${ROUTER_NAME}" --region="${REGION}" \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges 2>/dev/null || echo "    already exists"

# ---------------------------------------------------------------------------
# 3. Firewall — the whole security story
# ---------------------------------------------------------------------------
# There is NO 0.0.0.0/0 ingress rule. The only allowed source is
# 35.235.240.0/20 (Google's IAP TCP-forwarding frontend). Reaching the VM
# therefore requires an IAP tunnel, which requires IAM permission.
# Port 9119 is allowed from that same range ONLY because IAP TCP forwarding
# needs an explicit firewall allow for the port it forwards — it is still not
# reachable from the internet.
echo "==> Firewall: allow SSH from IAP range only"
gcloud compute firewall-rules create "${VPC_NAME}-allow-iap-ssh" \
  --network="${VPC_NAME}" --direction=INGRESS --action=ALLOW \
  --rules=tcp:22 --source-ranges="${IAP_RANGE}" \
  --target-tags="${NET_TAG}" \
  --description="SSH via IAP TCP forwarding only" 2>/dev/null || echo "    already exists"

echo "==> Firewall: allow dashboard :${DASHBOARD_PORT} from IAP range only"
gcloud compute firewall-rules create "${VPC_NAME}-allow-iap-dashboard" \
  --network="${VPC_NAME}" --direction=INGRESS --action=ALLOW \
  --rules="tcp:${DASHBOARD_PORT}" --source-ranges="${IAP_RANGE}" \
  --target-tags="${NET_TAG}" \
  --description="Hermes dashboard via IAP TCP forwarding only" 2>/dev/null || echo "    already exists"

echo "==> Firewall: deny all other ingress (explicit, low priority)"
gcloud compute firewall-rules create "${VPC_NAME}-deny-all-ingress" \
  --network="${VPC_NAME}" --direction=INGRESS --action=DENY \
  --rules=all --source-ranges=0.0.0.0/0 --priority=65000 \
  --description="Belt-and-braces: nothing from the internet" 2>/dev/null || echo "    already exists"

# ---------------------------------------------------------------------------
# 4. Service account
# ---------------------------------------------------------------------------
echo "==> Creating service account ${SA_EMAIL} (idempotent)"
gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="Hermes Agent VM" 2>/dev/null || echo "    already exists"

# GOTCHA: right after creation the SA may not have propagated, and an immediate
# add-iam-policy-binding fails with "does not exist". Poll until it resolves.
echo "==> Waiting for service account to propagate"
for i in $(seq 1 30); do
  if gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
    echo "    ready"; break
  fi
  sleep 2
done

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

# ---------------------------------------------------------------------------
# 5. The VM — no external IP
# ---------------------------------------------------------------------------
echo "==> Creating VM ${VM_NAME} in ${ZONE} (no external IP)"
# Check-then-create rather than `|| echo already exists`: swallowing stderr here
# would hide real failures (quota, bad image family, region capacity) and leave
# the script spinning in the SSH wait loop below for no reason.
if gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
  echo "    already exists — leaving it alone"
else
  gcloud compute instances create "${VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --subnet="${SUBNET_NAME}" \
    --no-address \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${IMAGE_PROJECT}" \
    --boot-disk-size="${BOOT_DISK_SIZE}" \
    --boot-disk-type=pd-balanced \
    --service-account="${SA_EMAIL}" \
    --scopes=cloud-platform \
    --tags="${NET_TAG}" \
    --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
    --metadata=enable-oslogin=TRUE
fi

# ---------------------------------------------------------------------------
# 6. Let the operator open IAP tunnels
# ---------------------------------------------------------------------------
CALLER="$(gcloud config get-value account 2>/dev/null)"
echo "==> Granting IAP tunnel access to ${CALLER}"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="user:${CALLER}" \
  --role="roles/iap.tunnelResourceAccessor" --condition=None >/dev/null
# Needed to SSH as a normal (non-root) Linux user with OS Login.
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="user:${CALLER}" \
  --role="roles/compute.osLogin" --condition=None >/dev/null

# The operator's own grant above covers `hermesctl` and interactive SSH. It is NOT
# enough for the gateway tunnel, which runs unattended as a LaunchAgent: Google
# enforces a periodic REAUTH on user credentials, and reauth cannot be answered by
# a background process ("cannot prompt during non-interactive execution"). So the
# tunnel gets its own service account, which is exempt from reauth.
#
# Minimal scope on purpose: tunnel access only. No osLogin (it does not SSH), no
# Vertex, no storage. See the TUNNEL_USE_SA block in 00-vars.sh.
if [ "${TUNNEL_USE_SA:-true}" = "true" ]; then
  echo "==> Service account for the local gateway tunnel: ${TUNNEL_SA_NAME}"
  if ! gcloud iam service-accounts describe "${TUNNEL_SA_EMAIL}" \
       --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud iam service-accounts create "${TUNNEL_SA_NAME}" \
      --project="${PROJECT_ID}" \
      --display-name="Hermes gateway tunnel (local LaunchAgent)" \
      --description="IAP tunnel only. Exempt from user-credential reauth so the \
gateway survives idle/reboot. Key lives on the operator Mac at 0600." >/dev/null
    # Same eventual-consistency trap as the VM SA above: a freshly created SA is
    # not immediately visible to add-iam-policy-binding.
    for i in $(seq 1 20); do
      gcloud iam service-accounts describe "${TUNNEL_SA_EMAIL}" \
        --project="${PROJECT_ID}" >/dev/null 2>&1 && break
      sleep 3
    done
  else
    echo "    already exists"
  fi
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${TUNNEL_SA_EMAIL}" \
    --role="roles/iap.tunnelResourceAccessor" --condition=None >/dev/null
  echo "    granted roles/iap.tunnelResourceAccessor"
  echo "    key is created later, on the Mac, by scripts/install-gateway-launchagent.sh"
fi

# ---------------------------------------------------------------------------
# 7. Copy the installer to the VM (over IAP — there is no public IP)
# ---------------------------------------------------------------------------
echo "==> Waiting for SSH to come up"
for i in $(seq 1 40); do
  if gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --tunnel-through-iap \
       --command='true' >/dev/null 2>&1; then
    echo "    ready"; break
  fi
  sleep 5
done

echo "==> Copying installation files to the VM"
# GOTCHA: `scp --recurse` of a directory INTO an existing target nests it
# (hermes-install/vpc-install/...). Delete the target first so re-runs are clean.
gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --tunnel-through-iap \
  --command='rm -rf ~/hermes-install' || true
gcloud compute scp --zone="${ZONE}" --tunnel-through-iap --recurse \
  "$(cd "$(dirname "$0")" && pwd)" "${VM_NAME}:~/hermes-install"

cat <<EOF

============================================================================
GCP provisioning complete.

  VPC          ${VPC_NAME} / ${SUBNET_NAME} (${SUBNET_RANGE}) in ${REGION}
  VM           ${VM_NAME} (${MACHINE_TYPE}, ${IMAGE_FAMILY}) — NO external IP
  Ingress      ${IAP_RANGE} only, on tcp:22 and tcp:${DASHBOARD_PORT}
  Egress       via Cloud NAT (${NAT_NAME})

Next — install Hermes on the VM:

  gcloud compute ssh ${VM_NAME} --zone=${ZONE} --tunnel-through-iap
  export HERMES_DASHBOARD_PASSWORD='choose-a-strong-password'
  bash ~/hermes-install/02-vm-install.sh
============================================================================
EOF
