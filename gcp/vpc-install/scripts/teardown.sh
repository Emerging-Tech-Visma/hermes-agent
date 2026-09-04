#!/usr/bin/env bash
# Run on YOUR PC. DESTROYS the installation so the next install starts VIRGIN.
#
#   bash gcp/vpc-install/scripts/teardown.sh              # VM + network + SA (keeps the bucket)
#   bash gcp/vpc-install/scripts/teardown.sh --with-bucket # ALSO deletes the memory backups
#   bash gcp/vpc-install/scripts/teardown.sh --vm-only     # just the VM
#
# WHY THIS EXISTS. Validation must start from a virgin installation — see the rule in
# AGENTS.md. Re-running the installer over an existing VM hides whole classes of defect:
# on 2026-08-18 a from-scratch rebuild found FIVE fresh-state-only bugs (an apt keyring
# written 0600, an apt failure that made re-runs impossible, a gpg overwrite prompt, an
# errexit trap in dashboard-setup.sh that killed the install silently, and a `sleep 6`
# that was too short) — every one of which an incremental re-run passes straight over.
# Without a one-command teardown nobody actually starts clean, so the rule needs this.
#
# Requires an explicit typed confirmation. Nothing is deleted before that.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/../00-vars.sh"

WITH_BUCKET="no"; VM_ONLY="no"; DESTROY_LIVE="no"
for arg in "$@"; do
  case "${arg}" in
    --with-bucket)      WITH_BUCKET="yes" ;;
    --vm-only)          VM_ONLY="yes" ;;
    --yes-destroy-live) DESTROY_LIVE="yes" ;;
    -h|--help)          sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: ${arg}" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Guard: this repo's install is ALSO somebody's running agent.
# ---------------------------------------------------------------------------
# The typed confirmation below is not a real barrier for an automated caller — it reads
# from stdin, so `echo "${VM_NAME}" | teardown.sh` sails straight through it. That is
# exactly how destructive code gets "tested" against a live project.
#
# On 2026-09-04 the VM's service account was deleted at 12:31:11 UTC and recreated 21
# seconds later while validating teardown changes. Recreating it gave the SAME EMAIL a
# NEW unique id, and the instance is bound to the id — so the metadata server returned
# 401 "Service account is deleted or disabled" indefinitely, every Vertex call failed,
# and the agent was dead until the ORIGINAL identity was undeleted. The VM survived; the
# thing that made it useful did not.
#
# So: a RUNNING instance is treated as the live install and requires explicit intent.
# A stopped or absent VM tears down as before.
if [ "${DESTROY_LIVE}" != "yes" ]; then
  LIVE_STATUS="$(gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}"                    --project="${PROJECT_ID}" --format='value(status)' 2>/dev/null || true)"
  if [ "${LIVE_STATUS}" = "RUNNING" ]; then
    cat >&2 <<EOF
============================================================================
REFUSING — ${VM_NAME} in ${PROJECT_ID} is RUNNING.

A running instance is a live agent: real conversations, real memory on its disk,
and a service account other things authenticate as. Tearing it down is not a
test, and the typed prompt below would not have stopped a script.

If you are certain, say so explicitly:

  bash teardown.sh --yes-destroy-live $*

To test teardown safely, point 00-vars.sh at a throwaway PROJECT_ID/VM_NAME, or
stop the VM first (hermesctl vm stop) so this guard steps aside.

Nothing was deleted.
============================================================================
EOF
    exit 1
  fi
fi

echo "============================================================================"
echo "TEARDOWN — project ${PROJECT_ID}"
echo
echo "  WILL DELETE:"
echo "    VM               ${VM_NAME} (${ZONE})   — all agent state on its disk"
if [ "${VM_ONLY}" != "yes" ]; then
  echo "    firewall rules   ${VPC_NAME}-allow-iap-ssh, -allow-iap-dashboard, -deny-all-ingress"
  echo "    Cloud NAT        ${NAT_NAME}   (billing stops)"
  echo "    Cloud Router     ${ROUTER_NAME}"
  echo "    subnet / VPC     ${SUBNET_NAME} / ${VPC_NAME}"
  echo "    service account  ${SA_EMAIL}"
  echo "    service account  ${TUNNEL_SA_EMAIL}   (+ its key on this Mac)"
fi
if [ "${WITH_BUCKET}" = "yes" ]; then
  echo "    BUCKET           ${MEMORY_BUCKET}  <-- ⚠️  DESTROYS ALL MEMORY BACKUPS"
