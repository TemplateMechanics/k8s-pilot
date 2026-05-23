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
    .helm/<contextSlug>/<namespace>/<release>/rollback.log
    (where `<contextSlug>` is the filesystem-safe slug of -Context; the true
    context name is recorded inside the JSON audit entries).

.PARAMETER OverrideAmbientContext
    See CLAUDE.md R3.

.PARAMETER SkipConfirm
    Skip the interactive confirmation prompt. Use only in automation paths
    that have already obtained explicit operator approval.

.OUTPUTS
    Status messages on the Information stream; helm's stdout from rollback.
    Exit codes:
      0   - rollback succeeded
      3   - helm binary not in PATH
      5   - user declined the confirmation prompt
      other - propagated directly from the underlying helm invocation
              (`helm get manifest` for the current revision, `helm get
              manifest --revision` for the target, or `helm rollback`).
              We do NOT collapse helm failures to a fixed code so callers
              can branch on the original helm exit.
    Parameter-validation failures (invalid -Revision range, empty -Reason,
    unsafe -Namespace/-Release, leading-dash on any of -Release/-Namespace/
    -Context) terminate before the script body runs and produce PowerShell's
    default error exit code (1).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Release,
    [Parameter(Mandatory)] [string] $Namespace,
    [Parameter(Mandatory)] [ValidateRange(1, 1000000)] [int] $Revision,
    [Parameter(Mandatory)] [string] $Context,
    [Parameter(Mandatory)]
    [ValidateScript({
        # Handle $null explicitly to avoid 'You cannot call a method on a
        # null-valued expression' from .Trim() and give the user the same
        # actionable error message regardless of input shape.
        if ($null -eq $_) { throw "-Reason must be a meaningful description (>=5 chars)." }
        if ($_.Trim().Length -lt 5) { throw "-Reason must be a meaningful description (>=5 chars)." }
        $true
    })]
    [string] $Reason,

    [switch] $OverrideAmbientContext,
    [switch] $SkipConfirm
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

Assert-SafePathSegment -Value $Namespace -Name '-Namespace'
Assert-SafePathSegment -Value $Release   -Name '-Release'
# -Context is slugified for the audit directory below; do not reject '/' here.
Assert-NonFlagArg      -Value $Release   -Name '-Release'
Assert-NonFlagArg      -Value $Namespace -Name '-Namespace'
Assert-NonFlagArg      -Value $Context   -Name '-Context'
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
    # Case-sensitive comparison (-cne) so 'Rollback', 'ROLLBACK', etc. do
    # not satisfy a strict safety gate. Trim incidental whitespace.
    if (($null -eq $confirm) -or ($confirm.Trim() -cne 'rollback')) {
        Write-Information "Aborted by user." -InformationAction Continue
        exit 5
    }
}

# Append pre-rollback audit log entry (event=started). The post-rollback
# entry below records the outcome so a failed rollback is distinguishable
# from a successful one when the log is replayed later.
$logFile = Join-Path $auditDir 'rollback.log'
$startedEntry = [pscustomobject]@{
    timestamp   = (Get-Date -AsUTC).ToString('o')
    event       = 'started'
    context     = $Context
    namespace   = $Namespace
    release     = $Release
    revision    = $Revision
    reason      = $Reason
    currentFile = $currentFile
    targetFile  = $targetFile
} | ConvertTo-Json -Compress
Add-Content -Path $logFile -Value $startedEntry -Encoding utf8

Write-Information "Rolling back '$Release' to revision $Revision..." -InformationAction Continue
& helm rollback $Release $Revision `
    --kube-context $Context `
    --namespace $Namespace `
    --wait
$rollbackExit = $LASTEXITCODE

$outcome = if ($rollbackExit -eq 0) { 'succeeded' } else { 'failed' }
$completedEntry = [pscustomobject]@{
    timestamp   = (Get-Date -AsUTC).ToString('o')
    event       = 'completed'
    outcome     = $outcome
    exitCode    = $rollbackExit
    context     = $Context
    namespace   = $Namespace
    release     = $Release
    revision    = $Revision
} | ConvertTo-Json -Compress
Add-Content -Path $logFile -Value $completedEntry -Encoding utf8

if ($rollbackExit -ne 0) {
    Write-Error "helm rollback failed (exit $rollbackExit). Audit log: $logFile"
    exit $rollbackExit
}

Write-Information "Rollback complete. Audit log: $logFile" -InformationAction Continue
exit 0
