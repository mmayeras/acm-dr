# 00 - Prerequisites and contexts

## What you need

*Acronyms: ACM = Advanced Cluster Management, SNO = Single Node OpenShift, CSV = ClusterServiceVersion (installed operator version), S3 = Amazon Simple Storage Service (object storage protocol), MCE = MultiClusterEngine, ODF = OpenShift Data Foundation, CLI = command-line interface, AWS = Amazon Web Services, MCG = Multicloud Object Gateway.*

| Item | Requirement |
|---|---|
| HUB1 | OpenShift with ACM 2.17 running (`MultiClusterHub` phase `Running`), at least one imported managed cluster (the spoke) |
| HUB2 | New SNO cluster, cluster-admin, **no ACM installed**, can pull from `registry.redhat.io` (or your mirror). Size it for an ACM hub: **at least the same vCPU / memory as HUB1** (8 vCPU / 32 GiB worked as HUB1 in this lab; 4 vCPU / 16 GiB is too small: MCE operator stays `Pending`, `Insufficient cpu`) |
| SPOKE | OpenShift cluster imported in HUB1, kubeconfig available (read-only checks) |
| S3 | Bucket reachable from both hubs. MinIO, ODF MCG or AWS S3. Empty prefix for this lab |
| Laptop | `oc`, `jq`, `envsubst` (`brew install gettext`), AWS CLI v2 (`brew install awscli`), optional `yq` |

> HUB2 must run the **exact same ACM version** as HUB1. Restoring onto an older ACM is not supported.
> Module 3 pins the CSV for you.

## Contexts

Log in to each cluster once and rename the context, so every command can use `--context`:

```bash
oc login https://api.<hub1-domain>:6443 -u kubeadmin
oc config rename-context "$(oc config current-context)" hub1

oc login https://api.<hub2-domain>:6443 -u kubeadmin
oc config rename-context "$(oc config current-context)" hub2

oc login https://api.<spoke-domain>:6443 -u kubeadmin
oc config rename-context "$(oc config current-context)" spoke1
```

Then:

```bash
cp env.example.sh env.sh   # edit values
source ./env.sh
chmod +x scripts/*.sh
```

## Pre-flight checks

*Acronyms: ACM = Advanced Cluster Management, SNO = Single Node OpenShift, S3 = Amazon Simple Storage Service (object storage protocol), API = Application Programming Interface, OBC = ObjectBucketClaim, ODF = OpenShift Data Foundation, DR = disaster recovery, MCG = Multicloud Object Gateway, RGW = Ceph object gateway.*

Each context points to the right cluster:

```bash
for c in $HUB1 $HUB2 $SPOKE; do echo "$c -> $(oc --context $c whoami --show-server)"; done
# three different API URLs (hub1 and hub2 must not point to the same cluster)
```

HUB1 ACM healthy and version:

```bash
oc --context $HUB1 get multiclusterhub -A \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,VERSION:.status.currentVersion
# Running   2.17.z
```

HUB2 has no ACM:

```bash
oc --context $HUB2 get csv -A | grep -i advanced-cluster-management || echo "OK: no ACM on HUB2"
# OK: no ACM on HUB2
```

HUB2 at least as big as HUB1:

```bash
for c in $HUB1 $HUB2; do
  oc --context $c get nodes --no-headers \
    -o custom-columns=NODE:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
done
# HUB2 CPU and MEM >= HUB1
```

HUB2 also needs free room (OpenShift alone already requests ~2.3 cores on SNO):

```bash
oc --context $HUB2 describe node | sed -n '/Allocated resources/,/memory/p'
# cpu requests well below 100%
```

Spoke is joined and available on HUB1:

```bash
oc --context $HUB1 get managedcluster $SPOKE_NAME
# JOINED=True AVAILABLE=True
```

HUB2 API reachable from the spoke (throwaway pod on the spoke):

```bash
HUB2_API=$(oc --context $HUB2 whoami --show-server)
oc --context $SPOKE run hub2-probe -n default --rm -i --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
  curl -sk -o /dev/null -w '%{http_code}\n' "$HUB2_API/version"
# Expect 200 (or 401/403). A timeout means the spoke cannot reach HUB2: fix that first.
```

