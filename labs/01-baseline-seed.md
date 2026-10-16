# 01 - Baseline HUB1 and seed test data

Goal: put known objects on HUB1 so that after restore you can prove what came back, what did not,
and that HUB2 really drives the spoke.

## 1. Snapshot the starting state

```bash
scripts/hub-status.sh $HUB1 | tee /tmp/hub1-before.txt
```

## 2. Create the test data

*Acronyms: ACM = Advanced Cluster Management.*

```bash
oc --context $HUB1 apply -f manifests/hub1/seed.yaml
```

Put the spoke in the lab cluster set (this label travels with the `ManagedCluster` in the
managed-clusters backup):

```bash
oc --context $HUB1 label managedcluster $SPOKE_NAME \
  cluster.open-cluster-management.io/clusterset=dr-lab --overwrite
```

Add a fake provider credential the way the console would create it. ACM backs up secrets carrying
`cluster.open-cluster-management.io/type`:

```bash
oc --context $HUB1 create secret generic dr-lab-aws-creds -n dr-lab \
  --from-literal=aws_access_key_id=FAKEKEY --from-literal=aws_secret_access_key=FAKESECRET
oc --context $HUB1 label secret dr-lab-aws-creds -n dr-lab \
  cluster.open-cluster-management.io/type=aws cluster.open-cluster-management.io/credentials=""
```

## 3. Confirm the policy reached the spoke

Policy status on HUB1:

```bash
oc --context $HUB1 get policy -n dr-lab dr-lab-marker
# COMPLIANCE STATE should reach Compliant within a minute
```

Object the policy created on the spoke:

```bash
oc --context $SPOKE get configmap dr-lab-marker -n dr-lab-canary -o jsonpath='{.data.managed-by-hub}{"\n"}'
# hub1
```

## 4. Record where the spoke's klusterlet points

```bash
oc --context $SPOKE get secret hub-kubeconfig-secret -n open-cluster-management-agent \
  -o jsonpath='{.data.kubeconfig}' | base64 -d | grep server:
# server: https://api.<hub1-domain>:6443
```

You will run this again later. Active scenario: the server must change to HUB2. Passive scenario: it
must stay HUB1.

## Expected results table

*Acronyms: ACM = Advanced Cluster Management, MSA = ManagedServiceAccount, RPO = Recovery Point Objective, API = Application Programming Interface.*

What each scenario should give on HUB2 (module 6 checks it):

| Object | On HUB1 | On HUB2, passive | On HUB2, active | Why |
|---|---|---|---|---|
| ManagedClusterSet `dr-lab` | yes | yes | yes | ACM API group, resources backup |
| Placement / Policy / PlacementBinding in `dr-lab` | yes | yes | yes | resources backup |
| Secret `dr-lab-aws-creds` | yes | yes | yes | credentials backup (`.../type` label) |
| ConfigMap `dr-lab-labeled` | yes | yes | yes | `cluster.open-cluster-management.io/backup` label |
| ConfigMap `dr-lab-unlabeled` | yes | **no** | **no** | plain core object, no label |
| ConfigMap `dr-lab-after-backup` (module 4) | yes | - | **no** | created after the last backup (RPO) |
| ManagedCluster `$SPOKE_NAME` | yes, Available | **no** | yes, Available | managed-clusters backup + MSA auto-import |
| `local-cluster` | yes | yes, HUB2 itself | yes, HUB2 itself | never backed up, each hub has its own |

## Checkpoint

- [ ] Policy `dr-lab-marker` Compliant on HUB1
- [ ] Spoke has ConfigMap `dr-lab-marker` with `managed-by-hub: hub1`
- [ ] Klusterlet server noted (HUB1)
