# Multi-cluster operations

This document explains the multi-cluster registry, selector model, and
fan-out safety rules that the `scripts/multi-cluster/*` wrappers
implement. The authoritative contract is in
[`CLAUDE.md`](../CLAUDE.md) §3.5 and rule R4; this doc explains the
*why* behind those rules and how operators interact with them.

## The registry: `config/clusters.yaml`

The registry is a flat YAML list of named clusters. Each entry
declares the kubectl context name, an environment tier, and free-form
labels for selector matching. See
[`config/clusters.schema.json`](../config/clusters.schema.json) for
the exact schema.

```yaml
schemaVersion: 1
clusters:
  - name: dev-us-east-1
    context: arn:aws:eks:us-east-1:111111111111:cluster/dev
    tier: dev
    labels:
      provider: aws
      region: us-east-1
      team: platform
```

| Field | Required | Notes |
|---|---|---|
| `name` | yes | DNS-1123 label (lower-case alphanumerics + `-`); unique across the file. Used as the selector key `name=` and in artifact paths. |
| `context` | yes | The kubectl context name. **The registry does not create or modify your kubeconfig** — these names must already exist in the kubeconfig your shell is using. |
| `kubeconfig` | no | Optional path to a non-default kubeconfig file. Omit to use the operator's default. |
| `tier` | yes | One of `dev`, `staging`, `prod`. Drives the prod-exclusion rule below. |
| `labels` | no | Map of string → string. Free-form. Used as additional selector keys. |

## Selector syntax

Selectors borrow from Kubernetes label selectors (a tiny subset). The
fan-out wrappers parse them into a list of `(key, op, value)` terms.

| Form | Meaning |
|---|---|
| `tier=staging` | tier field equals "staging" |
| `tier!=prod` | tier field does not equal "prod" |
| `tier=staging,region=us-east-1` | both terms must match (AND) |
| `name=kind-local` | top-level `name` field equals (special key) |
| `context=arn:aws:eks:...` | top-level `context` field equals (special key) |
| `team=payments` | label `team` equals "payments" |

**Recognized special keys** (matched against top-level fields, not labels):
`name`, `context`, `tier`. Anything else is a label match against
`labels.<key>`.

**Operators**: `=` and `!=` only. There is no `in (...)` syntax yet.
Empty selectors and empty terms are rejected (a trailing comma is an
editing error, not "match all").

## The prod-exclusion rule (R4)

`tier=prod` clusters are **excluded by default** from selector matches.
This is the single rule that distinguishes the multi-cluster layer
from a naive `for ctx in $contexts; do ...; done` loop.

There are two opt-in mechanisms, used for different purposes:

| Mechanism | When to use |
|---|---|
| `name=<cluster>` in the selector | You know exactly which prod cluster you want. Opt-in is per-name; other prod clusters in the registry still stay excluded. |
| `-IncludeProd` switch on the wrapper | You want a label-based selector (e.g. `team=payments`) to widen to prod too. Wrappers print the matched prod cluster set before fan-out so you can abort. |

There is no mutation-side `-IncludeProd` because there is no
multi-cluster mutation wrapper (CLAUDE.md §3.5). Cross-cluster
mutations must iterate one cluster at a time via the per-tool
wrappers under `scripts/<tool>/`, with a pause for explicit user
approval between clusters.

## Wrappers

| Wrapper | Mode | What it does |
|---|---|---|
| `Get-Clusters.ps1` | read | Returns matching cluster objects (`name`, `context`, `tier`, `kubeconfig`, `labels`). |
| `Invoke-KubectlGetAcross.ps1` | read | Parallel `kubectl get <Resource>` across matched clusters. Pass `-AllNamespaces` for `-A`; otherwise scopes to the kubectl default (or `-Namespace <ns>`). |
| `Invoke-HelmStatusAcross.ps1` | read | Parallel `helm status <release> -n <ns> --kube-context <ctx>` across matched clusters. |

All three honor `-IncludeProd`, accept `-MaxParallel <int>` to cap
concurrency (default 8), and emit per-cluster structured rows with
`cluster`, `context`, `tier`, `output`, `exitCode`, `stderr` columns.

## Failure semantics

Per-cluster failures do not abort the fan-out — the wrapper emits a
row for every matched cluster with `exitCode` and `stderr` populated,
then sets the wrapper's overall exit code to 1 if any per-cluster
call failed. An unexpected exception inside the parallel scriptblock
(e.g. binary missing mid-flight) also produces a row with
`exitCode=-1` and the exception message in `stderr`, so no cluster
silently disappears from the output set.

## Required dependency

`mikefarah/yq v4+` must be on PATH. The wrappers detect:

- `yq` missing → throw with the install URL.
- `yq` present but version < 4 → throw (v3's CLI syntax is incompatible).
- `yq` present but looks like the Python `kislyuk/yq` reimplementation
  (which is `jq` under the hood) → throw (different parser).

Install via your package manager (`brew install yq`, `winget install
MikeFarah.yq`, etc.) or `go install github.com/mikefarah/yq/v4@latest`.

## Operator workflow

1. **Inspect the matched set first**: run `Get-Clusters.ps1
   -Selector <expr>` and read the output. Make sure the blast radius
   is what you intend. The fan-out wrappers also print the matched
   set (with a `[PROD]` marker on prod-tier rows) before they fan out.
2. **Fan out a read**: use one of the `Invoke-*Across.ps1` wrappers.
   Aggregate the results in PowerShell — the per-cluster rows compose
   well with `Where-Object`, `Group-Object`, `Sort-Object tier`.
3. **For mutations, iterate one cluster at a time**: there is no
   multi-cluster mutation wrapper. Loop over `Get-Clusters.ps1`
   output and call the per-tool wrappers explicitly with the cluster's
   `context`, pausing for explicit user approval between clusters.

## Anti-patterns

- Hand-parsing `config/clusters.yaml` from chat instead of going
  through `Get-Clusters.ps1` (bypasses the prod-exclusion rule).
- Wrapping the per-tool mutation wrappers in a `foreach $c in
  $clusters` loop without per-cluster approval (re-creates the
  hazard CLAUDE.md §3.5 forbids; the spelling doesn't matter).
- Using `-IncludeProd` and then ignoring the matched-set print-out
  the wrapper produces — the print is the safety; read it.
- Storing per-cluster secrets in `config/clusters.yaml` (the schema
  has no field for them, and the file is committed; use the operator's
  kubeconfig + an external secret store).