else
  echo "  KEEPING:"
  echo "    bucket           ${MEMORY_BUCKET}  (memory backups; --with-bucket to delete)"
fi
echo
echo "  NOT touched: project itself, enabled APIs, your IAM roles."
echo "============================================================================"
printf 'Type the VM name (%s) to confirm: ' "${VM_NAME}"
read -r REPLY_NAME
if [ "${REPLY_NAME}" != "${VM_NAME}" ]; then
  echo "Aborted — nothing was deleted."
  exit 1
fi

gone() { echo "    (absent)"; }

echo "==> Deleting VM ${VM_NAME}"
gcloud compute instances delete "${VM_NAME}" --zone="${ZONE}" --quiet 2>/dev/null || gone

if [ "${VM_ONLY}" != "yes" ]; then
  # Order matters: firewall rules and NAT hold references to the network, and the
  # network cannot be deleted while anything still points at it.
  for rule in "${VPC_NAME}-allow-iap-ssh" "${VPC_NAME}-allow-iap-dashboard" "${VPC_NAME}-deny-all-ingress"; do
    echo "==> Deleting firewall rule ${rule}"
    gcloud compute firewall-rules delete "${rule}" --quiet 2>/dev/null || gone
  done

  echo "==> Deleting Cloud NAT ${NAT_NAME}"
  gcloud compute routers nats delete "${NAT_NAME}" --router="${ROUTER_NAME}" \
    --region="${REGION}" --quiet 2>/dev/null || gone

  echo "==> Deleting Cloud Router ${ROUTER_NAME}"
  gcloud compute routers delete "${ROUTER_NAME}" --region="${REGION}" --quiet 2>/dev/null || gone

  echo "==> Deleting subnet ${SUBNET_NAME}"
  gcloud compute networks subnets delete "${SUBNET_NAME}" --region="${REGION}" --quiet 2>/dev/null || gone

  echo "==> Deleting VPC ${VPC_NAME}"
  gcloud compute networks delete "${VPC_NAME}" --quiet 2>/dev/null || gone

  echo "==> Deleting service account ${SA_EMAIL}"
  gcloud iam service-accounts delete "${SA_EMAIL}" --quiet 2>/dev/null || gone

  # The tunnel SA must go too, or teardown leaves an orphan holding a live
  # roles/iap.tunnelResourceAccessor grant on the project. Deleting the SA also
  # invalidates its keys server-side — but the key FILE stays on this Mac, and the
  # installer's "Reusing existing tunnel key" path would then hand launchd a key
  # whose service account no longer exists. So remove both.
  echo "==> Deleting tunnel service account ${TUNNEL_SA_EMAIL}"
  gcloud iam service-accounts delete "${TUNNEL_SA_EMAIL}" --quiet 2>/dev/null || gone
  if [ -f "${TUNNEL_SA_KEY}" ]; then
    rm -f "${TUNNEL_SA_KEY}"
    echo "    removed the local key ${TUNNEL_SA_KEY}"
  fi
fi

if [ "${WITH_BUCKET}" = "yes" ]; then
  echo "==> Deleting bucket ${MEMORY_BUCKET} and everything in it"
  gcloud storage rm --recursive "${MEMORY_BUCKET}" --quiet 2>/dev/null || gone
fi

# The operator's Mac keeps a LaunchAgent pointing at a VM that no longer exists. Left
# running it fails forever and squats port 9119 — exactly the stale-agent mess found on
# 2026-08-18 from the previous install. Clear it as part of teardown.
if [ "$(uname -s)" = "Darwin" ] \
   && launchctl list 2>/dev/null | grep -q com.hermes.gateway-tunnel; then
  echo "==> Removing the local gateway LaunchAgent (its VM is gone)"
  bash "${HERE}/install-gateway-launchagent.sh" --uninstall || true
fi

cat <<EOF

============================================================================
Teardown complete. Confirm it really is virgin before reinstalling:

  gcloud compute instances list --project=${PROJECT_ID}    # expect: Listed 0 items.
  gcloud compute networks list  --project=${PROJECT_ID}    # expect: no ${VPC_NAME}

Then install from zero:

  bash 01-gcp-setup.sh
  gcloud compute ssh ${VM_NAME} --zone=${ZONE} --tunnel-through-iap
  bash ~/hermes-install/02-vm-install.sh
  bash ~/hermes-install/03-verify.sh          # must be 14/14
  bash scripts/install-gateway-launchagent.sh # back on your PC

Record the date, the Hermes version and the Honcho SHA in AGENTS.md when you do.
============================================================================
EOF
