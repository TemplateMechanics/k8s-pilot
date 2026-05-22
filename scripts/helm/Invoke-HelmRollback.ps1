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
    Status messages on the Information stream; helm's stdout from rollback.
    Exit codes:
      0   - rollback succeeded
      1   - helm error (helm get manifest failed, or helm rollback failed
            with a non-zero code other than the ones below)
      3   - helm binary not in PATH
      5   - user declined the confirmation prompt
      other - propagated from the underlying helm invocation
    Parameter-validation failures (invalid -Revision range, empty -Reason,
    unsafe -Context/-Namespace/-Release) terminate before the script body
    runs and produce PowerShell's default error exit code (1).
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
Assert-NonFlagArg      -Value $Release   -Name '-Release'
Assert-ContextSafety -Context $Context -OverrideAmbientContext:$OverrideAmbientContext

if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    Write-Error "helm not found in PATH."
    exit 3
}

# Render cross-revision delta: helm get manifest <release> --revision <target>
# vs current. This is the "rollback diff" per §3.6.
# Capture stderr to a temp file so any helm warnings (e.g. kubeconfig
# permission notices) are not embedded into the YAML artifacts.
$errFile = [System.IO.Path]::GetTempFileName()
try {
    $currentManifest = & helm get manifest $Release `
        --kube-context $Context `
        --namespace $Namespace 2>$errFile
    $currentExit = $LASTEXITCODE
    $currentStderr = Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue
    if ($currentExit -ne 0) {
        Write-Error "helm get manifest (current) failed (exit $currentExit): $currentStderr"
        exit $currentExit
    }
    if ($currentStderr) {
        Write-Warning "helm get manifest (current) produced stderr (not embedded in artifact):`n$currentStderr"
    }

    Clear-Content -Path $errFile -ErrorAction SilentlyContinue
    $targetManifest = & helm get manifest $Release `
        --kube-context $Context `
        --namespace $Namespace `
        --revision $Revision 2>$errFile
    $targetExit = $LASTEXITCODE
    $targetStderr = Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue
    if ($targetExit -ne 0) {
        Write-Error "helm get manifest --revision $Revision failed (does that revision exist? Check 'helm history $Release -n $Namespace --kube-context $Context'): $targetStderr"
        exit $targetExit
    }
    if ($targetStderr) {
        Write-Warning "helm get manifest --revision $Revision produced stderr (not embedded in artifact):`n$targetStderr"
    }
}
finally {
    Remove-Item -Path $errFile -Force -ErrorAction SilentlyContinue
}

# Filesystem-safe slug for the context portion of the audit path; the true
# context name is recorded inside the JSON audit entry below.
$contextSlug = ConvertTo-SafeFilename -Value $Context
$auditDir = Join-Path (Join-Path (Join-Path '.helm' $contextSlug) $Namespace) $Release
if (-not (Test-Path $auditDir)) {
    New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
}
# Millisecond-precision timestamp to avoid collisions when two rollbacks for
# the same release fire within the same second.
$timestamp = Get-Date -AsUTC -Format 'yyyyMMdd-HHmmssfff'
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
