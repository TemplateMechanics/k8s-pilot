# Kubernetes Skill — authoritative reference for k8s-pilot agents

This is the single source of truth for Kubernetes, Kustomize, Helm, Argo CD, and Flux API/field reference in this repository. Per `CLAUDE.md` Rule R5, agent personas and scripts must link here rather than restate field shapes.

**Scope:** common kinds, fields, and gotchas an AI agent needs to author and review manifests correctly. Not a tutorial. Not exhaustive — when a kind or field is not covered here, fall back to live discovery (MCP, `kubectl explain`, or upstream docs).

**Versions assumed:**
- Kubernetes API: `v1.28+`
- Kustomize: `v5.0+`
- Helm: `v3.13+`
- Argo CD: `v2.10+`
- Flux: `v2.2+`

If a project pins an older floor, defer to that project's pin and note any field that has changed since.

---

## 0. Conventions used in this document

- **YAML fragments** show only the relevant fields; assume standard `apiVersion` + `kind` + `metadata` are present unless shown.
- **(required)** marks fields whose absence causes admission rejection.
- **(strong default)** marks fields that the cluster defaults if omitted — but you should set them explicitly anyway for review legibility.
- **(gotcha)** flags a field whose surface behavior differs from intuition.
- Examples target a generic cluster — adjust namespace, labels, and image references for the actual workload.

---

## 1. Kubernetes Workloads

### 1.1 Pod (`v1`)

Building block for every workload kind. You rarely create Pods directly; they are owned by a controller (Deployment / StatefulSet / DaemonSet / Job).

Essential spec fields:

```yaml
spec:
  serviceAccountName: <sa>           # (strong default: default) — name an SA explicitly
  automountServiceAccountToken: false # set false unless the pod actually calls the apiserver
  restartPolicy: Always              # Always | OnFailure | Never (Jobs use OnFailure or Never)
  terminationGracePeriodSeconds: 30  # increase for stateful workloads
  securityContext:                   # pod-level; per-container override available
    runAsNonRoot: true               # (recommended) enforced by the kubelet at container start, and required by PodSecurity Admission "restricted" if the namespace is labeled — NOT a general admission rejection by the apiserver
    fsGroup: 2000                    # makes mounted volumes group-owned for this gid
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: registry.example.com/app@sha256:...  # pin by digest in prod tiers
      imagePullPolicy: IfNotPresent  # Always for :latest, IfNotPresent for tags/digests
      ports:
        - name: http
          containerPort: 8080
          protocol: TCP
      env:
        - name: LOG_LEVEL
          value: info
      envFrom:
        - configMapRef: { name: app-config }
        - secretRef:    { name: app-secrets }
      resources:
        requests: { cpu: 100m, memory: 128Mi }
        limits:   { cpu: 500m, memory: 256Mi }
      readinessProbe:
        httpGet: { path: /ready, port: http }
        periodSeconds: 5
        failureThreshold: 3
      livenessProbe:
        httpGet: { path: /healthz, port: http }
        periodSeconds: 10
        initialDelaySeconds: 30
        failureThreshold: 3
      startupProbe:                  # use for slow-start workloads instead of long initialDelay
        httpGet: { path: /healthz, port: http }
        periodSeconds: 5
        failureThreshold: 60         # = 5min before liveness takes over
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: cache
          mountPath: /var/cache/app
  volumes:
    - name: cache
      emptyDir: { sizeLimit: 100Mi }
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: ScheduleAnyway   # DoNotSchedule is strict; ScheduleAnyway is best-effort
      labelSelector:
        matchLabels: { app.kubernetes.io/name: app }
```

**Gotchas:**
- `imagePullPolicy: Always` with a digest is wasteful (the digest already pins the bits). Use `IfNotPresent` with digests.
- `livenessProbe` that just hits `/` is worse than no liveness probe; it causes restart storms on transient back-end failures. Use a probe that distinguishes "process broken" from "dependency broken."
- `readOnlyRootFilesystem: true` is correct for almost every workload; mount writable scratch as `emptyDir`.
- Pod-level `terminationGracePeriodSeconds` is the cap; the kubelet sends SIGTERM, waits this long, then SIGKILL. Long-running connections need preStop hooks to drain.

