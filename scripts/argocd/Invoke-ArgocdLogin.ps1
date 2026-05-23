<#
.SYNOPSIS
    Authenticate the argocd CLI against a specific Argo CD server
    (CLAUDE.md §3.3 Login).

.DESCRIPTION
    Thin wrapper around `argocd login` that records the named server so
    subsequent diff/sync/wait wrappers can verify they are talking to the
    expected instance.

    The argocd CLI session is stored in the user's standard config location
    (`%USERPROFILE%\.config\argocd\config` on Windows, `~/.config/argocd/config`
    on Linux/macOS). The repo-local `.argocd/` directory under the workspace
    is used by the diff/sync wrappers to store ARTIFACTS (per-server diff
    files + metadata), not the CLI session itself; relocating the CLI
    session reliably across platforms is out of scope for this wrapper.

.PARAMETER Server
    Argo CD API server host (e.g. `argocd.example.com`). Used as
    `argocd login <Server>`.

.PARAMETER Username
    Username for login (passed via `--username`). Optional if using SSO.

.PARAMETER Password
    Password (passed via `--password`). Optional if using SSO. Consider
    `--sso` flow instead for production.

.PARAMETER Sso
    Use SSO browser flow (`--sso`). Mutually exclusive with -Username/-Password.

.PARAMETER Insecure
    Skip TLS verification (passes `--insecure`). Discouraged; use only
    against dev/test servers with self-signed certs.

.OUTPUTS
    argocd's stdout. Exit codes:
      0   - login succeeded
      2   - mutually-exclusive option combination (-Sso with -Username/-Password)
      3   - argocd binary not in PATH
      other - propagated from `argocd login`
    Preflight parameter-validation failures (Assert-NonFlagArg)
    terminate via throw with PowerShell's default exit 1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Server,
    [string] $Username,
    [string] $Password,
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
if ($Sso -and ($Username -or $Password)) {
    Write-Error "-Sso is mutually exclusive with -Username/-Password."
    exit 2
}

$loginArgs = @('login', $Server)
if ($Sso) { $loginArgs += '--sso' }
if ($Username) { $loginArgs += @('--username', $Username) }
if ($Password) { $loginArgs += @('--password', $Password) }
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
