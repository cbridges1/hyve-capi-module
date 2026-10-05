@CONNECT@

if [ "$mgmt_missing" = true ]; then
  # No kind management cluster yet, so no Cluster in it either.
  echo "HYVE_CLUSTER_STATUS=NOT_FOUND"
  exit 0
fi

if out=$(mk get "$cluster_res" "$name" -o name 2>&1); then
  :
else
  case "$out" in
    *NotFound*|*"not found"*) echo "HYVE_CLUSTER_STATUS=NOT_FOUND"; exit 0 ;;
  esac
  echo "Error: can't read Cluster $ns/$name from the management cluster: $out" >&2
  exit 1
fi

cond() { printf '{.status.conditions[?(@.type=="%s")].%s}' "$1" "${2:-status}"; }
jp="{.metadata.deletionTimestamp}|{.status.phase}|{.metadata.generation}|{.status.observedGeneration}"
for c in Available ControlPlaneAvailable RollingOut ScalingUp ScalingDown TopologyReconciled; do
  jp="$jp|$(cond "$c")"
done
jp="$jp|$(cond TopologyReconciled reason)"
fields=$(mk get "$cluster_res" "$name" -o jsonpath="$jp")
IFS='|' read -r deleting phase generation observed available cp_available rolling scaling_up scaling_down topology topology_reason <<FIELDS
$fields
FIELDS
echo "phase=${phase:-none} available=${available:-unknown} topology=${topology:-unknown}/${topology_reason:-none} rollingOut=${rolling:-unknown}"

in_flight=false
if [ -n "$observed" ] && [ "$generation" != "$observed" ]; then in_flight=true; fi
if [ "$topology" = "False" ] || [ "$rolling" = "True" ] || [ "$scaling_up" = "True" ] || [ "$scaling_down" = "True" ]; then in_flight=true; fi

if [ -n "$deleting" ]; then
  echo "HYVE_CLUSTER_STATUS=DELETING"
elif [ "$phase" = "Failed" ]; then
  echo "HYVE_CLUSTER_STATUS=FAILED"
elif [ "$in_flight" = "true" ] && [ "$cp_available" = "True" ]; then
  echo "HYVE_CLUSTER_STATUS=UPDATING"
elif [ "$available" = "True" ] && [ "$in_flight" = "false" ]; then
  echo "HYVE_CLUSTER_STATUS=ACTIVE"
else
  echo "HYVE_CLUSTER_STATUS=CREATING"
fi