### 1.2 Deployment (`apps/v1`)

Default for stateless workloads.

```yaml
spec:
  replicas: 3
  revisionHistoryLimit: 5            # (strong default: 10) — keep small to bound etcd usage
  progressDeadlineSeconds: 600       # rollout is marked Failed if not Progressing for this long
  selector:
    matchLabels: { app.kubernetes.io/name: app, app.kubernetes.io/instance: app-prod }
  strategy:
    type: RollingUpdate              # RollingUpdate (default) | Recreate
    rollingUpdate:
      maxSurge: 25%                  # extra Pods during rollout
      maxUnavailable: 25%            # Pods that may be unavailable during rollout
  template:
    metadata:
      labels: { app.kubernetes.io/name: app, app.kubernetes.io/instance: app-prod }
    spec: { ... }                    # see Pod above
```

**Gotchas:**
- `selector.matchLabels` is **immutable** after creation. To change them, delete and recreate the Deployment.
- `template.metadata.labels` must be a superset of `selector.matchLabels`.
- A Deployment owns ReplicaSets — `kubectl rollout undo deployment/app` rolls back to the prior ReplicaSet, controlled by `revisionHistoryLimit`.

### 1.3 StatefulSet (`apps/v1`)

For workloads needing stable identity and stable storage (Postgres, Kafka, Zookeeper, etc.).

```yaml
spec:
  serviceName: app-headless          # (required) name of the headless Service for DNS
  replicas: 3
  podManagementPolicy: OrderedReady  # OrderedReady (default) | Parallel
  updateStrategy:
    type: RollingUpdate              # RollingUpdate | OnDelete
    rollingUpdate:
      partition: 0                   # rolls only pods with ordinal >= partition (canary control)
  selector: { ... }
  template: { ... }
  volumeClaimTemplates:              # (gotcha) each replica gets its own PVC from this template
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources: { requests: { storage: 100Gi } }
```

**Gotchas:**
- `volumeClaimTemplates` **does not delete PVCs on StatefulSet delete**. Use `persistentVolumeClaimRetentionPolicy` (1.27+) to control.
- Scaling down does NOT delete PVCs by default. Scale-up reattaches the existing PVC.
- `serviceName` MUST point to a headless Service (`clusterIP: None`) for pod DNS to work.
- Rolling updates go in **reverse ordinal order** (highest first). Use `partition` for canary rollouts.

### 1.4 DaemonSet (`apps/v1`)

One Pod per matching node (logging agents, CNI, CSI).

```yaml
spec:
  selector: { ... }
  template:
    spec:
      tolerations:                   # required to land on tainted nodes
        - operator: Exists           # tolerate any taint — common for node-level agents
      hostNetwork: false             # set true only if the agent needs host net (CNI etc.)
      hostPID: false                 # same caution
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
```

**Gotchas:**
- DaemonSet Pods are scheduled by the DaemonSet controller, **not** the default scheduler. They ignore PodTopologySpreadConstraints.
- `tolerations: [operator: Exists]` lands on every node including control-plane and tainted ones. Restrict if you don't want that.

### 1.5 Job (`batch/v1`) and CronJob (`batch/v1`)

```yaml
# Job
spec:
  parallelism: 1
  completions: 1
  backoffLimit: 6                    # retries before marking Failed
  activeDeadlineSeconds: 3600        # hard cap on running time
  ttlSecondsAfterFinished: 86400     # auto-delete after 1d
  template:
    spec:
      restartPolicy: OnFailure       # (required for Jobs) OnFailure | Never
      containers: [ ... ]

# CronJob
spec:
  schedule: "0 3 * * *"              # cron syntax in cluster TZ (set tzdata in 1.27+ with timeZone)
  timeZone: "America/New_York"       # (1.27+) explicit TZ; otherwise cluster local
  concurrencyPolicy: Forbid          # Allow (default) | Forbid | Replace
  startingDeadlineSeconds: 60        # skip run if more than 60s late
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec: { ... Job spec ... }
```

**Gotchas:**
- `restartPolicy: Always` is invalid in a Job template — must be `OnFailure` or `Never`.
- A long-running CronJob with `concurrencyPolicy: Allow` and a quick schedule can stack jobs. Use `Forbid` unless overlap is desired.
- `startingDeadlineSeconds` matters when the cluster was down — without it, missed runs queue up and fire when the controller comes back.

