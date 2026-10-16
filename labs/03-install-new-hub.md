# 03 - Install ACM on the new SNO hub (HUB2)

*Acronyms: ACM = Advanced Cluster Management, SNO = Single Node OpenShift.*

Doc prerequisites for a restore hub:
- same ACM version as the backup hub,
- same extra operators as the backup hub, same namespaces,
- `cluster-backup` enabled and a `DataProtectionApplication` pointing at the **same** storage.

## 1. Read the exact version from HUB1

*Acronyms: CSV = ClusterServiceVersion (installed operator version), OLM = Operator Lifecycle Manager.*

```bash
export ACM_CHANNEL=$(oc --context $HUB1 get sub -n open-cluster-management \
  -o jsonpath='{.items[?(@.spec.name=="advanced-cluster-management")].spec.channel}')
export ACM_CSV=$(oc --context $HUB1 get sub -n open-cluster-management \
  -o jsonpath='{.items[?(@.spec.name=="advanced-cluster-management")].status.installedCSV}')
echo "ACM_CHANNEL=$ACM_CHANNEL ACM_CSV=$ACM_CSV"
# ACM_CHANNEL=release-2.17 ACM_CSV=advanced-cluster-management.v2.17.3
```

Both must be non-empty. Also write them into `env.sh` so a new shell keeps them.

> If `ACM_CSV` is empty, the subscription has no `startingCSV` and OLM installs the **latest** CSV of
> the channel, which may be newer than HUB1.

## 2. Install the operator, pinned

```bash
if [ -z "$ACM_CSV" ]; then
  echo "ACM_CSV is empty in this shell: run step 1 or 'source ./env.sh', then retry"
else
  envsubst < manifests/hub2/acm-operator.yaml.tpl | oc --context $HUB2 apply -f -

  # Wait for OLM to create the install plan for the pinned CSV (can take a minute)
  until IP=$(oc --context $HUB2 get installplan -n open-cluster-management -o json \
      | jq -er --arg csv "$ACM_CSV" \
        '[.items[] | select(.spec.clusterServiceVersionNames | index($csv))][0].metadata.name'); do
    echo "waiting for install plan of $ACM_CSV..."; sleep 10
  done
  echo "install plan: $IP"

  # Manual approval: approve only that plan
  oc --context $HUB2 patch installplan "$IP" -n open-cluster-management --type merge -p '{"spec":{"approved":true}}'
fi
```

The whole step is one `if` block on purpose: when you paste lines into a terminal, a failing line
does not stop the next ones, so the check must wrap the commands it protects.

Wait for the operator:

```bash
oc --context $HUB2 get csv -n open-cluster-management -w    # Succeeded, Ctrl+C
```

Check HUB2 got exactly the HUB1 version:

```bash
oc --context $HUB2 get csv -n open-cluster-management -o name | grep advanced-cluster-management
# clusterserviceversion.operators.coreos.com/<same as $ACM_CSV>
```

Leave approval on `Manual` for the rest of the lab so HUB2 cannot drift ahead of HUB1.

## 3. Install add-on operators

*Acronyms: ACM = Advanced Cluster Management.*

Install every ACM-related operator from your module 0 inventory (same channel, same namespace).
Example for OpenShift GitOps if HUB1 uses `GitOpsCluster`:

```bash
oc --context $HUB1 get sub -A | grep -i gitops    # copy channel / namespace from here
```

Skip if HUB1 has nothing extra.

## 4. Create the MultiClusterHub (with backup enabled)

*Acronyms: ACM = Advanced Cluster Management, MCE = MultiClusterEngine.*

```bash
oc --context $HUB2 apply -f manifests/hub2/multiclusterhub.yaml
```

The ACM operator now creates the MultiClusterEngine subscription in `multicluster-engine` **with the
same `Manual` approval** as ACM. Its install plan waits for you, and the MultiClusterHub stays
`Installing` forever if you skip this. Approve it only if it is the same MCE version as HUB1:

