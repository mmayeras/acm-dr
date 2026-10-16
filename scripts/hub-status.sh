#!/usr/bin/env bash
# Snapshot of everything that matters for ACM backup/restore on one hub.
# Usage: scripts/hub-status.sh <kube-context>
set -uo pipefail

CTX=${1:?usage: $0 <kube-context>}
NS=open-cluster-management-backup

section() { printf '\n=== %s ===\n' "$1"; }
# Print stdin, or the given hint when stdin is empty ("oc get" exits 0 on empty lists).
or_none() { local out; out=$(cat); if [ -n "$out" ]; then echo "$out"; else echo "  (none) $1"; fi; }

if ! SERVER=$(oc --context "$CTX" whoami --show-server 2>&1); then
  echo "ERROR: cannot use context '$CTX': $SERVER" >&2
  echo "Check: oc config get-contexts   (re-login / rename-context, see labs/00-prereqs.md)" >&2
  exit 1
fi
printf '### Hub: %s (%s)\n' "$CTX" "$SERVER"

section "ACM / MCE"
oc --context "$CTX" get multiclusterhub -A --no-headers \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,VERSION:.status.currentVersion 2>/dev/null \
  | or_none "-> no MultiClusterHub: ACM not installed (module 3 for HUB2)"
oc --context "$CTX" get multiclusterengine --no-headers \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,VERSION:.status.currentVersion 2>/dev/null \
  | or_none "-> no MultiClusterEngine"
BACKUP_ENABLED=$(oc --context "$CTX" get multiclusterhub -A \
  -o jsonpath='{.items[0].spec.overrides.components[?(@.name=="cluster-backup")].enabled}' 2>/dev/null)
echo "cluster-backup enabled: ${BACKUP_ENABLED:-unknown}"
[ "$BACKUP_ENABLED" = true ] || echo "  -> backup component off: no OADP, no BackupSchedule possible (module 2 step 1)"
echo "managedserviceaccount enabled: $(oc --context "$CTX" get multiclusterengine \
  -o jsonpath='{.items[0].spec.overrides.components[?(@.name=="managedserviceaccount")].enabled}' 2>/dev/null)"
echo "autoImportStrategy: $(oc --context "$CTX" get configmap import-controller-config -n multicluster-engine \
  -o jsonpath='{.data.autoImportStrategy}' 2>/dev/null || true) (empty = default ImportOnly)"

section "OADP"
oc --context "$CTX" get csv -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null \
  | grep -i oadp | or_none "-> OADP operator not installed (comes with cluster-backup: module 2 step 1)"
oc --context "$CTX" get dataprotectionapplication -n "$NS" --no-headers \
  -o custom-columns='NAME:.metadata.name,RECONCILED:.status.conditions[?(@.type=="Reconciled")].status' 2>/dev/null \
  | or_none "-> no DataProtectionApplication (module 2 step 3)"
oc --context "$CTX" get backupstoragelocation.velero.io -n "$NS" --no-headers \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,LAST-VALIDATED:.status.lastValidationTime 2>/dev/null \
  | or_none "-> no BackupStorageLocation (created by the DPA)"

section "BackupSchedule"
oc --context "$CTX" get backupschedule.cluster.open-cluster-management.io -n "$NS" --no-headers \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,PAUSED:.spec.paused,CRON:.spec.veleroSchedule,MSA:.spec.useManagedServiceAccount,MSG:.status.lastMessage 2>/dev/null \
  | or_none "-> no BackupSchedule (HUB1: module 2 step 4; HUB2: none expected before restore)"

section "Latest velero backup per schedule (synced from the bucket)"
for s in $(oc --context "$CTX" get backup.velero.io -n "$NS" -o json 2>/dev/null \
    | jq -r '.items[].metadata.labels["velero.io/schedule-name"] // empty' | sort -u); do
  printf '%-40s ' "$s"
  oc --context "$CTX" get backup.velero.io -n "$NS" -l velero.io/schedule-name="$s" \
    --sort-by=.metadata.creationTimestamp --no-headers \
    -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startTimestamp | tail -n1
done | or_none "-> no velero backups (none taken yet, or BSL not Available)"

section "Restores (ACM)"
oc --context "$CTX" get restore.cluster.open-cluster-management.io -n "$NS" --no-headers \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,MSG:.status.lastMessage 2>/dev/null \
  | or_none "-> no ACM Restore"

section "ManagedClusters"
oc --context "$CTX" get managedcluster --no-headers \
  -o custom-columns='NAME:.metadata.name,JOINED:.status.conditions[?(@.type=="ManagedClusterJoined")].status,AVAILABLE:.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status,SET:.metadata.labels.cluster\.open-cluster-management\.io/clusterset,DISABLE-AUTO-IMPORT:.metadata.annotations.import\.open-cluster-management\.io/disable-auto-import' 2>/dev/null \
  | or_none "-> no ManagedCluster"

section "Auto-import tokens (ManagedServiceAccount auto-import-account)"
oc --context "$CTX" get managedserviceaccount -A --no-headers \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,EXPIRES:.status.expirationTimestamp 2>/dev/null \
  | grep auto-import | or_none "-> no tokens (need BackupSchedule with useManagedServiceAccount: true)"

section "Backup validation policy"
oc --context "$CTX" get policy.policy.open-cluster-management.io -A --field-selector metadata.name=backup-restore-enabled --no-headers \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,COMPLIANCE:.status.compliant 2>/dev/null \
  | or_none "-> backup-restore-enabled policy absent (installed with cluster-backup)"
