@CONNECT@

if [ "$management" = kind ]; then
  # A persistent kind cluster on this machine, made once and reused —
  # it holds every cluster's CAPI objects, so deleting it orphans them.
  if [ "$mgmt_missing" = true ]; then
    kind_cfg=$(mktemp)
    # The Docker socket mount lets CAPD (Docker nodes) run from it.
    cat > "$kind_cfg" <<KIND
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock
KIND
    echo "Creating kind management cluster $kind_name..."
    mgmt_kc=$(mktemp)
    # --kubeconfig: never touch the user's own ~/.kube/config.
    kind create cluster --name "$kind_name" --config "$kind_cfg" --kubeconfig "$mgmt_kc" ${HYVE_PARAM_KIND_NODE_IMAGE:+--image "$HYVE_PARAM_KIND_NODE_IMAGE"}
  fi

  # Cluster API plus params.providers (clusterctl infrastructure
  # providers, comma-separated: docker, gcp, aws, azure, ... — each
  # optionally pinned, docker:v1.12.7), installing only what's missing.
  # params.capi_version pins Cluster API itself (core and kubeadm); unset,
  # clusterctl installs the latest. Provider credentials come from the environment
  # the way clusterctl expects (e.g. GCP_B64ENCODED_CREDENTIALS);
  # params.init_env ("KEY=VALUE;...") adds anything else clusterctl
  # needs, such as a provider's feature flags.
  if ! command -v clusterctl >/dev/null 2>&1; then
    echo "Error: management: kind needs clusterctl on PATH to install Cluster API" >&2
    exit 1
  fi
  providers="$HYVE_PARAM_PROVIDERS"
  installed=$(kubectl --kubeconfig "$mgmt_kc" get providers.clusterctl.cluster.x-k8s.io -A \
    -o jsonpath='{range .items[*]}{.type}/{.providerName}{"\n"}{end}' 2>/dev/null || true)
  missing=""
  for provider in $(printf '%s' "$providers" | tr ',' ' '); do
    if ! printf '%s\n' "$installed" | grep -qx "InfrastructureProvider/${provider%%:*}"; then
      missing="${missing:+$missing,}$provider"
    fi
  done
  if [ -n "$missing" ] || ! printf '%s\n' "$installed" | grep -q '^CoreProvider/'; then
    if [ -z "$providers" ]; then
      echo "Error: management: kind needs params.providers — the clusterctl infrastructure providers to install (e.g. docker, gcp)" >&2
      exit 1
    fi
    export CLUSTER_TOPOLOGY=true EXP_MACHINE_POOL=true
    old_ifs=$IFS; IFS=';'
    for kv in $HYVE_PARAM_INIT_ENV; do
      IFS=$old_ifs
      if [ -n "$kv" ]; then export "$kv"; fi
      IFS=';'
    done
    IFS=$old_ifs
    echo "Installing Cluster API on $kind_name (infrastructure: ${missing:-$providers})..."
    pin=""
    if [ -n "$HYVE_PARAM_CAPI_VERSION" ]; then
      v="$HYVE_PARAM_CAPI_VERSION"
      pin="--core cluster-api:$v --bootstrap kubeadm:$v --control-plane kubeadm:$v"
    fi
    # shellcheck disable=SC2086 # $pin is several flags
    clusterctl init --kubeconfig "$mgmt_kc" $pin --infrastructure "${missing:-$providers}" --wait-providers
  fi
fi

if ! kubectl --kubeconfig "$mgmt_kc" get namespace "$ns" >/dev/null 2>&1; then
  kubectl --kubeconfig "$mgmt_kc" create namespace "$ns"
fi
# params.cluster_class_path: ClusterClass manifests (a file, a directory,
# or a URL — relative paths from the repository hyve runs in) applied on
# every create, so a fresh management cluster (kind) has them.
# Retried: right after clusterctl init, the providers' admission webhooks
# can take a minute to start serving.
if [ -n "$HYVE_PARAM_CLUSTER_CLASS_PATH" ]; then
  tries=0
  until kubectl --kubeconfig "$mgmt_kc" apply -n "$ns" -R -f "$HYVE_PARAM_CLUSTER_CLASS_PATH"; do
    tries=$((tries + 1))
    if [ "$tries" -ge 12 ]; then
      echo "Error: couldn't apply $HYVE_PARAM_CLUSTER_CLASS_PATH after $tries tries" >&2
      exit 1
    fi
    echo "Retrying in 10s (the providers' webhooks may still be starting)..."
    sleep 10
  done
fi

@SPEC@

if ! mk get clusterclasses.v1beta2.cluster.x-k8s.io "$class" -o name >/dev/null 2>&1; then
  echo "Error: ClusterClass $ns/$class not found on the management cluster — install it there, or set params.cluster_class_path" >&2
  exit 1
fi

cluster_file=$(mktemp)
{
  printf 'apiVersion: cluster.x-k8s.io/v1beta2\nkind: Cluster\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    app.kubernetes.io/managed-by: hyve\n' "$name" "$ns"
  # params.labels: "key=value,..." — e.g. for a ClusterResourceSet
  # that installs a CNI on matching clusters (capd's cni=flannel).
  for kv in $(printf '%s' "$labels" | tr ',' ' '); do
    printf '    %s: "%s"\n' "${kv%%=*}" "${kv#*=}"
  done
  printf 'spec:\n'
  if [ -n "$pod_cidr$service_cidr" ]; then
    printf '  clusterNetwork:\n'
    if [ -n "$pod_cidr" ]; then printf '    pods:\n      cidrBlocks: ["%s"]\n' "$pod_cidr"; fi
    if [ -n "$service_cidr" ]; then printf '    services:\n      cidrBlocks: ["%s"]\n' "$service_cidr"; fi
  fi
  cat "$topology_file"
} > "$cluster_file"

echo "Applying Cluster $ns/$name ($class $version, ${cp_count:-managed} control plane, $workers workers)..."
mk apply -f "$cluster_file"
if [ -n "$api_host" ]; then echo "HYVE_CAPI_API_HOST=$api_host"; fi
