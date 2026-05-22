<#
.SYNOPSIS
    Diff a rendered kustomization against the live cluster (CLAUDE.md §3.1 Diff).

.DESCRIPTION
    Renders -Path via Invoke-KustomizeBuild.ps1, then runs `kubectl diff -f`
    against the named -Context. Emits a diff artifact at
    kustomize-build/<context>/<name>.diff with a sidecar metadata JSON that
    Invoke-KubectlApply.ps1 consumes to verify the pairing.

.PARAMETER Path
    Path to a kustomization directory.

.PARAMETER Context
    Kubernetes context to diff against. The wrapper asserts this matches the
    ambient context unless -OverrideAmbientContext is passed.

.PARAMETER OverrideAmbientContext
    See CLAUDE.md R3. Use sparingly.

.PARAMETER OutputDir
    Override the default kustomize-build/ directory.

.OUTPUTS
    Writes the resolved path of the diff artifact file (.diff) to the pipeline
    on its own line, so scripted callers can capture it via `$diff = & ...`.
    Exit code 0 = no diff, 1 = diff present (kubectl diff convention), >1 = error.

.EXAMPLE
    pwsh ./scripts/kubectl/Invoke-KubectlDiff.ps1 -Path apps/web/overlays/staging -Context staging
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string] $Path,

    [Parameter(Mandatory)]
    [string] $Context,

    [switch] $OverrideAmbientContext,

    [string] $OutputDir = 'kustomize-build'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../_lib/Context.ps1"
Assert-SafePathSegment -Value $Context -Name '-Context'
Assert-ContextSafety -Context $Context -OverrideAmbientContext:$OverrideAmbientContext

# Render first so we can both diff and (later) apply the exact same bytes.
# Wrap in try/catch because Invoke-KustomizeBuild.ps1 throws on render error,
# which under $ErrorActionPreference='Stop' would terminate this script with
# PowerShell's default exit 1 — colliding with kubectl diff's "diff present"
# semantics. Catching lets us exit 2 instead, preserving the contract.
$renderedPath = $null
try {
    $renderedPath = & "$PSScriptRoot/Invoke-KustomizeBuild.ps1" -Path $Path -Context $Context -OutputDir $OutputDir
}
catch {
    Write-Error "Render step failed: $($_.Exception.Message)"
    exit 2
}
if (-not $renderedPath) {
    Write-Error "Render step produced no output path; aborting diff."
    exit 2
}

$name = Get-PathBasename -Path $Path
$outDir = Join-Path $OutputDir $Context
$diffFile = Join-Path $outDir "$name.diff"
$metaFile = "$diffFile.meta.json"

# `kubectl diff` returns 1 when there is a diff, 0 when clean, >1 on error.
$diffOutput = & kubectl --context $Context diff -f $renderedPath 2>&1
$diffExit   = $LASTEXITCODE

if ($diffExit -gt 1) {
    # Surface kubectl's stderr/stdout for diagnosis, then propagate the
    # original kubectl exit code so callers can distinguish error (>1) from
    # diff-present (1). A `throw` here would collapse everything into exit 1.
    # Note: wrap in @(...) before -join to defend against the PowerShell trap
    # where a scalar string gets joined character-by-character.
    $diffText = @($diffOutput) -join "`n"
    Write-Error "kubectl diff failed (exit $diffExit) for '$renderedPath': $diffText"
    exit $diffExit
}

$diffOutput | Set-Content -Path $diffFile -Encoding utf8

$sha = (Get-FileHash -Algorithm SHA256 -Path $renderedPath).Hash
$meta = [pscustomobject]@{
    schemaVersion = 1
    artifactKind  = 'kubectl-diff'
    context       = $Context
    sourcePath    = (Resolve-Path $Path).Path
    renderedPath  = (Resolve-Path $renderedPath).Path
    renderedSha256 = $sha
    diffExitCode  = $diffExit
    generatedAt   = (Get-Date -AsUTC).ToString('o')
}
$meta | ConvertTo-Json -Depth 5 | Set-Content -Path $metaFile -Encoding utf8

if ($diffExit -eq 0) {
    Write-Information "No diff: rendered manifest already matches cluster state." -InformationAction Continue
}
else {
    Write-Information "Diff written to $diffFile (meta: $metaFile). Review before apply." -InformationAction Continue
}

# Emit the diff artifact path to the pipeline so callers can capture it.
Write-Output (Resolve-Path $diffFile).Path

# Preserve kubectl diff's exit semantics so scripted callers can branch.
exit $diffExit
