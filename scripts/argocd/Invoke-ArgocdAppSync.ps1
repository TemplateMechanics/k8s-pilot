<#
.SYNOPSIS
    Sync an Argo CD Application to a reviewed target revision
    (CLAUDE.md §3.3 App sync).

.DESCRIPTION
    Refuses to run without a valid -DiffFile produced by Invoke-ArgocdAppDiff.ps1.
    Verifies:
      1. The sidecar metadata exists and is valid JSON.
      2. artifactKind == 'argocd-diff' and schemaVersion == 1.
      3. Every consumed metadata field is a scalar string.
      4. metadata.server == -Server (case-sensitive).
      5. metadata.app == -App (case-sensitive).
      6. metadata.revision == -Revision (case-sensitive).
      7. metadata.app == basename of DiffFile's parent directory.
      8. metadata.server == basename of DiffFile's grandparent directory
         (slug match, since the path uses ConvertTo-SafeFilename).
      9. diffExitCode == 1 (helm-diff's "changes present"; we mapped to 2 in
         the wrapper exit, but the sidecar records argocd's native code).

    On success, runs `argocd app sync <app> --revision <rev> --server <server>`.

.OUTPUTS
    argocd's stdout. Exit codes:
      0   - sync succeeded
      3   - argocd binary not in PATH
      4   - metadata validation failure
      other - propagated from `argocd app sync`
    Preflight failures terminate with PS default exit 1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $DiffFile,

    [Parameter(Mandatory)] [string] $App,
    [Parameter(Mandatory)] [string] $Revision,
    [Parameter(Mandatory)] [string] $Server,

    [switch] $Prune
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

Assert-NonFlagArg -Value $App      -Name '-App'
Assert-NonFlagArg -Value $Revision -Name '-Revision'
Assert-NonFlagArg -Value $Server   -Name '-Server'

if (-not (Get-Command argocd -ErrorAction SilentlyContinue)) {
    Write-Error "argocd not found in PATH."
    exit 3
}

$metaFile = "$DiffFile.meta.json"
if (-not (Test-Path -LiteralPath $metaFile)) {
    Write-Error "Diff metadata sidecar not found at '$metaFile'. Regenerate via Invoke-ArgocdAppDiff.ps1."
    exit 4
}

try {
    $meta = Get-Content -LiteralPath $metaFile -Raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "Failed to parse diff metadata sidecar '$metaFile' as JSON: $($_.Exception.Message). Regenerate via Invoke-ArgocdAppDiff.ps1."
    exit 4
}

if ($meta.artifactKind -ne 'argocd-diff') {
    Write-Error "Diff metadata artifactKind is '$($meta.artifactKind)', expected 'argocd-diff'. Wrong wrapper?"
    exit 4
}
$EXPECTED_SCHEMA_VERSION = 1
if ($meta.PSObject.Properties.Name -notcontains 'schemaVersion' -or $meta.schemaVersion -ne $EXPECTED_SCHEMA_VERSION) {
    Write-Error "Diff metadata schemaVersion is '$($meta.schemaVersion)', expected $EXPECTED_SCHEMA_VERSION. Regenerate via Invoke-ArgocdAppDiff.ps1."
    exit 4
}

# Every consumed metadata field must be a scalar string.
foreach ($field in @('artifactKind', 'server', 'app', 'revision')) {
    $value = $meta.$field
    if ($null -eq $value -or $value -isnot [string]) {
        $actualType = if ($null -eq $value) { '<null>' } else { $value.GetType().FullName }
        Write-Error "Diff metadata field '$field' is not a scalar string (got $actualType). Regenerate via Invoke-ArgocdAppDiff.ps1."
        exit 4
    }
}

# Defend against argument injection from corrupted sidecar.
foreach ($field in @('server', 'app', 'revision')) {
    try {
        Assert-NonFlagArg -Value $meta.$field -Name "metadata.$field"
    }
    catch {
        Write-Error "Diff metadata field '$field' is unsafe: $($_.Exception.Message). Regenerate via Invoke-ArgocdAppDiff.ps1."
        exit 4
    }
}

# Case-sensitive match: argocd identifiers are case-sensitive.
if ($meta.server -cne $Server) {
    Write-Error "Diff metadata server '$($meta.server)' does not match -Server '$Server'. Refusing to sync against a different Argo CD instance."
    exit 4
}
if ($meta.app -cne $App) {
    Write-Error "Diff metadata app '$($meta.app)' does not match -App '$App'. Refusing to sync a different app."
    exit 4
}
if ($meta.revision -cne $Revision) {
    Write-Error "Diff metadata revision '$($meta.revision)' does not match -Revision '$Revision'. Refusing to sync a different revision than was reviewed."
    exit 4
}

# Cross-check the DiffFile path layout (.argocd/<serverSlug>/<appSlug>/<rev>.diff)
# against the metadata-recorded server/app slugs.
$parent      = Split-Path -LiteralPath $DiffFile -Parent
$appSlugDir  = Split-Path -LiteralPath $parent -Leaf
$grandparent = Split-Path -LiteralPath $parent -Parent
$serverSlugDir = Split-Path -LiteralPath $grandparent -Leaf
$expectedAppSlug    = ConvertTo-SafeFilename -Value $meta.app
$expectedServerSlug = ConvertTo-SafeFilename -Value $meta.server
if ($expectedAppSlug -cne $appSlugDir) {
    Write-Error "Diff metadata app slug '$expectedAppSlug' does not match app directory '$appSlugDir' in artifact path. Sidecar may be hand-edited or moved."
    exit 4
}
if ($expectedServerSlug -cne $serverSlugDir) {
    Write-Error "Diff metadata server slug '$expectedServerSlug' does not match server directory '$serverSlugDir' in artifact path. Sidecar may be hand-edited or moved."
    exit 4
}

# argocd app diff exit code 1 = changes present; refuse to sync against
# a clean diff (no-op syncs add audit noise and bump nothing useful).
if ($meta.diffExitCode -isnot [int] -and $meta.diffExitCode -isnot [long]) {
    Write-Error "Diff metadata diffExitCode is not an integer (got '$($meta.diffExitCode)'). Regenerate via Invoke-ArgocdAppDiff.ps1."
    exit 4
}
if ($meta.diffExitCode -ne 1) {
    Write-Error "Diff metadata records diffExitCode=$($meta.diffExitCode); argocd reports '1' when changes are present. Refusing to sync against an empty/clean diff. Re-diff after making the change you want to apply."
    exit 4
}

$syncArgs = @('app', 'sync', $App, '--revision', $Revision, '--server', $Server)
if ($Prune) { $syncArgs += '--prune' }

Write-Information "Syncing Argo CD app '$App' to revision $Revision on server '$Server'..." -InformationAction Continue
& argocd @syncArgs
$exit = $LASTEXITCODE
if ($exit -ne 0) {
    Write-Error "argocd app sync failed (exit $exit)."
    exit $exit
}
Write-Information "Sync complete. Consider running Invoke-ArgocdAppWait.ps1 to wait for Healthy + Synced." -InformationAction Continue
exit 0
