<#
.SYNOPSIS
    Authenticate the argocd CLI against a specific Argo CD server
    (CLAUDE.md §3.3 Login).

.DESCRIPTION
    Thin wrapper around `argocd login`. The subsequent diff/sync/wait
    wrappers each take their own mandatory `-Server` argument and pass it
    to every argocd invocation, so the safety guarantee is per-call rather
    than via a persisted local "current server" record.

    The argocd CLI session is stored in the user's standard config location
    (`%USERPROFILE%\.config\argocd\config` on Windows, `~/.config/argocd/config`
    on Linux/macOS). CLAUDE.md §3.3 originally described a repo-local
    `.argocd/` session dir; that has been refined in CLAUDE.md to clarify
    that `.argocd/` holds ARTIFACTS only (diff files + metadata) and that
    the safety guarantee is per-call via the mandatory `-Server <host>`
    argument on every diff/sync/wait wrapper rather than via a relocated
    session. Cross-platform session relocation requires non-portable
    env-var hacks and is intentionally out of scope.

.PARAMETER Server
    Argo CD API server host (e.g. `argocd.example.com`). Used as
    `argocd login <Server>`.

.PARAMETER Username
    Username for login (passed via `--username`). Optional if using SSO.
    When set without -Sso, argocd will prompt INTERACTIVELY for the
    password. We deliberately do not accept a `-Password` parameter
    because passing secrets on the process command line exposes them
    via `ps`/`tasklist` and may be captured by shell history or
    monitoring agents.

.PARAMETER Sso
    Use SSO browser flow (`--sso`). Mutually exclusive with -Username.

.PARAMETER Insecure
    Skip TLS verification (passes `--insecure`). Discouraged; use only
    against dev/test servers with self-signed certs.

.OUTPUTS
    argocd's stdout. Exit codes:
      0   - login succeeded
      2   - mutually-exclusive option combination (-Sso with -Username)
      3   - argocd binary not in PATH
      other - propagated from `argocd login`
    Preflight parameter-validation failures (Assert-NonFlagArg)
    terminate via throw with PowerShell's default exit 1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Server,
    [string] $Username,
    [switch] $Sso,
    [switch] $Insecure
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Write-Error:ErrorAction'] = 'Continue'

. "$PSScriptRoot/../_lib/Context.ps1"

Assert-NonFlagArg -Value $Server -Name '-Server'
if ($Username) { Assert-NonFlagArg -Value $Username -Name '-Username' }

if (-not (Get-Command argocd -ErrorAction SilentlyContinue)) {
    Write-Error "argocd not found in PATH. Install argocd >= 2.10."
    exit 3
}
if ($Sso -and $Username) {
    Write-Error "-Sso is mutually exclusive with -Username."
    exit 2
}

$loginArgs = @('login', $Server)
if ($Sso) { $loginArgs += '--sso' }
if ($Username) {
    # argocd will prompt for the password interactively when --username is
    # set without --password; deliberate, to keep secrets off the command line.
    $loginArgs += @('--username', $Username)
}
if ($Insecure) { $loginArgs += '--insecure' }

Write-Information "Logging into Argo CD server '$Server'..." -InformationAction Continue
& argocd @loginArgs
$exit = $LASTEXITCODE
if ($exit -ne 0) {
    Write-Error "argocd login failed (exit $exit)."
    exit $exit
}
Write-Information "Login complete." -InformationAction Continue
exit 0
