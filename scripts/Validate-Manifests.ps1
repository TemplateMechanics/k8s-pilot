<#
.SYNOPSIS
    Canonical validator entrypoint for k8s-pilot. Orchestrates kubeconform,
    kube-score, and polaris on a rendered manifest path.

.DESCRIPTION
    Per CLAUDE.md Section 3.0, this is the single cross-cutting validator. It
    operates on already-rendered manifests, regardless of producer (kubectl,
    kustomize, helm template, flux build, argocd manifest dump).

    Each underlying tool is optional but at least one must succeed; missing tools
    are skipped with a warning so this script remains useful in partial environments.

.PARAMETER Path
    A file or directory containing rendered Kubernetes manifests (YAML).

.PARAMETER SkipKubeconform
    Skip the kubeconform schema check.

.PARAMETER SkipKubeScore
    Skip the kube-score quality check.

.PARAMETER SkipPolaris
    Skip the polaris policy check.

.PARAMETER KubernetesVersion
    Kubernetes API version to validate against (kubeconform --kubernetes-version).
    Defaults to 1.28.0 to match the repo floor.

.OUTPUTS
    PSCustomObject with per-tool result (PassCount/FailCount/Skipped/Notes).
    Exits non-zero if any non-skipped tool reports failure.

.EXAMPLE
    pwsh ./scripts/Validate-Manifests.ps1 -Path kustomize-build/staging/web.yaml

.EXAMPLE
    pwsh ./scripts/Validate-Manifests.ps1 -Path helm-output/web/templated.yaml -SkipPolaris
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string] $Path,

    [switch] $SkipKubeconform,
    [switch] $SkipKubeScore,
    [switch] $SkipPolaris,

    [string] $KubernetesVersion = '1.28.0'
)

$ErrorActionPreference = 'Stop'

function Test-Command {
    param([string] $Name)
    return [bool] (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Kubeconform {
    param([string] $Target, [string] $Version)
    if (-not (Test-Command 'kubeconform')) {
        return [pscustomobject]@{ Tool = 'kubeconform'; Skipped = $true; Notes = 'binary not in PATH' }
    }
    $output = & kubeconform -summary -strict -kubernetes-version $Version -ignore-missing-schemas $Target 2>&1
    $exit = $LASTEXITCODE
    return [pscustomobject]@{
        Tool     = 'kubeconform'
        Skipped  = $false
        ExitCode = $exit
        Output   = ($output -join "`n")
    }
}

function Invoke-KubeScore {
    param([string] $Target)
    if (-not (Test-Command 'kube-score')) {
        return [pscustomobject]@{ Tool = 'kube-score'; Skipped = $true; Notes = 'binary not in PATH' }
    }
    $output = & kube-score score --output-format ci $Target 2>&1
    $exit = $LASTEXITCODE
    return [pscustomobject]@{
        Tool     = 'kube-score'
        Skipped  = $false
        ExitCode = $exit
        Output   = ($output -join "`n")
    }
}

function Invoke-Polaris {
    param([string] $Target)
    if (-not (Test-Command 'polaris')) {
        return [pscustomobject]@{ Tool = 'polaris'; Skipped = $true; Notes = 'binary not in PATH' }
    }
    $output = & polaris audit --audit-path $Target --format=pretty --set-exit-code-on-danger 2>&1
    $exit = $LASTEXITCODE
    return [pscustomobject]@{
        Tool     = 'polaris'
        Skipped  = $false
        ExitCode = $exit
        Output   = ($output -join "`n")
    }
}

$results = @()
if (-not $SkipKubeconform) { $results += Invoke-Kubeconform -Target $Path -Version $KubernetesVersion }
if (-not $SkipKubeScore)   { $results += Invoke-KubeScore   -Target $Path }
if (-not $SkipPolaris)     { $results += Invoke-Polaris     -Target $Path }

$summary = [pscustomobject]@{
    Path    = (Resolve-Path $Path).Path
    Results = $results
}

# Write summary to stdout as JSON for downstream tooling, plus human-readable lines to stderr.
foreach ($r in $results) {
    if ($r.Skipped) {
        Write-Warning "$($r.Tool): skipped ($($r.Notes))"
    }
    elseif ($r.ExitCode -ne 0) {
        Write-Warning "$($r.Tool): FAIL (exit $($r.ExitCode))"
        Write-Host $r.Output
    }
    else {
        Write-Host "$($r.Tool): pass"
    }
}

$summary | ConvertTo-Json -Depth 5

# Exit non-zero if any non-skipped tool failed.
$anyFailure = $results | Where-Object { -not $_.Skipped -and $_.ExitCode -ne 0 }
$anyRan     = $results | Where-Object { -not $_.Skipped }
if (-not $anyRan) {
    Write-Warning "No validators ran (all skipped or missing). Install kubeconform / kube-score / polaris to enable validation."
    exit 2
}
if ($anyFailure) { exit 1 }
exit 0
