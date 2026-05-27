# Contributing to k8s-pilot

Thanks for your interest in contributing. k8s-pilot is built up via small, reviewable PRs against `main`. The contribution loop is intentionally lightweight so AI agents and human contributors follow the same path.

## Ground rules

1. **One PR, one concern.** A PR introduces one capability or fixes one issue. If you find yourself touching unrelated files, split the PR.
2. **Diff before mutate.** Any change that adds or modifies a wrapper script for `kubectl`, `helm`, `argocd`, or `flux` must keep the diff-before-mutate discipline. Wrappers that apply changes must require a diff artifact or a `-Force` flag with a clear justification.
3. **No GitHub Actions CI on this repo at this time.** Validation is local-only via `scripts/Pre-Commit.ps1`. If you believe a workflow is needed, open an issue first.
4. **Skill files are authoritative.** Do not duplicate API reference content into agent personas, docs, or scripts. Link to `skills/kubernetes/SKILL.md` instead.
5. **Context safety.** Any script that mutates cluster state must take an explicit `-Context` (or `-Cluster <name>` resolved via `config/clusters.yaml`) before invoking `kubectl`/`helm`/`argocd`/`flux`. Never trust the ambient kubeconfig context.
6. **Multi-cluster safety.** Read/diff wrappers may fan out across many clusters. Mutation wrappers must run against a single cluster per invocation unless the caller passes `-AcknowledgeMultiClusterMutation`, and `tier=prod` clusters in `config/clusters.yaml` must be excluded from any fan-out by default (selector must explicitly include them).

## Development workflow

```bash
# 1. Fork and clone
git clone git@github.com:<you>/k8s-pilot.git
cd k8s-pilot

# 2. Create a feature branch
git checkout -b feat/<short-description>

# 3. Make your change. Keep diffs minimal and focused.

# 4. Run the local pre-push gate (-Context is required because the
#    gate auto-renders kustomize directories under examples/)
pwsh ./scripts/Pre-Commit.ps1 -Context <your-context>

# 5. Commit using Conventional Commits
git commit -m "feat(scripts): add kubectl diff wrapper"

# 6. Open a PR
gh pr create --fill
```

## Commit message convention

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). The scopes used in this repo:

| Scope | When to use |
|---|---|
| `meta` | Repository hygiene (README, LICENSE, CHANGELOG, etc.) |
| `agents` | Agent personas and instruction files |
| `skill` | The authoritative skill reference |
| `scripts` | kubectl/kustomize/helm/argocd/flux wrapper scripts |
| `mcp` | MCP server configuration and launchers |
| `examples` | The baseline stack and any sample manifests |
| `docs` | Deep-dive references and runbooks |
| `policy` | Validation, lint, security, or policy gates |

## Pull request lifecycle

Every PR goes through:

1. **Copilot review** — automatically requested on PR open. Copilot's feedback is treated as advisory but must be addressed (applied, deferred with a comment, or declined with rationale).
2. **Maintainer review** — a human maintainer reviews after Copilot has been reconciled.
3. **Squash merge** — PRs merge as a single squashed commit with the PR title as the commit subject.

PRs that introduce a new wrapper script must include:
- The wrapper itself under `scripts/<tool>/`
- A usage block in the script header
- A reference in the relevant agent persona (`agents/<tool>.agent.md`)
- Coverage in `skills/kubernetes/SKILL.md` if it introduces a new concept

## Reporting bugs and proposing features

Open a GitHub issue with:
- What you tried
- What you expected
- What actually happened
- The minimal manifest / script / chart that reproduces the issue

For larger proposals (new tool integrations, structural changes), open a short design note under `docs/design/` as a PR first, before implementation.

## Code of conduct

Contributors are expected to act with respect, good faith, and professionalism in all project interactions.
