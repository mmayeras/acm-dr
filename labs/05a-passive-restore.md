# 05a - Passive scenario: restore WITHOUT importing clusters

*Acronyms: DR = disaster recovery.*

> **Passive scenario** (no cluster import, diagram flows 2 and 3). Instead of modules 4 and 5.
> Step 4 shows how to switch to the active scenario later (diagram flow 6).

HUB2 receives the hub data (policies, placements, cluster sets, credentials,
applications) but **no managed clusters**. The spoke stays on HUB1 and never notices anything.

Use it for:
- a DR rehearsal that does not touch the fleet,
- a warm standby hub kept in sync with HUB1 (active-passive),
- inspecting what a backup contains before committing to a switch.

## How it works

The backup has two halves:

| Half | Velero backups | Restore field |
|---|---|---|
| Passive data | `acm-credentials-*`, `acm-resources-schedule`, `acm-resources-generic-schedule` | `veleroCredentialsBackupName`, `veleroResourcesBackupName` |
| Activation data | `acm-managed-clusters-schedule`: `ManagedCluster`, `KlusterletAddonConfig`, `ManagedClusterAddOn`, Hive `ClusterDeployment`, objects labeled `cluster.open-cluster-management.io/backup: cluster-activation`, auto-import tokens | `veleroManagedClustersBackupName` |

`veleroManagedClustersBackupName: skip` leaves the activation half in the bucket. No `ManagedCluster`
means no import, no auto-import secret, no klusterlet change.

It is all or nothing: restored `ManagedCluster` objects get imported. To keep the clusters on HUB1,
use `skip`.

## What changes compared to modules 4 and 5

*Acronyms: ACM = Advanced Cluster Management, DPA = DataProtectionApplication.*

- **HUB1 keeps running normally.** No pause, no tagging restore, no `disable-auto-import`. The doc's
  active-passive setup has HUB1 keep writing backups while HUB2 reads them.
- **HUB2 still gets no `BackupSchedule`** (collision).
- Module 3 must be done (ACM + DPA on HUB2, backups visible).

## 1. Pick one flavour

Both restore HUB1 data without clusters. They differ in what happens after the first restore:

| | One-shot | Continuous |
|---|---|---|
| Restores | latest backup, **once** | latest backup, then **each new one** every `restoreSyncInterval` |
| Phase | `Finished` | `Enabled` (keeps running) |
| Object deleted on HUB1 | stays on HUB2 (`cleanupBeforeRestore: None`) | removed from HUB2 at next sync (`CleanupRestored`) |
| Get newer data | delete + re-apply the restore | automatic |
| Use for | point-in-time copy of HUB1 | warm standby |

