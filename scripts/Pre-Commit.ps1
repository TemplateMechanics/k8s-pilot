<#
.SYNOPSIS
    Local pre-push gate for k8s-pilot. Runs the minimum validation set
    over the staged/committed changes (or a caller-supplied path set)
    before the operator pushes.

.DESCRIPTION
    Per CLAUDE.md R6, there is no CI in this repo. `Pre-Commit.ps1` is
    the local gate that catches the cheap classes of problems before a
    push: rendered-manifest schema/quality/policy, and MCP config
    secret hygiene.

    What it runs (each step is optional):
      - Validate-Manifests.ps1 on every directory under -ManifestPaths
        (or every kustomize directory discovered under examples/ if no
        paths given). Orchestrates kubeconform + kube-score + polaris;
        skips any tool that isn't installed.
      - Test-McpConfigSecrets.ps1 against the workspace's MCP config
        files.

    The gate is fast-fail: the first failing step's exit code becomes
    the script's exit code, but every step still runs (so a single push
    surfaces every class of issue at once rather than serializing one-
    fix-per-push).

.PARAMETER ManifestPaths
    One or more paths to validate. Each entry can be a single rendered
    manifest YAML file OR a kustomize directory (in which case the
    gate renders it via Invoke-KustomizeBuild.ps1 first and validates
    the rendered output).

    Default: every directory under `examples/` that contains a
    `kustomization.yaml` (so the bundled example is exercised by
    default, but real users override with their own paths).

.PARAMETER Context
    Kubernetes context to pass to Invoke-KustomizeBuild.ps1 for
    rendering. Required when -ManifestPaths is or includes a
    kustomize directory.

.PARAMETER SkipManifestValidation
    Skip the Validate-Manifests step entirely (only run the secret scan).

.PARAMETER SkipMcpSecretScan
    Skip the MCP secret scan step entirely (only run manifest validation).

.OUTPUTS
    Per-step status on the Information stream; structured per-step
    summary on stdout. Exit codes:
      0 - every executed step succeeded (or was skipped)
      1 - at least one step failed (per-step exit code in summary)
      2 - no steps ran (everything was skipped — operator error)

.EXAMPLE
    # Default: validates the bundled example + scans MCP configs
    pwsh ./scripts/Pre-Commit.ps1 -Context kind-kind

.EXAMPLE
    # Validate a specific path
    pwsh ./scripts/Pre-Commit.ps1 -ManifestPaths apps/web/overlays/staging -Context staging
#>
[CmdletBinding()]
param(
    [string[]] $ManifestPaths,
    [string]   $Context,
    [switch]   $SkipManifestValidation,
    [switch]   $SkipMcpSecretScan
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

$repoRoot = Split-Path -LiteralPath $PSScriptRoot -Parent

# Resolve default ManifestPaths if not provided: every directory under
# examples/ that contains a kustomization.yaml.
if (-not $ManifestPaths -or $ManifestPaths.Count -eq 0) {
    $examplesDir = Join-Path $repoRoot 'examples'
    if (Test-Path -LiteralPath $examplesDir -PathType Container) {
        $ManifestPaths = @(
            Get-ChildItem -LiteralPath $examplesDir -Recurse -Force -File `
                | Where-Object { $_.Name -eq 'kustomization.yaml' } `
                | ForEach-Object { $_.Directory.FullName }
        )
    }
    if (-not $ManifestPaths -or $ManifestPaths.Count -eq 0) {
        Write-Warning "No -ManifestPaths supplied and no kustomization.yaml found under examples/. Will only run the MCP secret scan."
        $ManifestPaths = @()
    }
}

$results = New-Object System.Collections.Generic.List[pscustomobject]

# Step 1: per-path Validate-Manifests
if (-not $SkipManifestValidation -and $ManifestPaths.Count -gt 0) {
    foreach ($p in $ManifestPaths) {
        if (-not (Test-Path -LiteralPath $p)) {
            $results.Add([pscustomobject]@{
                step     = 'validate-manifests'
                path     = $p
                exitCode = 1
                notes    = "Path does not exist."
            })
            continue
        }

        # If $p is a directory containing a kustomization.yaml, render
        # first via Invoke-KustomizeBuild then validate the output.
        $isKustomize = (Test-Path -LiteralPath $p -PathType Container) -and `
                       ((Test-Path -LiteralPath (Join-Path $p 'kustomization.yaml')) -or `
                        (Test-Path -LiteralPath (Join-Path $p 'kustomization.yml')))

        $targetForValidator = $p
        if ($isKustomize) {
            if (-not $Context) {
                $results.Add([pscustomobject]@{
                    step     = 'kustomize-build'
                    path     = $p
                    exitCode = 1
                    notes    = "-Context is required to render a kustomize directory."
                })
                continue
            }
            try {
                $rendered = & "$PSScriptRoot/kubectl/Invoke-KustomizeBuild.ps1" -Path $p -Context $Context
                $targetForValidator = $rendered
                $results.Add([pscustomobject]@{
                    step     = 'kustomize-build'
                    path     = $p
                    exitCode = 0
                    notes    = "Rendered to $rendered"
                })
            }
            catch {
                $results.Add([pscustomobject]@{
                    step     = 'kustomize-build'
                    path     = $p
                    exitCode = 1
                    notes    = "Render failed: $($_.Exception.Message)"
                })
                continue
            }
        }

        & "$PSScriptRoot/Validate-Manifests.ps1" -Path $targetForValidator | Out-Null
        $results.Add([pscustomobject]@{
            step     = 'validate-manifests'
            path     = $targetForValidator
            exitCode = $LASTEXITCODE
            notes    = if ($LASTEXITCODE -eq 0) { 'pass' }
                       elseif ($LASTEXITCODE -eq 2) { 'no validators ran (install kubeconform / kube-score / polaris)' }
                       else { 'one or more validators failed' }
        })
    }
}

# Step 2: MCP secret scan
if (-not $SkipMcpSecretScan) {
    $mcpScanner = Join-Path $PSScriptRoot 'mcp/Test-McpConfigSecrets.ps1'
    if (Test-Path -LiteralPath $mcpScanner -PathType Leaf) {
        & $mcpScanner | Out-Null
        $exit = $LASTEXITCODE
        $results.Add([pscustomobject]@{
            step     = 'mcp-secret-scan'
            path     = '.vscode/mcp*.json'
            exitCode = $exit
            notes    = switch ($exit) {
                0 { 'clean' }
                1 { 'suspected secret(s) detected' }
                2 { 'no MCP config files present (skipped)' }
                default { "scanner exited $exit" }
            }
        })
    }
}

# Emit structured summary on stdout.
$summary = [pscustomobject]@{
    repoRoot  = $repoRoot
    timestamp = (Get-Date -AsUTC).ToString('o')
    steps     = $results
}
$summary | ConvertTo-Json -Depth 5

# Human-readable per-step lines on Information.
foreach ($r in $results) {
    $marker = if ($r.exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    Write-Information ("{0,4}  {1,-24}  {2}  {3}" -f $marker, $r.step, $r.path, $r.notes) -InformationAction Continue
}

# Exit codes.
if ($results.Count -eq 0) {
    Write-Warning "No pre-commit steps ran (all skipped or nothing to validate)."
    exit 2
}
$anyFailed = @($results | Where-Object { $_.exitCode -ne 0 }).Count -gt 0
if ($anyFailed) { exit 1 } else { exit 0 }
