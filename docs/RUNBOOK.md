# Runbook — common operational scenarios

Quick-reference for things that go wrong (or look like they're going
wrong) when driving the k8s-pilot wrappers. Each entry is a symptom,
the likely cause, and the fix.

For deep Kubernetes API reference (kind shapes, field-level
gotchas), see [`skills/kubernetes/SKILL.md`](../skills/kubernetes/SKILL.md).

---

## Diff/apply pairing

### `Invoke-KubectlApply.ps1` exits 4 with "metadata context does not match"

**Cause**: the diff was rendered against a different `-Context` than
the one passed to apply.

**Fix**: re-run `Invoke-KubectlDiff.ps1 -Context <intended>` to
produce a fresh diff artifact, then apply it.

### `Invoke-HelmUpgrade.ps1` exits 4 with "sha mismatch" on the values file

**Cause**: the values file was edited after the diff was generated.
The wrapper refuses to apply a chart against a different values file
than what the operator reviewed.

**Fix**: re-run `Invoke-HelmDiff.ps1` with the same parameters to
refresh the sidecar SHA, then upgrade.

### `Invoke-HelmUpgrade.ps1` exits 4 with "diffExitCode must be 2"

**Cause**: the diff was clean (no changes), so the wrapper refuses
to bump the release revision for nothing.

**Fix**: make the actual change you want to apply in the chart or
values, re-run `Invoke-HelmDiff.ps1`, then upgrade.

### `Invoke-FluxReconcile.ps1` exits 4 with "pathContentSha256 sha mismatch"

**Cause**: the source path (the directory the Flux Kustomization
points at) was edited after the diff. Same drift protection as the
Helm case.

**Fix**: re-run `Invoke-FluxDiff.ps1 -Kustomization <name> -Path
<path> -Context <ctx>`, then reconcile.

---

## Context safety (R3)

### Any mutation wrapper exits with "Refusing to run: requested -Context X differs from ambient Y"

**Cause**: the kubectl `current-context` is not the cluster you
named. Most often: you switched contexts in another terminal and the
kubeconfig file change is now visible in this terminal too.

**Fix**: either `kubectl config use-context X` first OR pass
`-OverrideAmbientContext` to the wrapper if you legitimately want to
script context switches per call (typical for multi-cluster
iteration).

### `Get-Clusters.ps1` returns nothing for a selector that includes prod

**Cause**: prod is excluded from selector matches by default (R4).

**Fix**: pass `-IncludeProd`, OR name the prod cluster(s) explicitly
via `name=<cluster>` terms in the selector. See
[`MULTI-CLUSTER.md`](MULTI-CLUSTER.md).

---

## Argo CD

### `Invoke-ArgocdAppDiff.ps1` exits 5 with "-Revision HEAD is rejected"

**Cause**: Argo CD revisions must pin to an immutable SHA or tag —
syncing against `HEAD` defeats the audit trail.

**Fix**: pass an actual commit SHA or tag (`git log -1 --format=%H`
on the source repo to grab the current commit).

### `Invoke-ArgocdAppSync.ps1` exits 4 with "Diff metadata server slug does not match server directory"

**Cause**: the diff artifact was moved on disk after generation, or
the sidecar's `server` field was hand-edited.

**Fix**: re-generate the diff via `Invoke-ArgocdAppDiff.ps1 -App
<app> -Revision <rev> -Server <server>`. Do not move artifacts out
of `.argocd/<serverSlug>/<appSlug>/`.

---

## Flux

### `flux build kustomization` fails with "no matches for kind Kustomization in version kustomize.config.k8s.io/v1beta1"

**Cause**: the path you handed to `Invoke-FluxBuild.ps1` is a
kustomize directory (correct) but Flux is failing to recognize one of
its CRDs (e.g. a HelmRelease) because the CRD isn't installed in
your local environment.

**Fix**: install the missing CRDs locally (`flux install
--dry-run`), or limit the build path to a directory that only
references built-in Kubernetes kinds.

### Flux Kustomization stuck in `NotReady` after `Invoke-FluxReconcile.ps1` exits 0

**Cause**: the reconcile was triggered but the controller has not
yet succeeded. `Invoke-FluxReconcile` does not block on health by
design (Flux's controllers are eventually consistent).

**Fix**: `flux get kustomization <name> --context <ctx>` to see the
status. If still NotReady after a few intervals, `flux events --for
kustomization/<name>` for the controller log.

---

## Multi-cluster

### `Invoke-KubectlGetAcross.ps1` returns rows with `exitCode=-1`

**Cause**: an exception inside the `ForEach-Object -Parallel`
scriptblock (e.g. kubectl crashed; temp-file I/O failed; kubeconfig
unreadable). The wrapper emits a structured row for every matched
cluster so failures aren't silently missing.

**Fix**: read the `stderr` column for the failing rows; usually it's
a clear message. If kubectl was missing on PATH at script start, the
wrapper would have exited 3 instead.

### `Get-Clusters.ps1` throws "Registry contains duplicate cluster name(s)"

**Cause**: `config/clusters.yaml` has two entries with the same
`name`. The wrapper rejects this because `name=<dup>` in a selector
would otherwise match both, potentially including a prod row.

**Fix**: edit `config/clusters.yaml` to make every name unique. If
you have two physical clusters with the same logical name in
different regions, encode that in the name (e.g. `web-prod-us-east-1`,
`web-prod-eu-west-1`).

---

## Helm

### `Invoke-HelmDiff.ps1` exits 3 with "helm-diff plugin not installed"

**Cause**: the helm-diff plugin (https://github.com/databus23/helm-diff)
is not installed. The wrapper requires it because `helm upgrade
--dry-run` does not produce a usable diff.

**Fix**: `helm plugin install https://github.com/databus23/helm-diff`.

### `Invoke-HelmUpgrade.ps1` exits with the underlying helm exit code, --atomic auto-rolled back

**Cause**: the upgrade failed AFTER changes were applied; `--atomic`
rolled the release back to the previous revision.

**Fix**: read helm's output for the underlying error. Typical
causes: workload failed readiness probe within the `--timeout` (5m
default), CRD conflict, image pull failure. Bump the timeout via
`-TimeoutSeconds <n>` if the chart is genuinely slow (Postgres,
Kafka).

---

## MCP

### `Start-KubernetesMcpServer.ps1` exits 4 with "Environment variable 'HOME' referenced in catalog launcher is unset/empty"

**Cause**: the docker launcher in the catalog references
`${env:HOME}/.kube` for the kubeconfig mount, but `HOME` isn't set
in your shell (typical on Windows where `USERPROFILE` is the
equivalent).

**Fix**: the wrapper falls back to PowerShell's `$HOME` automatic
variable for the `HOME` case specifically, so this should be rare.
If you still hit it, `$env:HOME = $HOME` before invoking the
script.

### MCP client reports "Failed to start server: argv corrupted"

**Cause**: status output is being written to stdout instead of
stderr, polluting the MCP stdio transport.

**Fix**: the wrapper writes to stderr by design — if you're piping
its output anywhere, ensure you preserve stderr separation.

---

## When in doubt

- Re-read [`CLAUDE.md`](../CLAUDE.md) — the hard rules answer most
  "should I do X" questions before you have to ask anyone.
- For API field shapes, look up
  [`skills/kubernetes/SKILL.md`](../skills/kubernetes/SKILL.md)
  before guessing.
- Run `Get-Help <script>.ps1 -Full` for the script's documented
  parameters and exit codes.
- The PR loop discipline applies to runbook entries too — if you
  hit a new failure mode that's not here, send a PR to add it.
