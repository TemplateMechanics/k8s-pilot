<#
.SYNOPSIS
    Apply the rendered manifest paired with a reviewed diff artifact
    (CLAUDE.md §3.1 Apply).

.DESCRIPTION
    Refuses to run without a valid -DiffFile produced by Invoke-KubectlDiff.ps1.
    Verifies that:
      1. The diff artifact's sidecar metadata exists.
      2. The metadata's recorded context matches -Context.
      3. The rendered manifest file referenced in the metadata still exists.
      4. The rendered manifest's SHA-256 still matches the metadata
         (so the manifest hasn't been edited between diff and apply).
    Then runs `kubectl apply -f <rendered>` against -Context.

.PARAMETER DiffFile
    The diff artifact produced by Invoke-KubectlDiff.ps1
    (kustomize-build/<context>/<name>.diff).

.PARAMETER Context
    Kubernetes context to apply against. Must match the ambient context unless
    -OverrideAmbientContext is passed; must match the metadata's recorded context.

.PARAMETER OverrideAmbientContext
    See CLAUDE.md R3.

.PARAMETER ServerSideApply
    Use server-side apply instead of client-side. Recommended for newer clusters.

.OUTPUTS
    kubectl apply's own output. Exit code 0 on success.

.EXAMPLE
    pwsh ./scripts/kubectl/Invoke-KubectlApply.ps1 -DiffFile kustomize-build/staging/web.diff -Context staging
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $DiffFile,

    [Parameter(Mandatory)]
    [string] $Context,

    [switch] $OverrideAmbientContext,

    [switch] $ServerSideApply
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../_lib/Context.ps1"
Assert-ContextSafety -Context $Context -OverrideAmbientContext:$OverrideAmbientContext

$metaFile = "$DiffFile.meta.json"
if (-not (Test-Path $metaFile)) {
    throw "Diff metadata sidecar not found at '$metaFile'. Regenerate the diff via Invoke-KubectlDiff.ps1."
}

$meta = Get-Content $metaFile -Raw | ConvertFrom-Json

if ($meta.artifactKind -ne 'kubectl-diff') {
    throw "Diff metadata artifactKind is '$($meta.artifactKind)', expected 'kubectl-diff'. Wrong wrapper?"
}
if ($meta.context -ne $Context) {
    throw "Diff metadata records context '$($meta.context)' but -Context '$Context' was passed. Refusing to apply a diff to a different cluster."
}
if (-not (Test-Path $meta.renderedPath)) {
    throw "Rendered manifest referenced by diff metadata is missing: '$($meta.renderedPath)'. Re-run Invoke-KubectlDiff.ps1."
}

$currentSha = (Get-FileHash -Algorithm SHA256 -Path $meta.renderedPath).Hash
if ($currentSha -ne $meta.renderedSha256) {
    throw "Rendered manifest at '$($meta.renderedPath)' has changed since the diff was produced (sha mismatch). Re-run Invoke-KubectlDiff.ps1 to refresh."
}

$applyArgs = @('--context', $Context, 'apply', '-f', $meta.renderedPath)
if ($ServerSideApply) {
    $applyArgs += @('--server-side', '--field-manager', 'k8s-pilot')
}

Write-Information "Applying '$($meta.renderedPath)' to context '$Context'..." -InformationAction Continue
& kubectl @applyArgs
$applyExit = $LASTEXITCODE

if ($applyExit -ne 0) {
    # Propagate the original kubectl exit code so retry logic / wrappers can
    # branch on it. A `throw` here would collapse it to exit 1.
    Write-Error "kubectl apply failed (exit $applyExit)."
    exit $applyExit
}

Write-Information "Apply complete. Consider running Invoke-RolloutStatus.ps1 for workload kinds." -InformationAction Continue
exit 0