---

## 2. Configuration and secrets

### 2.1 ConfigMap (`v1`)

```yaml
data:
  config.yaml: |
    server:
      port: 8080
  feature_flags: "alpha,beta"
binaryData:                          # base64-encoded for binary content
  cert.der: <base64>
immutable: true                      # (recommended for shipped config) — can't be modified, only replaced
```

**Gotchas:**
- ConfigMaps mounted as files **update live** when the ConfigMap changes (after kubelet sync, ~1m), but ConfigMaps mounted via `envFrom`/`env.valueFrom` do NOT — the pod must restart to pick up changes. Use a checksum annotation on the Pod template to force restart on config change.
- `immutable: true` saves apiserver/kubelet load on large fleets but means a change requires creating a new ConfigMap and updating the consumer.

### 2.2 Secret (`v1`)

```yaml
type: Opaque                         # Opaque | kubernetes.io/dockerconfigjson | kubernetes.io/tls | ...
immutable: true
data:                                # base64-encoded; must be valid base64 or admission rejects
  password: <base64>
stringData:                          # plaintext at apply, converted to data on storage
  api-key: "supersecret"
```

**Gotchas:**
- Secrets are base64-**encoded**, not encrypted. Cluster encryption-at-rest is configured at the apiserver level; without it, etcd holds them in cleartext.
- `stringData` overrides `data` for the same key at apply. Use `stringData` for human-edited values and `data` for already-base64 inputs.
- `kubectl create secret generic` with `--from-literal` puts the value in your shell history. Prefer `--from-file` or an external secret manager.
- For real secret hygiene, use **SealedSecrets** (Bitnami), **External Secrets Operator** (ESO), or a CSI secret driver — not raw Secrets in Git.

### 2.3 ServiceAccount (`v1`)

```yaml
automountServiceAccountToken: false  # workload-level default unless the pod actually calls apiserver
imagePullSecrets:
  - name: registry-creds
```

**Gotchas:**
- In Kubernetes 1.24+ the SA token is no longer auto-generated as a long-lived Secret. Use `kubectl create token <sa>` (TokenRequest API) for ephemeral tokens. Generating a long-lived Secret requires an explicit `kubernetes.io/service-account-token` Secret.

---

## 3. Networking

### 3.1 Service (`v1`)

```yaml
spec:
  type: ClusterIP                    # ClusterIP (default) | NodePort | LoadBalancer | ExternalName
  clusterIP: None                    # None → headless Service (DNS records, no proxy IP)
  selector: { app.kubernetes.io/name: app }
  ports:
    - name: http
      port: 80                       # service-facing port
      targetPort: http               # container port (name or number)
      protocol: TCP
      appProtocol: http              # (recommended) helps ingress/mesh route correctly
  sessionAffinity: None              # None | ClientIP
  ipFamilyPolicy: SingleStack        # SingleStack | PreferDualStack | RequireDualStack
  internalTrafficPolicy: Cluster     # Cluster | Local (Local skips kube-proxy load balancing)
  externalTrafficPolicy: Cluster     # Local preserves source IP, Cluster does SNAT
```

**Gotchas:**
- `targetPort` accepts a port **name** matching a `containerPort.name` — preferred over numeric ports because it survives container-port renumbering.
- `externalTrafficPolicy: Local` preserves source IP but only routes to nodes that have a Pod, which can cause uneven load — pair with `healthCheckNodePort` and node-local routing.
- Headless Service (`clusterIP: None`) gives one A record per Pod, which is what StatefulSets need.

### 3.2 Ingress (`networking.k8s.io/v1`)

```yaml
spec:
  ingressClassName: nginx            # (recommended) optional in v1 but always set it explicitly — if omitted, the cluster's default IngressClass (the one with annotation ingressclass.kubernetes.io/is-default-class=true) is used, which can land your Ingress on the wrong controller
  tls:
    - hosts: [app.example.com]
      secretName: app-tls
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix         # Prefix | Exact | ImplementationSpecific
            backend:
              service:
                name: app
                port:
                  number: 80
```