Every field of both manifests is explained in [REFERENCE: Restore spec, field by field](../REFERENCE.md#restore-spec-field-by-field).

**One-shot** (diagram flow 2; snapshot of the latest backup, ends in `Finished`):

```bash
oc --context $HUB2 apply -f manifests/restore/restore-acm-passive.yaml
oc --context $HUB2 get restore.cluster.open-cluster-management.io restore-acm-passive -n $BKP_NS -w
# restore-acm-passive   Finished   All Velero restores have run successfully
```

**Continuous** (diagram flow 3; re-restores every new HUB1 backup, stays `Enabled`):

```bash
oc --context $HUB2 apply -f manifests/restore/restore-acm-passive-sync.yaml
oc --context $HUB2 get restore.cluster.open-cluster-management.io restore-acm-passive-sync -n $BKP_NS -w
# restore-acm-passive-sync   Enabled   Velero restores have run to completion, restore will continue to sync with new backups
```

`restoreSyncInterval: 10m` in the manifest: HUB2 checks for new backups every 10 minutes (default 30m).

## 2. Validate: data yes, clusters no

The `dr-lab` objects checked below were created on HUB1 in module 1 from
[manifests/hub1/seed.yaml](../manifests/hub1/seed.yaml). They should now exist on HUB2, except
ConfigMap `dr-lab-unlabeled`: it has no `cluster.open-cluster-management.io/backup` label, so it was
never backed up.

Velero restores on HUB2:

```bash
oc --context $HUB2 get restore.velero.io -n $BKP_NS
# credentials + resources restores only, no acm-managed-clusters-schedule restore
```

No cluster came with the data:

```bash
oc --context $HUB2 get managedcluster
# local-cluster only
```

Hub data is there:

```bash
oc --context $HUB2 get managedclusterset dr-lab
oc --context $HUB2 get policy,placement -n dr-lab
oc --context $HUB2 get secret dr-lab-aws-creds -n dr-lab
# all found
```

Only the labeled ConfigMap came:

```bash
oc --context $HUB2 get configmap -n dr-lab
# dr-lab-labeled only, no dr-lab-unlabeled
```

The policy targets no cluster on HUB2:

```bash
oc --context $HUB2 get placementdecision -n dr-lab \
  -o jsonpath='{.items[*].status.decisions}{"\n"}'
# empty: the policy exists on HUB2 but targets no cluster, so HUB2 cannot touch the spoke
```

Spoke side, nothing moved. Still managed by HUB1:

```bash
oc --context $HUB1 get managedcluster $SPOKE_NAME
# AVAILABLE=True
```

Klusterlet still points to HUB1:

```bash
oc --context $SPOKE get secret hub-kubeconfig-secret -n open-cluster-management-agent \
  -o jsonpath='{.data.kubeconfig}' | base64 -d | grep server:
# server: https://api.<hub1-domain>:6443
```

`scripts/compare-hubs.sh $HUB1 $HUB2` should show `same` everywhere except `managedclusters` and
per-cluster secrets.

## 3. See a HUB1 change arrive on HUB2

*Acronyms: RPO = Recovery Point Objective, TTL = time to live.*

HUB2 never reads HUB1 directly, only the bucket. A change on HUB1 reaches HUB2 in two hops:

1. HUB1 writes it to the bucket at its **next backup** (`BACKUP_CRON`: top of every hour).
2. HUB2 restores it: the continuous flavour checks every `restoreSyncInterval` (10 min), the one-shot
   flavour never does by itself.

Left alone, that is up to about 70 minutes: the RPO of a passive hub. The steps below shorten both
hops so the test takes about 5 minutes.

**a. HUB1 schedule must be running.** If you ran module 4 step 1, it is `Paused` and no new backup
will ever be written:

```bash
oc --context $HUB1 get backupschedule schedule-acm-msa -n $BKP_NS
# schedule-acm-msa   Enabled    -> good, go to step b
# schedule-acm-msa   Paused     -> undo module 4 below, then unpause in step c
```

Undoing module 4 is safe only while HUB1 still owns everything. Both checks must pass:

```bash
oc --context $HUB2 get backupschedule -n $BKP_NS
# No resources found   (else BackupCollision)
```

```bash
oc --context $HUB1 get managedcluster $SPOKE_NAME
# AVAILABLE=True   (fleet not moved)
```

Then undo the two other module 4 changes, before unpausing.

`disable-auto-import` (module 4 step 3) stops HUB1 from re-importing a cluster that moved away.
Nothing moves in this path, so remove it. Do it before unpausing: otherwise the next backup copies
the annotation along with the `ManagedCluster`.

> **Only matters at activation.** A restore with `veleroManagedClustersBackupName: skip` (this
> module) never restores `ManagedCluster` objects, so the annotation in the bucket has no effect.
> It reaches HUB2 only with a restore that brings managed clusters: `latest` in step 4 below.

```bash
# module 4 step 3: remove disable-auto-import
oc --context $HUB1 get managedcluster -o name | grep -v local-cluster \
  | xargs -I{} oc --context $HUB1 annotate {} import.open-cluster-management.io/disable-auto-import-
# managedcluster.cluster.open-cluster-management.io/<name> annotated   (or "not found" if never set)
```

```bash
# module 4 step 2: a leftover restore sends the schedule to FailedValidation.
# The velero.io/backup-name labels it added stay.
oc --context $HUB1 delete restore.cluster.open-cluster-management.io restore-acm -n $BKP_NS --ignore-not-found
```

**b. Create the test object on HUB1:**

```bash
oc --context $HUB1 create configmap dr-lab-sync-test -n dr-lab --from-literal=note=sync
oc --context $HUB1 label configmap dr-lab-sync-test -n dr-lab cluster.open-cluster-management.io/backup=""
```

**c. Hop 1, faster: back up HUB1 every 5 minutes** (also unpauses it):

```bash
oc --context $HUB1 patch backupschedule schedule-acm-msa -n $BKP_NS --type merge \
  -p '{"spec":{"paused":false,"veleroSchedule":"*/5 * * * *"}}'
oc --context $HUB1 get schedule.velero.io -n $BKP_NS \
  -o custom-columns=NAME:.metadata.name,CRON:.spec.schedule,PAUSED:.spec.paused
# all: */5 * * * *   false
```

**d. Check HUB2 sees the new backup.** A labeled ConfigMap is a plain (non-ACM) object, so it goes
into the **generic** backup (`acm-resources-generic-schedule`). Velero on HUB2 lists the bucket about
every minute. Run on both hubs and wait until HUB2 shows a newer timestamp than the one it restored
in step 1:

```bash
oc --context $HUB1 get backup.velero.io -n $BKP_NS --sort-by=.metadata.creationTimestamp \
  -o name | grep acm-resources-generic-schedule | tail -1
# backup.velero.io/acm-resources-generic-schedule-<new timestamp>
```

```bash
oc --context $HUB2 get backup.velero.io -n $BKP_NS --sort-by=.metadata.creationTimestamp \
  -o name | grep acm-resources-generic-schedule | tail -1
# same name as on HUB1 (if older, wait a minute and retry)
```

The backup must start **after** the ConfigMap was created (step b), otherwise wait for the next one.

**e. Hop 2: restore the new backup on HUB2.** Same commands for both flavours (delete the restore
from step 1, apply it again: a new `Restore` picks `latest` right away), but not for the same reason.

**One-shot:** you must run it. Your `Finished` restore is done for good: HUB2 will never get the new
backup without a new `Restore`.

```bash
oc --context $HUB2 delete restore.cluster.open-cluster-management.io restore-acm-passive -n $BKP_NS
oc --context $HUB2 apply -f manifests/restore/restore-acm-passive.yaml
```

**Continuous:** you can skip it. Your restore already picks up the new backup by itself at its next
check (`restoreSyncInterval`, every 10 minutes). Run this only to get it now instead of waiting.

```bash
oc --context $HUB2 delete restore.cluster.open-cluster-management.io restore-acm-passive-sync -n $BKP_NS
oc --context $HUB2 apply -f manifests/restore/restore-acm-passive-sync.yaml
```

**f. Verify on HUB2.** The generic restore name ends with the new backup timestamp, and the
ConfigMap is there:

```bash
oc --context $HUB2 get restore.cluster.open-cluster-management.io -n $BKP_NS \
  -o jsonpath='{.items[0].status.veleroGenericResourcesRestoreName}{"\n"}'
# restore-acm-passive-acm-resources-generic-schedule-<new timestamp>
```

```bash
oc --context $HUB2 get configmap dr-lab-sync-test -n dr-lab
# dr-lab-sync-test   1   ...
```

**g. Put the HUB1 schedule back right away.** Left at every 5 minutes with a 120h TTL, it keeps
about 1,400 backups per group in the bucket:

```bash
oc --context $HUB1 patch backupschedule schedule-acm-msa -n $BKP_NS --type merge \
  -p "{\"spec\":{\"veleroSchedule\":\"$BACKUP_CRON\"}}"
```

> Do not edit restored objects on HUB2 while it is passive. With `CleanupRestored`, the next sync can
> overwrite or remove them.

## 4. Later: activate (move the clusters)

Switch to the **active** scenario (diagram flow 6), when you decide to move the clusters. Three steps.

**a. Freeze HUB1:** do **module 4** (pause schedule, tagging restore, `disable-auto-import`). From
now on, HUB1's newest backup is the last one.

**b. Bring HUB2 up to that last backup.** One-shot: re-run it as in step 3e. Continuous: re-run it
the same way, or wait for its next sync. Then check both names end with the same timestamp:

```bash
oc --context $HUB1 get backup.velero.io -n $BKP_NS --sort-by=.metadata.creationTimestamp \
  -o name | grep acm-resources-schedule | tail -1
# backup.velero.io/acm-resources-schedule-<last ts>
```

```bash
oc --context $HUB2 get restore.cluster.open-cluster-management.io -n $BKP_NS \
  -o jsonpath='{.items[0].status.veleroResourcesRestoreName}{"\n"}'
# restore-acm-passive...-acm-resources-schedule-<last ts>
```

**c. Restore the managed clusters on HUB2.** This is the step that moves the spoke.

Continuous: patch the running restore (sync stops, phase goes to `Finished`):

```bash
oc --context $HUB2 patch restore.cluster.open-cluster-management.io restore-acm-passive-sync -n $BKP_NS \
  --type merge -p '{"spec":{"veleroManagedClustersBackupName":"latest"}}'
oc --context $HUB2 get restore.cluster.open-cluster-management.io restore-acm-passive-sync -n $BKP_NS -w
# restore-acm-passive-sync   Finished   (Ctrl+C)
```

One-shot: replace the finished restore with
[restore-acm-activate.yaml](../manifests/restore/restore-acm-activate.yaml) (managed clusters only,
the rest is already on HUB2):

```bash
oc --context $HUB2 delete restore.cluster.open-cluster-management.io restore-acm-passive -n $BKP_NS
oc --context $HUB2 apply -f manifests/restore/restore-acm-activate.yaml
oc --context $HUB2 get restore.cluster.open-cluster-management.io restore-acm-activate -n $BKP_NS -w
# restore-acm-activate   Finished   (Ctrl+C)
```

Then continue with module 5 step 3 (watch the spoke move) and module 6.

## Checkpoint

- [ ] HUB2 restore `Finished` (one-shot) or `Enabled` (continuous)
- [ ] `dr-lab` objects present on HUB2, only `local-cluster` as `ManagedCluster`
- [ ] Spoke still Available on HUB1, klusterlet still points to HUB1
- [ ] Step 3: `dr-lab-sync-test` on HUB2, HUB1 schedule `Enabled` and back on `$BACKUP_CRON`

Next:

- Staying passive: [module 6](06-validate.md) step 2 only, then the passive section of
  [module 7](07-cleanup-primary.md#clean-up-the-passive-hub-5a-only).
- Activated (step 4): [module 6](06-validate.md), all steps.
