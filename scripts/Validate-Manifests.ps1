<#
.SYNOPSIS
    Canonical validator entrypoint for k8s-pilot. Orchestrates kubeconform,
    kube-score, and polaris on a rendered manifest path.

.DESCRIPTION
    Per CLAUDE.md Section 3.0, this is the single cross-cutting validator. It
    operates on already-rendered manifests, regardless of producer (kubectl,
    kustomize, helm template, flux build, argocd manifest dump).

    Each underlying tool is optional. Missing tools are skipped with a warning.
    Exit codes:
      0 - every non-skipped tool passed
      1 - at least one non-skipped tool failed
      2 - no validators ran (all tools missing or all -Skip* flags set)

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
    JSON object on stdout with the shape:
      { "Path": "<absolute-path>",
        "Results": [
          { "Tool": "kubeconform"|"kube-score"|"polaris",
            "Skipped": <bool>,
            "ExitCode": <int>,        # present when Skipped=false
            "Output":   "<text>",     # present when Skipped=false
            "Notes":    "<text>"      # present when Skipped=true
          }, ... ] }
    Human-readable per-tool status lines are written to the Information stream.
    Exit codes: 0 = all passed (or all skipped is treated as 2), 1 = at least
    one non-skipped tool failed, 2 = no validators ran.

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
        # @(...) forces array context so a single-string output is not joined
        # character-by-character by `-join`.
        Output   = (@($output) -join "`n")
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
        Output   = (@($output) -join "`n")
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
        Output   = (@($output) -join "`n")
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

# Stream routing:
#   - JSON summary goes to stdout (success stream) — this is the structured
#     contract for downstream tooling and the only thing on stdout.
#   - Skips are surfaced as Warnings (a skipped validator is something the
#     operator should know about but isn't an error).
#   - Pass / fail status lines and tool stdout go to the Information stream
#     with -InformationAction Continue, so callers can silence them with
#     -InformationAction SilentlyContinue without losing the JSON document.
foreach ($r in $results) {
    if ($r.Skipped) {
        Write-Warning "$($r.Tool): skipped ($($r.Notes))"
    }
    elseif ($r.ExitCode -ne 0) {
        Write-Information "$($r.Tool): FAIL (exit $($r.ExitCode))" -InformationAction Continue
        Write-Information $r.Output -InformationAction Continue
    }
    else {
        Write-Information "$($r.Tool): pass" -InformationAction Continue
    }
}

# Single JSON document on stdout.
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
