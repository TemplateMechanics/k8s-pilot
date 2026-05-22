<#
.SYNOPSIS
    Shared context-safety helpers for k8s-pilot wrappers.

.DESCRIPTION
    Implements CLAUDE.md Rule R3: every mutation wrapper must take an explicit
    -Context (or -Cluster resolved via config/clusters.yaml) and refuse to run
    when it differs from the ambient kubectl context, unless -OverrideAmbientContext
    is also passed.

    Sourced by other wrappers via:  . "$PSScriptRoot/../_lib/Context.ps1"
#>

$ErrorActionPreference = 'Stop'

function Assert-KubectlAvailable {
    [CmdletBinding()]
    param()
    $kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
    if (-not $kubectl) {
        throw "kubectl not found in PATH. Install kubectl >= 1.28 before using this wrapper."
    }
}

function Get-AmbientContext {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Assert-KubectlAvailable
    $ctx = & kubectl config current-context 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $ctx) {
        return $null
    }
    return $ctx.Trim()
}

function Test-KubectlContextExists {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Context
    )
    Assert-KubectlAvailable
    $existing = & kubectl config get-contexts -o name 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($existing -split "`n" | ForEach-Object { $_.Trim() }) -contains $Context
}

function Assert-ContextSafety {
    <#
    .SYNOPSIS
        Verifies that $Context exists in the active kubeconfig AND matches the
        ambient context (unless overridden). Throws on violation.

    .PARAMETER Context
        The named kubectl context the caller wants to target.

    .PARAMETER OverrideAmbientContext
        Allow the named context to differ from the ambient `kubectl config current-context`.
        Use only when invoking from automation that legitimately switches contexts
        per call (e.g. multi-cluster fan-out wrappers — see scripts/multi-cluster/).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Context,
        [switch] $OverrideAmbientContext
    )

    if (-not (Test-KubectlContextExists -Context $Context)) {
        throw "Context '$Context' is not defined in the active kubeconfig. Run 'kubectl config get-contexts' to inspect available contexts."
    }

    if ($OverrideAmbientContext) { return }

    $ambient = Get-AmbientContext
    if (-not $ambient) {
        throw "kubectl has no current-context. Pass -OverrideAmbientContext if you are scripting context switches deliberately."
    }
    if ($ambient -ne $Context) {
        throw "Refusing to run: requested -Context '$Context' differs from ambient kubectl current-context '$ambient'. Per CLAUDE.md R3, the wrapper will not silently retarget. Either run 'kubectl config use-context $Context' first, or pass -OverrideAmbientContext if this is intentional."
    }
}

function Get-PathBasename {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)
    return (Split-Path -Path (Resolve-Path -Path $Path).Path -Leaf)
}
