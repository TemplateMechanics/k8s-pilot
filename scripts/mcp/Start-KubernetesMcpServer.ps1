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
      2      - catalog parse error / schemaVersion mismatch / -ServerId
               not found in catalog
      4      - no usable launcher (none available on PATH, or
               -PreferredKind specified and no matching launcher exists
               or none of them are on PATH)
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
    # -CommandType Application restricts the resolution to native
    # executables; without this, an alias or function with the same
    # name in the caller's session could be invoked instead of the
    # real binary (catalog tampering escalation risk).
    if (Get-Command $l.command -CommandType Application -ErrorAction SilentlyContinue) {
        $selected = $l
        break
    }
}
if (-not $selected) {
    $kinds = ($candidates | ForEach-Object { "$($_.kind):$($_.command)" }) -join ', '
    Write-Error "No launcher for '$ServerId' has its command on PATH as a native executable (tried: $kinds)."
    exit 4
}

# Defense in depth on the launcher command name itself.
Assert-NonFlagArg -Value $selected.command -Name "catalog.launchers[].command"

# Expand ${env:VAR} interpolations in args. The catalog uses VS Code-style
# variable syntax (so the catalog also makes sense to humans editing it),
# but native command invocation doesn't expand those - we do it here. An
# unresolved variable is replaced with an empty string and logged so the
# operator notices.
function Expand-CatalogArg {
    param([string] $Arg)
    return [regex]::Replace($Arg, '\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}', {
        param($m)
        $name = $m.Groups[1].Value
        $val  = [System.Environment]::GetEnvironmentVariable($name)
        # Special-case HOME so Windows operators don't have to set the env
        # var manually: PowerShell's $HOME automatic variable is
        # cross-platform (USERPROFILE on Windows, $HOME on Unix).
        if (($null -eq $val -or $val -eq '') -and $name -eq 'HOME' -and $HOME) {
            return $HOME
        }
        if ($null -eq $val -or $val -eq '') {
            # Fail loud: silently substituting an empty string can produce
            # malformed args like '-v /.kube:/root/.kube:ro' (rooted at
            # the FS root) which mounts the wrong directory. Throw and
            # let the caller surface exit 4.
            throw "Environment variable '$name' referenced in catalog launcher is unset/empty. Set it before launching or change the catalog to a literal."
        }
        return $val
    })
}

# Normalize args (may be $null in catalog) and expand env interpolation.
# A failed expansion (unset env var) becomes an exit-4 error so the
# operator notices instead of silently launching with bogus args.
$rawArgs = if ($selected.args) { @($selected.args) } else { @() }
try {
    $expanded = foreach ($a in $rawArgs) {
        if ($null -eq $a) { '' } else { Expand-CatalogArg -Arg ([string]$a) }
    }
}
catch {
    Write-Error "Catalog launcher args could not be resolved: $($_.Exception.Message)"
    exit 4
}
$expanded = @($expanded)

# Status to STDERR, not stdout — when this script is used as the MCP
# transport for a client that speaks the MCP stdio protocol, any
# non-protocol bytes on stdout corrupt the framing. Log only the
# launcher kind + command name (not the expanded argv) so values
# sourced from ${env:VAR} interpolations don't leak into logs.
[Console]::Error.WriteLine("Starting MCP server '$ServerId' via $($selected.kind):$($selected.command) (argv redacted to avoid leaking env-sourced values; re-run with -Verbose if you need to see them).")
if ($VerbosePreference -ne 'SilentlyContinue') {
    [Console]::Error.WriteLine("  argv: $($expanded -join ' ')")
}
& $selected.command @expanded
exit $LASTEXITCODE
