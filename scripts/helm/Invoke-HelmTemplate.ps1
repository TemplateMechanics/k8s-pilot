<#
.SYNOPSIS
    Render a Helm chart to a manifest artifact (CLAUDE.md §3.2 Template).

.DESCRIPTION
    Wraps `helm template`. Emits the rendered manifest under
    helm-output/<namespace>/<release>/templated.yaml. Output is intended as
    input to Invoke-HelmDiff.ps1 or Validate-Manifests.ps1.

    Per CLAUDE.md §3.2, -Namespace is mandatory because Helm releases are
    namespaced and `<release>` alone is not unique.

.PARAMETER ChartPath
    Path to a chart directory (containing Chart.yaml) or a packaged .tgz.

.PARAMETER ValuesFile
    Path to a values.yaml file with environment-specific overrides.

.PARAMETER Release
    Release name (passed to `helm template` as the first positional argument).

.PARAMETER Namespace
    Target namespace. Recorded in the output path so subsequent helm wrappers
    can verify the same namespace is used end-to-end.

.PARAMETER OutputDir
    Override the default helm-output/ directory.

.OUTPUTS
    Writes the resolved path of the rendered manifest to the pipeline.
    Exit codes:
      0   - success
      3   - helm binary not in PATH
      other - propagated from `helm template`

.EXAMPLE
    pwsh ./scripts/helm/Invoke-HelmTemplate.ps1 -ChartPath charts/web -ValuesFile charts/web/values-prod.yaml -Release web -Namespace web
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string] $ChartPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $ValuesFile,

    [Parameter(Mandatory)]
    [string] $Release,

    [Parameter(Mandatory)]
    [string] $Namespace,

    [string] $OutputDir = 'helm-output'
)

$ErrorActionPreference = 'Stop'
# Write-Error becomes terminating under -Stop, which would short-circuit the
# `Write-Error ...; exit <code>` pattern and break the documented exit-code
# contract. Force it back to non-terminating for this script.
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

Assert-SafePathSegment -Value $Namespace -Name '-Namespace'
Assert-SafePathSegment -Value $Release   -Name '-Release'
Assert-NonFlagArg      -Value $Release   -Name '-Release'
Assert-NonFlagArg      -Value $ChartPath -Name '-ChartPath'
Assert-NonFlagArg      -Value $ValuesFile -Name '-ValuesFile'

if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    Write-Error "helm not found in PATH. Install helm >= 3.13 before using this wrapper."
    exit 3
}

$outDir = Join-Path (Join-Path $OutputDir $Namespace) $Release
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$outFile = Join-Path $outDir 'templated.yaml'

# Capture stderr separately so warnings cannot pollute the rendered manifest.
$errFile = [System.IO.Path]::GetTempFileName()
try {
    $rendered = & helm template $Release $ChartPath `
        --namespace $Namespace `
        --values $ValuesFile `
        --include-crds 2>$errFile
    $helmExit = $LASTEXITCODE

    $stderrContent = Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue

    if ($helmExit -ne 0) {
        Write-Error "helm template failed for '$ChartPath' (exit $helmExit): $stderrContent"
        exit $helmExit
    }
    if ($stderrContent) {
        Write-Warning "helm produced stderr output (not included in rendered file):`n$stderrContent"
    }

    $rendered | Set-Content -Path $outFile -Encoding utf8
}
finally {
    Remove-Item -Path $errFile -Force -ErrorAction SilentlyContinue
}

Write-Information "Rendered $ChartPath -> $outFile" -InformationAction Continue
Write-Output (Resolve-Path $outFile).Path
exit 0
