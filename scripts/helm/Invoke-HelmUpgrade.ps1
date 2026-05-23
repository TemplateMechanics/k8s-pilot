<#
.SYNOPSIS
    Apply a Helm chart upgrade paired with a reviewed diff artifact
    (CLAUDE.md §3.2 Upgrade).

.DESCRIPTION
    Refuses to run without a valid -DiffFile produced by Invoke-HelmDiff.ps1.
    Verifies:
      1. The diff metadata sidecar exists and is artifactKind=helm-diff.
      2. The metadata's context matches -Context.
      3. The metadata's namespace matches -Namespace.
      4. The referenced chart path and values file still exist.

    Runs `helm upgrade --install --atomic --timeout 5m` against the recorded
    context + namespace.

.PARAMETER DiffFile
    The diff artifact path produced by Invoke-HelmDiff.ps1.

.PARAMETER Namespace
    Target namespace; must match the diff metadata's namespace.

.PARAMETER Context
    Kubernetes context; must match the diff metadata's context.

.PARAMETER OverrideAmbientContext
    See CLAUDE.md R3.

.PARAMETER TimeoutSeconds
    Helm timeout. Default 300 (5 min). Increase for slow workloads with explicit justification.

.OUTPUTS
    helm's stdout. Exit codes:
      0   - upgrade succeeded
      3   - helm binary not in PATH
      4   - metadata validation failure (missing sidecar, invalid JSON,
            artifactKind mismatch, context/namespace/chartPath/valuesFile
            mismatch or drift, unsafe field in sidecar)
      other - propagated from `helm upgrade`
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $DiffFile,

    [Parameter(Mandatory)] [string] $Namespace,
    [Parameter(Mandatory)] [string] $Context,

    [switch] $OverrideAmbientContext,

    [ValidateRange(30, 3600)]
    [int] $TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"
Assert-SafePathSegment -Value $Namespace -Name '-Namespace'
# Do NOT Assert-SafePathSegment on -Context: -Context is only passed to helm
# as --kube-context here (no path component), and legitimate EKS ARN contexts
# contain '/'. Argument injection is still defended via Assert-NonFlagArg.
Assert-NonFlagArg      -Value $Namespace -Name '-Namespace'
Assert-NonFlagArg      -Value $Context   -Name '-Context'
Assert-ContextSafety -Context $Context -OverrideAmbientContext:$OverrideAmbientContext

if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    Write-Error "helm not found in PATH."
    exit 3
}

$metaFile = "$DiffFile.meta.json"
if (-not (Test-Path $metaFile)) {
    Write-Error "Diff metadata sidecar not found at '$metaFile'. Regenerate via Invoke-HelmDiff.ps1."
    exit 4
}

try {
    $meta = Get-Content $metaFile -Raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "Failed to parse diff metadata sidecar '$metaFile' as JSON: $($_.Exception.Message). Regenerate via Invoke-HelmDiff.ps1."
    exit 4
}

# Validate every field we will pass to helm is a scalar string. A
# hand-edited sidecar with a field changed to an array (e.g.
# "chartPath": ["foo", "--bad-flag"]) would otherwise splat into multiple
# native args, and Assert-NonFlagArg's string coercion would see something
# like "foo --bad-flag" or "System.Object[]" rather than the original array.
foreach ($field in @('artifactKind', 'context', 'namespace', 'release', 'chartPath', 'valuesFile')) {
    $value = $meta.$field
    if ($null -eq $value -or $value -isnot [string]) {
        $actualType = if ($null -eq $value) { '<null>' } else { $value.GetType().FullName }
        Write-Error "Diff metadata field '$field' is not a scalar string (got $actualType). Sidecar may be corrupted or hand-edited; regenerate via Invoke-HelmDiff.ps1."
        exit 4
    }
}

if ($meta.artifactKind -ne 'helm-diff') {
    Write-Error "Diff metadata artifactKind is '$($meta.artifactKind)', expected 'helm-diff'. Wrong wrapper?"
    exit 4
}
if ($meta.context -ne $Context) {
    Write-Error "Diff metadata context '$($meta.context)' does not match -Context '$Context'. Refusing to upgrade against a different cluster."
    exit 4
}
if ($meta.namespace -ne $Namespace) {
    Write-Error "Diff metadata namespace '$($meta.namespace)' does not match -Namespace '$Namespace'. Refusing to upgrade against a different namespace."
    exit 4
}
if (-not (Test-Path $meta.chartPath)) {
    Write-Error "Chart path referenced by diff metadata is missing: '$($meta.chartPath)'. Re-run Invoke-HelmDiff.ps1."
    exit 4
}
if (-not (Test-Path $meta.valuesFile)) {
    Write-Error "Values file referenced by diff metadata is missing: '$($meta.valuesFile)'. Re-run Invoke-HelmDiff.ps1."
    exit 4
}

