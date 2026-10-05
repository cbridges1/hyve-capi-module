@CONNECT@

if [ "$mgmt_missing" = true ]; then
  echo "⚠️  kind management cluster $kind_name doesn't exist, so neither does $ns/$name's Cluster — if it was deleted while this cluster was up, its cloud resources are orphaned and need removing by hand"
  exit 0
fi

cluster_exists() {
  if out=$(mk get "$cluster_res" "$name" -o name 2>&1); then
    return 0
  fi
  case "$out" in
    *NotFound*|*"not found"*) return 1 ;;
  esac
  echo "Error: can't read Cluster $ns/$name from the management cluster: $out" >&2
  exit 1
}

if cluster_exists; then
  mk delete "$cluster_res" "$name" --wait=false
  limit=840
  waited=0
  while cluster_exists; do
    if [ "$waited" -ge "$limit" ]; then
      echo "Error: $ns/$name still deleting after ${limit}s — hyve will keep checking until it's gone" >&2
      exit 1
    fi
    sleep 10
    waited=$((waited + 10))
  done
  echo "✅ Cluster $ns/$name deleted"
else
  echo "Cluster $ns/$name already gone"
fi

# params.kind_cleanup: true deletes the kind management cluster once it
# holds no Clusters at all — for pipelines that create and tear down.
if [ "$management" = kind ] && [ "$HYVE_PARAM_KIND_CLEANUP" = true ]; then
  remaining=$(kubectl --kubeconfig "$mgmt_kc" get "$cluster_res" -A -o name 2>/dev/null | wc -l | tr -d ' ')
  if [ "$remaining" = 0 ]; then
    echo "No Clusters left — deleting kind management cluster $kind_name"
    kind delete cluster --name "$kind_name"
  fi
fi
