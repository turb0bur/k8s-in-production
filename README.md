# k8s-in-production

## Module 02 – Security & Policy as Code

### Tasks

1. Create a Kubernetes cluster with one namespace for the mentor and three namespaces for students (e.g. `student01`, `student02`, `student03`).

   The mentor and each student must have separate kubeconfig files.

   Implement RBAC:

   - The mentor has RW access to the student namespaces.
   - Students 01 and 03 have RW access only to their own namespaces.
   - Student 02 has RO access to the student 01 namespace and the `default` namespace.
   - Neither the mentor nor the students may have Cluster Admin rights.

2. Create a Kyverno policy that validates a read-only root filesystem, in audit mode.

3. Create a Kyverno policy that adds the label `person` to pods. In student namespaces the value is `student`, in the mentor namespace it is `mentor`, and all other namespaces must not have this label at all.

### Project structure

```
.
├── README.md
├── manifests
│   └── rbac
│       ├── roles.yaml              # ClusterRoles ns-rw and ns-ro (permission templates)
│       └── additional-grants.csv   # extra access, user,role,namespaces
├── scripts
│   ├── generate-manifests.sh       # namespaces and RoleBindings for the mentor and N students
│   ├── issue-credentials.sh        # key, CSR, signed cert and kubeconfig for one user
│   └── issue-all-credentials.sh    # the same for the mentor and every student namespace
├── policies
│   └── kyverno
│       ├── require-readonly-root-filesystem.yaml  # ValidatingPolicy, Audit
│       ├── add-person-label.yaml                  # MutatingPolicy, person=<namespace role>
│       └── validate-person-label.yaml             # ValidatingPolicy, Audit
└── kubeconfigs                     # generated, gitignored
```

### Prerequisites

- Any Kubernetes cluster (kind, minikube, Docker Desktop, a cloud cluster, ...) where you can create namespaces, RBAC objects and CertificateSigningRequests. The cluster must sign client certificates with the built-in `kubernetes.io/kube-apiserver-client` signer.
- `kubectl`, `openssl`, `helm` 3 (to install Kyverno) and, optionally, the Kyverno CLI for offline policy tests. Tested with `kubectl` and a Kubernetes server at v1.36.1.
- Admin access to the cluster, with `kubectl` pointed at it:

```bash
kubectl config get-contexts
kubectl config use-context <your-context>
kubectl get nodes
```

Everything below runs against the current `kubectl` context, so double-check it before applying anything. To make the credentials script refuse any other context, run it with `EXPECTED_CONTEXT=<your-context>`.

### 1. Namespaces and RBAC

Run from the repository root, in this order. The RoleBindings need the ClusterRoles and the namespaces to exist.

1. Create the ClusterRoles (the permission templates):

   ```bash
   kubectl apply -f manifests/rbac/roles.yaml
   ```

2. Generate the namespaces and RoleBindings for the mentor and 3 students, and apply them. The script only prints YAML, so `kubectl apply` is what creates the objects:

   ```bash
   chmod +x scripts/*.sh
   ./scripts/generate-manifests.sh 3 --additional-grants manifests/rbac/additional-grants.csv | kubectl apply -f -
   ```

   To review the YAML first, run the script without the pipe. To validate it against the cluster without creating anything, pipe it to `kubectl apply --dry-run=server -f -`.

- The mentor gets `ns-rw` in the `mentor` namespace and in every `studentNN` namespace.
- Each student `studentNN` gets `ns-rw` in its own namespace only.
- Extra access goes into the additional grants file, a CSV with the header `user,role,namespaces`. The namespaces column takes one or more namespaces separated by `;`, and one row creates a RoleBinding in each of them. The role can be any ClusterRole, and blank lines are ignored.

```csv
user,role,namespaces
student02,ns-ro,student01;default
```

To change the number of students, rerun the generator with another N. Removing students is not automatic: delete their namespaces by hand.

| User      | Access                                         |
|-----------|------------------------------------------------|
| mentor    | RW in mentor, student01, student02, student03  |
| student01 | RW in student01                                |
| student02 | RW in student02, RO in student01 and default   |
| student03 | RW in student03                                |

Verify as admin:

