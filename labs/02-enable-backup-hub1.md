# 02 - Enable backup on HUB1

Doc sections: "Enabling the backup and restore operator", "Creating a DataProtectionApplication",
"Scheduling a cluster backup", "Automatically connecting clusters by using a Managed Service Account".

## 1. Enable the `cluster-backup` component

*Acronyms: OADP = OpenShift API for Data Protection, STS = Security Token Service, AWS = Amazon Web Services.*

This installs the backup controller **and** OADP in `open-cluster-management-backup`.

```bash
MCH=$(oc --context $HUB1 get multiclusterhub -n $ACM_NS -o jsonpath='{.items[0].metadata.name}')
IDX=$(oc --context $HUB1 get multiclusterhub $MCH -n $ACM_NS -o json \
  | jq '.spec.overrides.components | map(.name) | index("cluster-backup")')
echo "MCH=$MCH cluster-backup index=$IDX"

if [ "$IDX" = "null" ]; then
  oc --context $HUB1 patch multiclusterhub $MCH -n $ACM_NS --type json \
    -p '[{"op":"add","path":"/spec/overrides/components/-","value":{"name":"cluster-backup","enabled":true}}]'
else
  oc --context $HUB1 patch multiclusterhub $MCH -n $ACM_NS --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/overrides/components/$IDX/enabled\",\"value\":true}]"
fi
```

Wait for OADP and the backup controller:

```bash
oc --context $HUB1 get csv -n $BKP_NS -w
# oadp-operator...   Succeeded   (Ctrl+C)
```

```bash
oc --context $HUB1 get pods -n $BKP_NS
# cluster-backup-chart-clusterbackup-*  and  openshift-adp-controller-manager-*  Running
```

> AWS STS clusters: OADP is not installed automatically. Install it manually first (doc 1.1.9).

## 2. Make sure ManagedServiceAccount is on

Needed for `useManagedServiceAccount: true`. It is a `MultiClusterEngine` component:

```bash
oc --context $HUB1 get multiclusterengine \
  -o jsonpath='{.items[0].spec.overrides.components[?(@.name=="managedserviceaccount")].enabled}{"\n"}'
```

If it prints `false`:

```bash
MCE=$(oc --context $HUB1 get multiclusterengine -o jsonpath='{.items[0].metadata.name}')
IDX=$(oc --context $HUB1 get multiclusterengine $MCE -o json \
  | jq '.spec.overrides.components | map(.name) | index("managedserviceaccount")')
oc --context $HUB1 patch multiclusterengine $MCE --type json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/overrides/components/$IDX/enabled\",\"value\":true}]"
```

## 3. S3 credentials and DataProtectionApplication

*Acronyms: S3 = Amazon Simple Storage Service (object storage protocol), DPA = DataProtectionApplication, TLS = Transport Layer Security, AWS = Amazon Web Services.*

```bash
cat > /tmp/credentials-velero <<EOF
[default]
aws_access_key_id=${S3_ACCESS_KEY}
aws_secret_access_key=${S3_SECRET_KEY}
EOF

oc --context $HUB1 create secret generic cloud-credentials -n $BKP_NS \
  --from-file=cloud=/tmp/credentials-velero

envsubst < manifests/common/dpa.yaml.tpl | oc --context $HUB1 apply -f -
```

> AWS S3 (not MinIO): remove the `s3Url`, `s3ForcePathStyle` and `insecureSkipTLSVerify` lines from
> the rendered DPA.

Wait for velero and the storage location:

```bash
oc --context $HUB1 get pods -n $BKP_NS -l app.kubernetes.io/name=velero
# velero-*   1/1   Running
```

```bash
oc --context $HUB1 get backupstoragelocation.velero.io -n $BKP_NS
# NAME        PHASE       ...
# dpa-acm-1   Available
```

