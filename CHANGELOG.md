# Changelog

All notable changes to k8s-pilot are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Repository meta files: README, LICENSE, CHANGELOG, CONTRIBUTING, .gitignore, .gitattributes.
- Target shape and 12-PR roadmap documented in README.
- `CLAUDE.md` operational contract: diff-before-mutate discipline, hard rules, tool-family wrapper contracts, agent-selection guide.
- `.github/copilot-instructions.md` mirroring CLAUDE.md for Copilot Chat.
- CLAUDE.md Section 3.6: defines the "metadata-only mutations" exception class for `Invoke-HelmRollback.ps1`, `Invoke-FluxSuspend.ps1`, and `Invoke-FluxResume.ps1` — these are exempt from the diff-artifact rule because their intent is captured by the wrapper parameters, but they still require explicit `-Context`, `-Reason`, and user approval.
- Agent personas under `agents/`:
  - `chief-systems-engineer.agent.md` — cross-tool architectural voice (Kustomize vs Helm, Argo CD vs Flux).
  - `kubernetes.agent.md` — raw kubectl + kustomize manifests and overlays.
  - `helm.agent.md` — chart authoring, values, releases, upgrade/rollback safety.
  - `argocd.agent.md` — Application/AppProject/ApplicationSet, sync waves, app-of-apps.
  - `flux.agent.md` — GitRepository/Kustomization/HelmRelease, reconciliation, suspend/resume.

- `skills/kubernetes/SKILL.md`: authoritative reference for Kubernetes kinds (Workloads/Config/Networking/Storage/RBAC/Policy), Kustomize, Helm, Argo CD CRDs, Flux CRDs, cross-tool composition patterns (Helm-under-Argo, Helm-under-Flux, Kustomize-over-Helm), debugging recipes, and field-specific gotchas. Per CLAUDE.md R5 this is the single source of truth — agent personas and scripts link here rather than restate field shapes.
- `scripts/_lib/Context.ps1`: shared context-safety helpers (`Assert-ContextSafety`, `Get-AmbientContext`, `Test-KubectlContextExists`, `Get-PathBasename`) per CLAUDE.md R3.
- `scripts/Validate-Manifests.ps1`: canonical cross-cutting validator entrypoint (CLAUDE.md §3.0). Orchestrates kubeconform + kube-score + polaris; gracefully skips missing tools; exits non-zero on any failure.
- `scripts/kubectl/Invoke-KustomizeBuild.ps1`: render a kustomization to `kustomize-build/<context>/<name>.yaml` (§3.1 Build). Prefers `kustomize` binary, falls back to `kubectl kustomize`.
- `scripts/kubectl/Invoke-KubectlDiff.ps1`: diff a rendered kustomization against live cluster (§3.1 Diff). Emits `.diff` artifact + `.diff.meta.json` sidecar with context, sourcePath, renderedPath, and SHA-256 for tamper detection. Preserves `kubectl diff` exit semantics (0 = clean, 1 = diff, >1 = error).
- `scripts/kubectl/Invoke-KubectlApply.ps1`: apply the rendered manifest paired with a reviewed diff artifact (§3.1 Apply). Refuses to run without `-DiffFile`; verifies metadata context matches `-Context`; verifies SHA-256 hasn't drifted since diff. Supports `-ServerSideApply` with `k8s-pilot` field manager.
- `scripts/kubectl/Invoke-RolloutStatus.ps1`: post-mutation read-only wait for Deployment/StatefulSet/DaemonSet (§3.1 Rollout). `TimeoutSeconds` default 300.

- `scripts/helm/Invoke-HelmTemplate.ps1`: render a Helm chart to `helm-output/<namespace>/<release>/templated.yaml` (§3.2 Template). Mandatory `-Namespace`. Captures stderr separately so warnings cannot pollute the rendered file.
- `scripts/helm/Invoke-HelmDiff.ps1`: `helm diff upgrade` paired with a `.diff` artifact + `.diff.meta.json` sidecar (context, namespace, release, chartPath, valuesFile, generatedAt) (§3.2 Diff). Requires `helm-diff` plugin. Preserves helm-diff exit semantics (0 = no diff, 2 = diff present, 1 = error).
- `scripts/helm/Invoke-HelmUpgrade.ps1`: apply paired with a reviewed diff (§3.2 Upgrade). Verifies metadata `context`, `namespace`, chartPath, valuesFile match. Calls `helm upgrade --install --atomic --timeout 5m`.
- `scripts/helm/Invoke-HelmRollback.ps1`: metadata-only mutation per §3.6. Requires `-Revision`, `-Reason` (>=5 chars), `-Context`, `-Namespace`. Renders cross-revision manifest delta (`helm get manifest --revision`) to `.helm/<contextSlug>/<namespace>/<release>/` for operator review (true context name preserved inside the JSON audit entries), pauses for explicit `rollback` confirmation, then appends a JSON audit entry to `rollback.log`.

### Planned
- `CODE_OF_CONDUCT.md` (Contributor Covenant v2.1) and `SECURITY.md` (disclosure policy) will land in a later docs PR.
- `agents/multi-cluster.agent.md` will land with the multi-cluster registry in PR 8.

## [0.1.0] - TBD

Initial harness scaffolding. See README for the target shape.

[Unreleased]: https://github.com/TemplateMechanics/k8s-pilot/compare/main...HEAD
[0.1.0]: https://github.com/TemplateMechanics/k8s-pilot/releases/tag/v0.1.0
