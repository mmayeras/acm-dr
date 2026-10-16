# ACM operator on HUB2, pinned to the exact CSV running on HUB1.
# Manual approval: OLM must not jump to a newer z-stream than HUB1 (restore to an older
# ACM is unsupported, and mismatched versions are untested territory).
# Render with: envsubst < manifests/hub2/acm-operator.yaml.tpl | oc --context "$HUB2" apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${ACM_NS}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: open-cluster-management
  namespace: ${ACM_NS}
spec:
  targetNamespaces:
    - ${ACM_NS}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: ${ACM_NS}
spec:
  name: advanced-cluster-management
  channel: ${ACM_CHANNEL}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
  startingCSV: ${ACM_CSV}
