# DataProtectionApplication for ACM hub backups (resources only, no volume snapshots).
# Render with: envsubst < manifests/common/dpa.yaml.tpl | oc --context <hub> apply -f -
# Identical on HUB1 and HUB2: same bucket, same prefix.
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-acm
  namespace: ${BKP_NS}
spec:
  backupImages: false            # hub backups are API objects only, no internal registry needed
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - aws                    # aws plugin = any S3-compatible endpoint
    nodeAgent:
      enable: false              # no PV data to back up on a hub
      uploaderType: kopia
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${S3_BUCKET}
          prefix: ${S3_PREFIX}
        config:
          region: ${S3_REGION}
          s3ForcePathStyle: "true"
          s3Url: ${S3_URL}
          insecureSkipTLSVerify: "${S3_INSECURE}"
        credential:
          name: cloud-credentials
          key: cloud
