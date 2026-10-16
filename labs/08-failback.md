# 08 - Optional: fail back to HUB1

Doc 1.1.43 "Restoring the primary hub cluster" and 1.1.44. Mirror image of modules 4 and 5, with one
difference: HUB1 is **not** a fresh hub, so the restore uses `CleanupRestored` to remove objects that
no longer exist in HUB2's backup.

Which scenario did you run?

| Scenario | Clusters moved? | What to run here |
|---|---|---|
| Active (module 5, or 5a then its step 4) | yes | everything |
| Passive (module 5a only) | **no** | nothing: the spoke never left HUB1, there is nothing to fail back |

## 0. Make a change on HUB2 that should survive the trip

```bash
oc --context $HUB2 create configmap dr-lab-from-hub2 -n dr-lab --from-literal=note="created on hub2"
oc --context $HUB2 label configmap dr-lab-from-hub2 -n dr-lab cluster.open-cluster-management.io/backup=""
```

And delete one object on HUB2 that HUB1 still has, to watch cleanup work:

```bash
oc --context $HUB2 delete configmap dr-lab-labeled -n dr-lab
```

## 1. Fresh backup on HUB2, then pause

*Acronyms: MSA = ManagedServiceAccount.*

HUB2 got `schedule-acm-msa` in module 6. Force a fresh, complete backup set by switching it to every
5 minutes:

```bash
oc --context $HUB2 patch backupschedule.cluster.open-cluster-management.io schedule-acm-msa -n $BKP_NS \
  --type merge -p '{"spec":{"veleroSchedule":"*/5 * * * *"}}'
```

Wait for a new set, started after step 0:

```bash
oc --context $HUB2 get backup.velero.io -n $BKP_NS --sort-by=.metadata.creationTimestamp -w
# 5 new acm-*-schedule-<ts> backups, PHASE Completed (Ctrl+C)
```

Pause, and put the cron back at the same time:

```bash
oc --context $HUB2 patch backupschedule.cluster.open-cluster-management.io schedule-acm-msa -n $BKP_NS \
  --type merge -p "{\"spec\":{\"paused\":true,\"veleroSchedule\":\"$BACKUP_CRON\"}}"
```

```bash
oc --context $HUB2 get backupschedule.cluster.open-cluster-management.io -n $BKP_NS
# schedule-acm-msa   Paused
```

Check the HUB2 MSA token is older than this backup (same check as module 2 step 5, on HUB2).

## 2. Release the clusters on HUB2

Same as module 4 step 3, on HUB2, and only **after** the backup above:

```bash
for mc in $(oc --context $HUB2 get managedcluster -o name | grep -v local-cluster); do
  oc --context $HUB2 annotate $mc import.open-cluster-management.io/disable-auto-import='' --overwrite
done
```

## 3. Prepare HUB1

*Acronyms: ACM = Advanced Cluster Management.*

Remove the module 4 restore, it is finished but keeps HUB1 in "restore" state:

```bash
oc --context $HUB1 delete restore.cluster.open-cluster-management.io restore-acm -n $BKP_NS --ignore-not-found
```

HUB1 velero syncs the new backups from the bucket:

```bash
oc --context $HUB1 get backup.velero.io -n $BKP_NS --sort-by=.metadata.creationTimestamp | tail -n5
```

**Case A: you ran module 7** (spoke deleted from HUB1). Nothing else to do: the restore recreates the
`ManagedCluster` and auto-import uses the HUB2 token.

**Case B: you skipped module 7** (spoke still on HUB1, `Unknown`, with `disable-auto-import`).
Velero does not overwrite existing objects, so the HUB1 copy keeps its annotation and, with ACM 2.14+
`ImportOnly`, a known cluster is not re-imported. Fix both: remove `disable-auto-import`, and ask for an immediate
import:

```bash
for mc in $(oc --context $HUB1 get managedcluster -o name | grep -v local-cluster); do
  oc --context $HUB1 annotate $mc import.open-cluster-management.io/disable-auto-import-
  oc --context $HUB1 annotate $mc import.open-cluster-management.io/immediate-import='' --overwrite
done
```

`immediate-import` must be empty to trigger. The controller sets it to `Completed` when done.