Check S3 from your laptop with the `labs3` wrapper defined in `env.sh` (`aws s3` with the lab
endpoint and credentials):

```bash
aws --version
# aws-cli/2.x
```

Create the bucket if it does not exist yet:

```bash
labs3 ls s3://$S3_BUCKET >/dev/null 2>&1 || labs3 mb s3://$S3_BUCKET
# make_bucket: <bucket>   (or nothing if it already existed)
```

```bash
labs3 ls s3://$S3_BUCKET/$S3_PREFIX/
# prints nothing, exit code 1 = prefix empty (expected)
```

### ODF bucket (ObjectBucketClaim)

An OBC gives you an in-cluster endpoint (`*.svc`). HUB2 is another cluster, so both hubs must use
the **route**, and the route must match the backend the OBC was created on:

| OBC StorageClass | Backend | Route in `openshift-storage` |
|---|---|---|
| `ocs-storagecluster-ceph-rgw` (endpoint `rook-ceph-rgw-...`) | Ceph RGW | `ocs-storagecluster-cephobjectstore-secure` |
| `openshift-storage.noobaa.io` (endpoint `s3.openshift-storage.svc`) | NooBaa / MCG | `s3` |

Wrong pairing = `InvalidAccessKeyId` (the keys exist only on the other backend).

```bash
OBC=<obc-name>; OBC_NS=<obc-namespace>; CTX=<cluster-hosting-the-obc>
oc --context $CTX get configmap $OBC -n $OBC_NS -o jsonpath='{.data.BUCKET_HOST}{" "}{.data.BUCKET_NAME}{"\n"}'
oc --context $CTX get secret $OBC -n $OBC_NS -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d; echo
oc --context $CTX get secret $OBC -n $OBC_NS -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d; echo
oc --context $CTX get route -n openshift-storage \
  -o custom-columns=NAME:.metadata.name,HOST:.spec.host,SVC:.spec.to.name
```

`S3_URL` = `https://<route host>` (scheme required, velero needs it too).

> If the bucket lives on HUB1's own cluster, losing HUB1 also loses the backups. Fine for this lab
> (HUB1 stays up). For real DR, keep the bucket outside both hubs.

With `S3_INSECURE=true`, expect `InsecureRequestWarning` lines on stderr. Harmless. Append
`2>/dev/null` once you trust the setup.

## Inventory of HUB1 add-ons

*Acronyms: ACM = Advanced Cluster Management, AAP = Ansible Automation Platform.*

HUB2 needs the same operators that HUB1 objects depend on (GitOps, Gatekeeper, AAP, etc.), installed
in the same namespaces, **before** restore. List what HUB1 runs:

```bash
oc --context $HUB1 get csv -A --no-headers -o custom-columns=NAME:.metadata.name \
  | sort -u | grep -v -e packageserver
```

Write the list down. Anything ACM-related (for example `openshift-gitops-operator` if you use
`GitOpsCluster`) must be installed on HUB2 in module 3.

## Hive clusters: preserveOnDelete

If HUB1 created clusters itself (Hive), deleting their `ManagedCluster` later would **destroy the real
cluster**. Check now:

```bash
oc --context $HUB1 get clusterdeployment -A \
  -o custom-columns=NAME:.metadata.name,NS:.metadata.namespace,PRESERVE:.spec.preserveOnDelete
```

Any `false` or `<none>` must be patched before module 7:

```bash
oc --context $HUB1 patch clusterdeployment <name> -n <ns> --type merge -p '{"spec":{"preserveOnDelete":true}}'
```

## Checkpoint

*Acronyms: ACM = Advanced Cluster Management, API = Application Programming Interface.*

- [ ] Three contexts work, three different API servers
- [ ] HUB1 ACM `Running`, version noted: `__________`
- [ ] HUB2 has no ACM
- [ ] Spoke `JOINED=True AVAILABLE=True` on HUB1
- [ ] Spoke reaches HUB2 API
- [ ] Bucket exists and prefix is empty
- [ ] Add-on operator list noted, Hive `preserveOnDelete` handled (or no Hive clusters)
