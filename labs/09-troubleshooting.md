# 09 - Troubleshooting

Generic checks only. Exact messages and fixes depend on your storage, network and versions: read the
real message first, then confirm the fix in the product doc
([Business continuity](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index)).

First look on any hub:

```bash
scripts/hub-status.sh <ctx>
```

## BSL Unavailable

*Acronyms: S3 = Amazon Simple Storage Service (object storage protocol), DPA = DataProtectionApplication, BSL = BackupStorageLocation, CA = certificate authority.*

Status and message:

```bash
oc --context <hub> get backupstoragelocation.velero.io -n $BKP_NS -o yaml | grep -E 'phase:|message:'
```

Velero errors about the storage:

```bash
oc --context <hub> logs -n $BKP_NS deploy/velero -c velero --since=10m | grep -i -E 'error|backup-location'
```

What to check, in that order:

1. Bucket and prefix in the `DataProtectionApplication` match the real bucket.
2. `cloud-credentials` secret holds valid keys for that bucket.
3. The hub reaches the S3 endpoint (egress, proxy, firewall).
4. The hub trusts the endpoint certificate (certificate errors: add the CA to the DPA).

## BackupSchedule not Enabled

*Acronyms: OADP = OpenShift API for Data Protection, BSL = BackupStorageLocation.*

```bash
oc --context <hub> get backupschedule.cluster.open-cluster-management.io -n $BKP_NS \
  -o jsonpath='{.items[0].status.phase}{": "}{.items[0].status.lastMessage}{"\n"}'
```

- `FailedValidation`: the message says what is missing. Usually the BSL is not `Available`, OADP is not
  ready, or a restore object still exists on that hub.
- `BackupCollision`: another hub wrote to the same storage location. Only one hub may have an active
  schedule per location: keep the schedule on the active hub, delete it on the other one.

## Restore not Finished

*Acronyms: ACM = Advanced Cluster Management.*

ACM restore, events and last message:

```bash
oc --context <hub> describe restore.cluster.open-cluster-management.io <name> -n $BKP_NS
```

Velero restores it created, one per backup group:

```bash
oc --context <hub> get restore.velero.io -n $BKP_NS
```

Details of one velero restore (errors and warnings):

```bash
oc --context <hub> describe restore.velero.io <velero-restore> -n $BKP_NS
```

Only one ACM restore can be active on a hub. Delete the old one before creating the next.

## Spoke stuck in Pending Import

*Acronyms: MSA = ManagedServiceAccount, API = Application Programming Interface.*

Active scenario only (a passive restore never imports clusters). Diagram flow 7 shows the two usual
causes.

On the restore hub, cluster conditions:

```bash
oc --context <hub> get managedcluster $SPOKE_NAME -o jsonpath='{.status.conditions}' | jq
```

Import secrets in the cluster namespace (an `auto-import-secret` appears while the import runs):

```bash
oc --context <hub> get secret -n $SPOKE_NAME
```

Import controller logs for that cluster:

```bash
oc --context <hub> logs -n multicluster-engine deploy/managedcluster-import-controller-v2 --since=15m | grep $SPOKE_NAME
```

On the spoke, klusterlet status and registration logs:

```bash
oc --context $SPOKE get klusterlet klusterlet -o jsonpath='{.status.conditions}' | jq
```

```bash
oc --context $SPOKE logs -n open-cluster-management-agent deploy/klusterlet-registration-agent --since=10m | tail -50
```

What to check:

1. The restored backup holds an MSA token for the cluster (module 2 step 5).
2. The token is still valid when you restore (validity is tied to `veleroTtl`).
3. Network both ways: restore hub -> spoke API `:6443` (auto-import), spoke -> restore hub API `:6443`
   (registration).
4. The cluster did not already exist on the target hub. If it did, see `autoImportStrategy` and the
   `immediate-import` annotation in the doc.

If auto-import cannot work, import the cluster manually (doc: "Importing a managed cluster").

## Reset the lab

*Acronyms: ACM = Advanced Cluster Management.*

HUB2, back to a fresh ACM hub (keeps ACM, OADP, the DPA and `cloud-credentials` installed).

1. Stop restores and backups. Restores go first: a `restore-acm-passive-sync` still `Enabled` brings
   everything back at its next sync. Deleting a restore never deletes what it restored.

```bash
oc --context $HUB2 delete restore.cluster.open-cluster-management.io --all -n $BKP_NS
oc --context $HUB2 delete restore.velero.io --all -n $BKP_NS
oc --context $HUB2 delete backupschedule.cluster.open-cluster-management.io --all -n $BKP_NS
```

2. Managed clusters (active scenario only, a passive restore never brings any). Module 7 rules apply,
   on HUB2 this time:

```bash
oc --context $HUB2 get managedcluster $SPOKE_NAME
# AVAILABLE=Unknown   (NOT True)
```

```bash
oc --context $HUB1 get managedcluster $SPOKE_NAME
# AVAILABLE=True      (spoke is back on HUB1, module 8)
```

```bash
oc --context $HUB2 get clusterdeployment -A \
  -o custom-columns=NAME:.metadata.name,PRESERVE:.spec.preserveOnDelete
# No resources found, or PRESERVE=true on every line
```

> **Warning:** If the spoke shows `AVAILABLE=True` on HUB2, HUB2 is its only hub: deleting the
> `ManagedCluster` detaches the spoke (klusterlet removed). Fail back first (module 8). A
> `ClusterDeployment` with `false` or `<none>` gets deprovisioned: patch it first (module 0).

```bash
for mc in $(oc --context $HUB2 get managedcluster -o name | grep -v local-cluster); do
  echo "deleting $mc on HUB2"
  oc --context $HUB2 delete $mc --wait=false
done
oc --context $HUB2 get managedcluster -w
# only local-cluster left
```

This also deletes the cluster namespaces on HUB2 and, with the `ManagedCluster`, its clusterset label.

3. Test data restored from HUB1. Deleting namespace `dr-lab` also removes the restored
   `dr-lab-aws-creds` secret and `dr-lab-from-hub2` (module 8). `dr-lab-unlabeled` was never restored,
   hence `--ignore-not-found`:

```bash
oc --context $HUB2 delete -f manifests/hub1/seed.yaml --ignore-not-found
oc --context $HUB2 wait --for=delete namespace/dr-lab --timeout=5m
```

4. Nothing restored left. Velero labels every object it restores with `velero.io/restore-name`:

```bash
oc --context $HUB2 get managedclusterset,managedclustersetbinding,placement,policy,placementbinding,secret,configmap \
  -A -l velero.io/restore-name
# No resources found
```

The synced `Backup` objects stay listed on HUB2 until they expire: see the bucket part below.

HUB1 and spoke, test data:

```bash
oc --context $HUB1 delete -f manifests/hub1/seed.yaml
oc --context $HUB1 label managedcluster $SPOKE_NAME cluster.open-cluster-management.io/clusterset-
oc --context $SPOKE delete namespace dr-lab-canary
```

Bucket: old backups expire with `veleroTtl`. To start clean, empty the prefix (`labs3` is defined in
`env.sh`):

```bash
labs3 rm --recursive s3://$S3_BUCKET/$S3_PREFIX/
```

Then delete the synced `Backup` objects on both hubs, or velero keeps listing them until they expire:

```bash
oc --context <hub> delete backup.velero.io --all -n $BKP_NS
```
