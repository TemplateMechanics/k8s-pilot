<#
.SYNOPSIS
    Scan the workspace's MCP config files for likely secret material
    before push.

.DESCRIPTION
    Greps for patterns that suggest a credential was inlined into an
    MCP config (which would then end up in git). Designed to be invoked
    by scripts/Pre-Commit.ps1 (PR 12) but runnable standalone.

    By default scans `.vscode/mcp.json` and
    `.vscode/mcp.servers.catalog.json` (silently skipping any that do
    not exist). Pass `-Paths` to scan additional or alternative paths
    (e.g. a glob expansion via `Get-ChildItem .vscode/mcp*.json`).

    Patterns checked (case-insensitive):
      - `"token"\s*:\s*"` followed by a non-`${env:...}` non-empty value
      - `"password"\s*:\s*"...`
      - `"apiKey"\s*:\s*"...` / `"api_key"`
      - `"secret"\s*:\s*"...`
      - JWT-shaped strings (three base64 segments separated by `.`)
      - AWS key prefixes `AKIA[0-9A-Z]{16}` (access key) / `ASIA...` (session key)

    Values that resolve via `${env:VAR}` interpolation are allowed; those
    are by-design references to environment variables and never contain
    the secret in the file.

.PARAMETER Paths
    Files to scan. Defaults to `.vscode/mcp.json` and `.vscode/mcp.servers.catalog.json` if present.

.OUTPUTS
    Exit codes:
      0 - no matches
      1 - at least one suspicious value (lines printed to Information stream)
      2 - none of the requested paths exist
#>
[CmdletBinding()]
param(
    [string[]] $Paths = @('.vscode/mcp.json', '.vscode/mcp.servers.catalog.json')
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

$existing = @($Paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
if ($existing.Count -eq 0) {
    Write-Warning "None of the requested MCP config paths exist: $($Paths -join ', ')."
    exit 2
}

# Patterns. Each is (regex, description).
$patterns = @(
    [pscustomobject]@{ Regex = '(?i)"(token|access_token|bearer|password|secret|api[_-]?key|apikey|client_secret)"\s*:\s*"(?!\$\{env:)([^"\\\s]{4,})"'; Desc = 'inline credential value (use ${env:VAR} instead)' },
    [pscustomobject]@{ Regex = '\b(eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,})\b'; Desc = 'JWT-shaped string' },
    [pscustomobject]@{ Regex = '\b(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16})\b'; Desc = 'AWS access key id prefix' }
)

$hits = 0
foreach ($file in $existing) {
    # Force array context: Get-Content on a single-line file returns
    # a scalar string, and $content.Count would then equal the char
    # count while $content[$i] would index characters instead of lines.
    $content = @(Get-Content -LiteralPath $file)
    for ($i = 0; $i -lt $content.Count; $i++) {
        $line = $content[$i]
        foreach ($p in $patterns) {
            if ($line -match $p.Regex) {
                # Report location + description; do NOT echo the matched
                # value (would re-expose the credential in terminal/CI
                # logs). If the operator needs the full line, they can
                # open the file at that line number.
                Write-Information "${file}:$($i + 1): suspected $($p.Desc) — value redacted; open the file at the line for context." -InformationAction Continue
                $hits++
            }
        }
    }
}

if ($hits -gt 0) {
    Write-Error "Found $hits suspected secret(s) in MCP config files. Replace with environment-variable interpolation (\${env:VAR}) or move to an out-of-tree secret store."
    exit 1
}
Write-Information "OK: no suspected secrets in $($existing.Count) MCP config file(s)." -InformationAction Continue
exit 0