`Unavailable` here means endpoint, credentials, bucket or TLS. See
[troubleshooting](09-troubleshooting.md#bsl-unavailable). Do not continue until `Available`.

## 4. Create the BackupSchedule

```bash
envsubst < manifests/common/backupschedule.yaml.tpl | oc --context $HUB1 apply -f -
oc --context $HUB1 get backupschedule.cluster.open-cluster-management.io -n $BKP_NS
# schedule-acm-msa   Enabled   Velero schedules are enabled
```

The controller creates velero `Schedule` objects, which run a first backup immediately:

```bash
oc --context $HUB1 get schedule.velero.io -n $BKP_NS
# acm-credentials-schedule, acm-managed-clusters-schedule, acm-resources-schedule,
# acm-resources-generic-schedule, acm-validation-policy-schedule
```

```bash
oc --context $HUB1 get backup.velero.io -n $BKP_NS -w
# one backup per schedule, PHASE Completed (Ctrl+C)
```

## 5. Make sure the backup holds an auto-import token

*Acronyms: MSA = ManagedServiceAccount.*

Needed for the **active** scenario (cluster import). The passive scenario does not use the token, but
checking it now costs nothing.

The MSA token for the spoke is created **after** the schedule is enabled, asynchronously. A backup
taken before the token exists cannot auto-import that cluster (doc: "A backup taken without a token
cannot auto-import that cluster").

The MSA exists:

```bash
oc --context $HUB1 get managedserviceaccount -n $SPOKE_NAME auto-import-account
# auto-import-account   ...
```

Its token secret exists and carries the backup label:

```bash
oc --context $HUB1 get secret -n $SPOKE_NAME auto-import-account \
  --show-labels | grep cluster.open-cluster-management.io/backup
# auto-import-account ... cluster.open-cluster-management.io/backup=...
```

Compare the token creation time with the latest managed-clusters backup. Token time:

```bash
oc --context $HUB1 get secret -n $SPOKE_NAME auto-import-account -o jsonpath='{.metadata.creationTimestamp}{"\n"}'
# <token time>, e.g. 2026-10-15T20:26:10Z
```

Latest managed-clusters backup start time:

```bash
oc --context $HUB1 get backup.velero.io -n $BKP_NS -l velero.io/schedule-name=acm-managed-clusters-schedule \
  --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,STARTED:.status.startTimestamp | tail -n1
# acm-managed-clusters-schedule-<ts>   <must be later than the token time>
```

If the backup is **older** than the token, either wait for the next hourly run, or force one by
switching the schedule to every 5 minutes:

```bash
oc --context $HUB1 patch backupschedule.cluster.open-cluster-management.io schedule-acm-msa -n $BKP_NS \
  --type merge -p '{"spec":{"veleroSchedule":"*/5 * * * *"}}'
# re-run the backup start time command above until it is later than the token time
```

Then put the cron back:

```bash
oc --context $HUB1 patch backupschedule.cluster.open-cluster-management.io schedule-acm-msa -n $BKP_NS \
  --type merge -p "{\"spec\":{\"veleroSchedule\":\"$BACKUP_CRON\"}}"
```

## 6. Verify

```bash
scripts/hub-status.sh $HUB1
```

Look at the bucket too, it shows what HUB2 will see:

```bash
labs3 ls s3://$S3_BUCKET/$S3_PREFIX/backups/
#  PRE acm-credentials-schedule-20261015100000/
#  PRE acm-managed-clusters-schedule-20261015100000/
#  ...  one folder per velero backup
```

## Checkpoint

*Acronyms: BSL = BackupStorageLocation.*

- [ ] BSL `dpa-acm-1` Available
- [ ] `schedule-acm-msa` phase `Enabled`
- [ ] Latest backup of each `acm-*` schedule `Completed`
- [ ] `auto-import-account` secret exists for the spoke and is older than the latest `acm-managed-clusters-schedule` backup
- [ ] Policy `backup-restore-enabled` Compliant (give it a few minutes; any violation explains what is wrong)
