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
    Exit 0 = no diff, 2 = diff present (helm-diff convention with --exit-code 2).
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
. "$PSScriptRoot/../_lib/Context.ps1"

Assert-SafePathSegment -Value $Namespace -Name '-Namespace'
Assert-SafePathSegment -Value $Release   -Name '-Release'
Assert-SafePathSegment -Value $Context   -Name '-Context'
Assert-ContextSafety -Context $Context -OverrideAmbientContext:$OverrideAmbientContext

if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    Write-Error "helm not found in PATH."
    exit 3
}

# Verify the helm-diff plugin is installed.
$plugins = & helm plugin list 2>$null
if ($LASTEXITCODE -ne 0 -or ($plugins | Out-String) -notmatch '\bdiff\b') {
    Write-Error "helm-diff plugin not installed. Run: helm plugin install https://github.com/databus23/helm-diff"
    exit 3
}

$outDir = Join-Path (Join-Path $OutputDir $Namespace) $Release
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$diffFile = Join-Path $outDir "$Context.diff"
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

if ($diffExit -eq 1) {
    $errText = @($diffOutput) -join "`n"
    Write-Error "helm diff upgrade failed (exit 1) for release '$Release': $errText"
    exit 1
}

$diffOutput | Set-Content -Path $diffFile -Encoding utf8

$meta = [pscustomobject]@{
    schemaVersion = 1
    artifactKind  = 'helm-diff'
    context       = $Context
    namespace     = $Namespace
    release       = $Release
    chartPath     = (Resolve-Path $ChartPath).Path
    valuesFile    = (Resolve-Path $ValuesFile).Path
    diffExitCode  = $diffExit
    generatedAt   = (Get-Date -AsUTC).ToString('o')
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
