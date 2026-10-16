# 05 - Restore on HUB2

> **Active scenario** (cluster import, diagram flow 5). Do [module 4](04-prepare-primary.md) first.

Doc 1.1.36 "Running the restore operation on the new hub cluster". Same `Restore` as module 4,
applied on **HUB2**. With `veleroManagedClustersBackupName: latest` it restores managed clusters
and connects them to HUB2.

## 1. Last checks on HUB2

*Acronyms: ACM = Advanced Cluster Management.*

No restore running (only one restore at a time):

```bash
oc --context $HUB2 get restore.cluster.open-cluster-management.io -n $BKP_NS
# No resources found, or only Finished ones
```

No schedule (HUB1 owns the bucket):

```bash
oc --context $HUB2 get backupschedule.cluster.open-cluster-management.io -n $BKP_NS
# No resources found
```

No cluster imported yet:

```bash
oc --context $HUB2 get managedcluster
# local-cluster only
```

ACM 2.14+ uses `autoImportStrategy: ImportOnly` by default. That is fine here: on a fresh hub the
spoke's `ManagedCluster` is new, so it is imported once. (Re-import of clusters that already exist
on the target hub is covered in module 8.)

## 2. Start the restore

Open a second terminal to watch the spoke side while this runs:

```bash
# terminal 2
watch -n5 "oc --context $SPOKE get secret hub-kubeconfig-secret -n open-cluster-management-agent \
  -o jsonpath='{.data.kubeconfig}' | base64 -d | grep server:"
```

[restore-acm.yaml](../manifests/restore/restore-acm.yaml): credentials, resources **and managed
clusters** on `latest` (that last one moves the spoke), cleanup `None` (HUB2 is empty). Fields
explained in [REFERENCE: Restore spec, field by field](../REFERENCE.md#restore-spec-field-by-field).

```bash
oc --context $HUB2 apply -f manifests/restore/restore-acm.yaml
oc --context $HUB2 get restore.cluster.open-cluster-management.io restore-acm -n $BKP_NS -w
```

Phases you should see: `Started` -> `Running` -> `Finished`.

What happened under the hood:

```bash
oc --context $HUB2 get restore.velero.io -n $BKP_NS
# restore-acm-acm-credentials-...        Completed
# restore-acm-acm-resources-schedule-... Completed
# restore-acm-acm-resources-generic-...  Completed
# restore-acm-acm-managed-clusters-...   Completed
```

Details and events, if one is not `Completed`:

```bash
oc --context $HUB2 describe restore.cluster.open-cluster-management.io restore-acm -n $BKP_NS
```

`PartiallyFailed` on one velero restore usually means an empty backup (for example no generic
resources). Read the events before worrying.

## 3. Watch the spoke move

*Acronyms: MSA = ManagedServiceAccount, API = Application Programming Interface.*

```bash
oc --context $HUB2 get managedcluster -w
```

Sequence for an imported cluster with an MSA token:

1. `ManagedCluster` restored, `HUB ACCEPTED=true`, joined/available unknown, console shows `Pending Import`
2. restore controller finds the token, creates `auto-import-secret` in the cluster namespace
3. HUB2 import controller uses it to update `bootstrap-hub-kubeconfig` on the spoke
4. klusterlet re-bootstraps against HUB2: `JOINED=True`, `AVAILABLE=True` (a few minutes)

```bash
oc --context $HUB2 get secret auto-import-secret -n $SPOKE_NAME
# exists briefly, then NotFound once the import is done (both are fine)
```

```bash
oc --context $HUB2 get managedcluster $SPOKE_NAME -o jsonpath='{.status.conditions[*].type}{"\n"}'
# ... ManagedClusterJoined ManagedClusterConditionAvailable ...
```

Terminal 2 should flip the `server:` line to HUB2's API.

Stuck in `Pending Import` for more than 10 minutes: see
[troubleshooting](09-troubleshooting.md#spoke-stuck-in-pending-import).

## Checkpoint

- [ ] `restore-acm` Finished on HUB2
- [ ] Spoke `JOINED=True AVAILABLE=True` on HUB2
- [ ] Spoke klusterlet `hub-kubeconfig-secret` points to HUB2

Next: [module 6](06-validate.md).
