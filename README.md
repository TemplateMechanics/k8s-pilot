# k8s-pilot

**k8s-pilot** is an AI-powered development harness for Kubernetes platform engineering in VS Code. It bridges the gap between AI coding assistants (Claude Code, GitHub Copilot, Cursor, Codex) and the Kubernetes toolchain — `kubectl`, `kustomize`, `helm`, `argocd`, and `flux` — by providing structured instructions, automation scripts, validation tooling, and reference material.

Modeled on [TemplateMechanics/tf-pilot](https://github.com/TemplateMechanics/tf-pilot) and [TemplateMechanics/dt-pilot](https://github.com/TemplateMechanics/dt-pilot).

> **Status:** This README describes the **target** shape of k8s-pilot. The repository is being built up across a series of small, reviewable PRs. Paths and scripts referenced below that are not yet present in the working tree are explicitly marked **(planned — lands in PR&nbsp;N)** and will be introduced in subsequent PRs.

## What problem does this solve?

LLMs are confidently wrong about Kubernetes. They invent API fields, skip `kubectl diff` before `apply`, push helm upgrades without `helm diff`, sync Argo CD apps against the wrong target revision, and apply manifests across the wrong context. k8s-pilot is a *harness* in the Mitchell-Hashimoto sense: it engineers the environment so the agent cannot easily make those mistakes.

It does this with three things:

1. **Instructions** that tell the AI exactly how to behave on this codebase (`CLAUDE.md`, `.github/copilot-instructions.md`, `agents/kubernetes.agent.md` — **planned, lands in PR&nbsp;2**).
2. **A single authoritative skill reference** the AI reads before editing (`skills/kubernetes/SKILL.md` — **planned, lands in PR&nbsp;3**).
3. **Wrapped automation** the AI is required to use instead of typing `kubectl`/`helm`/`argocd`/`flux` directly (`scripts/*.ps1` — **planned, lands in PRs&nbsp;4–7**).

It also includes:

- A **multi-cluster registry and fan-out layer** so agents can search, diff, and report across many clusters at once while keeping mutations strictly per-cluster and tier-gated (`config/clusters.yaml`, `scripts/multi-cluster/*` — **planned, lands in PR&nbsp;8**).
- A **Kubernetes MCP server integration** so agents can query a single cluster's context, resource graphs, and events with first-party tooling before mutating workloads (**planned, lands in PR&nbsp;9**).

## Architecture

k8s-pilot is designed as a layered control plane around the Kubernetes toolchain, not just a set of helper scripts. The key design choice is split responsibility:

- **Read/discovery path:** Kubernetes MCP server (resources, events, logs) + reference docs
- **Write/mutation path:** guarded scripts with explicit diff / dry-run / apply gates per tool family

That split keeps agents fast at lookup while making mutation workflows deterministic and auditable.

```text
User request
  -> Agent instructions (CLAUDE.md / .github/copilot-instructions.md / agents/*.agent.md)
  -> Authoritative skill (skills/kubernetes/SKILL.md)
  -> Discovery (Kubernetes MCP per-cluster, docs/, reflected API catalog,
                multi-cluster fan-out via scripts/multi-cluster/)
  -> Mutation via wrappers (scripts/*.ps1 only, single cluster per call by default)
      - kubectl + kustomize: diff -> apply -> rollout status
      - helm:                template -> diff -> upgrade -> rollback gate
      - argocd:              app diff -> app sync (with --dry-run preview)
      - flux:                build -> diff -> reconcile
  -> Quality gates (manifest schema, kubeconform, policy)
```

### Instruction layering

1. `CLAUDE.md` / `.github/copilot-instructions.md`: operational safety rules and workflow constraints
2. `agents/*.agent.md`: tool-specific conversational personas (kubernetes, helm, argocd, flux, chief-engineer)
3. `skills/kubernetes/SKILL.md`: deep, authoritative Kubernetes reference
4. `docs/`: design references and operational playbooks
5. `examples/`: executable examples that validate expected patterns

## What's innovative here

1. **Four-tool layered control plane**
   `kubectl` + `kustomize` for raw manifests, `helm` for chart-managed workloads, `argocd` and `flux` for GitOps reconciliation — all wrapped by a single consistent script contract (`Invoke-*` verbs, plan-before-apply discipline, structured output).
2. **Plan-as-artifact discipline**
   `Invoke-KubectlDiff.ps1`, `Invoke-HelmDiff.ps1`, and `Invoke-ArgocdAppDiff.ps1` (**planned, PRs 4–6**) emit structured diff artifacts that downstream apply/upgrade scripts require. This makes change review explicit and repeatable.
3. **MCP-first reads, scripts-only writes**
   Agent workflows use MCP for live cluster context and wrappers for mutations to avoid direct, unsafe CLI behavior. The AI may never type `kubectl apply -f` or `helm upgrade` directly.
4. **Context-pinning safety**
   Every mutation wrapper requires an explicit `-Context` parameter (or asserts a pinned context file). The AI cannot accidentally hit prod because the active context changed.
5. **GitOps tools as peers, not alternatives**
   Argo CD and Flux wrappers coexist. Examples demonstrate when each is appropriate (Argo CD for app-of-apps UI flows, Flux for Kustomize/Helm controller reconciliation).
6. **Multi-cluster as a first-class operation**
   A registry-backed fan-out layer (`config/clusters.yaml`, `scripts/multi-cluster/*.ps1` — planned, PR 8) lets the agent ask questions like "diff this kustomization across all `tier=staging` clusters" or "show me which clusters have CrashLoopBackOff pods in `team=payments`". Mutations are still strictly single-cluster per call unless the caller passes `-AcknowledgeMultiClusterMutation`, and `tier=prod` clusters are excluded from any fan-out by default.

## Quick start

> **Note:** Most of these paths land in subsequent PRs. The Quick start is the steady-state experience.

1. Fork this repository (recommended) or copy the harness into your Kubernetes platform repo.
2. Open the project in VS Code with the [Kubernetes extension](https://marketplace.visualstudio.com/items?itemName=ms-kubernetes-tools.vscode-kubernetes-tools) installed.
3. Install the supporting CLIs: PowerShell 7+, `kubectl`, `kustomize`, `helm` (3.x), `argocd`, `flux`. Optional: `kubeconform`, `kube-score`, `polaris`, `trivy`.
4. Talk to your AI assistant in natural language. It will read `CLAUDE.md` (or `.github/copilot-instructions.md`) and follow the operational sequence.
5. Configure MCP via `.vscode/mcp.json` (**planned, PR 9**). The Kubernetes MCP server is the default discovery path.
6. Before pushing changes, run `./scripts/Pre-Commit.ps1` (**planned, PR 12**) for the local validation gate.

## The mandatory diff/apply discipline

> **WARNING:** Just like tf-pilot enforces plan-before-apply and dt-pilot enforces dry-run-before-deploy, k8s-pilot enforces a **diff-before-mutate** discipline. The AI will refuse to call `kubectl apply`, `helm upgrade`, `argocd app sync`, or `flux reconcile` without first running the corresponding `Invoke-*Diff.ps1` wrapper, presenting the diff output, and waiting for explicit user approval.

## Requirements

- PowerShell `7.0+` (cross-platform; `pwsh`)
- `kubectl` `>= 1.28`
- `kustomize` `>= 5.0` (or use the `kubectl kustomize` built-in)
- `helm` `>= 3.13` with `helm-diff` plugin
- `argocd` CLI `>= 2.10`
- `flux` CLI `>= 2.2`
- VS Code with the **Kubernetes** extension
- Optional: [kubeconform](https://github.com/yannh/kubeconform), [kube-score](https://github.com/zegl/kube-score), [polaris](https://github.com/FairwindsOps/polaris), [trivy](https://github.com/aquasecurity/trivy)

## What you don't have to do

| You normally have to | k8s-pilot does for you |
|---|---|
| Memorize Kubernetes API fields per kind | MCP + skill reference provide live API/resource context |
| Remember every validation/lint/security command | `./scripts/Validate-Manifests.ps1` (planned) runs kubeconform + kube-score + polaris |
| Risk direct `kubectl apply` against the wrong context | `Invoke-KubectlApply.ps1` (planned) requires an explicit `-Context` and a saved diff |
| Risk a blind `helm upgrade` | `Invoke-HelmUpgrade.ps1` (planned) requires the output of `Invoke-HelmDiff.ps1` |
| Sync the wrong Argo CD revision | `Invoke-ArgocdAppSync.ps1` (planned) requires an explicit `-Revision` and a diff artifact |
| Drift between `flux build` and what's reconciled | `Invoke-FluxReconcile.ps1` (planned) emits a build/diff/reconcile triplet |
| Hand-poll many clusters for the same question | `scripts/multi-cluster/Invoke-KubectlGetAcross.ps1` (planned) fans out with a label selector and aggregates results |
| Accidentally mutate many clusters at once | Multi-cluster mutations require `-AcknowledgeMultiClusterMutation` and exclude `tier=prod` unless explicitly named |
| Manually maintain version-pinned reference docs | `skills/kubernetes/SKILL.md` is the single source of truth, refreshed per release |

## How a request flows through this harness

1. User asks for a change in chat.
2. Agent loads instruction files and safety rules.
3. Agent consults `skills/kubernetes/SKILL.md` before editing.
4. Agent discovers cluster/resource context with MCP and `docs/`.
5. Agent edits manifests / values / kustomizations with repository patterns.
6. Agent runs validation wrappers (`Validate-Manifests.ps1`, kubeconform, policy).
7. Agent runs the relevant diff wrapper (kubectl / helm / argocd / flux) and presents the diff summary.
8. User approves the mutation explicitly.
9. Agent runs the matching apply / upgrade / sync / reconcile wrapper.
10. Pre-commit gate (`Pre-Commit.ps1`) re-validates before push.

## Layout (target)

| Path | Purpose | Status |
|---|---|---|
| `CLAUDE.md` | Instructions loaded by Claude Code | PR 2 |
| `.github/copilot-instructions.md` | Instructions loaded by GitHub Copilot | PR 2 |
| `agents/kubernetes.agent.md` | Conversational persona for raw `kubectl` + `kustomize` work | PR 2 |
| `agents/helm.agent.md` | Persona for Helm chart authoring and upgrades | PR 2 |
| `agents/argocd.agent.md` | Persona for Argo CD application management | PR 2 |
| `agents/flux.agent.md` | Persona for Flux Kustomization and HelmRelease management | PR 2 |
| `agents/chief-systems-engineer.agent.md` | Cross-tool architectural persona | PR 2 |
| `agents/multi-cluster.agent.md` | Persona for multi-cluster fan-out queries and mutation safety | PR 8 |
| `skills/kubernetes/SKILL.md` | Authoritative kubectl/kustomize/helm/argocd/flux reference | PR 3 |
| `scripts/kubectl/` | kubectl + kustomize wrappers (diff/apply/rollout) | PR 4 |
| `scripts/helm/` | helm wrappers (template/diff/upgrade/rollback) | PR 5 |
| `scripts/argocd/` | argocd CLI wrappers (login/app diff/app sync) | PR 6 |
| `scripts/flux/` | flux CLI wrappers (build/diff/reconcile) | PR 7 |
| `config/clusters.yaml` + `config/clusters.schema.json` | Multi-cluster registry (named clusters, contexts, tiers, labels) | PR 8 |
| `scripts/multi-cluster/` | Cross-cluster fan-out wrappers (`Get-Clusters.ps1`, `Invoke-KubectlGetAcross.ps1`, etc.) | PR 8 |
| `.vscode/mcp.json` | Workspace MCP integration (Kubernetes MCP server) | PR 9 |
| `examples/baseline-stack/` | End-to-end example covering all four tools + multi-cluster fan-out | PR 10 |
| `docs/K8S-REFERENCE.md` | Deep Kubernetes API and workload reference | PR 11 |
| `docs/MULTI-CLUSTER.md` | Multi-cluster registry, selection model, and mutation safety | PR 11 |
| `docs/BRANCH-WORKFLOW.md` | Branch protection and required-check merge workflow | PR 11 |
| `docs/SECURITY-SCANNING.md` | Trivy / kube-score / polaris policy guidance | PR 11 |
| `docs/RUNBOOK.md` | Operational troubleshooting runbook | PR 11 |
| `scripts/Pre-Commit.ps1` | Local pre-push validation gate | PR 12 |

## License

MIT. See [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). All PRs are reviewed by GitHub Copilot before merge as part of the autonomous PR loop documented in `docs/BRANCH-WORKFLOW.md` (**planned, PR 11**).

## Security

A formal `SECURITY.md` disclosure policy will land in a later docs PR. Until then, please report any harness-level issue privately to the repository owner via GitHub.
