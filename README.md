# hyve-capi-module

A [hyve](https://github.com/cbridges1/hyve) driver module for Kubernetes
clusters built by [Cluster API](https://cluster-api.sigs.k8s.io/) from a
ClusterClass. hyve creates, scales, upgrades, deletes, and authenticates to
them by driving `Cluster` objects on a CAPI management cluster with
`kubectl`; CAPI's own controllers do the machine-level work.

Reference from a cluster definition as:

```yaml
spec:
  driver:
    source: github.com/cbridges1/hyve-capi-module
    version: latest
  dependsOn:
    - unraid-k3s          # the management cluster — wait for it first
  params:
    flavor: gke
    worker_count: "1"
```

## Flavors

| `flavor` | Clusters | ClusterClass it expects |
|---|---|---|
| `capd` (default) | Docker containers on the management node (CAPD): kubeadm control plane, MachineDeployment workers, flannel CNI, reached through a NodePort relay | `capd` |
| `gke` | Managed GKE (CAPG, experimental GKE support): MachinePool workers, GKE's own CNI and public endpoint | `gke` |

## The management cluster

`module.yaml`'s `requirements.mgmtCluster` names the hyve cluster that runs
Cluster API — `unraid-k3s`. hyve gives every op `HYVE_MGMT_KUBECONFIG`, a
kubeconfig for it (that cluster's own auth kubeconfig, or a freshly minted
one when hyve itself runs on it). It isn't a param: a management cluster
with another name needs a fork or a different version of this module.

It must have, in the `namespace` param's namespace (default `capi-clusters`):

- **`capd`:** CAPI core with ClusterTopology on, the kubeadm bootstrap and
  control-plane providers, the Docker provider (which needs the node's
  Docker socket), a `capd` ClusterClass with one `default-worker`
  MachineDeployment class and an `extraCertSANs` (string array) variable,
  and a ClusterResourceSet that installs a CNI on Clusters labeled
  `cni: flannel` (pod CIDR `10.244.0.0/16`).
- **`gke`:** the GCP provider with its GKE and MachinePool features on, and
  a `gke` ClusterClass with one `default-worker` MachinePool class and a
  `machineType` (string) variable.

The reference setup — Rancher Turtles `CAPIProvider`s, both ClusterClasses,
and the flannel ClusterResourceSet — is `argo/capi/` in
nexus-configuration.

## Operations

| Op | What it does |
|---|---|
| `create` | Applies a `Cluster` with `spec.topology` (ClusterClass, version, worker count). `capd`: control plane count, the `cni: flannel` label, and the management node's IP baked into the API server certificate. `gke`: MachinePool workers and the `machineType` variable. Returns immediately. |
| `status` | `NOT_FOUND` / `CREATING` / `UPDATING` / `ACTIVE` / `DELETING` / `FAILED` from the Cluster's conditions — ACTIVE needs `Available` with nothing in flight (not just phase `Provisioned`). An unreachable management cluster is an error, never `NOT_FOUND`. |
| `scale` | Any param change: one patch of the topology's version (an upgrade) and worker count — plus control plane count (`capd`) or machine type (`gke`). |
| `auth` | Writes CAPI's admin kubeconfig (Secret `<name>-kubeconfig`). If the API endpoint is a private address (CAPD's, on the management node's Docker network, which only the node can route to), it first creates a NodePort relay on the management cluster — a selector-less Service plus EndpointSlice, owned by the Cluster — and points the kubeconfig at `<node IP>:<nodePort>`. A public endpoint (GKE) is used as is. |
| `delete` | Deletes the Cluster and waits (up to 14 min, under cluster mode's 15-minute Job deadline) until it's gone; the relay goes with it. |

## Params

| Param | Default | |
|---|---|---|
| `flavor` | `capd` | `capd` or `gke`. Fixed at create |
| `kubernetes_version` | `v1.34.8` (capd), `v1.35.8` (gke) | capd: a `kindest/node` tag must exist. gke: a version GKE's channel offers |
| `worker_count` | `1` | capd's `md-0` MachineDeployment or gke's `mp-0` MachinePool |
| `control_plane_count` | `1` | capd only |
| `machine_type` | `e2-medium` | gke only |
| `cluster_class` | by flavor | Fixed at create |
| `namespace` | `capi-clusters` | Fixed at create |
| `api_host` | management node IP | capd only. Fixed at create (it's in the certificate) |

## Tested

Against a kind management cluster with CAPI v1.12.7 (2026-09-30/10-01):
capd end-to-end — create, status, auth (relay + TLS), scale up/down, an
upgrade v1.34.8 → v1.35.5, delete. gke as far as it goes without GCP
credentials — the ClusterClass and the module's Cluster validate, and the
topology controller produces the right GKE objects; CAPG then fails on the
dummy credentials. Not yet run against real GCP.

## Notes

- Moved out of nexus-configuration's `modules/capi/` into its own repo so
  it's a git-sourced module, which cluster-mode hyve can use (it doesn't
  resolve paths inside a consuming repo).
- Each op inlines its own setup instead of sourcing a shared file — hyve
  runs a module's scripts with the consuming repo's root as the working
  directory.
- CAPD is a development provider; GKE support in CAPG is experimental.