# Cross-check that meta.release AND meta.namespace match the directory
# layout implied by the diff artifact path (helm-output/<namespace>/<release>/
# <slug>.diff). A hand-edited or moved sidecar would otherwise let us
# upgrade a different release / namespace than the artifact the operator
# actually reviewed.
$artifactReleaseDir   = Split-Path -Path $DiffFile -Parent | Split-Path -Leaf
$artifactNamespaceDir = Split-Path -Path $DiffFile -Parent | Split-Path -Parent | Split-Path -Leaf
if ($meta.release -ne $artifactReleaseDir) {
    Write-Error "Diff metadata release '$($meta.release)' does not match the release directory '$artifactReleaseDir' in the artifact path '$DiffFile'. Sidecar may be hand-edited or moved."
    exit 4
}
if ($meta.namespace -ne $artifactNamespaceDir) {
    Write-Error "Diff metadata namespace '$($meta.namespace)' does not match the namespace directory '$artifactNamespaceDir' in the artifact path '$DiffFile'. Sidecar may be hand-edited or moved."
    exit 4
}

# Defend against argument injection: a corrupted/hand-edited sidecar where
# any of these fields starts with '-' would be parsed as a helm flag.
foreach ($field in @('release', 'chartPath', 'valuesFile')) {
    try {
        Assert-NonFlagArg -Value $meta.$field -Name "metadata.$field"
    }
    catch {
        Write-Error "Diff metadata field '$field' is unsafe: $($_.Exception.Message). Regenerate via Invoke-HelmDiff.ps1."
        exit 4
    }
}

# Verify the values file hasn't drifted since the diff was produced.
# Invoke-HelmDiff always emits schemaVersion=2 with valuesFileSha256, so a
# missing/empty hash is treated as a metadata-validation failure (exit 4)
# rather than a soft warning — otherwise the safety check could be bypassed
# by hand-deleting the field from a sidecar.
if ($meta.PSObject.Properties.Name -notcontains 'valuesFileSha256' -or -not $meta.valuesFileSha256 -or $meta.valuesFileSha256 -isnot [string]) {
    Write-Error "Diff metadata is missing or has an invalid valuesFileSha256 field. Regenerate via Invoke-HelmDiff.ps1 (current schemaVersion is 3 and always includes this hash)."
    exit 4
}
try {
    $currentValuesSha = (Get-FileHash -Algorithm SHA256 -Path $meta.valuesFile -ErrorAction Stop).Hash
}
catch {
    Write-Error "Failed to compute SHA-256 for values file '$($meta.valuesFile)': $($_.Exception.Message)"
    exit 4
}
if ($currentValuesSha -ne $meta.valuesFileSha256) {
    Write-Error "Values file '$($meta.valuesFile)' has changed since the diff was produced (sha mismatch). Re-run Invoke-HelmDiff.ps1 to refresh."
    exit 4
}

# Verify the chart contents haven't drifted since the diff was produced.
# schemaVersion 3 always emits chartContentSha256 (covers both .tgz files
# and chart directories via a recursive manifest hash). Treat missing/
# invalid hash as a metadata-validation failure (matches valuesFileSha256
# enforcement) - hand-deleting the field cannot bypass the safety check.
if ($meta.PSObject.Properties.Name -notcontains 'chartContentSha256' -or -not $meta.chartContentSha256 -or $meta.chartContentSha256 -isnot [string]) {
    Write-Error "Diff metadata is missing or has an invalid chartContentSha256 field. Regenerate via Invoke-HelmDiff.ps1 (current schemaVersion is 3 and always includes this hash)."
    exit 4
}
try {
    $currentChartSha = Get-PathContentHash -Path $meta.chartPath
}
catch {
    Write-Error "Failed to compute content hash for chart '$($meta.chartPath)': $($_.Exception.Message)"
    exit 4
}
if ($currentChartSha -ne $meta.chartContentSha256) {
    Write-Error "Chart contents at '$($meta.chartPath)' have changed since the diff was produced (sha mismatch). Re-run Invoke-HelmDiff.ps1 to refresh."
    exit 4
}

Write-Information "Upgrading helm release '$($meta.release)' in namespace '$Namespace' on context '$Context'..." -InformationAction Continue
# Note: --create-namespace is omitted intentionally. Helm defaults it to false,
# and PowerShell's colon-form switch syntax (--create-namespace:$false) would
# emit the literal "--create-namespace:False" string, which helm rejects as an
# unknown flag. If a caller actually needs namespace creation, that's an
# upstream decision (apply the Namespace via kubectl wrappers first).
& helm upgrade --install $meta.release $meta.chartPath `
    --kube-context $Context `
    --namespace $Namespace `
    --values $meta.valuesFile `
    --atomic `
    --timeout "${TimeoutSeconds}s"
$upgradeExit = $LASTEXITCODE

if ($upgradeExit -ne 0) {
    Write-Error "helm upgrade failed (exit $upgradeExit). Because --atomic was set, the release should have rolled back automatically — verify with: helm history $($meta.release) -n $Namespace --kube-context $Context"
    exit $upgradeExit
}

Write-Information "Upgrade complete. Consider running: helm status $($meta.release) -n $Namespace --kube-context $Context" -InformationAction Continue
exit 0
