# Reference: ACM hub disaster recovery lab

*Acronyms: ACM = Advanced Cluster Management.*

The details behind the lab. For the short version, read the [overview](README.md) and watch the
[animated flow diagram](https://mmayeras.fr/acm-dr/flow/). Product procedure followed:
[Keeping the primary hub cluster active during a restore process](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#keep-hub-active-restore).

## Topology

*Acronyms: ACM = Advanced Cluster Management, SNO = Single Node OpenShift, OADP = OpenShift API for Data Protection, CSV = ClusterServiceVersion (installed operator version), S3 = Amazon Simple Storage Service (object storage protocol), API = Application Programming Interface, DPA = DataProtectionApplication.*

```
                    S3 bucket  s3://$S3_BUCKET/$S3_PREFIX
                 (velero backups, shared by both hubs)
                    ^  write                read  |
                    |                             v
   +----------------+---------+       +-----------+--------------+
   | HUB1  (existing, primary)|       | HUB2  (new SNO)          |
   | ACM 2.17.z               |       | ACM 2.17.z (same CSV)    |
   | OADP + DPA + BackupSched |       | OADP + DPA, NO schedule  |
   | ManagedCluster spoke1    |       | Restore                  |
   +------------+-------------+       +-----------+--------------+
                |  klusterlet before              |  klusterlet after (active only)
                +-------------+    +--------------+
                              |    |
                        +-----+----+-----+
                        |  SPOKE (spoke1) |
                        +-----------------+
```

Network paths:

| From | To | Why | Needed for |
|---|---|---|---|
| HUB1, HUB2 | bucket | HUB1 writes backups, HUB2 reads them | all scenarios |
| HUB2 | spoke API `:6443` | auto-import rewrites the spoke's hub address | active |
| spoke | HUB2 API `:6443` | the klusterlet registers with HUB2 | active |

## Key ideas

*Acronyms: RPO = Recovery Point Objective.*

1. **The backup has two halves.** Hub data (credentials, resources, labeled objects) and managed
   clusters. Restoring the first half gives a passive copy. Restoring the second moves the clusters.
2. **Only one hub writes to the bucket.** Two running `BackupSchedule` objects on the same location
   end in `BackupCollision`.
3. **Imported clusters move only with a token in the backup** (`useManagedServiceAccount: true`).
   Without it, they stay in `Pending Import` on HUB2.
4. **HUB1 must let go before a move.** Pause its schedule and add `disable-auto-import`, so it never
   takes the clusters back.
5. **A restore on HUB1 itself is on purpose.** It labels HUB1 objects with `velero.io/backup-name`, so
   a later failback can clean them up.
6. **RPO = time since the last backup.** Anything newer is missing on HUB2.

## How imported clusters move: ManagedServiceAccount (MSA)

*Acronyms: MSA = ManagedServiceAccount, API = Application Programming Interface.*

**The problem.** The klusterlet (the agent on the spoke) knows one hub: its `bootstrap-hub-kubeconfig`
secret points to HUB1. Restoring the `ManagedCluster` on HUB2 does not change that, and HUB2 has no
access to the spoke. The cluster stays in `Pending Import`. (Hive-provisioned clusters are fine: their
admin kubeconfig is in the backup.)

**The fix.** With `useManagedServiceAccount: true` on the `BackupSchedule`, the hub creates a
ServiceAccount on each imported spoke, gets its token back, and stores it in the backup. On restore,
HUB2 uses that token to rewrite `bootstrap-hub-kubeconfig`, and the klusterlet re-registers on HUB2.

```
 HUB1                                   SPOKE
 ManagedServiceAccount  ---- add-on ---> ServiceAccount auto-import-account
 Secret auto-import-account   <--------- token (can only update bootstrap-hub-kubeconfig)
   -> goes into the backup
                    |
                    v  restore with managed clusters = latest
 HUB2
 restore controller -> auto-import-secret
 import controller  -> calls the spoke API ---> rewrites bootstrap-hub-kubeconfig to HUB2
                                                klusterlet re-registers on HUB2
```

| Step | Where | How to see it |
|---|---|---|
| Token created | HUB1 | `oc get secret -n <cluster> auto-import-account` |
| Token in the backup | bucket | an `acm-managed-clusters-schedule-*` backup taken **after** the token |
| Import started | HUB2 | `auto-import-secret` appears briefly in the `<cluster>` namespace |
| Spoke moved | spoke | `bootstrap-hub-kubeconfig` server = HUB2, then `JOINED=True AVAILABLE=True` on HUB2 |

Keep in mind:

- **Limited rights.** The token can only read and update `bootstrap-hub-kubeconfig`. Not cluster-admin.
- **Timing.** The token appears shortly after the schedule is enabled. Older backups cannot
  auto-import (module 2 step 5 checks it).
- **Expiry.** The token is valid 2 x `veleroTtl` (240h here). Restoring an older backup means a manual
  import.
- **Network.** HUB2 must reach the spoke API on `:6443`.

## Restore spec, field by field

*Acronyms: MSA = ManagedServiceAccount.*

Every restore is a `Restore` (`cluster.open-cluster-management.io/v1beta1`) in
`open-cluster-management-backup`. It runs one velero restore per backup group.

### Which backups to restore

Each field takes `latest`, `skip`, or the name of one backup.

| Field | Backup group | Brings back |
|---|---|---|
| `veleroCredentialsBackupName` | `acm-credentials-schedule` | hub secrets, such as provider credentials |
| `veleroResourcesBackupName` | `acm-resources-schedule` + `acm-resources-generic-schedule` | policies, placements, cluster sets, apps, and any object labeled `cluster.open-cluster-management.io/backup` |
| `veleroManagedClustersBackupName` | `acm-managed-clusters-schedule` | `ManagedCluster`, add-ons, Hive `ClusterDeployment`, MSA tokens |

The first two are hub data (passive). The third is the switch: `latest` moves the clusters, `skip`
leaves them on HUB1.

### Objects already on the hub

`cleanupBeforeRestore`:

- `None`: delete nothing. For an empty hub.
- `CleanupRestored`: delete objects from a previous restore (labeled `velero.io/backup-name`) that are
  not in the new backup. Unlabeled objects are never touched. For a hub that already holds restored
  data: continuous sync, activation after a passive restore, failback.

### Keep following new backups (passive only)

- `syncRestoreWithNewBackups: true`: the restore stays `Enabled` and restores every newer backup.
  Requires credentials and resources on `latest`, managed clusters on `skip`.
- `restoreSyncInterval: 10m`: how often it checks (default `30m`).

Setting managed clusters to `latest` on a syncing restore stops the sync and moves the clusters.

### The five restores in this lab

| Manifest | Credentials | Resources | Clusters | Cleanup | Sync | Used in |
|---|---|---|---|---|---|---|
| [restore-acm.yaml](manifests/restore/restore-acm.yaml) | `latest` | `latest` | `latest` | `None` | no | module 4 (on HUB1, labels only), module 5 |
| [restore-acm-passive.yaml](manifests/restore/restore-acm-passive.yaml) | `latest` | `latest` | `skip` | `None` | no | module 5a, one-shot |
| [restore-acm-passive-sync.yaml](manifests/restore/restore-acm-passive-sync.yaml) | `latest` | `latest` | `skip` | `CleanupRestored` | `10m` | module 5a continuous, module 8 |
| [restore-acm-activate.yaml](manifests/restore/restore-acm-activate.yaml) | `skip` | `skip` | `latest` | `CleanupRestored` | no | module 5a step 4 |
| [restore-acm-failback.yaml](manifests/restore/restore-acm-failback.yaml) | `latest` | `latest` | `latest` | `CleanupRestored` | no | module 8 |

One restore at a time per hub: delete a finished one before creating the next.

## Repository layout

*Acronyms: ACM = Advanced Cluster Management, DPA = DataProtectionApplication, URL = Uniform Resource Locator.*

```
env.example.sh                  variables (copy to env.sh)
labs/                           the guided modules
manifests/common/               DPA + BackupSchedule templates (both hubs)
manifests/hub1/seed.yaml        test data created on HUB1
manifests/hub2/                 ACM operator + MultiClusterHub for HUB2
manifests/restore/              the five Restore objects
diagrams/acm-dr-flow.html       animated flow diagram
flow/index.html                 short URL /flow/ for the diagram on GitHub Pages
scripts/hub-status.sh <ctx>     backup and restore status of one hub
scripts/compare-hubs.sh <a> <b> name-level diff of ACM objects between two hubs
```

