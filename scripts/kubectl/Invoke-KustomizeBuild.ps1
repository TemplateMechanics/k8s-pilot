<#
.SYNOPSIS
    Render a kustomize overlay to a file artifact (CLAUDE.md §3.1 Build).

.DESCRIPTION
    Wraps `kustomize build` (or `kubectl kustomize` as a fallback). Emits the
    rendered manifest under kustomize-build/<context>/<name>.yaml, where <name>
    is the basename of -Path. The output is intended as input to
    Invoke-KubectlDiff.ps1 and downstream Invoke-KubectlApply.ps1.

.PARAMETER Path
    Path to a kustomization (directory containing kustomization.yaml).

.PARAMETER Context
    Kubernetes context this build is targeted at. Recorded in the artifact path
    so the eventual apply knows which cluster the render was produced for.

.PARAMETER OutputDir
    Override the default kustomize-build/ directory.

.OUTPUTS
    The resolved path of the rendered manifest file.

.EXAMPLE
    pwsh ./scripts/kubectl/Invoke-KustomizeBuild.ps1 -Path apps/web/overlays/staging -Context staging
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string] $Path,

    [Parameter(Mandatory)]
    [string] $Context,

    [string] $OutputDir = 'kustomize-build'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../_lib/Context.ps1"

Assert-SafePathSegment -Value $Context -Name '-Context'

if (-not (Test-Path (Join-Path $Path 'kustomization.yaml')) -and -not (Test-Path (Join-Path $Path 'kustomization.yml'))) {
    throw "No kustomization.yaml (or .yml) found in '$Path'. Invoke-KustomizeBuild.ps1 requires a kustomize directory."
}

$name = Get-PathBasename -Path $Path
$outDir = Join-Path $OutputDir $Context
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$outFile = Join-Path $outDir "$name.yaml"

# Prefer kustomize binary if available; fall back to `kubectl kustomize`.
# Capture stderr to a temp file so it cannot pollute the rendered YAML (a
# 2>&1 merge would inject warnings into the file and break diff/apply).
$errFile = [System.IO.Path]::GetTempFileName()
try {
    if (Get-Command kustomize -ErrorAction SilentlyContinue) {
        $rendered = & kustomize build $Path 2>$errFile
    }
    elseif (Get-Command kubectl -ErrorAction SilentlyContinue) {
        Write-Warning "kustomize binary not found; falling back to 'kubectl kustomize'."
        $rendered = & kubectl kustomize $Path 2>$errFile
    }
    else {
        throw "Neither 'kustomize' nor 'kubectl' is on PATH."
    }

    $stderrContent = Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        throw "kustomize build failed for '$Path' (exit $LASTEXITCODE): $stderrContent"
    }
    if ($stderrContent) {
        # Non-fatal warnings from kustomize go to stderr; surface them but
        # do NOT include them in the rendered output.
        Write-Warning "kustomize produced stderr output (not included in rendered file):`n$stderrContent"
    }

    $rendered | Set-Content -Path $outFile -Encoding utf8
}
finally {
    Remove-Item -Path $errFile -Force -ErrorAction SilentlyContinue
}

Write-Information "Rendered $Path -> $outFile" -InformationAction Continue
return (Resolve-Path $outFile).Path
