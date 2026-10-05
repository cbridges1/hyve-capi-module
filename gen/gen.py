"""Builds hyve-capi-module's operation files from ops/*.sh, inlining the
shared blocks (connect.sh, spec.sh) — hyve runs each op as a standalone
script (in cluster mode, inside a Job), so they can't source a shared file."""
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1]
connect = open(os.path.join(here, 'connect.sh')).read().rstrip('\n')
spec = open(os.path.join(here, 'spec.sh')).read().rstrip('\n')

def script(op):
    s = open(os.path.join(here, 'ops', op + '.sh')).read().rstrip('\n')
    return s.replace('@CONNECT@', connect).replace('@SPEC@', spec)

def indent(text, n):
    pad = ' ' * n
    return '\n'.join((pad + line) if line else '' for line in text.split('\n'))

header = "# Generated from hyve-capi-module/gen/ by gen.py — edit those, then run `python3 gen/gen.py .`.\n"

workflows = {
    'create': "Applies a topology-managed CAPI Cluster built from a ClusterClass and returns — CAPI provisions it asynchronously, and status reports CREATING until it's Available. Under management: kind it first makes sure the kind management cluster, Cluster API, the requested providers, and the ClusterClasses exist. Idempotent: re-applying an existing Cluster changes nothing (scale owns changes).",
    'status': "Maps the CAPI Cluster's state to hyve's status vocabulary. ACTIVE needs the Cluster's Available condition with no change in flight, not just phase Provisioned (which only means the API endpoint exists). Deleting maps to DELETING, never FAILED — FAILED on a cluster that isn't marked for deletion makes hyve re-run create.",
    'scale': "hyve runs this on any params change, so it re-applies the whole desired topology — kubernetes_version (an upgrade), control_plane_count, worker_count, variables — as one patch. CAPI rolls the machines; status reports UPDATING meanwhile. cluster_class and namespace can't change on a live cluster.",
    'delete': "Deletes the CAPI Cluster and waits for it to be gone — hyve removes the cluster's definition as soon as this succeeds. CAPI's finalizers tear down workers, the control plane, then the infrastructure; auth's NodePort relay is owned by the Cluster and goes with it. The wait stops short of cluster mode's 15-minute Job deadline: past that, this fails and hyve keeps checking (status reports DELETING) until it's gone.",
}
for op, desc in workflows.items():
    body = (header + "apiVersion: v1\nkind: Workflow\nmetadata:\n  name: %s\n  description: >-\n%s\nspec:\n  jobs:\n    - name: %s\n      steps:\n        - name: %s\n          script: |\n%s\n"
            % (op, indent(desc, 4), op, op, indent(script(op), 12)))
    open(os.path.join(out, op + '.yaml'), 'w').write(body)

auth = (header + """apiVersion: v1
kind: ClusterAuth
metadata:
  name: capi-auth
spec:
  methods:
    - name: kubeconfig
      description: >
        Reads the admin kubeconfig CAPI writes (Secret <name>-kubeconfig on
        the management cluster) and, when the API endpoint isn't reachable
        from where hyve runs, points it through a relay — see
        params.api_access.
      deps:
        - kubectl
      auth:
        script: |
%s
      exports: KUBECONFIG
""" % indent(script('auth'), 10))
open(os.path.join(out, 'auth.yaml'), 'w').write(auth)
