<#
.SYNOPSIS
    Diff a Helm chart upgrade against the live release (CLAUDE.md §3.2 Diff).

.DESCRIPTION
    Wraps the `helm diff upgrade` plugin command (requires the helm-diff plugin
    from https://github.com/databus23/helm-diff). Emits a diff artifact under
    helm-output/<namespace>/<release>/<context>.diff with a sidecar metadata
    JSON that Invoke-HelmUpgrade.ps1 consumes to verify the pairing.

.PARAMETER ChartPath
    Path to a chart directory or packaged .tgz.

.PARAMETER ValuesFile
    Path to a values.yaml.

.PARAMETER Release
    Release name.

.PARAMETER Namespace
    Target namespace (mandatory; see CLAUDE.md §3.2).

.PARAMETER Context
    Kubernetes context. Must match ambient unless -OverrideAmbientContext.

.PARAMETER OverrideAmbientContext
    See CLAUDE.md R3.

.PARAMETER OutputDir
    Override the default helm-output/ directory.

.OUTPUTS
    Writes the diff artifact path to the pipeline.
    Exit codes:
      0   - no diff
      2   - diff present (helm-diff --detailed-exitcode convention)
      3   - helm binary or helm-diff plugin not installed
      other - propagated from `helm diff upgrade` (treated as error)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string] $ChartPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $ValuesFile,

    [Parameter(Mandatory)] [string] $Release,
    [Parameter(Mandatory)] [string] $Namespace,
    [Parameter(Mandatory)] [string] $Context,

    [switch] $OverrideAmbientContext,

    [string] $OutputDir = 'helm-output'
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

Assert-SafePathSegment -Value $Namespace -Name '-Namespace'
Assert-SafePathSegment -Value $Release   -Name '-Release'
# Do NOT Assert-SafePathSegment on -Context: legitimate context names (EKS
# ARN-style "...:cluster/my-cluster") contain '/' and would be rejected.
# Path safety is handled by ConvertTo-SafeFilename below; the true context
# value is preserved in the sidecar metadata for verification.
Assert-NonFlagArg      -Value $Release    -Name '-Release'
Assert-NonFlagArg      -Value $Namespace  -Name '-Namespace'
Assert-NonFlagArg      -Value $Context    -Name '-Context'
Assert-NonFlagArg      -Value $ChartPath  -Name '-ChartPath'
Assert-NonFlagArg      -Value $ValuesFile -Name '-ValuesFile'
Assert-ContextSafety -Context $Context -OverrideAmbientContext:$OverrideAmbientContext

if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    Write-Error "helm not found in PATH."
    exit 3
}

# Verify the helm-diff plugin is installed. Parse the NAME column (first
# whitespace-separated token of each non-header line) so we don't match
# unrelated plugins whose DESCRIPTION mentions the word "diff".
$pluginsRaw = & helm plugin list 2>$null
$helmPluginExit = $LASTEXITCODE
$pluginNames = if ($helmPluginExit -eq 0 -and $pluginsRaw) {
    @($pluginsRaw) | Select-Object -Skip 1 | ForEach-Object {
        ($_ -split '\s+', 2)[0]
    } | Where-Object { $_ }
} else { @() }
if ($helmPluginExit -ne 0 -or 'diff' -notin $pluginNames) {
    Write-Error "helm-diff plugin not installed (found plugins: $($pluginNames -join ', ')). Run: helm plugin install https://github.com/databus23/helm-diff"
    exit 3
}

$outDir = Join-Path (Join-Path $OutputDir $Namespace) $Release
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
# Use a filesystem-safe slug for the filename; the true context name is
# preserved inside the metadata sidecar so Upgrade still verifies it.
$contextSlug = ConvertTo-SafeFilename -Value $Context
$diffFile = Join-Path $outDir "$contextSlug.diff"
$metaFile = "$diffFile.meta.json"

# helm diff upgrade exit codes (with --detailed-exitcode):
#   0 - no changes
#   2 - changes present
#   1 - error
$diffOutput = & helm diff upgrade $Release $ChartPath `
    --kube-context $Context `
    --namespace $Namespace `
    --values $ValuesFile `
    --allow-unreleased `
    --detailed-exitcode 2>&1
$diffExit = $LASTEXITCODE

if ($diffExit -ne 0 -and $diffExit -ne 2) {
    # 0 = no changes, 2 = changes present, anything else = error.
    # Propagate the actual exit code so callers can branch on it.
    $errText = @($diffOutput) -join "`n"
    Write-Error "helm diff upgrade failed (exit $diffExit) for release '$Release': $errText"
    exit $diffExit
}

$diffOutput | Set-Content -Path $diffFile -Encoding utf8

$valuesSha = (Get-FileHash -Algorithm SHA256 -Path $ValuesFile).Hash
$meta = [pscustomobject]@{
    schemaVersion   = 2
    artifactKind    = 'helm-diff'
    context         = $Context
    namespace       = $Namespace
    release         = $Release
    chartPath       = (Resolve-Path $ChartPath).Path
    valuesFile      = (Resolve-Path $ValuesFile).Path
    valuesFileSha256 = $valuesSha
    diffExitCode    = $diffExit
    generatedAt     = (Get-Date -AsUTC).ToString('o')
}
$meta | ConvertTo-Json -Depth 5 | Set-Content -Path $metaFile -Encoding utf8

if ($diffExit -eq 0) {
    Write-Information "No diff: release '$Release' in namespace '$Namespace' already matches the chart + values." -InformationAction Continue
}
else {
    Write-Information "Diff written to $diffFile (meta: $metaFile). Review before upgrade." -InformationAction Continue
}

Write-Output (Resolve-Path $diffFile).Path
exit $diffExit
