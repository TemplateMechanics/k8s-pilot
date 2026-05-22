<#
.SYNOPSIS
    Roll back a Helm release to a named prior revision (CLAUDE.md §3.2 / §3.6).

.DESCRIPTION
    Metadata-only mutation per CLAUDE.md §3.6 (exempt from the diff-artifact
    rule because the intent is captured by -Revision). Still requires:
      - explicit -Context
      - explicit -Namespace
      - explicit -Revision number (not "the previous one")
      - explicit -Reason recorded in the audit log

    Before executing, renders the cross-revision manifest delta (current vs
    target) and presents it to the operator for approval. The wrapper will
    pause for explicit confirmation unless -SkipConfirm is passed.

.PARAMETER Release
    Helm release name.

.PARAMETER Namespace
    Release namespace.

.PARAMETER Revision
    Target revision number. Find with: helm history <release> -n <ns> --kube-context <ctx>

.PARAMETER Context
    Kubernetes context.

.PARAMETER Reason
    Required free-text reason recorded to the audit log at
    .helm/<context>/<namespace>/<release>/rollback.log.

.PARAMETER OverrideAmbientContext
    See CLAUDE.md R3.

.PARAMETER SkipConfirm
    Skip the interactive confirmation prompt. Use only in automation paths
    that have already obtained explicit operator approval.

.OUTPUTS
    helm's output. Exit propagates helm's code; 4 on validation failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Release,
    [Parameter(Mandatory)] [string] $Namespace,
    [Parameter(Mandatory)] [ValidateRange(1, 1000000)] [int] $Revision,
    [Parameter(Mandatory)] [string] $Context,
    [Parameter(Mandatory)]
    [ValidateScript({ if ($_.Trim().Length -lt 5) { throw "-Reason must be a meaningful description (>=5 chars)." } $true })]
    [string] $Reason,

    [switch] $OverrideAmbientContext,
    [switch] $SkipConfirm
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../_lib/Context.ps1"

Assert-SafePathSegment -Value $Namespace -Name '-Namespace'
Assert-SafePathSegment -Value $Release   -Name '-Release'
Assert-SafePathSegment -Value $Context   -Name '-Context'
Assert-ContextSafety -Context $Context -OverrideAmbientContext:$OverrideAmbientContext

if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    Write-Error "helm not found in PATH."
    exit 3
}

# Render cross-revision delta: helm get manifest <release> --revision <target>
# vs current. This is the "rollback diff" per §3.6.
$currentManifest = & helm get manifest $Release `
    --kube-context $Context `
    --namespace $Namespace 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "helm get manifest (current) failed: $(@($currentManifest) -join "`n")"
    exit 1
}

$targetManifest = & helm get manifest $Release `
    --kube-context $Context `
    --namespace $Namespace `
    --revision $Revision 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "helm get manifest --revision $Revision failed (does that revision exist? Check 'helm history $Release -n $Namespace --kube-context $Context'): $(@($targetManifest) -join "`n")"
    exit 1
}

$auditDir = Join-Path (Join-Path (Join-Path '.helm' $Context) $Namespace) $Release
if (-not (Test-Path $auditDir)) {
    New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
}
$timestamp = Get-Date -AsUTC -Format 'yyyyMMdd-HHmmss'
$currentFile = Join-Path $auditDir "$timestamp-current.yaml"
$targetFile  = Join-Path $auditDir "$timestamp-revision-$Revision.yaml"
$currentManifest | Set-Content -Path $currentFile -Encoding utf8
$targetManifest  | Set-Content -Path $targetFile  -Encoding utf8

Write-Information "Cross-revision delta for release '$Release' (current -> revision $Revision):" -InformationAction Continue
Write-Information "  current  : $currentFile" -InformationAction Continue
Write-Information "  target   : $targetFile"  -InformationAction Continue
Write-Information "  reason   : $Reason"      -InformationAction Continue
Write-Information "Inspect the two files (or run a diff tool of choice) before approving." -InformationAction Continue

if (-not $SkipConfirm) {
    $confirm = Read-Host "Type 'rollback' to proceed"
    if ($confirm -ne 'rollback') {
        Write-Information "Aborted by user." -InformationAction Continue
        exit 5
    }
}

# Append audit log entry.
$logFile = Join-Path $auditDir 'rollback.log'
$logEntry = [pscustomobject]@{
    timestamp  = (Get-Date -AsUTC).ToString('o')
    context    = $Context
    namespace  = $Namespace
    release    = $Release
    revision   = $Revision
    reason     = $Reason
    currentFile = $currentFile
    targetFile  = $targetFile
} | ConvertTo-Json -Compress
Add-Content -Path $logFile -Value $logEntry

Write-Information "Rolling back '$Release' to revision $Revision..." -InformationAction Continue
& helm rollback $Release $Revision `
    --kube-context $Context `
    --namespace $Namespace `
    --wait
$rollbackExit = $LASTEXITCODE

if ($rollbackExit -ne 0) {
    Write-Error "helm rollback failed (exit $rollbackExit)."
    exit $rollbackExit
}

Write-Information "Rollback complete. Audit log: $logFile" -InformationAction Continue
exit 0
