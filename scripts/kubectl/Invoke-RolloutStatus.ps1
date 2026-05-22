<#
.SYNOPSIS
    Block until a workload's rollout completes or times out (CLAUDE.md §3.1).

.DESCRIPTION
    Thin wrapper around `kubectl rollout status` with mandatory -Context, -Kind,
    -Name, -Namespace. Read-only verification step; safe to run any time.

.PARAMETER Kind
    Workload kind. Must be one of Deployment, StatefulSet, DaemonSet.

.PARAMETER Name
    Workload name.

.PARAMETER Namespace
    Namespace of the workload.

.PARAMETER Context
    Kubernetes context.

.PARAMETER TimeoutSeconds
    Maximum seconds to wait for rollout. Default 300 (5 min).

.OUTPUTS
    kubectl rollout status output. Exit 0 on success, non-zero on timeout/failure.

.EXAMPLE
    pwsh ./scripts/kubectl/Invoke-RolloutStatus.ps1 -Kind Deployment -Name web -Namespace web -Context staging
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Deployment', 'StatefulSet', 'DaemonSet')]
    [string] $Kind,

    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Namespace,
    [Parameter(Mandatory)] [string] $Context,

    [ValidateRange(10, 3600)]
    [int] $TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../_lib/Context.ps1"
Assert-KubectlAvailable

# Read-only: context safety check is light. Ensure the context exists; do not
# require ambient match (read-only checks should work even when the operator is
# investigating a different cluster from the same shell).
if (-not (Test-KubectlContextExists -Context $Context)) {
    throw "Context '$Context' is not defined in the active kubeconfig."
}

$kindLower = $Kind.ToLowerInvariant()
& kubectl --context $Context -n $Namespace rollout status "$kindLower/$Name" --timeout "${TimeoutSeconds}s"
exit $LASTEXITCODE
