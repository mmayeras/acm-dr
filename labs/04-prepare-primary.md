# 04 - Prepare HUB1 (it stays active)

> **Active scenario only** (cluster import, diagram flow 4). Passive scenario: skip this module, go to
> [module 5a](05a-passive-restore.md).

Doc 1.1.35 "Preparing the primary hub cluster". Three actions, all on **HUB1**:

1. pause the backup schedule,
2. tag HUB1 resources by running a restore on HUB1 itself,
3. stop HUB1 from re-importing the clusters that are about to move.

Why: after module 5 both hubs know the same clusters. If HUB1 grabbed them back it could overwrite
policy or application changes made on HUB2.

## 0. RPO demo: something the backup will not have

*Acronyms: RPO = Recovery Point Objective.*

Before pausing, make sure the last backup is recent and complete:

```bash
scripts/hub-status.sh $HUB1 | sed -n '/Latest velero/,/Restores/p'
```

Now create an object **after** that backup:

```bash
oc --context $HUB1 create configmap dr-lab-after-backup -n dr-lab --from-literal=note="created after last backup"
oc --context $HUB1 label configmap dr-lab-after-backup -n dr-lab cluster.open-cluster-management.io/backup=""
```

It has the backup label, yet it will be missing on HUB2: no backup ran after it was created.

## 1. Pause the BackupSchedule

```bash
oc --context $HUB1 patch backupschedule.cluster.open-cluster-management.io schedule-acm-msa -n $BKP_NS \
  --type merge -p '{"spec":{"paused":true}}'
```

```bash
oc --context $HUB1 get backupschedule.cluster.open-cluster-management.io -n $BKP_NS
# schedule-acm-msa   Paused
```

```bash
oc --context $HUB1 get schedule.velero.io -n $BKP_NS
# NAME                       STATUS    SCHEDULE      LASTBACKUP   AGE   PAUSED
# acm-credentials-schedule   Enabled   0 */1 * * *   64m          99m   true
# ...                        (all 5 schedules kept, PAUSED=true, no new backups; old backups kept)
```

Confirm nothing is still running:

```bash
oc --context $HUB1 get backup.velero.io -n $BKP_NS -o json \
  | jq -r '.items[] | select(.status.phase=="InProgress") | .metadata.name'
# (empty)
```

## 2. Tag HUB1 resources with a restore on HUB1

[restore-acm.yaml](../manifests/restore/restore-acm.yaml): all three groups `latest`, cleanup `None`.
Fields explained in [REFERENCE: Restore spec, field by field](../REFERENCE.md#restore-spec-field-by-field).

```bash
oc --context $HUB1 apply -f manifests/restore/restore-acm.yaml
oc --context $HUB1 get restore.cluster.open-cluster-management.io restore-acm -n $BKP_NS -w
# restore-acm   Finished   All Velero restores have run successfully
```

The doc states this restore "tags all hub cluster resources that would be backed up" with a
`velero.io/backup-name` label. The value is the name of the velero backup the object was found in.
With `veleroResourcesBackupName: latest`, that is the newest `acm-resources-schedule-*` backup.

Name of that backup:

```bash
oc --context $HUB1 get backup.velero.io -n $BKP_NS --sort-by=.metadata.creationTimestamp \
  -o name | grep acm-resources-schedule | tail -1
# backup.velero.io/acm-resources-schedule-20261015210059
```

Objects that were in that backup now carry its name:

```bash
oc --context $HUB1 get policy dr-lab-marker -n dr-lab \
  -o jsonpath='{.metadata.labels.velero\.io/backup-name}{"\n"}'
# acm-resources-schedule-20261015210059
```

```bash
oc --context $HUB1 get managedclusterset dr-lab \
  -o jsonpath='{.metadata.labels.velero\.io/backup-name}{"\n"}'
# acm-resources-schedule-20261015210059
```

Same value as the backup above: expected.

`dr-lab-after-backup` (created in step 0, after the last backup) is in no backup, so it does **not**
get the label:

```bash
oc --context $HUB1 get configmap dr-lab-after-backup -n dr-lab \
  -o jsonpath='{.metadata.labels.velero\.io/backup-name}{"\n"}'
# (empty line)
```

Why it matters: in a failback with `CleanupRestored` (module 8), only objects carrying
`velero.io/backup-name` are candidates for cleanup. Unlabeled objects are never touched.

`velero.io/restore-name` / `backup-name` labels on hub objects are the bookkeeping the restore
controller uses. Do not strip them.

## 3. Disable auto-import on HUB1 for every cluster that moves

```bash
for mc in $(oc --context $HUB1 get managedcluster -o name | grep -v local-cluster); do
  oc --context $HUB1 annotate $mc import.open-cluster-management.io/disable-auto-import='' --overwrite
done

oc --context $HUB1 get managedcluster \
  -o custom-columns='NAME:.metadata.name,DISABLE-AUTO-IMPORT:.metadata.annotations.import\.open-cluster-management\.io/disable-auto-import'
```

> If your HUB1 renamed the self-managed cluster (not `local-cluster`), adjust the `grep -v`.
> Never annotate or move the hub's own self-managed cluster.

The annotation is added **after** the last backup on purpose: it is an instruction for HUB1 only, so
it must never travel to HUB2 inside a backup.

## Checkpoint

- [ ] `schedule-acm-msa` Paused, velero `Schedule`s show `PAUSED=true`, no backup `InProgress`
- [ ] `restore-acm` Finished on HUB1, policy and clusterset carry `velero.io/backup-name` = latest
      `acm-resources-schedule-*`, `dr-lab-after-backup` does not
- [ ] Every non-local `ManagedCluster` on HUB1 has `disable-auto-import`
- [ ] Spoke still `Available` on HUB1 (nothing moved yet, HUB1 is fully active)

Next: [module 5](05-restore-new-hub.md) (fresh HUB2), or [module 5a step 4](05a-passive-restore.md#4-later-activate-move-the-clusters)
(HUB2 already holds a passive copy).
