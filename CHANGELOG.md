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
- Agent personas under `agents/`:
  - `chief-systems-engineer.agent.md` — cross-tool architectural voice (Kustomize vs Helm, Argo CD vs Flux).
  - `kubernetes.agent.md` — raw kubectl + kustomize manifests and overlays.
  - `helm.agent.md` — chart authoring, values, releases, upgrade/rollback safety.
  - `argocd.agent.md` — Application/AppProject/ApplicationSet, sync waves, app-of-apps.
  - `flux.agent.md` — GitRepository/Kustomization/HelmRelease, reconciliation, suspend/resume.

### Planned
- `CODE_OF_CONDUCT.md` (Contributor Covenant v2.1) and `SECURITY.md` (disclosure policy) will land in a later docs PR.
- `agents/multi-cluster.agent.md` will land with the multi-cluster registry in PR 8.

## [0.1.0] - TBD

Initial harness scaffolding. See README for the target shape.

[Unreleased]: https://github.com/TemplateMechanics/k8s-pilot/compare/main...HEAD
[0.1.0]: https://github.com/TemplateMechanics/k8s-pilot/releases/tag/v0.1.0
