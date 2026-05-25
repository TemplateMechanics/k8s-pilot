# baseline-stack — end-to-end wrapper-flow example

This directory is the **canonical exercise** for k8s-pilot. It is a minimal
nginx-based app that can be deployed via every supported tool family
(kubectl+kustomize, helm, argocd, flux), so contributors can drive the
wrappers end-to-end against a real (kind / minikube / dev) cluster.

The manifests themselves are deliberately tiny. The point of this
example is the **wrapper flow**, not the workload.

## Layout

```
examples/baseline-stack/
  kustomize/
    base/                   plain manifests + kustomization
    overlays/
      dev/                  per-tier overlay (replicas, image tag)
      staging/
  helm/                     packaged equivalent of the kustomize app
    Chart.yaml
    values.yaml
    values-staging.yaml
    templates/
  argocd/
    application.yaml        Application CR pointing at the kustomize path
    appproject.yaml         project + RBAC scope
  flux/
    gitrepository.yaml      Flux Source for the same kustomize path
    kustomization.yaml      Flux reconciler
    helmrelease.yaml        alternative path via the helm chart
```

## Running each wrapper family

> Pre-flight: ensure `kubectl config current-context` is what you intend.
> The wrappers REQUIRE you to pass `-Context <name>` and assert it matches.

### kubectl + kustomize (CLAUDE.md §3.1)

```powershell
# Render -> validate -> diff -> apply -> wait
$rendered = ./scripts/kubectl/Invoke-KustomizeBuild.ps1 `
    -Path examples/baseline-stack/kustomize/overlays/dev `
    -Context kind-kind

./scripts/Validate-Manifests.ps1 -Path $rendered

$diff = ./scripts/kubectl/Invoke-KubectlDiff.ps1 `
    -Path examples/baseline-stack/kustomize/overlays/dev `
    -Context kind-kind
# Review the printed diff. If acceptable:

./scripts/kubectl/Invoke-KubectlApply.ps1 -DiffFile $diff -Context kind-kind

./scripts/kubectl/Invoke-RolloutStatus.ps1 `
    -Kind Deployment -Name baseline-web -Namespace baseline -Context kind-kind
```

### helm (CLAUDE.md §3.2)

```powershell
$rendered = ./scripts/helm/Invoke-HelmTemplate.ps1 `
    -ChartPath examples/baseline-stack/helm `
    -ValuesFile examples/baseline-stack/helm/values.yaml `
    -Release baseline -Namespace baseline

./scripts/Validate-Manifests.ps1 -Path $rendered

$diff = ./scripts/helm/Invoke-HelmDiff.ps1 `
    -ChartPath examples/baseline-stack/helm `
    -ValuesFile examples/baseline-stack/helm/values.yaml `
    -Release baseline -Namespace baseline -Context kind-kind

./scripts/helm/Invoke-HelmUpgrade.ps1 -DiffFile $diff -Namespace baseline -Context kind-kind
```

### argocd (CLAUDE.md §3.3)

```powershell
./scripts/argocd/Invoke-ArgocdLogin.ps1 -Server argocd.dev.example.com

# The Application CR itself goes through the kubectl flow first
# (it's a normal manifest):
$diff = ./scripts/kubectl/Invoke-KubectlDiff.ps1 `
    -Path examples/baseline-stack/argocd -Context kind-kind
./scripts/kubectl/Invoke-KubectlApply.ps1 -DiffFile $diff -Context kind-kind

# Then drive the actual workload sync via the argocd wrappers:
$rev = '<sha-of-the-source-commit>'
$appDiff = ./scripts/argocd/Invoke-ArgocdAppDiff.ps1 `
    -App baseline -Revision $rev -Server argocd.dev.example.com
./scripts/argocd/Invoke-ArgocdAppSync.ps1 `
    -App baseline -DiffFile $appDiff -Revision $rev -Server argocd.dev.example.com
./scripts/argocd/Invoke-ArgocdAppWait.ps1 `
    -App baseline -TimeoutSeconds 300 -Server argocd.dev.example.com
```

### flux (CLAUDE.md §3.4)

```powershell
$rendered = ./scripts/flux/Invoke-FluxBuild.ps1 `
    -Kustomization baseline -Path examples/baseline-stack/kustomize/overlays/dev

./scripts/Validate-Manifests.ps1 -Path $rendered

$diff = ./scripts/flux/Invoke-FluxDiff.ps1 `
    -Kustomization baseline `
    -Path examples/baseline-stack/kustomize/overlays/dev `
    -Context kind-kind

./scripts/flux/Invoke-FluxReconcile.ps1 `
    -Kustomization baseline -DiffFile $diff -Context kind-kind
```

### multi-cluster (CLAUDE.md §3.5)

```powershell
# Show pods across every dev cluster:
./scripts/multi-cluster/Invoke-KubectlGetAcross.ps1 `
    -Selector 'tier=dev' -Resource pods -AllNamespaces

# Helm status of this release on every staging cluster:
./scripts/multi-cluster/Invoke-HelmStatusAcross.ps1 `
    -Selector 'tier=staging' -Release baseline -Namespace baseline
```

## What this example does NOT do

- It does not provision a cluster. Bring your own (kind / minikube / EKS / GKE).
- It does not configure Argo CD or Flux — install them per their upstream docs first.
- It does not include real secrets. The example does not need any; a
  production fork should use SealedSecrets / ESO / SOPS as described in
  `skills/kubernetes/SKILL.md` §2.2.
- It does not run automatically. There is no CI here (k8s-pilot is
  local-only by design — see [CONTRIBUTING.md](../../CONTRIBUTING.md)).