**Gotchas:**
- `pathType` is **required** in v1. `Prefix` matches `/api` AND `/api/foo`; `Exact` matches only `/api`.
- Ingress is being superseded by **Gateway API** (`gateway.networking.k8s.io`) for new clusters — use Gateway/HTTPRoute when the controller supports it.

### 3.3 NetworkPolicy (`networking.k8s.io/v1`)

```yaml
spec:
  podSelector: { matchLabels: { app: api } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: web } }
        - podSelector: { matchLabels: { app: web } }
      ports: [{ protocol: TCP, port: 8080 }]
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.0.0/8
            except: [10.0.5.0/24]
      ports: [{ protocol: TCP, port: 5432 }]
```

**Gotchas:**
- NetworkPolicies are **additive allow-lists**. With `policyTypes: [Ingress]` set, all ingress not explicitly allowed is denied.
- A NetworkPolicy is enforced only if the CNI supports it (Calico, Cilium, etc. yes; default kindnet no).
- `namespaceSelector` + `podSelector` together in a single `from` entry is an AND (pod must match AND be in the matched namespace). Use separate `from` entries for OR.

### 3.4 Gateway API (`gateway.networking.k8s.io/v1`)

```yaml
# GatewayClass
spec:
  controllerName: example.com/gateway-controller

# Gateway
spec:
  gatewayClassName: example
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: { from: Same }   # Same | Selector | All

# HTTPRoute
spec:
  parentRefs:
    - name: example-gw
  hostnames: [app.example.com]
  rules:
    - matches:
        - path: { type: PathPrefix, value: /api }
      backendRefs:
        - name: api
          port: 80
          weight: 100
```

**Gotchas:**
- Gateway API decouples cluster-level (Gateway/GatewayClass — admin) from route-level (HTTPRoute — app team) via `allowedRoutes`. Don't put HTTPRoute and Gateway in the same Helm chart unless they share a tenancy boundary.

---

## 4. Storage

### 4.1 PersistentVolumeClaim (`v1`)

```yaml
spec:
  storageClassName: gp3              # cluster-specific; "" = no provisioner, manual PV bind
  accessModes: [ReadWriteOnce]       # RWO | ROX | RWX | RWOP (1.27+)
  resources: { requests: { storage: 100Gi } }
  volumeMode: Filesystem             # Filesystem (default) | Block
```

**Gotchas:**
- `accessModes` is a **request, not a guarantee**. The actual modes depend on the CSI driver. `ReadWriteOnce` on EBS is single-node; `ReadWriteMany` is rare and usually needs NFS / EFS / similar.
- Resizing: most CSI drivers support online resize. `kubectl edit pvc` to increase `storage:`. Decreasing is not supported.
- A PVC bound to a PV cannot be unbound by deleting the PVC if the PV `persistentVolumeReclaimPolicy: Retain` — the PV becomes `Released` and needs manual cleanup.

### 4.2 StorageClass (`storage.k8s.io/v1`)

```yaml
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer  # WaitForFirstConsumer | Immediate
reclaimPolicy: Delete                # Delete | Retain
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
```

**Gotchas:**
- `volumeBindingMode: WaitForFirstConsumer` is almost always what you want — defers PV creation until a Pod is scheduled so the PV lands in the right AZ.

---

## 5. RBAC (`rbac.authorization.k8s.io/v1`)

```yaml
# Role (namespaced)
rules:
  - apiGroups: [""]                  # "" = core API group
    resources: [pods, pods/log]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments]
    verbs: [get, list, watch, update, patch]
    resourceNames: [app]             # restrict to a specific resource

# RoleBinding (namespaced)
subjects:
  - kind: ServiceAccount
    name: app
    namespace: prod
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role                         # Role | ClusterRole
  name: app-reader

# ClusterRole + ClusterRoleBinding — same shape, cluster-wide
```

**Gotchas:**
- A `RoleBinding` referencing a `ClusterRole` grants that ClusterRole's permissions **only in the RoleBinding's namespace** — useful pattern for sharing a stock ClusterRole across namespaces.
- Verbs include `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`, `deletecollection`, plus subresource-specific verbs like `bind`, `escalate`, `impersonate`, `approve`.
- `escalate` lets a principal modify Roles to grant more than they have themselves. Never grant on a production cluster.

