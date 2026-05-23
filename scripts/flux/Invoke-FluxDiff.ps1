<#
.SYNOPSIS
    Diff a Flux Kustomization against the live cluster (CLAUDE.md §3.4 Diff).

.DESCRIPTION
    Wraps `flux diff kustomization`. Emits a diff artifact at
    `.flux/<kustomization>/<contextSlug>.diff` with a sidecar metadata
    JSON that Invoke-FluxReconcile.ps1 consumes to verify the pairing.

.PARAMETER Kustomization
    Flux Kustomization CR name.

.PARAMETER Path
    Filesystem path the Kustomization references.

.PARAMETER Context
    Kubernetes context. Must match ambient unless -OverrideAmbientContext.

.PARAMETER OverrideAmbientContext
    See CLAUDE.md R3.

.PARAMETER OutputDir
    Override the default `.flux/` directory.

.OUTPUTS
    Writes the diff artifact path to the pipeline.
    Exit codes:
      0   - no diff
      1   - wrapper-side metadata-write failure (partial artifacts cleaned up)
      2   - diff present (translated from flux's native exit 1 + stdout
            containing diff markers, matching the convention used by
            Invoke-HelmDiff and Invoke-ArgocdAppDiff. Note that
            Invoke-KubectlDiff intentionally preserves kubectl's native
            exit 1 for "diff present" so its callers can pipe through
            existing kubectl-diff tooling unchanged.)
      3   - flux binary not in PATH
      4   - `flux diff` returned exit 1 but stdout had no diff markers
            (treated as an error to avoid silently writing a non-diff
            artifact)
      other - propagated from `flux diff kustomization` (exit > 1)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Kustomization,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $Path,

    [Parameter(Mandatory)] [string] $Context,

    [switch] $OverrideAmbientContext,

    [string] $OutputDir = '.flux'
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

Assert-SafePathSegment -Value $Kustomization -Name '-Kustomization'
Assert-NonFlagArg      -Value $Kustomization -Name '-Kustomization'
Assert-NonFlagArg      -Value $Path          -Name '-Path'
Assert-NonFlagArg      -Value $Context       -Name '-Context'
Assert-ContextSafety -Context $Context -OverrideAmbientContext:$OverrideAmbientContext

if (-not (Get-Command flux -ErrorAction SilentlyContinue)) {
    Write-Error "flux not found in PATH."
    exit 3
}

$contextSlug = ConvertTo-SafeFilename -Value $Context
$outDir = Join-Path $OutputDir $Kustomization
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -LiteralPath $outDir -Force | Out-Null
}
$diffFile = Join-Path $outDir "$contextSlug.diff"
$metaFile = "$diffFile.meta.json"

# flux diff kustomization classification: exit-code-driven (see the
# detailed block below the invocation). Stderr is captured for diagnosis
# only; it does NOT decide error-vs-diff.
$errFile = [System.IO.Path]::GetTempFileName()
try {
    $diffOutput = & flux diff kustomization $Kustomization `
        --path $Path `
        --context $Context 2>$errFile
    $diffExit = $LASTEXITCODE
    $diffStderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue

    # flux diff kustomization exit semantics (observed):
    #   0      = no diff
    #   1      = diff detected (diff goes to stdout)
    #   >1     = error (message on stderr)
    # Treat any exit > 1 as an unambiguous error. For exit == 1 we ALSO
    # require stdout to contain visible diff markers ('@@', '+', '-', or
    # 'ID:') to defend against a future flux release that conflates
    # 'diff' and 'error' both as exit 1. If exit==1 but stdout has no diff
    # markers, treat as error and surface stderr for diagnosis.
    $hasDiffMarkers = ($diffOutput | Out-String) -match '(?m)^[+\-@]|^\s*ID:'
    $isError = ($diffExit -gt 1) -or (($diffExit -eq 1) -and -not $hasDiffMarkers)
    if ($isError) {
        $combined = @(@($diffOutput) -join "`n"; $diffStderr) -join "`n--- stderr ---`n"
        Write-Error "flux diff kustomization failed (exit $diffExit) for '$Kustomization': $combined"
        # Remap flux's exit 1 to wrapper exit 4 in the error path so it
        # cannot collide with the documented "wrapper-side metadata-write
        # failure" (also exit 1). For exit > 1, propagate as-is so callers
        # can branch on the original flux error code.
        if ($diffExit -eq 1) { exit 4 } else { exit $diffExit }
    }
    if ($diffStderr) {
        Write-Warning "flux diff produced stderr output (not included in diff artifact):`n$diffStderr"
    }
}
finally {
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
}

try {
    $diffOutput | Set-Content -LiteralPath $diffFile -Encoding utf8
    $pathContentSha = Get-PathContentHash -Path $Path
    $meta = [pscustomobject]@{
        schemaVersion      = 1
        artifactKind       = 'flux-diff'
        context            = $Context
        kustomization      = $Kustomization
        path               = (Resolve-Path -LiteralPath $Path).Path
        pathContentSha256  = $pathContentSha
        diffExitCode       = $diffExit
        generatedAt        = (Get-Date -AsUTC).ToString('o')
    }
    $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metaFile -Encoding utf8
}
catch {
    Remove-Item -LiteralPath $metaFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $diffFile -Force -ErrorAction SilentlyContinue
    Write-Error "Failed to write diff metadata for '$Kustomization': $($_.Exception.Message)"
    exit 1
}

# Translate to the 0/2 convention used by other diff wrappers.
$wrapperExit = if ($diffExit -eq 0) { 0 } else { 2 }

if ($diffExit -eq 0) {
    Write-Information "No diff: Kustomization '$Kustomization' already matches live state on context '$Context'." -InformationAction Continue
}
else {
    Write-Information "Diff written to $diffFile (meta: $metaFile). Review before reconcile." -InformationAction Continue
}

Write-Output (Resolve-Path -LiteralPath $diffFile).Path
exit $wrapperExit