```bash
kubectl get namespaces -l role
kubectl get rolebindings -A | grep -E 'ns-r[wo]'

kubectl auth can-i delete pods -n student03 --as mentor      # yes
kubectl auth can-i delete pods -n student01 --as student01   # yes
kubectl auth can-i get pods -n student03 --as student01      # no
kubectl auth can-i get pods -n student01 --as student02      # yes
kubectl auth can-i delete pods -n student01 --as student02   # no
kubectl auth can-i get pods -n default --as student02        # yes
kubectl auth can-i '*' '*' --all-namespaces --as mentor      # no, not cluster-admin
```

- `ns-rw` and `ns-ro` are ClusterRoles used only through namespaced RoleBindings, so nobody has cluster-wide access and nobody is cluster-admin.
- `ns-ro` excludes secrets and `pods/exec`.
- RW for student02 in its own namespace is an assumption; the task only lists the RO access.
- Bindings reference users by name (`kind: User`). Kubernetes has no user objects: the name comes from the CN of the client certificate.

### 2. Credentials

```bash
./scripts/issue-all-credentials.sh        # mentor and every namespace labelled role=student
./scripts/issue-credentials.sh student01  # or a single user
```

For each user the script creates a key and a CSR with `CN=<user>`, submits it through the Kubernetes CSR API (valid for 365 days), approves it, and builds `kubeconfigs/<user>.kubeconfig`. The cluster address and CA are copied from the current context. Re-running replaces the user's files; the old certificate stays valid until it expires.

### 3. Switching users

```bash
# one terminal per user
export KUBECONFIG=$PWD/kubeconfigs/student01.kubeconfig
kubectl auth whoami
unset KUBECONFIG                          # back to your default kubeconfig

# single command
kubectl --kubeconfig kubeconfigs/student02.kubeconfig get pods -n student01

# check your own permissions with a user kubeconfig (no --as)
kubectl --kubeconfig kubeconfigs/student01.kubeconfig auth can-i delete pods -n student01   # yes
kubectl --kubeconfig kubeconfigs/student01.kubeconfig auth can-i delete pods -n student03   # no

# check any user's permissions as admin, without their kubeconfig
kubectl auth can-i delete pods -n student01 --as student02
```

`--as` is impersonation and works only with admin credentials. Using it with a student kubeconfig fails with `cannot impersonate-on:user-info:create`.

### 4. Kyverno policies

Run every command in this section as cluster admin (your default kubeconfig, `KUBECONFIG` unset): the policies are cluster-scoped, and the checks need access to `default` and to reports across all namespaces.

Install Kyverno, then apply the policies:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --set global.image.registry=ghcr.io

kubectl get pods -n kyverno               # wait until all pods are Ready
kubectl apply -f policies/kyverno/
kubectl get validatingpolicy,mutatingpolicy
```

The policies use the CEL-based `policies.kyverno.io/v1` API, because `ClusterPolicy` is deprecated since Kyverno 1.19.

| Policy | Type | What it does |
|--------|------|--------------|
| `require-readonly-root-filesystem` | ValidatingPolicy (Audit) | Reports pods whose containers or init containers do not set `readOnlyRootFilesystem: true`. Skips `kube-system` and `kyverno`. |
| `add-person-label` | MutatingPolicy | Sets `person` on new pods to the `role` label of their namespace (`student` or `mentor`). Namespaces without that role are not matched, so pods there get no label. A `person` label that is already set is not overwritten. |
| `validate-person-label` | ValidatingPolicy (Audit) | Reports pods whose `person` label differs from the namespace role (for example `mentor` in a student namespace), and pods with a `person` label in any other namespace. |

Verify:

```bash
kubectl run t1 --image=nginx -n student01
kubectl get pod t1 -n student01 --show-labels     # person=student
kubectl run t2 --image=nginx -n mentor
kubectl get pod t2 -n mentor --show-labels        # person=mentor
kubectl run t3 --image=nginx -n default
kubectl get pod t3 -n default --show-labels       # no person label

# audit findings (readOnlyRootFilesystem is not set on these pods)
kubectl get policyreport -A
kubectl delete pod t1 -n student01 && kubectl delete pod t2 -n mentor && kubectl delete pod t3 -n default
```
