<#
.SYNOPSIS
    Local pre-push gate for k8s-pilot. Runs the minimum validation set
    over a caller-supplied path set (or a sensible default discovered
    from the working tree) before the operator pushes.

.DESCRIPTION
    Per CLAUDE.md R6, there is no CI in this repo. `Pre-Commit.ps1` is
    the local gate that catches the cheap classes of problems before a
    push: rendered-manifest schema/quality/policy, and MCP config
    secret hygiene.

    What it runs:
      - Validate-Manifests.ps1 on every entry in -ManifestPaths.
        Kustomize directories are auto-rendered first via
        Invoke-KustomizeBuild.ps1 (requires -Context). Validator
        orchestrates kubeconform + kube-score + polaris; skips any
        tool that isn't installed.
      - Test-McpConfigSecrets.ps1 against the workspace's MCP config
        files.

    The gate is FAIL-LATE: every step runs even if a prior step
    failed, so a single push surfaces every class of issue at once.
    The script exits 1 if any step exited non-zero (excluding the
    "skipped — nothing to do" exit code 2 from the secret scan when
    no MCP config files are present).

    NOTE: this script does NOT integrate with git directly (no
    inspection of staged/committed paths). Drive it from your editor /
    pre-push hook by passing the paths you want validated; the default
    is to discover kustomize directories under examples/.

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

# Resolve the PowerShell host BEFORE Push-Location. `pwsh` is required
# (the wrappers target PS 7+); we run each child script as a SUBPROCESS
# via -File so that the child's `exit <code>` does not terminate this
# orchestrator. Avoid the null-conditional `?.` operator here so the
# script at least parses on Windows PowerShell 5.1 (where this check
# would otherwise fail before producing the intended error message).
$pwshCmd  = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue
$pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { $null }
if (-not $pwshPath) {
    Write-Error "pwsh (PowerShell 7+) not found in PATH. Install pwsh — the wrappers target PS 7."
    exit 1
}

