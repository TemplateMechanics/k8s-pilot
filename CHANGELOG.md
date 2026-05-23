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
- `scripts/helm/Invoke-HelmDiff.ps1`: `helm diff upgrade` paired with a `.diff` artifact + `.diff.meta.json` sidecar (§3.2 Diff). Sidecar (schemaVersion=3) records: `context`, `namespace`, `release`, `chartPath`, `chartContentSha256` (recursive content hash via `Get-PathContentHash`, deterministic across runs and case-sensitive filesystems), `valuesFile`, `valuesFileSha256`, `generatedAt`. Requires `helm-diff` plugin (NAME-column parsed, no false positives on plugin descriptions). Preserves helm-diff exit semantics (0 = no diff, 2 = diff present, 1 = error or wrapper-side metadata failure with partial-artifact cleanup).
- `scripts/helm/Invoke-HelmUpgrade.ps1`: apply paired with a reviewed diff (§3.2 Upgrade). Verifies (1) `artifactKind=helm-diff`, (2) metadata `context`/`namespace`/`release` match `-Context`/`-Namespace` AND the directory layout of the artifact path, (3) `chartContentSha256` and `valuesFileSha256` still match current content (closes the diff-then-edit window for both chart and values), (4) every consumed metadata field is a scalar string starting with a non-flag character (defends against argument injection via hand-edited sidecar). Calls `helm upgrade --install --atomic --timeout 5m`.
- `scripts/helm/Invoke-HelmRollback.ps1`: metadata-only mutation per §3.6. Requires `-Revision`, `-Reason` (>=5 chars), `-Context`, `-Namespace`. Renders cross-revision manifest delta (`helm get manifest --revision`) to `.helm/<contextSlug>/<namespace>/<release>/` for operator review (true context name preserved inside the JSON audit entries), pauses for explicit `rollback` confirmation, then appends a JSON audit entry to `rollback.log`.

- `scripts/argocd/Invoke-ArgocdLogin.ps1`: `argocd login <server>` with optional `-Sso` (browser flow), `-Username` (argocd prompts interactively for the password — no `-Password` param by design, to keep secrets off the process command line), and `-Insecure`. Mutually-exclusive `-Sso` / `-Username` check. CLI session stored in the user's standard config dir (cross-platform repo-local relocation is out of scope for this PR; the diff/sync wrappers use `.argocd/` only for artifacts).
- `scripts/argocd/Invoke-ArgocdAppDiff.ps1`: `argocd app diff --revision --server --exit-code`; emits `.argocd/<serverSlug>/<appSlug>/<revisionSlug>.diff` + `.diff.meta.json` sidecar (schemaVersion=1; server/app/revision/diffExitCode/generatedAt). Every path segment is a `ConvertTo-SafeFilename` slug so revisions like `release/v1.2.3` are filesystem-safe; true identifiers are recorded in the sidecar. Rejects `-Revision HEAD` (case-insensitive). Captures stderr separately so warnings cannot pollute the diff artifact. Translates argocd's exit 1 ("diff present") to wrapper exit 2 so callers branch consistently with helm-diff/kubectl-diff.
- `scripts/argocd/Invoke-ArgocdAppSync.ps1`: apply paired with a reviewed diff. Verifies sidecar exists / valid JSON / artifactKind / schemaVersion / scalar-string fields / `Assert-NonFlagArg` on server/app/revision / case-sensitive `meta.server`/`meta.app`/`meta.revision` match / path layout matches `ConvertTo-SafeFilename` slugs / `diffExitCode==1`. Optional `-Prune` switch. All PR 5 idioms applied: `Write-Error`+exit, `-LiteralPath` everywhere, `$PSDefaultParameterValues['Write-Error:ErrorAction']='Continue'`.
- `scripts/argocd/Invoke-ArgocdAppWait.ps1`: read-only `argocd app wait --health --sync`. `TimeoutSeconds` default 300.