## 4. Restore on HUB1 with cleanup

*Acronyms: DR = disaster recovery.*

[restore-acm-failback.yaml](../manifests/restore/restore-acm-failback.yaml): all three groups `latest`,
cleanup `CleanupRestored` (HUB1 is not empty). Fields explained in [REFERENCE: Restore spec, field by field](../REFERENCE.md#restore-spec-field-by-field).

```bash
oc --context $HUB1 apply -f manifests/restore/restore-acm-failback.yaml
oc --context $HUB1 get restore.cluster.open-cluster-management.io restore-acm-failback -n $BKP_NS -w
# restore-acm-failback   Finished   (Ctrl+C)
```

```bash
oc --context $HUB1 get managedcluster -w
# $SPOKE_NAME   JOINED=True   AVAILABLE=True   (a few minutes, Ctrl+C)
```

Expected on HUB1:

```bash
oc --context $HUB1 get configmap -n dr-lab
# dr-lab-from-hub2      came from HUB2 backup
# dr-lab-unlabeled      never had a backup label, never touched
# dr-lab-after-backup   created on HUB1 after the last HUB1 backup, no velero.io/backup-name label,
#                       so CleanupRestored leaves it alone
# dr-lab-labeled        GONE: carried velero.io/backup-name (module 4), absent from HUB2 backup -> cleaned
# dr-lab-sync-test      only if you ran 5a step 3: in HUB2 backup, so it stays
```

```bash
oc --context $HUB1 get policy dr-lab-marker -n dr-lab \
  -o jsonpath='{.spec.policy-templates[0].objectDefinition.spec.object-templates[1].objectDefinition.data}{"\n"}'
```

The policy is the interesting one: HUB1 already had `dr-lab-marker` (value `hub1`), HUB2's backup has
it with value `hub2`. Record which value HUB1 ends up with, and what the spoke ConfigMap shows:

```bash
oc --context $SPOKE get configmap dr-lab-marker -n dr-lab-canary -o jsonpath='{.data.managed-by-hub}{"\n"}'
```

Velero's default is to skip objects that already exist rather than overwrite them. If HUB1 kept `hub1`,
that is why, and it is the main lesson of failback onto a non-empty hub: **check every object you
changed on the DR hub**, a restore onto an existing hub does not guarantee they win.

## 5. Re-enable backup on HUB1, clean HUB2

```bash
oc --context $HUB1 delete restore.cluster.open-cluster-management.io restore-acm-failback -n $BKP_NS
oc --context $HUB1 patch backupschedule.cluster.open-cluster-management.io schedule-acm-msa -n $BKP_NS \
  --type merge -p '{"spec":{"paused":false}}'
```

On HUB2, once the spoke is `Unknown` there and `Available` on HUB1, either delete the clusters (module 7
on HUB2) or turn HUB2 into a warm standby (passive scenario, continuous, as in module 5a):

```bash
oc --context $HUB2 delete backupschedule.cluster.open-cluster-management.io schedule-acm-msa -n $BKP_NS
# backupschedule... "schedule-acm-msa" deleted   (HUB1 owns the bucket again)
```

Remove leftover restores on HUB2 first (`restore-acm`, `restore-acm-activate` or a finished
`restore-acm-passive-sync`). Otherwise `apply` below only patches a finished restore and nothing runs:

```bash
oc --context $HUB2 delete restore.cluster.open-cluster-management.io --all -n $BKP_NS
```

```bash
oc --context $HUB2 apply -f manifests/restore/restore-acm-passive-sync.yaml
oc --context $HUB2 get restore.cluster.open-cluster-management.io restore-acm-passive-sync -n $BKP_NS
# Enabled   Velero restores have run to completion, restore will continue to sync with new backups
```

## Checkpoint

- [ ] Spoke `Available` on HUB1, klusterlet points to HUB1
- [ ] `dr-lab-labeled` cleaned, `dr-lab-from-hub2` present on HUB1
- [ ] HUB1 schedule `Enabled` on `$BACKUP_CRON`, HUB2 has no active schedule
- [ ] Standby chosen: HUB2 restore `restore-acm-passive-sync` `Enabled`
