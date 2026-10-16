# 07 - Clean up

Which scenario did you run?

| Scenario | Clusters moved? | What to run here |
|---|---|---|
| Active (module 5, or 5a then its step 4) | yes | [Clean up HUB1](#clean-up-hub1-clusters-moved) |
| Passive (module 5a only) | **no** | [Clean up the passive hub](#clean-up-the-passive-hub-5a-only) |

> **Passive hub: never delete `ManagedCluster` objects on HUB1.** HUB1 is the only hub managing them.

## Clean up HUB1 (clusters moved)

*Acronyms: ACM = Advanced Cluster Management.*

Doc 1.1.37: once the managed clusters are connected to the new hub, delete them from the primary.

> **Skip this module if you plan to run module 8 (failback) and want to see the "clusters still
> exist on the target hub" path.** The doc also says to skip it if you will restore the primary later.
> Module 8 handles both cases.

### Safety checks (all must pass)

1. Spoke available on HUB2:

```bash
oc --context $HUB2 get managedcluster $SPOKE_NAME
# AVAILABLE=True
```

2. Spoke lost on HUB1:

```bash
oc --context $HUB1 get managedcluster $SPOKE_NAME
# AVAILABLE=Unknown   (NOT True)
```

3. No Hive cluster without `preserveOnDelete` on HUB1:

```bash
oc --context $HUB1 get clusterdeployment -A \
  -o custom-columns=NAME:.metadata.name,PRESERVE:.spec.preserveOnDelete
# No resources found, or PRESERVE=true on every line
```

> **Warning:** If a `ClusterDeployment` shows `false` or `<none>`, deleting its `ManagedCluster`
> deprovisions the real cluster. Stop and patch it (module 0).
>
> If the spoke shows `AVAILABLE=True` on HUB1, it has not moved. Stop and go back to module 5 (or
> 5a step 4).

### Delete the moved clusters from HUB1

```bash
for mc in $(oc --context $HUB1 get managedcluster -o name | grep -v local-cluster); do
  echo "deleting $mc on HUB1"
  oc --context $HUB1 delete $mc --wait=false
done
oc --context $HUB1 get managedcluster -w
```

This also deletes the cluster namespaces on HUB1. The spoke is not affected: its klusterlet talks to
HUB2, and HUB1 cannot push anything to it.

```bash
oc --context $SPOKE get pods -n open-cluster-management-agent
# klusterlet pods still Running
```

```bash
oc --context $HUB2 get managedcluster $SPOKE_NAME
# AVAILABLE=True
```

### What HUB1 is now

- an ACM hub still `Running`, managing only `local-cluster`,
- with a paused `schedule-acm-msa`, and objects tagged `velero.io/backup-name`,
- ready to become a target again (module 8) or to be decommissioned.

Decommission (not part of the lab): delete `MultiClusterHub`, then the operator. Backups in the bucket
are not touched, HUB2 is using them.

## Clean up the passive hub (5a only)

HUB1 keeps running as before. Only the 5a leftovers go.

HUB1 schedule back to hourly (5a step 3g, if not done yet):

```bash
oc --context $HUB1 get backupschedule.cluster.open-cluster-management.io schedule-acm-msa -n $BKP_NS \
  -o jsonpath='{.spec.paused}{" "}{.spec.veleroSchedule}{"\n"}'
# false 0 */1 * * *
```

If not, fix it:

```bash
oc --context $HUB1 patch backupschedule.cluster.open-cluster-management.io schedule-acm-msa -n $BKP_NS \
  --type merge -p "{\"spec\":{\"paused\":false,\"veleroSchedule\":\"$BACKUP_CRON\"}}"
```

Test object from 5a step 3, on HUB1:

```bash
oc --context $HUB1 delete configmap dr-lab-sync-test -n dr-lab --ignore-not-found
```

Stop HUB2 from following HUB1. Deleting the restore stops the sync; what it already restored stays on
HUB2:

```bash
oc --context $HUB2 get restore.cluster.open-cluster-management.io -n $BKP_NS
# restore-acm-passive or restore-acm-passive-sync
```

```bash
oc --context $HUB2 delete restore.cluster.open-cluster-management.io --all -n $BKP_NS
```

Want HUB2 empty again? Use [Reset the lab](09-troubleshooting.md#reset-the-lab), HUB2 part only.
Keep it as a standby? Skip this section entirely.

## Checkpoint

Active scenario:

- [ ] Only `local-cluster` left on HUB1
- [ ] Spoke still Available on HUB2

Passive scenario:

- [ ] Spoke still Available on HUB1, nothing deleted there
- [ ] HUB1 schedule `Enabled` on `$BACKUP_CRON`
- [ ] No restore left on HUB2 (unless you keep it as a standby)
