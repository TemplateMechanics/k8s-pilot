<#
.SYNOPSIS
    Wait for an Argo CD Application to become Healthy and Synced
    (CLAUDE.md §3.3 App wait). Read-only post-mutation verification.

.DESCRIPTION
    Thin wrapper around `argocd app wait --health --sync`. Read-only; safe
    to run at any time.

.PARAMETER App
    Argo CD Application name.

.PARAMETER Timeout
    Maximum time to wait, in seconds. Default 300 (5 min).

.PARAMETER Server
    Argo CD API server host.

.OUTPUTS
    argocd's stdout. Exit codes:
      0   - app is Healthy + Synced before timeout
      3   - argocd binary not in PATH
      other - propagated from `argocd app wait`
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $App,
    [Parameter(Mandatory)] [string] $Server,
    [ValidateRange(10, 3600)] [int] $TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

Assert-NonFlagArg -Value $App    -Name '-App'
Assert-NonFlagArg -Value $Server -Name '-Server'

if (-not (Get-Command argocd -ErrorAction SilentlyContinue)) {
    Write-Error "argocd not found in PATH."
    exit 3
}

Write-Information "Waiting for Argo CD app '$App' on server '$Server' to become Healthy + Synced (up to ${TimeoutSeconds}s)..." -InformationAction Continue
& argocd app wait $App --server $Server --health --sync --timeout $TimeoutSeconds
exit $LASTEXITCODE
