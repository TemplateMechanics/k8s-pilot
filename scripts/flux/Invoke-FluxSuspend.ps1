<#
.SYNOPSIS
    Suspend reconciliation on a Flux resource (CLAUDE.md §3.4 / §3.6).

.DESCRIPTION
    Metadata-only mutation per CLAUDE.md §3.6 (exempt from the diff-artifact
    rule because the change IS the parameter — flips `spec.suspend: true`).
    Still requires explicit `-Context` and a meaningful `-Reason` recorded
    in the local audit log.

.PARAMETER Kind
    Flux CR kind. One of: kustomization, helmrelease, gitrepository,
    helmrepository, ocirepository, bucket, alert, provider, receiver,
    imageupdateautomation, imagepolicy, imagerepository.

.PARAMETER Name
    Flux CR name.

.PARAMETER Reason
    Required free-text reason (>=5 chars) recorded to
    `.flux/audit/<contextSlug>/suspend.log`.

.PARAMETER Context
    Kubernetes context.

.PARAMETER OverrideAmbientContext
    See CLAUDE.md R3.

.OUTPUTS
    flux's stdout. Exit codes:
      0   - suspend succeeded
      3   - flux binary not in PATH
      other - propagated from `flux suspend`
    Preflight failures terminate with PS default exit 1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('kustomization','helmrelease','gitrepository','helmrepository','ocirepository','bucket','alert','provider','receiver','imageupdateautomation','imagepolicy','imagerepository')]
    [string] $Kind,

    [Parameter(Mandatory)] [string] $Name,

    [Parameter(Mandatory)]
    [ValidateScript({
        if ($null -eq $_) { throw "-Reason must be a meaningful description (>=5 chars)." }
        if ($_.Trim().Length -lt 5) { throw "-Reason must be a meaningful description (>=5 chars)." }
        $true
    })]
    [string] $Reason,

    [Parameter(Mandatory)] [string] $Context,

    [switch] $OverrideAmbientContext
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

Assert-SafePathSegment -Value $Name -Name '-Name'
Assert-NonFlagArg      -Value $Name    -Name '-Name'
Assert-NonFlagArg      -Value $Context -Name '-Context'
Assert-ContextSafety -Context $Context -OverrideAmbientContext:$OverrideAmbientContext

if (-not (Get-Command flux -ErrorAction SilentlyContinue)) {
    Write-Error "flux not found in PATH."
    exit 3
}

$contextSlug = ConvertTo-SafeFilename -Value $Context
$auditDir = Join-Path (Join-Path '.flux' 'audit') $contextSlug
if (-not (Test-Path -LiteralPath $auditDir)) {
    New-Item -ItemType Directory -LiteralPath $auditDir -Force | Out-Null
}
$logFile = Join-Path $auditDir 'suspend.log'

$startedEntry = [pscustomobject]@{
    timestamp = (Get-Date -AsUTC).ToString('o')
    event     = 'started'
    action    = 'suspend'
    kind      = $Kind
    name      = $Name
    context   = $Context
    reason    = $Reason
} | ConvertTo-Json -Compress
Add-Content -LiteralPath $logFile -Value $startedEntry -Encoding utf8

Write-Information "Suspending $Kind/$Name on context '$Context' (reason: $Reason)..." -InformationAction Continue
& flux suspend $Kind $Name --context $Context
$exit = $LASTEXITCODE

$outcome = if ($exit -eq 0) { 'succeeded' } else { 'failed' }
$completedEntry = [pscustomobject]@{
    timestamp = (Get-Date -AsUTC).ToString('o')
    event     = 'completed'
    action    = 'suspend'
    outcome   = $outcome
    exitCode  = $exit
    kind      = $Kind
    name      = $Name
    context   = $Context
} | ConvertTo-Json -Compress
Add-Content -LiteralPath $logFile -Value $completedEntry -Encoding utf8

if ($exit -ne 0) {
    Write-Error "flux suspend $Kind $Name failed (exit $exit). Audit log: $logFile"
    exit $exit
}
Write-Information "Suspend complete. Audit log: $logFile" -InformationAction Continue
exit 0
