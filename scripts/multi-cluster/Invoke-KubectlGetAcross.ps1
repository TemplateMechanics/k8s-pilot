<#
.SYNOPSIS
    Read-only fan-out of `kubectl get <resource>` across matching clusters
    (CLAUDE.md §3.5 Read).

.DESCRIPTION
    Read-only. Resolves clusters via the same selector + prod-exclusion
    rules as Get-Clusters.ps1, then runs `kubectl get <Resource>`
    against each cluster's context IN PARALLEL (PowerShell 7+
    ForEach-Object -Parallel). Scope semantics:
      - No -Namespace and no -AllNamespaces  -> kubectl default
        (cluster-default namespace for namespaced kinds; cluster-scope
        for cluster-scoped kinds like nodes/namespaces/crds).
      - -Namespace <ns>                       -> `-n <ns>`.
      - -AllNamespaces                        -> `-A` (rejected by
        kubectl for cluster-scoped kinds).
    Aggregates per-cluster results into a single object stream with a
    `cluster` column for grouping.

    No mutations. There is intentionally no multi-cluster mutation wrapper
    (CLAUDE.md §3.5): cluster-state mutations must be iterated one cluster
    at a time via the per-tool wrappers.

.PARAMETER Selector
    Cluster registry selector (see Get-Clusters.ps1).

.PARAMETER Resource
    Kubernetes resource passed to `kubectl get` (e.g. 'pods', 'deployments').

.PARAMETER Namespace
    Optional namespace scope (passed as `-n <namespace>`). Omit for the
    cluster default scope — note that this means namespaced resources
    will only show the kubectl default (usually `default`); pass
    `-AllNamespaces` to explicitly fan out across all namespaces for
    namespaced kinds.

.PARAMETER AllNamespaces
    Pass `-A` / `--all-namespaces` to kubectl. Only valid for namespaced
    resources; kubectl rejects this for cluster-scoped kinds (nodes,
    namespaces, clusterroles, crds, ...). Mutually exclusive with
    -Namespace.

.PARAMETER MaxParallel
    Maximum concurrent cluster queries. Default 8. Cap so kubeconfig /
    API-server rate limiting doesn't get hammered.

.PARAMETER RegistryPath
    Override config/clusters.yaml.

.PARAMETER IncludeProd
    See Get-Clusters.ps1.

.OUTPUTS
    Array of [pscustomobject]@{ cluster; context; tier; output; exitCode; stderr }.
    Exit codes:
      0  - every per-cluster kubectl returned 0
      1  - either at least one per-cluster kubectl failed (per-cluster
           code in output objects) OR a preflight throw (missing yq,
           invalid registry YAML, invalid selector, registry-supplied
           context/kubeconfig that starts with '-'). Throws hit
           PowerShell's default exit code 1 before any cluster query.
      2  - no clusters matched the selector
      3  - kubectl binary not in PATH
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Selector,
    [Parameter(Mandatory)] [string] $Resource,
    [string] $Namespace,
    [switch] $AllNamespaces,
    [ValidateRange(1, 32)] [int] $MaxParallel = 8,
    [string] $RegistryPath = 'config/clusters.yaml',
    [switch] $IncludeProd
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/_lib/Registry.ps1"
. "$PSScriptRoot/../_lib/Context.ps1"

Assert-NonFlagArg -Value $Resource -Name '-Resource'
if ($Namespace) { Assert-NonFlagArg -Value $Namespace -Name '-Namespace' }
if ($Namespace -and $AllNamespaces) {
    Write-Error "-Namespace and -AllNamespaces are mutually exclusive."
    exit 1
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Error "kubectl not found in PATH."
    exit 3
}

$clusters = Select-ClustersBySelector `
    -Selector     $Selector `
    -RegistryPath $RegistryPath `
    -IncludeProd:$IncludeProd

if ($clusters.Count -eq 0) {
    Write-Warning "No clusters matched selector '$Selector'. Note: tier=prod clusters are excluded by default; pass -IncludeProd or use an explicit name=<cluster> term to opt in."
    exit 2
}

# Validate registry-supplied values that will be passed to native CLIs.
# A registry entry with a leading '-' in context/kubeconfig could be parsed
# as a flag by kubectl. Catch this BEFORE we fan out so we fail fast at one
# place rather than per-cluster inside the parallel block.
foreach ($c in $clusters) {
    Assert-NonFlagArg -Value $c.context -Name "registry.cluster[$($c.name)].context"
    if ($c.kubeconfig) {
        Assert-NonFlagArg -Value $c.kubeconfig -Name "registry.cluster[$($c.name)].kubeconfig"
    }
}

# Surface the resolved cluster list (especially prod-tier rows) BEFORE
# fan-out so the operator can abort if the blast radius isn't what they
# intended. Required by CLAUDE.md R4 when -IncludeProd is used.
Write-Information "Resolved $($clusters.Count) cluster(s) for selector '$Selector':" -InformationAction Continue
foreach ($c in $clusters) {
    $prodMarker = if ($c.tier -ceq 'prod') { ' [PROD]' } else { '' }
    Write-Information "  - $($c.name) (context=$($c.context), tier=$($c.tier))$prodMarker" -InformationAction Continue
}
Write-Information "Fanning kubectl get $Resource out to $($clusters.Count) cluster(s) ($MaxParallel concurrent)..." -InformationAction Continue

$results = $clusters | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
    $c = $_
    # Always wrap in try/catch + finally so an unexpected exception
    # inside the parallel block still emits a structured result row
    # for this cluster (exitCode=-1, stderr=exception message). Without
    # this the cluster would be silently missing from the result set.
    try {
        $kubectlArgs = @('--context', $c.context, 'get', $using:Resource)
        if ($using:Namespace) {
            $kubectlArgs += @('-n', $using:Namespace)
        }
        elseif ($using:AllNamespaces) {
            $kubectlArgs += '-A'
        }
        if ($c.kubeconfig) {
            $kubectlArgs = @('--kubeconfig', $c.kubeconfig) + $kubectlArgs
        }

        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $out = & kubectl @kubectlArgs 2>$errFile
            $exit = $LASTEXITCODE
            $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        }
        finally {
            Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
        }

        [pscustomobject]@{
            cluster  = $c.name
            context  = $c.context
            tier     = $c.tier
            output   = (@($out) -join "`n")
            exitCode = $exit
            stderr   = $err
        }
    }
    catch {
        [pscustomobject]@{
            cluster  = $c.name
            context  = $c.context
            tier     = $c.tier
            output   = ''
            exitCode = -1
            stderr   = "Wrapper exception: $($_.Exception.Message)"
        }
    }
}

# Print structured output.
$results

$anyFailed = @($results | Where-Object { $_.exitCode -ne 0 }).Count -gt 0
if ($anyFailed) {
    Write-Warning "At least one per-cluster kubectl failed; inspect the .exitCode and .stderr fields per result row."
    exit 1
}
exit 0