---

## 6. Policy

### 6.1 PodSecurity admission (built-in, replaces deprecated PodSecurityPolicy)

Set on namespace labels:

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

Levels: `privileged` (no restrictions) | `baseline` (sensible defaults) | `restricted` (locked down — required for most production).

**Gotchas:**
- `restricted` requires `runAsNonRoot: true`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, dropping all caps. Many off-the-shelf charts will fail; check before enforcing.

### 6.2 ResourceQuota (`v1`)

```yaml
spec:
  hard:
    requests.cpu: "10"
    requests.memory: "20Gi"
    limits.cpu: "20"
    limits.memory: "40Gi"
    pods: "50"
    persistentvolumeclaims: "10"
    services.loadbalancers: "2"
  scopes: [NotTerminating]           # filter to which objects the quota applies
```

### 6.3 LimitRange (`v1`)

```yaml
spec:
  limits:
    - type: Container
      default:        { cpu: 500m, memory: 256Mi }   # set if container omits limits
      defaultRequest: { cpu: 100m, memory: 128Mi }   # set if container omits requests
      min:            { cpu: 50m,  memory: 64Mi }
      max:            { cpu: 2,    memory: 2Gi }
```

---

## 7. Kustomize reference

### 7.1 `kustomization.yaml` shape

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: prod                      # applied to every resource in the build
namePrefix: prod-
nameSuffix: -v2
commonLabels:                        # added to every resource AND its selectors (use carefully — affects matching)
  tier: prod
commonAnnotations:
  managed-by: kustomize

resources:                           # paths (local or remote) or other kustomizations
  - ../base
  - extra/configmap.yaml

components:                          # kustomize components (composable overlays)
  - ../../components/monitoring

patches:                             # preferred over patchesStrategicMerge / patchesJson6902 (deprecated)
  - target: { kind: Deployment, name: app }
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 5

  - path: patches/deployment.yaml    # strategic merge patch via file
    target: { kind: Deployment, name: app }

configMapGenerator:
  - name: app-config
    files: [config.yaml=config/app.yaml]
    options: { disableNameSuffixHash: false }   # default: appends content hash

secretGenerator:
  - name: app-secrets
    literals: [api_key=fromenv]      # avoid in committed kustomizations — `literals` puts the value in source. Use SOPS (with Flux Kustomization spec.decryption), External Secrets Operator, SealedSecrets, or generate the Secret manifest outside kustomize. (`--load-restrictor` only controls cross-directory file loading; it does NOT secure secret material.)

images:
  - name: registry.example.com/app
    newName: registry.example.com/app
    newTag: v1.2.3

replicas:
  - name: app
    count: 5
```

**Gotchas:**
- `commonLabels` modifies Deployment selectors too — and selectors are immutable. Apply `commonLabels` BEFORE the first apply or use `labels:` (newer syntax) with `includeSelectors: false`.
- `configMapGenerator` appends a content hash to the name (`app-config-abc123`). This forces pod restart on config change because the Pod spec's `envFrom` / `volumes` reference the new name. Disable only when an external consumer needs a stable name.
- `patches` is the modern entrypoint; `patchesStrategicMerge` and `patchesJson6902` are deprecated.
- `components` allow stacking "feature" overlays on a base — different from `bases:` which is now `resources:`.

### 7.2 Common overlay pattern

```text
apps/<app>/
  base/
    kustomization.yaml               # resources only
    deployment.yaml
    service.yaml
  overlays/
    dev/
      kustomization.yaml             # references ../../base, patches replicas/image
    staging/
      kustomization.yaml
    prod/
      kustomization.yaml
```

---

## 8. Helm reference

### 8.1 `Chart.yaml`

```yaml
apiVersion: v2
name: app
version: 0.3.1                       # chart version — bump on any template change
appVersion: "1.5.0"                  # underlying app version (string, quoted)
type: application                    # application | library
kubeVersion: ">=1.28-0"
description: My app
dependencies:
  - name: postgresql
    version: "15.4.2"                # pinned semver, NOT a range
    repository: oci://registry-1.docker.io/bitnamicharts
    condition: postgresql.enabled
    alias: db                        # use chart under .Values.db instead of .Values.postgresql
