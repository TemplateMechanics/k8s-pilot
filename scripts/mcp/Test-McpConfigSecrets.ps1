<#
.SYNOPSIS
    Scan committed .vscode/mcp*.json files for likely secret material
    before push.

.DESCRIPTION
    Greps for patterns that suggest a credential was inlined into an
    MCP config (which would then end up in git). Designed to be invoked
    by scripts/Pre-Commit.ps1 (PR 12) but runnable standalone.

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
    [pscustomobject]@{ Regex = '(?i)"(token|access_token|bearer|password|secret|api_-?key|client_secret)"\s*:\s*"(?!\$\{env:)([^"\\\s]{4,})"'; Desc = 'inline credential value (use ${env:VAR} instead)' },
    [pscustomobject]@{ Regex = '\b(eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,})\b'; Desc = 'JWT-shaped string' },
    [pscustomobject]@{ Regex = '\b(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16})\b'; Desc = 'AWS access key id prefix' }
)

$hits = 0
foreach ($file in $existing) {
    $content = Get-Content -LiteralPath $file
    for ($i = 0; $i -lt $content.Count; $i++) {
        $line = $content[$i]
        foreach ($p in $patterns) {
            if ($line -match $p.Regex) {
                Write-Information "${file}:$($i + 1): suspected $($p.Desc)" -InformationAction Continue
                Write-Information "  > $line" -InformationAction Continue
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
