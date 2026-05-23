<#
.SYNOPSIS
    Diff an Argo CD Application against a target git revision
    (CLAUDE.md §3.3 App diff).

.DESCRIPTION
    Wraps `argocd app diff <app> --revision <rev> --server <server>`. Emits
    a diff artifact at `.argocd/<serverSlug>/<appSlug>/<revision>.diff`
    with a sidecar metadata JSON that Invoke-ArgocdAppSync.ps1 consumes
    to verify the pairing.

.PARAMETER App
    Argo CD Application name (the Application CR's `metadata.name`).

.PARAMETER Revision
    Target git revision (commit SHA or immutable tag). Never `HEAD`.

.PARAMETER Server
    Argo CD API server host. Sidecar records the server so Sync refuses
    to run against a different one.

.OUTPUTS
    Writes the diff artifact path to the pipeline.
    Exit codes:
      0   - no diff
      1   - either propagated from `argocd app diff` error OR wrapper-side
            metadata-write failure (partial artifacts cleaned up)
      2   - diff present (argocd app diff convention with --exit-code)
      3   - argocd binary not in PATH
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

Assert-SafePathSegment -Value $App      -Name '-App'
Assert-SafePathSegment -Value $Revision -Name '-Revision'
Assert-NonFlagArg      -Value $App      -Name '-App'
Assert-NonFlagArg      -Value $Revision -Name '-Revision'
Assert-NonFlagArg      -Value $Server   -Name '-Server'

if (-not (Get-Command argocd -ErrorAction SilentlyContinue)) {
    Write-Error "argocd not found in PATH."
    exit 3
}

$serverSlug = ConvertTo-SafeFilename -Value $Server
$appSlug    = ConvertTo-SafeFilename -Value $App
$outDir = Join-Path (Join-Path $OutputDir $serverSlug) $appSlug
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -LiteralPath $outDir -Force | Out-Null
}
$diffFile = Join-Path $outDir "$Revision.diff"
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
