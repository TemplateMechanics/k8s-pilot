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
      2   - diff present (flux diff convention)
      3   - flux binary not in PATH
      other - propagated from `flux diff kustomization`
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

# flux diff kustomization exits non-zero when changes are present (and on
# error). We capture both stdout and stderr; treat any non-zero with
# stderr empty as "diff present", anything with stderr content as error.
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
        exit $diffExit
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