# Anchor at the repo root so relative paths (config/, examples/) resolve
# consistently regardless of where the operator invoked the script from.
# Wrap the body in try/finally so an unexpected terminating error
# (under -Stop) cannot leave the caller's working directory at
# $repoRoot. $pushed is set after Push-Location succeeds and read in
# the finally block so we only pop if we actually pushed.
$pushed = $false
Push-Location -LiteralPath $repoRoot
$pushed = $true
try {

# Resolve default ManifestPaths if not provided: every directory under
# examples/ that contains a kustomization.yaml.
if (-not $ManifestPaths -or $ManifestPaths.Count -eq 0) {
    $examplesDir = Join-Path $repoRoot 'examples'
    if (Test-Path -LiteralPath $examplesDir -PathType Container) {
        $ManifestPaths = @(
            Get-ChildItem -LiteralPath $examplesDir -Recurse -Force -File `
                | Where-Object { $_.Name -ceq 'kustomization.yaml' -or $_.Name -ceq 'kustomization.yml' } `
                | ForEach-Object { $_.Directory.FullName } `
                | Sort-Object -Unique
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
            $kustomizeBuild = Join-Path $PSScriptRoot 'kubectl/Invoke-KustomizeBuild.ps1'
            # Run as subprocess so the child's `exit` does not kill us.
            # Capture stderr to a temp file (not 2>$null) so we can
            # surface diagnostics — child wrappers stream Write-Warning,
            # Write-Information, and Write-Error to stderr.
            $childErr = [System.IO.Path]::GetTempFileName()
            try {
                $renderedLines = & $pwshPath -NoProfile -File $kustomizeBuild -Path $p -Context $Context 2>$childErr
                $buildExit = $LASTEXITCODE
                $childErrText = Get-Content -LiteralPath $childErr -Raw -ErrorAction SilentlyContinue
            }
            finally {
                Remove-Item -LiteralPath $childErr -Force -ErrorAction SilentlyContinue
            }
            # Surface non-fatal diagnostics from the child on the parent's
            # Warning stream so they aren't lost (kustomize-binary fallback,
            # kustomize stderr warnings).
            if ($childErrText -and $buildExit -eq 0) {
                Write-Warning "Invoke-KustomizeBuild.ps1 stderr for '$p': $($childErrText.Trim())"
            }
            if ($buildExit -ne 0) {
                # Collapse multi-line stderr to single-line so the
                # per-step PASS/FAIL formatting stays scannable. Cap at
                # 240 chars so a runaway message doesn't dominate.
                $errSnippet = ''
                if ($childErrText) {
                    $errSnippet = ($childErrText -replace '\s+', ' ').Trim()
                    if ($errSnippet.Length -gt 240) {
                        $errSnippet = $errSnippet.Substring(0, 240) + '…'
                    }
                }
                $results.Add([pscustomobject]@{
                    step     = 'kustomize-build'
                    path     = $p
                    exitCode = $buildExit
                    notes    = "Render failed (exit $buildExit): $errSnippet"
                })
                continue
            }
            # The script writes the rendered path to its success stream
            # as its last line. Defensively walk the lines in reverse
            # and take the first one that actually exists on disk —
            # any informational text the child emits via Write-Output
            # (or accidentally pipes from a sub-call) won't validate as
            # a real path. If nothing in the output is a path, fall back
            # to the last non-empty line and let Validate-Manifests fail
            # loudly with a missing-path error.
            # Take the last 5 non-empty lines, then reverse the array
            # so the loop walks newest -> oldest. Select-Object -Last
            # alone preserves original order, which would pick an
            # earlier existing path before the actually-final one.
            $rendered = $null
            $tail = @($renderedLines | Where-Object { $_ } | Select-Object -Last 5)
            [array]::Reverse($tail)
            foreach ($line in $tail) {
                $candidate = ([string]$line).Trim()
                if ($candidate -and (Test-Path -LiteralPath $candidate)) {
                    $rendered = $candidate
                    break
                }
            }
            if (-not $rendered) {
                $rendered = (@($renderedLines | Where-Object { $_ }) | Select-Object -Last 1)
            }
            $targetForValidator = $rendered
            $results.Add([pscustomobject]@{
                step     = 'kustomize-build'
                path     = $p
                exitCode = 0
                notes    = "Rendered to $rendered"
            })
        }

        $validate = Join-Path $PSScriptRoot 'Validate-Manifests.ps1'
        # Capture the child's stdout (its JSON summary) into a variable
        # and route it to the parent's Information stream so it does
        # NOT collide with this orchestrator's own structured JSON
        # summary on stdout. Stderr is forwarded as-is (Information /
        # Warning / Error from the child).
        $validateOut = & $pwshPath -NoProfile -File $validate -Path $targetForValidator
        $validateExit = $LASTEXITCODE
        foreach ($line in @($validateOut)) {
            if ($null -ne $line -and $line -ne '') {
                Write-Information "  [validate-manifests:$targetForValidator] $line" -InformationAction Continue
            }
        }
        $results.Add([pscustomobject]@{
            step     = 'validate-manifests'
            path     = $targetForValidator
            exitCode = $validateExit
            notes    = if ($validateExit -eq 0) { 'pass' }
                       elseif ($validateExit -eq 2) { 'no validators ran (install kubeconform / kube-score / polaris)' }
                       else { 'one or more validators failed' }
        })
    }
}

# Step 2: MCP secret scan
if (-not $SkipMcpSecretScan) {
    $mcpScanner = Join-Path $PSScriptRoot 'mcp/Test-McpConfigSecrets.ps1'
    if (Test-Path -LiteralPath $mcpScanner -PathType Leaf) {
        # Subprocess for the same reason — child's `exit` shouldn't
        # take down the orchestrator. Capture stdout and route to
        # Information so the per-line warnings reach the operator
        # without colliding with the orchestrator's JSON summary on
        # stdout.
        $mcpOut = & $pwshPath -NoProfile -File $mcpScanner
        $mcpExitCode = $LASTEXITCODE
        foreach ($line in @($mcpOut)) {
            if ($null -ne $line -and $line -ne '') {
                Write-Information "  [mcp-secret-scan] $line" -InformationAction Continue
            }
        }
        $results.Add([pscustomobject]@{
            step     = 'mcp-secret-scan'
            path     = '.vscode/mcp*.json'
            exitCode = $mcpExitCode
            notes    = switch ($mcpExitCode) {
                0 { 'clean' }
                1 { 'suspected secret(s) detected' }
                2 { 'no MCP config files present (skipped)' }
                default { "scanner exited $mcpExitCode" }
            }
        })
    }
    else {
        # The scanner script should ship with the repo (PR 9). If it's
        # missing, log a result row so the gate doesn't silently exit
        # 'success' when a step the operator expected to run is gone.
        $results.Add([pscustomobject]@{
            step     = 'mcp-secret-scan'
            path     = $mcpScanner
            exitCode = 1
            notes    = "Scanner script missing — was scripts/mcp/Test-McpConfigSecrets.ps1 deleted or moved?"
        })
    }
}

# Emit structured summary on stdout.
$summary = [pscustomobject]@{
    repoRoot  = $repoRoot
    # ToUniversalTime() is cross-version; Get-Date -AsUTC is PS 7+ only
    # and would fail at parse-time on Windows PowerShell 5.1.
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    steps     = $results
}
$summary | ConvertTo-Json -Depth 5

# Human-readable per-step lines on Information.
foreach ($r in $results) {
    # SKIP (not FAIL) for mcp-secret-scan exit 2 (no MCP files
    # present). The overall exit-code logic below already excludes
    # this from the failure count.
    $marker = if ($r.exitCode -eq 0) { 'PASS' }
              elseif ($r.step -eq 'mcp-secret-scan' -and $r.exitCode -eq 2) { 'SKIP' }
              else { 'FAIL' }
    Write-Information ("{0,4}  {1,-24}  {2}  {3}" -f $marker, $r.step, $r.path, $r.notes) -InformationAction Continue
}

# Exit codes.
}
finally {
    if ($pushed) {
        Pop-Location -ErrorAction SilentlyContinue
        $pushed = $false
    }
}

if ($results.Count -eq 0) {
    Write-Warning "No pre-commit steps ran (all skipped or nothing to validate)."
    exit 2
}
# Treat the MCP secret scanner's exit code 2 ("no MCP config files
# present") as non-failing — it's a legitimate skip, not an error,
# and would otherwise flip the whole gate red on repos that don't
# happen to use MCP.
$anyFailed = @(
    $results | Where-Object {
        $_.exitCode -ne 0 -and -not ($_.step -eq 'mcp-secret-scan' -and $_.exitCode -eq 2)
    }
).Count -gt 0
if ($anyFailed) { exit 1 } else { exit 0 }
