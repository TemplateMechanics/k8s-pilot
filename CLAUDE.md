# CLAUDE.md — Operational instructions for Claude Code in k8s-pilot

You are working inside **k8s-pilot**, an AI harness for Kubernetes platform engineering wrapping `kubectl`, `kustomize`, `helm`, `argocd`, and `flux`. This file is your operational contract. Follow it before consulting any other reference.

Modeled on [tf-pilot/CLAUDE.md](https://github.com/TemplateMechanics/tf-pilot/blob/main/CLAUDE.md) and [dt-pilot/CLAUDE.md](https://github.com/TemplateMechanics/dt-pilot/blob/main/CLAUDE.md). See [README.md](README.md) for the project overview and the planned PR roadmap.

---

## 1. Mandatory operational sequence

For every user request that touches cluster state, follow this sequence in order. Do not skip steps. Do not reorder them.

1. **Load instructions.** This file (`CLAUDE.md`), then the relevant agent persona under `agents/`, then the skill (`skills/kubernetes/SKILL.md` — planned, PR 3).
2. **Discover, don't guess.** Use the Kubernetes MCP server (planned, PR 9) or the `scripts/multi-cluster/` fan-out wrappers (planned, PR 8) to read current cluster state. Do not invent API field names — look them up.
3. **Plan the change in chat.** Describe what kinds, namespaces, contexts, and clusters will be touched. Identify the blast radius before writing files.
4. **Edit manifests, values, kustomizations, charts, or app definitions** using the repository's existing patterns.
5. **Run the matching diff wrapper** for the tool family you're touching (see Section 3). Present the diff output to the user.
6. **Wait for explicit user approval** of the diff before mutating.
7. **Run the matching mutation wrapper** with the approved diff artifact and an explicit `-Context` or `-Cluster`.
8. **Run the post-mutation check** (`kubectl rollout status`, `helm status`, `argocd app wait`, or `flux reconcile --status`) and report the outcome.

If a wrapper script for the tool you need does not yet exist (the harness is being built up across PRs 4–7), stop and tell the user. Do not silently fall back to typing the bare CLI.

---

## 2. Hard rules

| # | Rule |
|---|------|
| R1 | Never call `kubectl apply`, `kubectl delete`, `kubectl patch`, `kubectl replace`, `helm upgrade`, `helm install`, `helm uninstall`, `helm rollback`, `argocd app sync`, `argocd app delete`, `flux reconcile`, or `flux suspend` directly. Always use the corresponding wrapper under `scripts/<tool>/`. |
| R2 | Never mutate cluster state without first showing a diff and getting explicit user approval for that specific diff. |
| R3 | Never trust the ambient kubeconfig context. Every mutation wrapper requires an explicit `-Context <name>` argument or a `-Cluster <name>` reference resolved through `config/clusters.yaml` (planned, PR 8). |
| R4 | Never fan out a mutation across multiple clusters unless the user explicitly passes `-AcknowledgeMultiClusterMutation`, and never include `tier=prod` clusters in a fan-out selector unless they are named explicitly. |
| R5 | Never duplicate API reference content into agent personas, scripts, or docs. The single source of truth is `skills/kubernetes/SKILL.md` (planned, PR 3). Link to it instead. |
| R6 | Never add a GitHub Actions workflow to this repo at this time. Validation is local-only via PowerShell scripts. |
| R7 | Never commit secrets, kubeconfigs, generated tokens, or `*.pem`/`*.key`/`*.crt` material. Treat anything not in `.gitignore` with suspicion before staging. |
| R8 | When the user asks for a change that violates these rules, refuse and explain which rule applies. Offer the closest compliant alternative. |

---

## 3. Tool families and their wrapper contracts

Every tool family has a parallel script contract: a **diff** wrapper that emits an artifact, and a **mutation** wrapper that requires that artifact.

### 3.1 `kubectl` + `kustomize`  (scripts/kubectl/, planned PR 4)

| Verb | Wrapper | Required arg | Emits / requires |
|------|---------|--------------|------------------|
| Validate | `Invoke-KubeconformValidate.ps1` | `-Path` | Pass/fail summary |
| Build | `Invoke-KustomizeBuild.ps1` | `-Path`, `-Context` | Rendered manifest to `kustomize-build/<context>/<name>.yaml` |
| Diff | `Invoke-KubectlDiff.ps1` | `-Path`, `-Context` | Diff artifact at `kustomize-build/<context>/<name>.diff` |
| Apply | `Invoke-KubectlApply.ps1` | `-DiffFile`, `-Context` | Applies only the manifest that produced the diff |
| Rollout | `Invoke-RolloutStatus.ps1` | `-Kind`, `-Name`, `-Namespace`, `-Context` | Blocks until rollout completes or times out |

### 3.2 `helm`  (scripts/helm/, planned PR 5)

| Verb | Wrapper | Required arg | Emits / requires |
|------|---------|--------------|------------------|
| Template | `Invoke-HelmTemplate.ps1` | `-ChartPath`, `-ValuesFile`, `-Release` | Rendered manifests to `helm-output/<release>/templated.yaml` |
| Diff | `Invoke-HelmDiff.ps1` | `-ChartPath`, `-ValuesFile`, `-Release`, `-Context` | Diff artifact at `helm-output/<release>/<context>.diff` |
| Upgrade | `Invoke-HelmUpgrade.ps1` | `-DiffFile`, `-Context` | Requires `helm-diff` plugin |
| Rollback | `Invoke-HelmRollback.ps1` | `-Release`, `-Revision`, `-Context` | Requires explicit revision number |

### 3.3 `argocd`  (scripts/argocd/, planned PR 6)

| Verb | Wrapper | Required arg | Emits / requires |
|------|---------|--------------|------------------|
| Login | `Invoke-ArgocdLogin.ps1` | `-Server` | Stores session in the gitignored Argo CD config dir |
| App diff | `Invoke-ArgocdAppDiff.ps1` | `-App`, `-Revision` | Diff artifact at `.argocd/<app>/<revision>.diff` |
| App sync | `Invoke-ArgocdAppSync.ps1` | `-App`, `-DiffFile`, `-Revision` | Mutation; requires diff artifact |
| App wait | `Invoke-ArgocdAppWait.ps1` | `-App`, `-Timeout` | Blocks until Healthy + Synced |

### 3.4 `flux`  (scripts/flux/, planned PR 7)

| Verb | Wrapper | Required arg | Emits / requires |
|------|---------|--------------|------------------|
| Build | `Invoke-FluxBuild.ps1` | `-Kustomization`, `-Path` | Rendered output to `.flux/<kustomization>.yaml` |
| Diff | `Invoke-FluxDiff.ps1` | `-Kustomization`, `-Path`, `-Context` | Diff artifact at `.flux/<kustomization>/<context>.diff` |
| Reconcile | `Invoke-FluxReconcile.ps1` | `-Kustomization`, `-DiffFile`, `-Context` | Triggers reconciliation; requires diff artifact |
| Suspend | `Invoke-FluxSuspend.ps1` | `-Kind`, `-Name`, `-Reason` | Suspends a resource with an audit reason |

### 3.5 Multi-cluster fan-out  (scripts/multi-cluster/, planned PR 8)

| Verb | Wrapper | Required arg | Notes |
|------|---------|--------------|-------|
| List | `Get-Clusters.ps1` | `-Selector` | Returns clusters from `config/clusters.yaml` matching a label selector |
| Read | `Invoke-KubectlGetAcross.ps1` | `-Selector`, `-Resource` | Parallel fan-out, aggregated table output |
| Status | `Invoke-HelmStatusAcross.ps1` | `-Selector`, `-Release` | Parallel fan-out for helm release status |
| (Mutation) | _intentionally absent_ | — | Multi-cluster mutations are NOT a single wrapper. Iterate one cluster at a time. |

---

## 4. Choosing which agent persona to load

Each tool family has a persona under `agents/`. Load the relevant one in addition to this file when the user's request narrows to a specific tool.

| Persona | Load when the user is asking about… |
|---|---|
| `agents/kubernetes.agent.md` | Raw manifests, kustomize overlays, namespace surgery, debugging Pods/Services/Deployments |
| `agents/helm.agent.md` | Authoring a chart, modifying values, upgrading a release, rolling back |
| `agents/argocd.agent.md` | Application definitions, projects, sync waves, RBAC, app-of-apps |
| `agents/flux.agent.md` | Kustomization CRs, HelmRelease CRs, GitRepository sources, reconciliation issues |
| `agents/multi-cluster.agent.md` | Anything spanning multiple clusters (planned, PR 8) |
| `agents/chief-systems-engineer.agent.md` | Cross-tool architectural questions, choosing between Argo CD and Flux, designing the boundary between Helm and Kustomize |

If the request mixes tools (e.g. "use Helm under Argo CD"), load both personas plus the chief-systems-engineer persona.

---

## 5. The diff/apply discipline (long form)

This is the most important rule in the harness. Repeat it back to the user if they ask you to skip it.

> **You will refuse to mutate cluster state until a diff artifact has been generated by the matching diff wrapper, shown to the user, and explicitly approved for that specific diff. "Just apply it" is not a valid override.**

Concrete examples:

- ❌ User: "Apply this manifest to dev." → You generate `kubectl apply -f manifest.yaml`. **Wrong.** You must `Invoke-KubectlDiff.ps1` first.
- ❌ User: "Upgrade the chart." → You generate `helm upgrade --install`. **Wrong.** You must `Invoke-HelmDiff.ps1` first.
- ❌ User: "Sync the Argo app." → You generate `argocd app sync my-app`. **Wrong.** You must `Invoke-ArgocdAppDiff.ps1` first.
- ✅ Correct sequence: edit → diff wrapper → present diff in chat → user approves diff → mutation wrapper takes the diff artifact as input.

If the user pushes back ("this is dev, just do it"), reply: "The harness requires the diff step even on dev because the same workflow runs against prod. The diff takes seconds. Want me to run `Invoke-KubectlDiff.ps1`?"

---

## 6. Context safety (long form)

Every mutation wrapper takes `-Context <name>` or `-Cluster <name>`. The reason:

- `kubectl config current-context` is mutable global state. A previous shell, a different terminal, a tool that called `kubectl config use-context`, or a stale kubeconfig merge can silently retarget you.
- The harness defends against this by **requiring** the context to be named in the command. The wrapper compares the named context to the ambient one and refuses to run if they differ unless `-OverrideAmbientContext` is also passed.

When the user says "deploy to staging", do not assume their current context is staging. Ask: "Which named context in your kubeconfig is staging? Or, if `config/clusters.yaml` is configured, which cluster name?"

---

## 7. PR loop discipline

This repository is built up via small, reviewable PRs. When you contribute changes:

1. One PR, one concern. If you find yourself touching unrelated files, split the PR.
2. Use Conventional Commits with the scopes listed in [CONTRIBUTING.md](CONTRIBUTING.md).
3. After opening a PR, request a Copilot review (the bot login is `copilot-pull-request-reviewer[bot]` against the REST `/requested_reviewers` endpoint).
4. Address every Copilot comment — apply, defer with a written reason, or decline with a written reason.
5. After addressing comments, **resolve each addressed review thread** via the GraphQL `resolveReviewThread` mutation before merging. Do not leave addressed threads open.
6. Squash-merge.

---

## 8. What this harness is NOT

- It is not a Kubernetes installer. Bring your own cluster(s).
- It is not a GitOps engine. It wraps `argocd` and `flux`; it does not replace them.
- It is not a policy engine. It wraps validation (kubeconform, kube-score, polaris) — policy decisions are the user's.
- It does not run in CI on this repo at this time. All validation is local-only.

---

## 9. When in doubt

Stop, summarize what you understand, and ask. The cost of a clarifying question is one round-trip. The cost of an unapproved mutation against the wrong cluster is potentially a recovery incident.
