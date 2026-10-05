set -e
@CONNECT@

if [ "$mgmt_missing" = true ]; then
  echo "Error: kind management cluster $kind_name doesn't exist" >&2
  exit 1
fi

endpoint=$(mk get "$cluster_res" "$name" -o jsonpath='{.spec.controlPlaneEndpoint.host}')
endpoint_port=$(mk get "$cluster_res" "$name" -o jsonpath='{.spec.controlPlaneEndpoint.port}')
uid=$(mk get "$cluster_res" "$name" -o jsonpath='{.metadata.uid}')
if [ -z "$endpoint" ] || [ -z "$endpoint_port" ]; then
  echo "Error: $ns/$name has no control plane endpoint yet" >&2
  exit 1
fi

# params.api_access — how to reach the API server:
#   direct — the endpoint as CAPI reports it (a public one, e.g. GKE)
#   nodeport — a NodePort relay on the management cluster, for an
#     endpoint only its nodes can route to (CAPD on a remote Docker host)
#   docker — the port Docker publishes on this machine for the cluster's
#     load balancer container (CAPD under a local kind cluster)
#   auto (default) — direct for a public endpoint; for a private one,
#     docker under management: kind, else nodeport
access="${HYVE_PARAM_API_ACCESS:-auto}"
if [ "$access" = auto ]; then
  case "$endpoint" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
      if [ "$management" = kind ]; then access=docker; else access=nodeport; fi ;;
    *) access=direct ;;
  esac
fi

server=""
case "$access" in
  direct) ;;
  nodeport)
    mk apply -f - <<RELAY
apiVersion: v1
kind: Service
metadata:
  name: $name-apiserver
  namespace: $ns
  labels:
    app.kubernetes.io/managed-by: hyve
  ownerReferences:
    - apiVersion: cluster.x-k8s.io/v1beta2
      kind: Cluster
      name: $name
      uid: $uid
spec:
  type: NodePort
  ports:
    - name: https
      port: $endpoint_port
      targetPort: $endpoint_port
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: $name-apiserver
  namespace: $ns
  labels:
    kubernetes.io/service-name: $name-apiserver
    endpointslice.kubernetes.io/managed-by: hyve.io
    app.kubernetes.io/managed-by: hyve
  ownerReferences:
    - apiVersion: cluster.x-k8s.io/v1beta2
      kind: Cluster
      name: $name
      uid: $uid
addressType: IPv4
ports:
  - name: https
    port: $endpoint_port
    protocol: TCP
endpoints:
  - addresses: ["$endpoint"]
RELAY
    node_port=$(mk get service "$name-apiserver" -o jsonpath='{.spec.ports[0].nodePort}')
    api_host="${HYVE_PARAM_API_HOST:-$HYVE_CAPI_API_HOST}"
    if [ -z "$api_host" ]; then
      api_host=$(kubectl --kubeconfig "$mgmt_kc" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    fi
    server="https://$api_host:$node_port" ;;
  docker)
    published=$(docker port "$name-lb" "$endpoint_port/tcp" 2>/dev/null | head -n 1)
    if [ -z "$published" ]; then
      echo "Error: no published port for container $name-lb — params.api_access: docker expects CAPD's load balancer container on this machine" >&2
      exit 1
    fi
    server="https://127.0.0.1:${published##*:}" ;;
  *)
    echo "Error: params.api_access must be auto, direct, nodeport, or docker (got '$access')" >&2
    exit 1 ;;
esac

fetched=$(mktemp)
mk get secret "$name-kubeconfig" -o jsonpath='{.data.value}' | base64 -d > "$fetched"
if [ -n "$server" ]; then
  # Connect through the relay, but verify the certificate against the
  # endpoint it was issued for.
  kubectl --kubeconfig "$fetched" config set-cluster "$name" --server="$server" --tls-server-name="$endpoint" >/dev/null
fi
# CAPI names the context <name>-admin@<name>; name it after the cluster so
# merged kubeconfigs stay readable.
ctx=$(kubectl --kubeconfig "$fetched" config current-context)
if [ "$ctx" != "$name" ]; then
  kubectl --kubeconfig "$fetched" config rename-context "$ctx" "$name" >/dev/null
fi
mv "$fetched" "$KUBECONFIG"
echo "✅ Kubeconfig for $name → $(kubectl --kubeconfig "$KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