```bash
MCE_CSV=$(oc --context $HUB1 get csv -n multicluster-engine -o name | grep -o 'multicluster-engine\.v.*')
echo "HUB1 MCE: $MCE_CSV"

until IP=$(oc --context $HUB2 get installplan -n multicluster-engine -o json \
    | jq -er --arg csv "$MCE_CSV" \
      '[.items[] | select(.spec.clusterServiceVersionNames | index($csv))][0].metadata.name'); do
  echo "waiting for install plan of $MCE_CSV..."; sleep 10
done
oc --context $HUB2 patch installplan "$IP" -n multicluster-engine --type merge -p '{"spec":{"approved":true}}'
```

Then wait:

```bash
oc --context $HUB2 get csv -n multicluster-engine -w
# multicluster-engine...   Succeeded   (Ctrl+C)
```

```bash
oc --context $HUB2 get multiclusterhub -n $ACM_NS -w
# multiclusterhub   Running   ...   (10 to 20 min on SNO)
```

Stuck in `Installing`? Look for `Pending` pods first:

```bash
oc --context $HUB2 get pods -A --field-selector=status.phase=Pending
# No resources found -> not a scheduling problem
```

If some are listed, read why:

```bash
oc --context $HUB2 get events -A --field-selector=reason=FailedScheduling | tail
# "Insufficient cpu" / "Insufficient memory" -> HUB2 too small, resize the node (see module 0)
```

After a resize, the pods get scheduled on their own. `ServiceAccount ... not found` or `secret ... not
found` warnings in `multicluster-engine` during the next minutes are normal: MCE creates them right
after the deployments.

Check versions match:

```bash
for c in $HUB1 $HUB2; do
  echo "$c ACM=$(oc --context $c get mch -A -o jsonpath='{.items[0].status.currentVersion}') \
MCE=$(oc --context $c get mce -o jsonpath='{.items[0].status.currentVersion}')"
done
```

If HUB1 `MultiClusterEngine` has `managedserviceaccount` disabled and you enabled it in module 2, also
check HUB2:

```bash
oc --context $HUB2 get multiclusterengine \
  -o jsonpath='{.items[0].spec.overrides.components[?(@.name=="managedserviceaccount")].enabled}{"\n"}'
```

## 5. OADP and the same storage location

*Acronyms: OADP = OpenShift API for Data Protection, DPA = DataProtectionApplication.*

Wait for OADP:

```bash
oc --context $HUB2 get csv -n $BKP_NS -w
# oadp-operator...   Succeeded   (Ctrl+C)
```

Same credentials and DPA as HUB1:

```bash
oc --context $HUB2 create secret generic cloud-credentials -n $BKP_NS \
  --from-file=cloud=/tmp/credentials-velero
envsubst < manifests/common/dpa.yaml.tpl | oc --context $HUB2 apply -f -
```

```bash
oc --context $HUB2 get backupstoragelocation.velero.io -n $BKP_NS
# dpa-acm-1   Available
```

The local credentials file is no longer needed: `rm /tmp/credentials-velero`

Compare OADP versions, they should match on both hubs:

```bash
for c in $HUB1 $HUB2; do echo "$c $(oc --context $c get csv -n $BKP_NS -o name | grep oadp)"; done
```

## 6. HUB2 sees HUB1 backups

Velero syncs `Backup` objects from the bucket into the cluster (every minute by default):

```bash
oc --context $HUB2 get backup.velero.io -n $BKP_NS --sort-by=.metadata.creationTimestamp | tail
```

## 7. Do NOT create a BackupSchedule on HUB2

HUB1 owns the bucket. A second active schedule writing to the same prefix sets both schedules to
`BackupCollision`. HUB2 only gets a schedule in module 6 (after HUB1 is paused) or module 8.

## Checkpoint

*Acronyms: ACM = Advanced Cluster Management, BSL = BackupStorageLocation, MCE = MultiClusterEngine.*

- [ ] HUB2 `MultiClusterHub` Running, same ACM and MCE version as HUB1
- [ ] Add-on operators installed on HUB2
- [ ] HUB2 BSL `Available`, same bucket + prefix
- [ ] HUB2 lists the same `acm-*` backups as HUB1
- [ ] No `BackupSchedule` on HUB2: `oc --context $HUB2 get backupschedule -n $BKP_NS` returns nothing

Next:

- **Passive** scenario (copy the hub, no cluster import): [module 5a](05a-passive-restore.md).
- **Active** scenario (cluster import, the spoke moves): [module 4](04-prepare-primary.md), then
  [module 5](05-restore-new-hub.md).
