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
    namespace-only/         install just the `baseline` Namespace (for the Helm and HelmRelease paths that bring their own workload)
  helm/                     packaged equivalent of the kustomize app
    Chart.yaml
    values.yaml
    values-staging.yaml
    templates/
  argocd/
    application.yaml        Application CR pointing at the kustomize path
    appproject.yaml         project + RBAC scope
    install/
      kustomization.yaml    kustomize wrapper so the kubectl flow can install both CRs
  flux/
    gitrepository.yaml      Flux Source for the same kustomize path
    flux-kustomization.yaml Flux reconciler (named to avoid collision with kustomize's own kustomization.yaml convention)
    helmrelease.yaml        alternative path via the helm chart
    install-kustomization/  kustomize wrapper: GitRepository + Flux Kustomization
    install-helmrelease/    kustomize wrapper: GitRepository + HelmRelease (alt path)
```

## Running each wrapper family

> Pre-flight: ensure `kubectl config current-context` is what you intend.
> The MUTATION wrappers (`Invoke-KubectlApply`, `Invoke-HelmUpgrade`,
> `Invoke-ArgocdAppSync`, `Invoke-FluxReconcile`, etc.) require an
> explicit `-Context <name>` and assert it matches the ambient context.
> The diff wrappers also require `-Context` so the artifact is tagged
> with a cluster identity. A few wrappers do NOT take `-Context`
> because they target something else: `Invoke-HelmTemplate` and
> `Invoke-FluxBuild` are pure rendering with no cluster contact;
> `Validate-Manifests` operates on rendered files; the `Invoke-Argocd*`
> wrappers take `-Server` instead of `-Context` because Argo CD has
> its own session. The multi-cluster wrappers resolve target clusters
> from `-Selector` against `config/clusters.yaml`.

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
# Invoke-KubectlDiff writes the diff to the artifact file whose path
# is returned in $diff; it does NOT print the diff body to the console.
# Open the file to review:
Get-Content -LiteralPath $diff   # or `cat $diff` on POSIX shells

# If the diff is acceptable:
./scripts/kubectl/Invoke-KubectlApply.ps1 -DiffFile $diff -Context kind-kind

./scripts/kubectl/Invoke-RolloutStatus.ps1 `
    -Kind Deployment -Name baseline-web -Namespace baseline -Context kind-kind
```

### helm (CLAUDE.md §3.2)

> The Helm wrappers do NOT pass `--create-namespace` (see CLAUDE.md
> §3.2 rationale). Create the namespace alone via the bundled
> namespace-only kustomize wrapper so you don't also install the
> kustomize-managed workload (which would conflict with this Helm
> release):
>
> ```powershell
> $diff = ./scripts/kubectl/Invoke-KubectlDiff.ps1 `
>     -Path examples/baseline-stack/kustomize/namespace-only `
>     -Context kind-kind
> ./scripts/kubectl/Invoke-KubectlApply.ps1 -DiffFile $diff -Context kind-kind
> ```
>
> Do not shell out to `kubectl create namespace` ad hoc; that bypasses
> the diff-before-mutate contract (CLAUDE.md R1).

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

# Invoke-HelmUpgrade refuses to run if the diff sidecar records
# diffExitCode != 2 (helm-diff convention: 2 = changes present).
# If $LASTEXITCODE from the diff is 0 (no changes), skip upgrade:
if ($LASTEXITCODE -eq 2) {
    ./scripts/helm/Invoke-HelmUpgrade.ps1 -DiffFile $diff -Namespace baseline -Context kind-kind
} else {
    Write-Host "No changes to upgrade (helm-diff exit $LASTEXITCODE)."
}
```

### argocd (CLAUDE.md §3.3)

> **Edit `examples/baseline-stack/argocd/application.yaml` first**:
> replace the `targetRevision: REPLACE_WITH_COMMIT_SHA_OR_TAG_BEFORE_APPLY`
> placeholder with an immutable commit SHA or tag. Applying the
> Application without this edit will leave it in an Unknown/Failed
> state in Argo CD because the placeholder isn't a real git ref.

```powershell
./scripts/argocd/Invoke-ArgocdLogin.ps1 -Server argocd.dev.example.com

# The Application CR itself goes through the kubectl flow first.
# Invoke-KubectlDiff requires a kustomize directory, so apply the
# install/ wrapper instead of the raw manifests:
$diff = ./scripts/kubectl/Invoke-KubectlDiff.ps1 `
    -Path examples/baseline-stack/argocd/install -Context kind-kind
./scripts/kubectl/Invoke-KubectlApply.ps1 -DiffFile $diff -Context kind-kind

# Then drive the actual workload sync via the argocd wrappers:
$rev = '<sha-of-the-source-commit>'
$appDiff = ./scripts/argocd/Invoke-ArgocdAppDiff.ps1 `
    -App baseline -Revision $rev -Server argocd.dev.example.com

# Invoke-ArgocdAppSync refuses to sync if the diff sidecar's native
# diffExitCode != 1 (argocd convention: 1 = changes present, wrapper
# exit 2). Skip sync when there's nothing to sync:
if ($LASTEXITCODE -eq 2) {
    ./scripts/argocd/Invoke-ArgocdAppSync.ps1 `
        -App baseline -DiffFile $appDiff -Revision $rev -Server argocd.dev.example.com
    ./scripts/argocd/Invoke-ArgocdAppWait.ps1 `
        -App baseline -TimeoutSeconds 300 -Server argocd.dev.example.com
} else {
    Write-Host "No changes to sync (argocd app diff wrapper exit $LASTEXITCODE)."
}
```

### flux (CLAUDE.md §3.4)

> **Apply the Flux CRs first.** The Flux wrappers operate on a
> Kustomization that already exists in the cluster. The kubectl
> wrapper flow only accepts kustomize directories, so use the
> bundled install wrapper:
>
> ```powershell
> $diff = ./scripts/kubectl/Invoke-KubectlDiff.ps1 `
>     -Path examples/baseline-stack/flux/install-kustomization `
>     -Context kind-kind
> ./scripts/kubectl/Invoke-KubectlApply.ps1 -DiffFile $diff -Context kind-kind
> ```
>
> Apply `flux/install-kustomization/` (GitRepository + Flux
> Kustomization) OR `flux/install-helmrelease/` (GitRepository +
> HelmRelease) — they are alternative reconciliation paths; applying
> both would race. The HelmRelease variant requires the `baseline`
> Namespace to exist first; use the namespace-only wrapper to create
> just the Namespace without also installing the kustomize workload:
>
> ```powershell
> $diff = ./scripts/kubectl/Invoke-KubectlDiff.ps1 `
>     -Path examples/baseline-stack/kustomize/namespace-only `
>     -Context kind-kind
> ./scripts/kubectl/Invoke-KubectlApply.ps1 -DiffFile $diff -Context kind-kind
> ```

```powershell
$rendered = ./scripts/flux/Invoke-FluxBuild.ps1 `
    -Kustomization baseline -Path examples/baseline-stack/kustomize/overlays/dev

./scripts/Validate-Manifests.ps1 -Path $rendered

$diff = ./scripts/flux/Invoke-FluxDiff.ps1 `
    -Kustomization baseline `
    -Path examples/baseline-stack/kustomize/overlays/dev `
    -Context kind-kind

# Invoke-FluxReconcile refuses to run if the diff sidecar records
# flux's native diffExitCode != 1 (flux convention: 1 = changes
# present, wrapper exit 2). Skip when clean:
if ($LASTEXITCODE -eq 2) {
    ./scripts/flux/Invoke-FluxReconcile.ps1 `
        -Kustomization baseline -DiffFile $diff -Context kind-kind
} else {
    Write-Host "No changes to reconcile (flux diff wrapper exit $LASTEXITCODE)."
}
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
