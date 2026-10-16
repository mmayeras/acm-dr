# ACM BackupSchedule. Name matches the product doc (schedule-acm-msa).
# useManagedServiceAccount: true -> imported clusters get an auto-import token in the backup,
# so they reconnect to the new hub on their own after an active restore (cluster import).
# Render with: envsubst < manifests/common/backupschedule.yaml.tpl | oc --context <hub> apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: BackupSchedule
metadata:
  name: schedule-acm-msa
  namespace: ${BKP_NS}
spec:
  veleroSchedule: "${BACKUP_CRON}"
  veleroTtl: ${BACKUP_TTL}
  useManagedServiceAccount: true
  paused: false
