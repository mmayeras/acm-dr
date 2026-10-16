# 06 - Validate

Compare with the expected results table of [module 1](01-baseline-seed.md#expected-results-table).

Which scenario did you run?

| Scenario | Clusters moved? | What to run here |
|---|---|---|
| Active (module 5) | yes | everything |
| Active after passive (module 5a, then its step 4) | yes | everything |
| Passive (module 5a only) | **no** | step 2 only. 5a step 2 already did the rest |

> **Passive hub: do not run step 5.** HUB1 still writes to the bucket. A schedule on HUB2 too means
> two writers on one prefix: `BackupCollision`.

## 1. Fleet view on both hubs

```bash
oc --context $HUB2 get managedcluster
# $SPOKE_NAME   JOINED=True   AVAILABLE=True
```

```bash
oc --context $HUB1 get managedcluster
# $SPOKE_NAME   AVAILABLE=Unknown   (lease no longer renewed)
# local-cluster AVAILABLE=True      (HUB1 is still up and still manages itself)
```

## 2. Object diff

*Acronyms: RPO = Recovery Point Objective.*

```bash
scripts/compare-hubs.sh $HUB1 $HUB2
```

How to read it (clusters moved):
- clustersets, bindings, placements, root policies: `same`
- `configmaps [cluster.open-cluster-management.io/backup]`: HUB1 has `dr-lab-after-backup` extra
  (module 4 step 0). That is your RPO
- `secrets [cluster.open-cluster-management.io/type]`: some per-cluster secrets differ (import and
  bootstrap secrets are regenerated per hub). `dr-lab/dr-lab-aws-creds` must be on both
- `managedclusters`: same names, different status

Passive hub (5a only), differences:
- `managedclusters`: `DIFF`, the spoke is on HUB1 only. Expected: managed clusters were skipped
- `configmaps`: `same` if HUB2 restored HUB1's newest backup. Anything created on HUB1 since then
  (for example `dr-lab-sync-test` before 5a step 3e) shows as HUB1 extra
- everything else: same as above

Targeted checks:

```bash
oc --context $HUB2 get configmap -n dr-lab
# dr-lab-labeled only (dr-lab-unlabeled has no backup label)
```

```bash
oc --context $HUB2 get secret dr-lab-aws-creds -n dr-lab
# dr-lab-aws-creds   Opaque   ...
```

```bash
oc --context $HUB2 get policy -n dr-lab dr-lab-marker
# dr-lab-marker   enforce   Compliant
```

```bash
oc --context $HUB2 get placementdecision -n dr-lab \
  -o jsonpath='{.items[*].status.decisions[*].clusterName}{"\n"}'
# $SPOKE_NAME   (HUB2 now targets the spoke)
```

## 3. Prove HUB2 is in control (not just a copy)

Change the policy on HUB2 and watch the spoke follow:

```bash
oc --context $HUB2 patch policy dr-lab-marker -n dr-lab --type json -p '[
  {"op":"replace",
   "path":"/spec/policy-templates/0/objectDefinition/spec/object-templates/1/objectDefinition/data/managed-by-hub",
   "value":"hub2"}]'

sleep 30
oc --context $SPOKE get configmap dr-lab-marker -n dr-lab-canary -o jsonpath='{.data.managed-by-hub}{"\n"}'
# hub2
```

And HUB1 cannot fight back. Its copy of the policy still says `hub1`, but its agents no longer reach
the spoke:

```bash
oc --context $HUB1 get policy dr-lab-marker -n dr-lab \
  -o jsonpath='{.spec.policy-templates[0].objectDefinition.spec.object-templates[1].objectDefinition.data}{"\n"}'
```

## 4. Spoke side

Kubeconfig the klusterlet uses now:

```bash
oc --context $SPOKE get secret hub-kubeconfig-secret -n open-cluster-management-agent \
  -o jsonpath='{.data.kubeconfig}' | base64 -d | grep server:
# server: https://api.<hub2-domain>:6443
```

Bootstrap kubeconfig (rewritten by the HUB2 import controller):

```bash
oc --context $SPOKE get secret bootstrap-hub-kubeconfig -n open-cluster-management-agent \
  -o jsonpath='{.data.kubeconfig}' | base64 -d | grep server:
# server: https://api.<hub2-domain>:6443
```

```bash
oc --context $SPOKE get pods -n open-cluster-management-agent
# klusterlet pods Running
```

```bash
oc --context $SPOKE get pods -n open-cluster-management-agent-addon
# add-on agent pods Running
```

Add-ons on HUB2:

```bash
oc --context $HUB2 get managedclusteraddon -n $SPOKE_NAME
# all AVAILABLE=True after a few minutes
```

## 5. Start protecting HUB2

*Acronyms: MSA = ManagedServiceAccount.*

HUB2 is now the active hub, and HUB1's schedule is paused. Give HUB2 its own schedule so the fleet is
protected again. Same bucket and prefix: allowed because HUB1 no longer writes.

```bash
envsubst < manifests/common/backupschedule.yaml.tpl | oc --context $HUB2 apply -f -
oc --context $HUB2 get backupschedule.cluster.open-cluster-management.io -n $BKP_NS
# schedule-acm-msa   Enabled
```

> If you get `FailedValidation` mentioning a restore, delete the finished restore first. Its name
> depends on the scenario: `restore-acm` (module 5), `restore-acm-passive-sync` or `restore-acm-activate`
> (5a step 4). List them with
> `oc --context $HUB2 get restore.cluster.open-cluster-management.io -n $BKP_NS`, then delete it:
> `oc --context $HUB2 delete restore.cluster.open-cluster-management.io <name> -n $BKP_NS`

Wait for the first HUB2 backups and the new MSA token:

```bash
oc --context $HUB2 get managedserviceaccount -n $SPOKE_NAME auto-import-account
# auto-import-account   ...   (token for the next move, now owned by HUB2)
```

```bash
scripts/hub-status.sh $HUB2
# first acm-* backups Completed on HUB2
```

> **Do not unpause the schedule on HUB1 now.** Two active schedules on one prefix = `BackupCollision`.

## Checkpoint

Active scenario (module 5, or 5a + step 4). Passive scenario: use the 5a checkpoint instead.

| Object | Expected on HUB2 | Observed |
|---|---|---|
| ManagedClusterSet `dr-lab` | yes | |
| Placement / Policy / PlacementBinding | yes | |
| Secret `dr-lab-aws-creds` | yes | |
| ConfigMap `dr-lab-labeled` | yes | |
| ConfigMap `dr-lab-unlabeled` | no | |
| ConfigMap `dr-lab-after-backup` | no | |
| ConfigMap `dr-lab-sync-test` (5a step 3 only) | yes | |
| `$SPOKE_NAME` Available on HUB2, Unknown on HUB1 | yes | |
| Spoke ConfigMap says `hub2` after policy edit | yes | |
| HUB2 schedule Enabled, first backups Completed | yes | |

Next: [module 7](07-cleanup-primary.md) (clean up), then optionally [module 8](08-failback.md) (fail back).
