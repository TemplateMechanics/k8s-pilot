# Security scanning

This doc explains which scanners the harness wraps, what each one
catches, and how they fit into the pre-commit / mutation flow. None
of these scanners run in CI (k8s-pilot is local-only by design — see
[BRANCH-WORKFLOW.md](BRANCH-WORKFLOW.md)). They run inside
`scripts/Validate-Manifests.ps1` and `scripts/Pre-Commit.ps1`.

## What is scanned

| Layer | Tool | What it catches | Where it runs |
|---|---|---|---|
| Manifest schema | [kubeconform](https://github.com/yannh/kubeconform) | Invalid API field types, unknown fields, missing required fields against a pinned Kubernetes API version. | `Validate-Manifests.ps1` |
| Manifest quality | [kube-score](https://github.com/zegl/kube-score) | Missing resource limits, no readiness probe, root-running pods, missing labels, image-pull-policy issues. | `Validate-Manifests.ps1` |
| Policy / hardening | [polaris](https://github.com/FairwindsOps/polaris) | Pod-level security policies (privileged, capabilities, securityContext, hostPID/hostNetwork, etc.). | `Validate-Manifests.ps1` |
| MCP config secrets | `scripts/mcp/Test-McpConfigSecrets.ps1` | Inline credentials in `.vscode/mcp*.json` (token / password / api key / JWT shapes / AWS access key prefixes). `${env:VAR}` interpolation is the allowed pattern. | `Pre-Commit.ps1` (planned, PR 12) |

## What is NOT scanned

Scope-cuts the harness deliberately does not address; treat these as
contributor responsibility OR install a separate scanner in your
fork:

- **Image vulnerability scanning** (trivy, grype, snyk). These belong
  in your container build pipeline, not in the Kubernetes wrapper
  flow.
- **Helm chart linting** (`helm lint`). The `Invoke-HelmTemplate` /
  `Invoke-HelmDiff` flow surfaces template errors at render time;
  `helm lint` adds value mainly for chart authors and is not wired in.
- **Argo CD `ApplicationSet` policy checks**. The argocd wrappers
  don't currently parse Application/AppProject specs beyond the
  diff/sync contract; tighter policy belongs in an OPA gatekeeper
  layer on the cluster itself.
- **Network policy verification**. NetworkPolicies are validated by
  kubeconform for schema correctness but not for semantic intent.
  Pair the manifests with a tool like `inspektor-gadget` or
  `np-viewer` if you need that.
- **Secret content scanning across the whole repo**.
  `Test-McpConfigSecrets.ps1` is intentionally narrow (MCP config
  only). For broader sweeps use `gitleaks` or `trufflehog` as a
  separate `Pre-Commit.ps1` step in your fork.

## Where the scanners live

`Validate-Manifests.ps1` (CLAUDE.md §3.0) orchestrates kubeconform +
kube-score + polaris. Each is optional — missing tools are skipped
with a warning rather than failing the script — so an environment
with only kubeconform installed still runs SOME validation. The
script exits 1 if any non-skipped tool fails, 2 if no validators ran
at all (every tool missing or every `-Skip*` flag set).

The validator runs on already-rendered manifests, regardless of
producer:

```powershell
# kustomize render -> validate
$rendered = ./scripts/kubectl/Invoke-KustomizeBuild.ps1 -Path apps/web/overlays/staging -Context staging
./scripts/Validate-Manifests.ps1 -Path $rendered

# helm template -> validate
$rendered = ./scripts/helm/Invoke-HelmTemplate.ps1 -ChartPath charts/web -ValuesFile charts/web/values-staging.yaml -Release web -Namespace web
./scripts/Validate-Manifests.ps1 -Path $rendered
```

## Suppressing or tuning scanners

- **kubeconform**: pass `-KubernetesVersion <ver>` to validate against
  a specific API version (default `1.28.0`). Use `-SkipKubeconform`
  to omit it from a single run; do not commit a permanent skip.
- **kube-score**: pass `-SkipKubeScore`. There is no per-rule disable
  here — tune via your `.kube-score.yaml` (kube-score's config) if
  you need it.
- **polaris**: pass `-SkipPolaris`. Tune via `polaris.yaml`.

## When a scanner blocks a legitimate change

If a kube-score or polaris finding is genuinely wrong for your case
(e.g. a workload that legitimately needs root because of a CSI
driver), document the exception in the workload's namespace
annotations or in a comment in the manifest, and run the validator
with the relevant `-Skip*` flag for that one render. Do not change
the workload to "pass the lint" if doing so weakens the workload.

## Threat model the harness assumes

- The kubeconfig file is treated as trusted; the wrappers don't
  defend against a malicious kubeconfig pointing at the wrong cluster
  (use the `-Context` argument check to defend against that). See
  CLAUDE.md R3.
- The repository's `config/clusters.yaml` is treated as trusted; the
  wrappers don't defend against a malicious registry entry pointing
  at the wrong server (use code review on the registry like any
  other config).
- Operator-supplied secrets passed via `${env:VAR}` interpolation in
  `.vscode/mcp.json` are out of scope for this scanner — the env var
  itself is the secret; the scanner just makes sure no literal
  credential is in the committed file.