- `scripts/flux/Invoke-FluxBuild.ps1`: streams `flux build kustomization` stdout directly to `.flux/<kustomization>.yaml`; stderr captured separately so warnings cannot pollute the rendered manifest. Exit 3 if flux missing.
- `scripts/flux/Invoke-FluxDiff.ps1`: wraps `flux diff kustomization`; emits `.flux/<kustomization>/<contextSlug>.diff` + `.diff.meta.json` sidecar (schemaVersion=1; context/kustomization/path/pathContentSha256/diffExitCode/generatedAt). Stderr captured to a temp file (surfaced as Warning on success, included in error message on failure) so warnings cannot pollute the diff artifact. Classification is exit-code-driven, not stderr-driven: exit 0 = no diff, exit 1 with visible diff markers in stdout = diff present, exit 1 without diff markers OR exit > 1 = error. Translates to wrapper exit 0 (clean) / 2 (diff) / 1 (wrapper metadata failure) for cross-family consistency.
- `scripts/flux/Invoke-FluxReconcile.ps1`: triggers a Flux reconcile paired with a reviewed diff (NOT a direct `kubectl apply` — Flux's controllers do the actual apply via `--with-source`). Verifies sidecar exists / valid JSON / artifactKind / schemaVersion / scalar-string types / Assert-NonFlagArg on consumed fields / case-sensitive context+kustomization matches / path-layout cross-check (directory AND filename slug) / diffExitCode == 1 (flux's native "changes present" exit code; any other integer is rejected as corrupted) / pathContentSha256 drift detection. Calls `flux reconcile kustomization --with-source --context`.
- `scripts/flux/Invoke-FluxSuspend.ps1`: metadata-only mutation per §3.6. Requires `-Kind` (validated against the flux CR set), `-Name`, `-Context`, `-Reason` (>=5 chars). Writes started+completed JSON entries to `.flux/audit/<contextSlug>/suspend.log` with outcome and exitCode.
- `scripts/flux/Invoke-FluxResume.ps1`: matching resume wrapper with the same validation contract and audit log structure at `.flux/audit/<contextSlug>/resume.log`. Documents that the first post-resume reconcile may apply accumulated drift.

- `config/clusters.yaml`: declarative multi-cluster registry (schemaVersion=1). Each entry has `name` (DNS-1123 label), `context` (kubectl context), optional `kubeconfig`, `tier` (dev/staging/prod), and free-form `labels`.
- `config/clusters.schema.json`: JSON Schema for the registry. Pinned `schemaVersion: 1`.
- `scripts/multi-cluster/_lib/Registry.ps1`: shared helpers — `Read-ClustersRegistry` (yq-based YAML parser), `ConvertFrom-ClusterSelector` (k8s-style label selector with `=`/`!=`), `Test-ClusterMatchesSelector`, `Select-ClustersBySelector` (with the prod-exclusion rule).
- `scripts/multi-cluster/Get-Clusters.ps1`: read-only registry query honoring `tier=prod` exclusion unless `-IncludeProd` or `name=<cluster>` is passed.
- `scripts/multi-cluster/Invoke-KubectlGetAcross.ps1`: parallel `kubectl get <Resource>` fan-out via `ForEach-Object -Parallel -ThrottleLimit`. Aggregates per-cluster results with `cluster`/`tier`/`output`/`exitCode`/`stderr` columns.
- `scripts/multi-cluster/Invoke-HelmStatusAcross.ps1`: matching parallel fan-out for `helm status -n <ns> --kube-context <ctx>`.
- `agents/multi-cluster.agent.md`: persona codifying the operational sequence (show matched clusters first; surface per-cluster failures by name; refuse multi-cluster mutations).
- Per CLAUDE.md §3.5, there is intentionally NO `Invoke-*Across.ps1` mutation wrapper. Cross-cluster mutations must iterate one cluster at a time via the per-tool wrappers under `scripts/<tool>/`.

### Planned
- `CODE_OF_CONDUCT.md` (Contributor Covenant v2.1) and `SECURITY.md` (disclosure policy) will land in a later docs PR.

## [0.1.0] - TBD

Initial harness scaffolding. See README for the target shape.

[Unreleased]: https://github.com/TemplateMechanics/k8s-pilot/compare/main...HEAD
[0.1.0]: https://github.com/TemplateMechanics/k8s-pilot/releases/tag/v0.1.0
