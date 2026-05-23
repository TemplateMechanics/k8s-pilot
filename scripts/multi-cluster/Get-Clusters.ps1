<#
.SYNOPSIS
    List clusters from config/clusters.yaml matching a selector
    (CLAUDE.md §3.5 List).

.DESCRIPTION
    Read-only registry query. Honors the prod-exclusion rule: clusters
    with tier=prod are excluded unless `-IncludeProd` is passed OR the
    selector explicitly names them via `name=<cluster>`.

.PARAMETER Selector
    Kubernetes-style label selector. Examples:
        'tier=staging'
        'tier=staging,region=us-east-1'
        'team=payments,tier!=prod'
        'name=prod-us-east-1'  (explicit prod opt-in via name=)

.PARAMETER RegistryPath
    Override the default config/clusters.yaml path.

.PARAMETER IncludeProd
    Include tier=prod clusters in label-based matches. Has no effect on
    selectors that already name prod clusters explicitly via name=.

.OUTPUTS
    Array of [pscustomobject] (one per matching cluster):
        name, context, kubeconfig (nullable), tier, labels (hashtable)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Selector,
    [string] $RegistryPath = 'config/clusters.yaml',
    [switch] $IncludeProd
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/_lib/Registry.ps1"

$clusters = Select-ClustersBySelector `
    -Selector     $Selector `
    -RegistryPath $RegistryPath `
    -IncludeProd:$IncludeProd

if ($clusters.Count -eq 0) {
    Write-Warning "No clusters matched selector '$Selector' (after prod-exclusion). Pass -IncludeProd or use 'name=' for explicit prod opt-in."
}

# Emit the structured objects to the pipeline so callers can pipe into
# ForEach-Object / other wrappers. Format-Table by default for interactive use.
$clusters
