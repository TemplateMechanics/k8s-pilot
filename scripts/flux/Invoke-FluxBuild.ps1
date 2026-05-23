<#
.SYNOPSIS
    Render a Flux Kustomization to a manifest artifact (CLAUDE.md §3.4 Build).

.DESCRIPTION
    Wraps `flux build kustomization`. Streams stdout directly to
    `.flux/<kustomization>.yaml` so large outputs don't accumulate in
    memory; stderr is captured separately so warnings cannot pollute the
    rendered manifest.

.PARAMETER Kustomization
    Name of the Flux Kustomization CR.

.PARAMETER Path
    Filesystem path to the directory the Kustomization references.

.PARAMETER OutputDir
    Override the default `.flux/` artifact root.

.OUTPUTS
    Writes the rendered manifest path to the pipeline.
    Exit codes:
      0   - success
      3   - flux binary not in PATH
      other - propagated from `flux build kustomization`
    Preflight Assert-NonFlagArg / Assert-SafePathSegment failures terminate
    with PowerShell's default exit 1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Kustomization,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string] $Path,

    [string] $OutputDir = '.flux'
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

Assert-SafePathSegment -Value $Kustomization -Name '-Kustomization'
Assert-NonFlagArg      -Value $Kustomization -Name '-Kustomization'
Assert-NonFlagArg      -Value $Path          -Name '-Path'

if (-not (Get-Command flux -ErrorAction SilentlyContinue)) {
    Write-Error "flux not found in PATH. Install flux >= 2.2."
    exit 3
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -LiteralPath $OutputDir -Force | Out-Null
}
$outFile = Join-Path $OutputDir "$Kustomization.yaml"

$errFile = [System.IO.Path]::GetTempFileName()
try {
    & flux build kustomization $Kustomization --path $Path 1>$outFile 2>$errFile
    $exit = $LASTEXITCODE
    $stderrContent = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue

    if ($exit -ne 0) {
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        Write-Error "flux build kustomization failed (exit $exit) for '$Kustomization': $stderrContent"
        exit $exit
    }
    if ($stderrContent) {
        Write-Warning "flux produced stderr output (not included in rendered file):`n$stderrContent"
    }
}
finally {
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
}

Write-Information "Rendered Flux Kustomization '$Kustomization' from '$Path' -> $outFile" -InformationAction Continue
Write-Output (Resolve-Path -LiteralPath $outFile).Path
exit 0
