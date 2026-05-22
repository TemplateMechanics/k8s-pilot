# GitHub Copilot — Operational instructions for k8s-pilot

This file is loaded automatically by GitHub Copilot Chat in this repository. It carries the same operational contract as [`CLAUDE.md`](../CLAUDE.md). When the two disagree, the rule that is more conservative wins.

You are working inside **k8s-pilot**, an AI harness for Kubernetes platform engineering wrapping `kubectl`, `kustomize`, `helm`, `argocd`, and `flux`. See [README.md](../README.md) for the project overview and the 12-PR roadmap.

---

## TL;DR for Copilot

1. **Diff before mutate, always.** Never suggest `kubectl apply`, `helm upgrade`, `argocd app sync`, or `flux reconcile` without first running the matching `Invoke-*Diff.ps1` wrapper and getting the user's approval of the diff output.
2. **Never invent API fields.** Consult `skills/kubernetes/SKILL.md` (planned, PR 3) or query the live cluster via MCP (planned, PR 9). If neither is available yet, ask the user to confirm the field name.
3. **Always name the context.** Every mutation wrapper takes `-Context <name>` or `-Cluster <name>`. Do not assume the ambient context.
4. **Multi-cluster mutations require `-AcknowledgeMultiClusterMutation`** and exclude `tier=prod` from fan-out selectors by default.
5. **No GitHub Actions workflows** in this repo at this time. If a validation step is needed, it goes into `scripts/Pre-Commit.ps1` (planned, PR 12), not into `.github/workflows/`.

---

## Tool wrappers (mandatory once they land)

| Tool | Diff wrapper | Mutation wrapper | Path |
|------|--------------|------------------|------|
| `kubectl` + `kustomize` | `Invoke-KubectlDiff.ps1` | `Invoke-KubectlApply.ps1` | `scripts/kubectl/` (PR 4) |
| `helm` | `Invoke-HelmDiff.ps1` | `Invoke-HelmUpgrade.ps1` | `scripts/helm/` (PR 5) |
| `argocd` | `Invoke-ArgocdAppDiff.ps1` | `Invoke-ArgocdAppSync.ps1` | `scripts/argocd/` (PR 6) |
| `flux` | `Invoke-FluxDiff.ps1` | `Invoke-FluxReconcile.ps1` | `scripts/flux/` (PR 7) |

Until a wrapper exists, Copilot's job is to flag the gap, not to fall back to raw CLI suggestions.

---

## Code suggestions for repo contributors

When the user is writing Kubernetes manifests, Helm charts, or wrapper scripts:

- **Manifests / kustomizations**: prefer `apiVersion`s that match the cluster's actual Kubernetes version (ask the user if unsure). Pin image tags by digest in production-tier paths. Use namespaces explicitly, never rely on the default namespace.
- **Helm charts**: keep `values.yaml` as the schema of record. Use `helm.sh/chart` and `app.kubernetes.io/*` recommended labels. Avoid templating logic that produces invalid YAML when a value is missing.
- **PowerShell wrapper scripts**: target PowerShell 7+. Use `[CmdletBinding()]` and `[Parameter(Mandatory)]`. Always pipe errors through `Write-Error` and exit with a non-zero code on failure. Emit JSON or structured objects, not free text, when the output is consumed by another script.
- **Argo CD Applications**: pin `targetRevision` to a SHA or tag, never `HEAD`. Use `syncPolicy.automated.prune: false` unless the user has opted in for that specific app.
- **Flux Kustomizations / HelmReleases**: set `interval` explicitly. Use `dependsOn` for ordering. Never use `force: true` without an audit reason in the commit message.

---

## What NOT to suggest

- `kubectl apply -f -` piped from stdin in a one-liner.
- `helm upgrade --install` without `--atomic` and without a prior `helm diff`.
- `argocd app sync --force --prune` without explicit user confirmation per call.
- `flux reconcile kustomization X --with-source` from chat — always go through the wrapper.
- Workflow files under `.github/workflows/` (the repo owner is conserving GitHub Actions minutes).
- Any change that adds `CODE_OF_CONDUCT.md` or `SECURITY.md` outside of the planned docs PR (PR 11).

---

## PR review behavior

When Copilot is reviewing a PR in this repo:

- Flag any new file that mutates cluster state without going through `scripts/<tool>/`.
- Flag any `kubectl`/`helm`/`argocd`/`flux` invocation in a non-wrapper script that lacks an explicit `-Context` / `--kube-context` / `--server`.
- Flag inconsistency between PR-N markers in different files (the README is the source of truth for the roadmap).
- Flag references to `CODE_OF_CONDUCT.md` or `SECURITY.md` that are not framed as "planned, lands in a later docs PR".
- Flag any change under `.github/workflows/`.

When the diff is plumbing or docs, keep review comments terse and concrete.
