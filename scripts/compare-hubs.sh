#!/usr/bin/env bash
# Diff the ACM objects that matter between two hubs (names only, not content).
# Usage: scripts/compare-hubs.sh <ctx-a> <ctx-b>
set -uo pipefail

A=${1:?usage: $0 <ctx-a> <ctx-b>}
B=${2:?usage: $0 <ctx-a> <ctx-b>}

# "resource|label-selector"  (empty selector = everything)
CHECKS=(
  "managedclusters.cluster.open-cluster-management.io|"
  "managedclustersets.cluster.open-cluster-management.io|"
  "managedclustersetbindings.cluster.open-cluster-management.io|"
  "placements.cluster.open-cluster-management.io|"
  "placementbindings.policy.open-cluster-management.io|"
  "policies.policy.open-cluster-management.io|!policy.open-cluster-management.io/root-policy"
  "policysets.policy.open-cluster-management.io|"
  "channels.apps.open-cluster-management.io|"
  "subscriptions.apps.open-cluster-management.io|"
  "applications.app.k8s.io|"
  "gitopsclusters.apps.open-cluster-management.io|"
  "applicationsets.argoproj.io|"
  "klusterletaddonconfigs.agent.open-cluster-management.io|"
  "clusterdeployments.hive.openshift.io|"
  "secrets|cluster.open-cluster-management.io/type"
  "configmaps|cluster.open-cluster-management.io/backup"
)

list() {
  local ctx=$1 res=$2 sel=$3
  oc --context "$ctx" get "$res" -A ${sel:+-l "$sel"} --no-headers \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null | sort
}

printf '%-62s %6s %6s  %s\n' "RESOURCE" "$A" "$B" "RESULT"
for c in "${CHECKS[@]}"; do
  res=${c%%|*}; sel=${c#*|}
  la=$(list "$A" "$res" "$sel"); lb=$(list "$B" "$res" "$sel")
  na=$(grep -c . <<<"$la"); nb=$(grep -c . <<<"$lb")
  if [[ "$la" == "$lb" ]]; then r="same"; else r="DIFF"; fi
  printf '%-62s %6s %6s  %s\n' "$res${sel:+ [$sel]}" "$na" "$nb" "$r"
  if [[ $r == DIFF ]]; then
    diff <(echo "$la") <(echo "$lb") | grep '^[<>]' | sed "s/^</    only in $A:/; s/^>/    only in $B:/"
  fi
done
