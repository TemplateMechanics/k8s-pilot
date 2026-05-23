<#
.SYNOPSIS
    Read-only fan-out of `helm status <release>` across matching clusters
    (CLAUDE.md §3.5 Status).

.DESCRIPTION
    Same fan-out and prod-exclusion semantics as Invoke-KubectlGetAcross.ps1.
    Read-only; no mutations.

.PARAMETER Selector
    Cluster registry selector.

.PARAMETER Release
    Helm release name.

.PARAMETER Namespace
    Release namespace (Helm releases are namespaced).

.PARAMETER MaxParallel
    Default 8.

.PARAMETER RegistryPath
    Override config/clusters.yaml.

.PARAMETER IncludeProd
    See Get-Clusters.ps1.

.OUTPUTS
    Array of [pscustomobject]@{ cluster; context; tier; release; namespace; output; exitCode; stderr }.
    Exit codes:
      0  - every per-cluster helm returned 0
      1  - at least one failed
      2  - no clusters matched
      3  - helm binary not in PATH
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Selector,
    [Parameter(Mandatory)] [string] $Release,
    [Parameter(Mandatory)] [string] $Namespace,
    [ValidateRange(1, 32)] [int] $MaxParallel = 8,
    [string] $RegistryPath = 'config/clusters.yaml',
    [switch] $IncludeProd
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/_lib/Registry.ps1"
. "$PSScriptRoot/../_lib/Context.ps1"

Assert-NonFlagArg -Value $Release   -Name '-Release'
Assert-NonFlagArg -Value $Namespace -Name '-Namespace'

if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    Write-Error "helm not found in PATH."
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

# Validate registry-supplied native-CLI args before fan-out (see same
# rationale in Invoke-KubectlGetAcross.ps1).
foreach ($c in $clusters) {
    Assert-NonFlagArg -Value $c.context -Name "registry.cluster[$($c.name)].context"
    if ($c.kubeconfig) {
        Assert-NonFlagArg -Value $c.kubeconfig -Name "registry.cluster[$($c.name)].kubeconfig"
    }
}

# Surface the matched cluster list (especially prod-tier rows) before
# fan-out per CLAUDE.md R4 / agents/multi-cluster.agent.md.
Write-Information "Resolved $($clusters.Count) cluster(s) for selector '$Selector':" -InformationAction Continue
foreach ($c in $clusters) {
    $prodMarker = if ($c.tier -ceq 'prod') { ' [PROD]' } else { '' }
    Write-Information "  - $($c.name) (context=$($c.context), tier=$($c.tier))$prodMarker" -InformationAction Continue
}
Write-Information "Fanning helm status '$Release' (-n $Namespace) out to $($clusters.Count) cluster(s) ($MaxParallel concurrent)..." -InformationAction Continue

$results = $clusters | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
    $c = $_
    $helmArgs = @('status', $using:Release, '-n', $using:Namespace, '--kube-context', $c.context)
    if ($c.kubeconfig) {
        $helmArgs += @('--kubeconfig', $c.kubeconfig)
    }
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $out = & helm @helmArgs 2>$errFile
        $exit = $LASTEXITCODE
        $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
    }
    finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{
        cluster   = $c.name
        context   = $c.context
        tier      = $c.tier
        release   = $using:Release
        namespace = $using:Namespace
        output    = (@($out) -join "`n")
        exitCode  = $exit
        stderr    = $err
    }
}

$results
$anyFailed = @($results | Where-Object { $_.exitCode -ne 0 }).Count -gt 0
if ($anyFailed) {
    Write-Warning "At least one per-cluster helm status failed; inspect the .exitCode and .stderr fields."
    exit 1
}
exit 0