```

**Gotchas:**
- `appVersion` MUST be quoted if it could be parsed as a number/date (e.g. `"1.0"`, `"2025-01"`).
- Dependency `version` accepts semver ranges (`^1.0`, `~15`), but **pin to an exact version** for production usage. Ranges work but defeat reproducibility — a fresh `helm dependency update` on the same `Chart.yaml` may resolve to a different sub-chart version.

### 8.2 Values and template idioms

```yaml
# values.yaml — defaults + schema
replicaCount: 1
image:
  repository: registry.example.com/app
  tag: ""                            # default to .Chart.AppVersion in templates
  pullPolicy: IfNotPresent
```

Template `_helpers.tpl`:

```yaml
{{/* Standard labels */}}
{{- define "app.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
```

**Common template functions:**
- `{{ .Values.foo | default "bar" }}` — default if unset/nil
- `{{ .Values.foo | required "foo is required" }}` — fail render if unset
- `{{ include "app.labels" . | nindent 4 }}` — render template, indent by 4 (nindent prepends newline)
- `{{- if .Values.x }}` / `{{- end }}` — leading `-` trims preceding whitespace; trailing `-` trims following
- `{{ toYaml .Values.nodeSelector | nindent 8 }}` — render arbitrary structure as YAML
- `{{ tpl .Values.template . }}` — re-evaluate a string as a template (powerful, dangerous)

**Gotchas:**
- An empty document (`---\n` with nothing after it) breaks `helm install`. Guard generation with `{{- if .Values.foo.enabled }}` and ensure the file produces nothing — not whitespace — when disabled.
- `helm template` and `helm install --dry-run` differ: `--dry-run` consults the apiserver for capabilities and existing releases; `template` does not. Use the wrapper script's render output for review and `helm-diff` for the diff.
- `{{ .Values.foo }}` for a list/map in `values.yaml` interpolated into YAML must use `nindent` or `toYaml`, never raw string concatenation.

### 8.3 Hooks

```yaml
metadata:
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
```

Hook events: `pre-install`, `post-install`, `pre-delete`, `post-delete`, `pre-upgrade`, `post-upgrade`, `pre-rollback`, `post-rollback`, `test`.

**Gotchas:**
- Hook resources are NOT tracked as part of the release once they complete. They won't be removed by `helm uninstall` unless you set a delete policy.
- `test` hooks run via `helm test <release>` — common pattern for smoke checks.

---

## 9. Argo CD reference

### 9.1 Application (`argoproj.io/v1alpha1`)

```yaml
metadata:
  name: app
  namespace: argocd                  # Argo CD's own namespace
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascading delete on app deletion
spec:
  project: tenant-a                  # AppProject name
  source:
    repoURL: https://github.com/org/repo.git
    targetRevision: a1b2c3d          # commit SHA or immutable tag — never HEAD/main
    path: apps/web/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: web
  syncPolicy:
    automated:                       # absence = manual sync only
      prune: false                   # delete resources removed from source
      selfHeal: false                # revert drift back to source
      allowEmpty: false              # error if source becomes empty (safer)
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - ApplyOutOfSyncOnly=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff: { duration: 5s, factor: 2, maxDuration: 3m }
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers: [/spec/replicas]  # HPA writes here; ignore drift
```

**Gotchas:**
- `automated.prune: true` removes resources the user deleted from source. PVCs and Secrets are usually NOT what you want pruned silently — limit to specific apps.
- `selfHeal: true` reverts `kubectl edit` changes. Great in steady state, surprising during incident response — consider disabling during planned firefighting.
- `ApplyOutOfSyncOnly=true` skips re-applying unchanged resources on every sync — meaningful perf win for large apps.
- `ServerSideApply=true` uses Kubernetes server-side apply, which resolves field manager conflicts better than client-side. Default for new apps.

### 9.2 AppProject

```yaml
spec:
  sourceRepos:
    - https://github.com/org/*
  destinations:
    - server: https://kubernetes.default.svc
      namespace: tenant-a-*
  clusterResourceWhitelist:
    - { group: "", kind: Namespace }
    - { group: rbac.authorization.k8s.io, kind: ClusterRole }
  namespaceResourceBlacklist:
    - { group: "", kind: ResourceQuota }
  roles:
    - name: read-only
      policies:
        - p, proj:tenant-a:read-only, applications, get, tenant-a/*, allow
      groups: [org:tenant-a-readers]   # OIDC group
```

### 9.3 ApplicationSet

```yaml
spec:
  generators:
    - clusters: {}                   # one Application per registered cluster
    - git:
        repoURL: https://github.com/org/repo.git
        revision: main
        directories: [{ path: apps/* }]
    - matrix:
        generators:
          - clusters: { selector: { matchLabels: { tier: staging } } }
          - git: { ... }
  template:
    metadata: { name: "{{name}}-{{path.basename}}" }
    spec: { ... Application spec ... }
```

### 9.4 Sync waves

`metadata.annotations["argocd.argoproj.io/sync-wave"]` — integer; lower runs first. Negative numbers run before zero. Within a wave, resources apply in parallel. Use `Sync` hooks for strict ordering inside a wave.

---

## 10. Flux reference

### 10.1 Sources (`source.toolkit.fluxcd.io/v1`)

```yaml
# GitRepository
spec:
  interval: 1m                       # poll frequency
  url: https://github.com/org/repo.git
  ref:
    branch: main                     # or: tag: v1.2.3 / commit: abc / semver: ">=1.0.0"
  secretRef: { name: github-creds }  # for HTTPS basic auth or SSH

# HelmRepository
spec:
  interval: 5m
  url: oci://registry-1.docker.io/bitnamicharts
  type: oci                          # omit for traditional Helm repos

# OCIRepository
spec:
  interval: 5m
  url: oci://ghcr.io/org/manifests
  ref: { tag: latest }
  layerSelector: { mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip }
```

### 10.2 Kustomization (`kustomize.toolkit.fluxcd.io/v1`)

```yaml
spec:
  interval: 10m
  path: ./apps/web/overlays/prod
  prune: true                        # delete resources removed from source
  sourceRef:
    kind: GitRepository
    name: web-repo
  targetNamespace: web               # override the kustomization's namespace
  timeout: 5m
  retryInterval: 2m
  wait: true                         # wait for healthchecks before marking Ready
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: web
      namespace: web
  dependsOn:
    - { name: crds, namespace: flux-system }
  postBuild:                         # substitute envsubst-style variables after kustomize build
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
  decryption:
    provider: sops
    secretRef: { name: sops-gpg }
  force: false                       # delete+recreate immutable resources on conflict — dangerous
```

### 10.3 HelmRelease (`helm.toolkit.fluxcd.io/v2`)

```yaml
spec:
  interval: 10m
  chart:
    spec:
      chart: nginx
      version: "15.4.2"              # pinned, NOT a range
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: flux-system
  targetNamespace: web
  releaseName: web                   # explicit; defaults to <namespace>-<name>
  install:
    remediation: { retries: 0 }
  upgrade:
    remediation: { retries: 0, remediateLastFailure: true }
    cleanupOnFail: true
  values:
    replicaCount: 3
  valuesFrom:
    - kind: ConfigMap
      name: web-values
      valuesKey: values.yaml
  dependsOn:
    - { name: postgres, namespace: data }
```

### 10.4 ImageUpdateAutomation / ImagePolicy / ImageRepository

For auto-bump on new image versions. Only enable when the team accepts automated commits from the Flux bot.

```yaml
# ImageRepository
spec:
  interval: 5m
  image: registry.example.com/app

# ImagePolicy
spec:
  imageRepositoryRef: { name: app }
  policy:
    semver: { range: ">=1.0.0 <2.0.0" }   # never use ">=0.0.0"
```

---

## 11. Cross-tool composition patterns

### 11.1 Helm under Argo CD

```yaml
# Application spec
source:
  repoURL: https://github.com/org/charts.git
  targetRevision: <sha>
  path: charts/web
  helm:
    valueFiles: [values.yaml, values-prod.yaml]
    parameters:
      - name: image.tag
        value: v1.2.3
```

**Gotcha:** Argo CD renders the Helm chart locally then applies. Helm hooks become Argo CD `PreSync`/`PostSync` hooks via annotations. CRDs are NOT auto-installed; either pre-create or include in a separate Application with a lower sync-wave.

### 11.2 Helm under Flux

```yaml
# HelmRelease + GitRepository source
spec:
  chart:
    spec:
      chart: ./charts/web
      sourceRef: { kind: GitRepository, name: charts-repo }
```

### 11.3 Kustomize over Helm

`kustomize build --enable-helm` lets a kustomization render a Helm chart and apply patches. Useful for adapting upstream charts.

```yaml
# kustomization.yaml
helmCharts:
  - name: nginx
    version: "15.4.2"
    repo: oci://registry-1.docker.io/bitnamicharts
    releaseName: web
    namespace: web
    valuesFile: values.yaml
```

Renders the chart then continues normal kustomize processing.

---

## 12. Common debugging recipes

| Symptom | First check |
|---|---|
| Pod stuck Pending | `kubectl describe pod` → Events. Usually scheduling (taints, node selector, resource requests too high). |
| Pod CrashLoopBackOff | `kubectl logs <pod> --previous`. If empty, container exited 0 — usually misconfigured args. |
| Pod ImagePullBackOff | Image name / tag wrong, or missing `imagePullSecrets`. |
| Service has no endpoints | `kubectl get endpointslices -l kubernetes.io/service-name=<svc>`. Selector vs Pod labels mismatch. |
| Ingress 404 | `pathType: Prefix` vs `Exact`, missing `ingressClassName`, controller not running. |
| Deployment rollout stuck | `kubectl rollout status deployment/<name>`. ReadinessProbe failing? `progressDeadlineSeconds` exceeded? |
| StatefulSet won't update | Update strategy `OnDelete`? `partition` set non-zero? |
| Argo CD app stuck OutOfSync | `argocd app diff <app>`. Often `ignoreDifferences` missing for controller-mutated fields. |
| Flux Kustomization stuck NotReady | `flux events --for kustomization/<name>`, then check `healthChecks` targets. |
| Helm upgrade hangs | `helm history <release>`. Stuck in pending-upgrade? Use `helm rollback` to the last successful revision, then retry. |

---

## 13. Field-specific gotchas worth memorizing

- **`Job.spec.template.spec.restartPolicy`**: must be `OnFailure` or `Never`. Not `Always`.
- **`Service.spec.selector` vs `Deployment.spec.selector`**: Service selects pods directly by labels; Deployment selects pods it owns by `selector.matchLabels` (immutable).
- **`Deployment.spec.selector.matchLabels`**: immutable. Wrong labels at creation = delete and recreate.
- **`ServiceAccount` token in 1.24+**: no auto-generated Secret. Use TokenRequest API.
- **`ConfigMap` change propagation**: `envFrom` / `env.valueFrom` values do NOT update live in a running container; the pod must restart to pick up changes (a rolling restart works). Volume-mounted values DO update live, after kubelet sync (~1 min). Matches §2.1.
- **`StatefulSet.spec.serviceName`**: must reference a **headless** Service (`clusterIP: None`).
- **`HPA` and `Deployment.spec.replicas`**: HPA owns replicas; remove the field from the Deployment manifest or add `ignoreDifferences` in Argo CD.
- **`PodDisruptionBudget`**: `maxUnavailable: 0` or `minAvailable: 100%` blocks evictions entirely — surprising during node drains.
- **`StorageClass.volumeBindingMode: Immediate`**: provisions PVs in arbitrary AZ; almost always wrong on multi-AZ clusters.
- **`Ingress.pathType`**: required in v1; `Prefix` is the usual default mental model.
- **`NetworkPolicy` + no CNI support**: silently has no effect. Verify with the CNI before relying on it.

---

## 14. When this skill is insufficient

If a question requires a field or behavior not documented here:

1. **Try `kubectl explain <kind>.<field>`** against the live cluster — authoritative for that cluster's API version.
2. **Try the Kubernetes MCP server** (planned, PR 9) for live cluster context.
3. **Consult upstream docs**: `kubernetes.io/docs`, `helm.sh/docs`, `argo-cd.readthedocs.io`, `fluxcd.io/flux/`.
4. **Ask the user** — better than guessing. Cite the missing context explicitly.

Do NOT invent API fields. If a field doesn't appear in `kubectl explain` or the live API, it doesn't exist on this cluster, regardless of what an older blog post says.
