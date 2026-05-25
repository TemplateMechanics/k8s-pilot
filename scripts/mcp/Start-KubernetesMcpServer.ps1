<#
.SYNOPSIS
    Launch the Kubernetes MCP server using the launcher recorded in
    .vscode/mcp.servers.catalog.json.

.DESCRIPTION
    Reads the catalog, selects the entry whose `id` matches -ServerId
    (default 'kubernetes'), and runs the first launcher in
    `launchers[]` whose `command` is on PATH. Operators using a
    different launcher (e.g. docker vs npx) can pass -PreferredKind to
    skip earlier matches.

    The script does not start a daemon — it forwards stdio so VS Code's
    MCP host or another mcp-aware client can use it directly.

.PARAMETER ServerId
    Catalog entry id (default 'kubernetes').

.PARAMETER PreferredKind
    Optional launcher kind preference (npx | docker | binary | go-run).
    If set, only launchers with that kind are considered. If none match
    the kind AND are available on PATH, the script exits 4.

.PARAMETER CatalogPath
    Override the default `.vscode/mcp.servers.catalog.json`.

.OUTPUTS
    Forwards the launcher's stdio. Exit codes:
      0      - launcher returned 0
      2      - catalog parse error / server id not found / no launcher available
      3      - yq not in PATH (none required; catalog is JSON, so this
               error only fires for a future YAML catalog variant)
      4      - -PreferredKind specified but no matching launcher available
      other  - propagated from the launcher
#>
[CmdletBinding()]
param(
    [string] $ServerId = 'kubernetes',
    [ValidateSet('npx','docker','binary','go-run')]
    [string] $PreferredKind,
    [string] $CatalogPath = '.vscode/mcp.servers.catalog.json'
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
    Write-Error "MCP catalog not found at '$CatalogPath'."
    exit 2
}
try {
    $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "Failed to parse '$CatalogPath' as JSON: $($_.Exception.Message)"
    exit 2
}

if ($catalog.schemaVersion -ne 1) {
    Write-Error "Catalog schemaVersion is '$($catalog.schemaVersion)', expected 1."
    exit 2
}

$server = $catalog.servers | Where-Object { $_.id -ceq $ServerId } | Select-Object -First 1
if (-not $server) {
    Write-Error "No catalog entry with id='$ServerId'. Available: $(@($catalog.servers | ForEach-Object id) -join ', ')."
    exit 2
}

$candidates = if ($PreferredKind) {
    @($server.launchers | Where-Object { $_.kind -ceq $PreferredKind })
} else {
    @($server.launchers)
}
if ($candidates.Count -eq 0) {
    Write-Error "Catalog entry '$ServerId' has no launcher of kind '$PreferredKind'."
    exit 4
}

$selected = $null
foreach ($l in $candidates) {
    if (Get-Command $l.command -ErrorAction SilentlyContinue) {
        $selected = $l
        break
    }
}
if (-not $selected) {
    $kinds = ($candidates | ForEach-Object { "$($_.kind):$($_.command)" }) -join ', '
    Write-Error "No launcher for '$ServerId' has its command on PATH (tried: $kinds)."
    exit 4
}

# Defense in depth: every arg about to hit a native CLI is rejected if it
# starts with '-' from an unexpected source (catalog tampering). Real
# flag args start with '-' too, so we accept this risk but check that
# command itself is safe.
Assert-NonFlagArg -Value $selected.command -Name "catalog.launchers[].command"

Write-Information "Starting MCP server '$ServerId' via $($selected.kind): $($selected.command) $($selected.args -join ' ')" -InformationAction Continue
& $selected.command @($selected.args)
exit $LASTEXITCODE
