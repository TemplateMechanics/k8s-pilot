<#
.SYNOPSIS
    Diff an Argo CD Application against a target git revision
    (CLAUDE.md §3.3 App diff).

.DESCRIPTION
    Wraps `argocd app diff <app> --revision <rev> --server <server>`. Emits
    a diff artifact at `.argocd/<serverSlug>/<appSlug>/<revisionSlug>.diff`
    where each slug is `ConvertTo-SafeFilename` of the corresponding value
    (handles `:` in server hostnames, `/` in revision tags like
    `release/v1.2.3`, etc.). The TRUE server / app / revision strings are
    preserved inside the `.diff.meta.json` sidecar so Invoke-ArgocdAppSync.ps1
    can verify the pairing on actual identifiers.

.PARAMETER App
    Argo CD Application name (the Application CR's `metadata.name`).

.PARAMETER Revision
    Target git revision (commit SHA or immutable tag). The literal value
    `HEAD` is rejected (case-insensitive) because syncing against a moving
    target defeats the audit trail — see .github/copilot-instructions.md.

.PARAMETER Server
    Argo CD API server host. Sidecar records the server so Sync refuses
    to run against a different one.

.OUTPUTS
    Writes the diff artifact path to the pipeline.
    Exit codes (translated from argocd's native semantics so the wrapper
    matches helm-diff / kubectl-diff conventions across the repo):
      0   - no diff (argocd native 0)
      1   - wrapper-side metadata-write failure (partial artifacts cleaned up)
      2   - diff present (argocd native 1, translated here to 2)
      3   - argocd binary not in PATH
      5   - input validation failure (e.g. -Revision = HEAD)
      other - propagated from `argocd app diff` (treated as error)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $App,
    [Parameter(Mandatory)] [string] $Revision,
    [Parameter(Mandatory)] [string] $Server,
    [string] $OutputDir = '.argocd'
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

Assert-SafePathSegment -Value $App -Name '-App'
# Revision is intentionally NOT Assert-SafePathSegment'd because legitimate
# git tag names can contain '/' (e.g. 'release/v1.2.3'). The slug below
# handles filesystem safety; the true revision is recorded in the sidecar.
Assert-NonFlagArg      -Value $App      -Name '-App'
Assert-NonFlagArg      -Value $Revision -Name '-Revision'
Assert-NonFlagArg      -Value $Server   -Name '-Server'

# Reject 'HEAD' (case-insensitive) per .github/copilot-instructions.md:
# Argo CD revisions must pin to an immutable SHA or tag, never a branch
# pointer. Catches HEAD, head, Head, etc.
if ($Revision.Trim().ToLowerInvariant() -eq 'head') {
    Write-Error "-Revision 'HEAD' is rejected. Pin to an immutable commit SHA or tag (Argo CD audit trail requires immutable revisions)."
    # Use exit 5 (not 2) so this validation failure does not collide with
    # exit 2 = 'diff present' in this wrapper's exit-code contract.
    exit 5
}

if (-not (Get-Command argocd -ErrorAction SilentlyContinue)) {
    Write-Error "argocd not found in PATH."
    exit 3
}

$serverSlug   = ConvertTo-SafeFilename -Value $Server
$appSlug      = ConvertTo-SafeFilename -Value $App
$revisionSlug = ConvertTo-SafeFilename -Value $Revision
$outDir = Join-Path (Join-Path $OutputDir $serverSlug) $appSlug
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -LiteralPath $outDir -Force | Out-Null
}
# Use revision slug for the filename so tags like 'release/v1.2.3' don't
# blow up filesystem path semantics. True revision recorded in sidecar.
$diffFile = Join-Path $outDir "$revisionSlug.diff"
$metaFile = "$diffFile.meta.json"

# argocd app diff exit codes:
#   0 - no diff
#   1 - diff present (NOT 2 like helm-diff; argocd uses 1)
# Capture stderr separately so warnings don't pollute the artifact.
$errFile = [System.IO.Path]::GetTempFileName()
try {
    $diffOutput = & argocd app diff $App `
        --revision $Revision `
        --server $Server `
        --exit-code 2>$errFile
    $diffExit = $LASTEXITCODE
    $diffStderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue

    if ($diffExit -ne 0 -and $diffExit -ne 1) {
        $combined = @(@($diffOutput) -join "`n"; $diffStderr) -join "`n--- stderr ---`n"
        Write-Error "argocd app diff failed (exit $diffExit) for '$App': $combined"
        exit $diffExit
    }
    if ($diffStderr) {
        Write-Warning "argocd app diff produced stderr (not included in artifact):`n$diffStderr"
    }
}
finally {
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
}

try {
    $diffOutput | Set-Content -LiteralPath $diffFile -Encoding utf8
    $meta = [pscustomobject]@{
        schemaVersion = 1
        artifactKind  = 'argocd-diff'
        server        = $Server
        app           = $App
        revision      = $Revision
        diffExitCode  = $diffExit
        generatedAt   = (Get-Date -AsUTC).ToString('o')
    }
    $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metaFile -Encoding utf8
}
catch {
    Remove-Item -LiteralPath $metaFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $diffFile -Force -ErrorAction SilentlyContinue
    Write-Error "Failed to write diff metadata for '$App': $($_.Exception.Message)"
    exit 1
}

# Translate argocd exit semantics to a convention consistent with our other
# diff wrappers: 0 = no diff, 2 = diff present. argocd's native 1 = diff
# present becomes 2 here so callers can use the same branching.
$wrapperExit = if ($diffExit -eq 0) { 0 } else { 2 }

if ($diffExit -eq 0) {
    Write-Information "No diff: app '$App' already matches revision $Revision on server '$Server'." -InformationAction Continue
}
else {
    Write-Information "Diff written to $diffFile (meta: $metaFile). Review before sync." -InformationAction Continue
}

Write-Output (Resolve-Path -LiteralPath $diffFile).Path
exit $wrapperExit
