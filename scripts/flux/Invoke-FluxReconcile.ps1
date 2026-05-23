<#
.SYNOPSIS
    Reconcile a Flux Kustomization paired with a reviewed diff artifact
    (CLAUDE.md §3.4 Reconcile).

.DESCRIPTION
    Refuses to run without a valid -DiffFile produced by Invoke-FluxDiff.ps1.
    Verifies sidecar metadata (artifactKind, schemaVersion, scalar-string
    types, Assert-NonFlagArg on consumed fields), case-sensitive identifier
    matches, path-layout cross-check via slug, and that the source path
    contents haven't drifted since the diff (pathContentSha256).

    On success, runs `flux reconcile kustomization <name> --with-source
    --context <ctx>`.

.PARAMETER Kustomization
    Flux Kustomization CR name.

.PARAMETER DiffFile
    The diff artifact path produced by Invoke-FluxDiff.ps1.

.PARAMETER Context
    Kubernetes context.

.PARAMETER OverrideAmbientContext
    See CLAUDE.md R3.

.OUTPUTS
    flux's stdout. Exit codes:
      0   - reconcile succeeded
      3   - flux binary not in PATH
      4   - sidecar metadata validation failure
      other - propagated from `flux reconcile kustomization`
    Preflight failures terminate with PS default exit 1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Kustomization,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $DiffFile,

    [Parameter(Mandatory)] [string] $Context,

    [switch] $OverrideAmbientContext
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

Assert-SafePathSegment -Value $Kustomization -Name '-Kustomization'
Assert-NonFlagArg      -Value $Kustomization -Name '-Kustomization'
Assert-NonFlagArg      -Value $Context       -Name '-Context'
Assert-ContextSafety -Context $Context -OverrideAmbientContext:$OverrideAmbientContext

if (-not (Get-Command flux -ErrorAction SilentlyContinue)) {
    Write-Error "flux not found in PATH."
    exit 3
}

$metaFile = "$DiffFile.meta.json"
if (-not (Test-Path -LiteralPath $metaFile)) {
    Write-Error "Diff metadata sidecar not found at '$metaFile'. Regenerate via Invoke-FluxDiff.ps1."
    exit 4
}

try {
    $meta = Get-Content -LiteralPath $metaFile -Raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "Failed to parse diff metadata sidecar '$metaFile' as JSON: $($_.Exception.Message). Regenerate via Invoke-FluxDiff.ps1."
    exit 4
}

if ($meta.artifactKind -ne 'flux-diff') {
    Write-Error "Diff metadata artifactKind is '$($meta.artifactKind)', expected 'flux-diff'. Wrong wrapper?"
    exit 4
}
$EXPECTED_SCHEMA_VERSION = 1
if ($meta.PSObject.Properties.Name -notcontains 'schemaVersion' -or $meta.schemaVersion -ne $EXPECTED_SCHEMA_VERSION) {
    Write-Error "Diff metadata schemaVersion is '$($meta.schemaVersion)', expected $EXPECTED_SCHEMA_VERSION. Regenerate via Invoke-FluxDiff.ps1."
    exit 4
}

foreach ($field in @('artifactKind', 'context', 'kustomization', 'path', 'pathContentSha256')) {
    $value = $meta.$field
    if ($null -eq $value -or $value -isnot [string]) {
        $actualType = if ($null -eq $value) { '<null>' } else { $value.GetType().FullName }
        Write-Error "Diff metadata field '$field' is not a scalar string (got $actualType). Regenerate via Invoke-FluxDiff.ps1."
        exit 4
    }
}

foreach ($field in @('context', 'kustomization', 'path')) {
    try {
        Assert-NonFlagArg -Value $meta.$field -Name "metadata.$field"
    }
    catch {
        Write-Error "Diff metadata field '$field' is unsafe: $($_.Exception.Message). Regenerate via Invoke-FluxDiff.ps1."
        exit 4
    }
}

if ($meta.context -cne $Context) {
    Write-Error "Diff metadata context '$($meta.context)' does not match -Context '$Context'. Refusing to reconcile against a different cluster."
    exit 4
}
if ($meta.kustomization -cne $Kustomization) {
    Write-Error "Diff metadata kustomization '$($meta.kustomization)' does not match -Kustomization '$Kustomization'."
    exit 4
}

# Cross-check the diff artifact path layout: .flux/<kustomization>/<contextSlug>.diff
$artifactParent     = Split-Path -LiteralPath $DiffFile       -Parent
$artifactKustomDir  = Split-Path -LiteralPath $artifactParent -Leaf
if ($meta.kustomization -cne $artifactKustomDir) {
    Write-Error "Diff metadata kustomization '$($meta.kustomization)' does not match artifact directory '$artifactKustomDir' in '$DiffFile'. Sidecar may be hand-edited or moved."
    exit 4
}
# Also verify the diff filename leaf matches the slugified context, closing
# the gap where meta.context could be hand-edited without renaming the file.
$expectedContextFile = (ConvertTo-SafeFilename -Value $meta.context) + '.diff'
$actualLeaf = Split-Path -LiteralPath $DiffFile -Leaf
if ($expectedContextFile -cne $actualLeaf) {
    Write-Error "Diff metadata context slug '$expectedContextFile' does not match artifact filename '$actualLeaf'. Sidecar may be hand-edited or moved."
    exit 4
}

# Refuse to reconcile against a clean diff. flux diff exits 0 when no
# changes are present; reconciling no-op against the live cluster is
# operational noise. Validate diffExitCode type AND value strictly.
if ($meta.PSObject.Properties.Name -notcontains 'diffExitCode') {
    Write-Error "Diff metadata missing diffExitCode field. Regenerate via Invoke-FluxDiff.ps1."
    exit 4
}
$diffExitVal = $meta.diffExitCode
$isIntegerScalar = $diffExitVal -is [int] -or $diffExitVal -is [long]
if (-not $isIntegerScalar) {
    Write-Error "Diff metadata diffExitCode must be an integer; got '$diffExitVal' (type $(if ($null -eq $diffExitVal) { '<null>' } else { $diffExitVal.GetType().Name })). Regenerate via Invoke-FluxDiff.ps1."
    exit 4
}
if ($diffExitVal -eq 0) {
    Write-Error "Diff metadata records diffExitCode=0 (no changes). Refusing to reconcile against a clean diff. If you need to force a reconcile (no diff to apply), use 'flux reconcile' directly and accept that nothing was reviewed."
    exit 4
}

# Verify path content hasn't drifted.
if (-not (Test-Path -LiteralPath $meta.path)) {
    Write-Error "Path referenced by diff metadata is missing: '$($meta.path)'. Re-run Invoke-FluxDiff.ps1."
    exit 4
}
try {
    $currentSha = Get-PathContentHash -Path $meta.path
}
catch {
    Write-Error "Failed to compute content hash for path '$($meta.path)': $($_.Exception.Message)"
    exit 4
}
if ($currentSha -ne $meta.pathContentSha256) {
    Write-Error "Source path '$($meta.path)' has changed since the diff was produced (sha mismatch). Re-run Invoke-FluxDiff.ps1."
    exit 4
}

Write-Information "Reconciling Flux Kustomization '$Kustomization' on context '$Context'..." -InformationAction Continue
& flux reconcile kustomization $Kustomization --with-source --context $Context
$exit = $LASTEXITCODE
if ($exit -ne 0) {
    Write-Error "flux reconcile kustomization failed (exit $exit)."
    exit $exit
}
Write-Information "Reconcile complete. Verify with: flux get kustomization $Kustomization --context $Context" -InformationAction Continue
exit 0
