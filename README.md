# hyve-capi-module

A [hyve](https://github.com/cbridges1/hyve) driver module for Kubernetes
clusters built by [Cluster API](https://cluster-api.sigs.k8s.io/) from a
ClusterClass, on any provider Cluster API supports. hyve creates, scales,
upgrades, deletes, and authenticates to them by driving `Cluster` objects
on a CAPI management cluster with `kubectl`; CAPI's controllers do the
machine-level work.

Nothing in it is tied to one installation: each template or cluster says
which management cluster and ClusterClass to use.

## Quick start

On an existing management cluster that hyve knows as `capi-mgmt`, with a
ClusterClass `my-class` installed in `capi-clusters`:

```yaml
apiVersion: hyve.io/v1alpha1
kind: Template
metadata:
  name: aws-small
spec:
  driver:
    source: github.com/cbridges1/hyve-capi-module
    version: v0.2.0
  mgmtCluster: capi-mgmt
  params:
    cluster_class: my-class
    kubernetes_version: v1.34.8
    control_plane_count: "3"
    worker_count: "2"
    variables: "region=us-east-1;instanceType=t3.large"
```

Locally or in a pipeline, with no management cluster at all — the module
makes a kind cluster, installs Cluster API and the Docker provider, applies
the reference ClusterClass, and builds a cluster of Docker containers:

```yaml
spec:
  driver:
    source: github.com/cbridges1/hyve-capi-module
    version: v0.2.0
  params:
    management: kind
    providers: docker
    flavor: capd
    cluster_class_path: <path to this repo>/clusterclasses/capd
```

## The management cluster

`params.management` picks where the cluster's CAPI objects live:

| `management` | Management cluster | Where it works |
|---|---|---|
| `hyve` (default) | The hyve cluster named by the template's or cluster's `spec.mgmtCluster` (`hyve template create --mgmt-cluster`); hyve passes its kubeconfig as `HYVE_MGMT_KUBECONFIG` | Local and cluster mode |
| `kubeconfig` | The cluster in the kubeconfig file at `params.mgmt_kubeconfig` | Local mode, pipelines |
| `kind` | A kind cluster on this machine, `params.kind_cluster` (default `hyve-capi`), created by the first `create` | Local mode, pipelines — needs Docker, `kind`, and `clusterctl` |

The management cluster needs Cluster API (with `CLUSTER_TOPOLOGY=true`),
the providers your ClusterClass uses, and the ClusterClass itself in
`params.namespace` (default `capi-clusters`). Under `hyve` and
`kubeconfig` you install those; under `kind` the module does:

- `params.providers` — clusterctl infrastructure providers, comma-separated
  (`docker`, `gcp`, `aws`, `azure`, …), each optionally pinned
  (`docker:v1.12.7`). Only missing ones are installed.
- `params.capi_version` — the Cluster API version (core and kubeadm
  providers, e.g. `v1.12.7`); unset, `clusterctl` installs the latest. Pin
  it in pipelines.
  Credentials come from the environment the way `clusterctl init` expects
  (e.g. `GCP_B64ENCODED_CREDENTIALS`, `AWS_B64ENCODED_CREDENTIALS`);
  `params.init_env` (`KEY=VALUE;…`) adds anything else, such as
  `EXP_CAPG_GKE=true`.
- `params.cluster_class_path` — ClusterClass manifests (file, directory, or
  URL), applied on every create. Usable under any `management` mode.

The kind cluster is persistent and shared by every cluster that names it,
because it holds their CAPI objects: delete it while a cloud cluster is up
and that cluster is orphaned (still running, no longer managed). Set
`params.kind_cleanup: "true"` to delete it automatically once its last
Cluster is gone — for pipelines that create and tear down.

The module never edits `~/.kube/config`; the kind cluster's kubeconfig is
fetched fresh for each operation (`kind get kubeconfig --name <name>`).

## The cluster

| Param | Default | |
|---|---|---|
| `cluster_class` | by `flavor` | Required otherwise. Fixed at create |
| `kubernetes_version` | by `flavor` | Required otherwise |
| `worker_count` | `1` | Replicas of the one worker (`md-0` or `mp-0`) |
| `worker_type` | `machineDeployment` | Or `machinePool`, matching how the ClusterClass defines workers |
| `worker_class` | `default-worker` | The ClusterClass's worker class |
| `control_plane_count` | by `flavor` | For a machine-based control plane; unset for a managed one |
| `variables` | | Topology variables, `name=value;name=value` — values are raw YAML (`e2-small`, `3`, `[a, b]`, `{k: v}`) |
| `labels` | by `flavor` | Cluster labels, `key=value,…` (e.g. to match a ClusterResourceSet) |
| `pod_cidr`, `service_cidr` | by `flavor` | `spec.clusterNetwork`, if the ClusterClass needs it |
| `namespace` | `capi-clusters` | Fixed at create |

`flavor` fills in defaults for the reference ClusterClasses in
`clusterclasses/` — every one can still be set explicitly:

| `flavor` | ClusterClass | Defaults |
|---|---|---|
| `capd` | `clusterclasses/capd` — Docker nodes (CAPD), kubeadm control plane, flannel via a ClusterResourceSet | `v1.34.8`, 1 control plane, label `cni=flannel`, pod CIDR `10.244.0.0/16`, the relay address in `extraCertSANs` |
| `gke` | `clusterclasses/gke` — managed GKE (CAPG), one MachinePool | `v1.35.8`, `worker_type: machinePool`, `machineType` from `params.machine_type` (default `e2-medium`). Also set `variables: "project=…;location=…;region=…"` |

## Reaching the API server

`auth` writes CAPI's admin kubeconfig (Secret `<name>-kubeconfig`).
`params.api_access` decides how hyve and kubectl reach the API server:

- `direct` — the endpoint as CAPI reports it (public endpoints: GKE, EKS, …).
- `nodeport` — a NodePort relay on the management cluster (a selector-less
  Service plus EndpointSlice, owned by the Cluster), for an endpoint only
  its nodes can route to, such as CAPD on a remote Docker host. Reached at
  `params.api_host` (default the management cluster's first node IP).
- `docker` — the port Docker publishes on this machine for CAPD's load
  balancer container, under `management: kind`.
- `auto` (default) — `direct` for a public endpoint; for a private one,
  `docker` under `management: kind`, else `nodeport`.

Through a relay the kubeconfig keeps verifying the certificate against the
original endpoint (`tls-server-name`), so no extra certificate names are
needed.

## Operations

| Op | What it does |
|---|---|
| `create` | (`kind`: makes sure the kind cluster, Cluster API, and providers exist.) Applies `cluster_class_path` if set, then a `Cluster` with `spec.topology` from the params. Returns immediately |
| `status` | `NOT_FOUND` / `CREATING` / `UPDATING` / `ACTIVE` / `DELETING` / `FAILED` from the Cluster's conditions — ACTIVE needs `Available` with nothing in flight. An unreachable management cluster is an error, never `NOT_FOUND` |
| `scale` | Any param change: one patch of the topology — version (an upgrade), replicas, variables. The class stays |
| `auth` | Writes the cluster's kubeconfig, through a relay when needed (above) |
| `delete` | Deletes the Cluster and waits (up to 14 min, under cluster mode's 15-minute Job deadline) until it's gone |

## Tested

2026-10-04, hyve with `spec.mgmtCluster` support:

- `management: kind` end to end on macOS (Docker Desktop, kind v0.32,
  clusterctl v1.12.7): created the kind cluster, installed Cluster API and
  the Docker provider, applied `clusterclasses/capd`, built a capd cluster
  (ACTIVE in about a minute), reached it via `api_access: docker`, scaled
  it to two workers, deleted it, and `kind_cleanup` removed the kind
  cluster.
- `management: hyve` against a CAPI v1.12.7 management cluster with CAPG:
  `status`; a flavor gke Cluster rendered by `create` passes a server-side
  dry run against the gke ClusterClass; both reference ClusterClasses pass
  one too.

Not yet run: a real GKE cluster from `clusterclasses/gke`, and the
`nodeport` relay since the move to `tls-server-name`.

## Developing

The operation files (`create.yaml`, …) are generated — hyve runs each op as
a standalone script (in cluster mode, inside a Job), so they can't share a
file, and the shared blocks are inlined. Edit `gen/connect.sh` (finding the
management cluster), `gen/spec.sh` (params to the desired topology), or
`gen/ops/*.sh`, then:

```sh
python3 gen/gen.py .
```
