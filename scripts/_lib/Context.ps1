<#
.SYNOPSIS
    Shared context-safety helpers for k8s-pilot wrappers.

.DESCRIPTION
    Implements CLAUDE.md Rule R3: every mutation wrapper must take an explicit
    -Context (or -Cluster resolved via config/clusters.yaml) and refuse to run
    when it differs from the ambient kubectl context, unless -OverrideAmbientContext
    is also passed.

    Sourced by other wrappers via:  . "$PSScriptRoot/../_lib/Context.ps1"

    Each entrypoint script is responsible for setting its own
    $ErrorActionPreference; this library does NOT mutate caller scope.
#>

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

function Assert-NonFlagArg {
    <#
    .SYNOPSIS
        Rejects values that look like CLI flags (start with '-').
    .DESCRIPTION
        Used to validate values that become positional arguments to a native
        CLI invocation. If a value starts with '-' the CLI parser (cobra etc.)
        may treat it as a flag, leading to argument injection or unexpected
        behavior. This helper is complementary to Assert-SafePathSegment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [string] $Name
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name must not be empty."
    }
    if ($Value.StartsWith('-')) {
        throw "$Name '$Value' is unsafe: must not start with '-' (would be parsed as a CLI flag)."
    }
}

function ConvertTo-SafeFilename {
    <#
    .SYNOPSIS
        Returns a filesystem-safe slug derived from a Kubernetes identifier.
    .DESCRIPTION
        Kubernetes context names can contain characters that are invalid in
        Windows filesystems — notably ':' in EKS ARN contexts
        (arn:aws:eks:us-east-1:123456789012:cluster/my-cluster). This helper
        produces a slug suitable for directory/file names while preserving
        enough of the original to be human-readable. The TRUE context name
        should still be recorded inside the artifact's metadata for
        verification.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Value)

    # Replace any character that is invalid on Windows OR awkward in shell
    # paths with a '_'. Collapses long runs.
    $invalidChars = '[<>:"/\\|?*\s\x00-\x1f]'
    $slug = $Value -replace $invalidChars, '_'
    $slug = $slug -replace '_+', '_'
    $slug = $slug.Trim('_')
    if (-not $slug) { $slug = 'unnamed' }
    # Hard cap so very long ARN-style names don't blow filesystem limits.
    # Hard cap at 80 chars TOTAL: 71 chars of slug + '_' + 8-char hash = 80.
    if ($slug.Length -gt 80) {
        $hash = [System.Security.Cryptography.SHA1]::HashData([System.Text.Encoding]::UTF8.GetBytes($Value))
        $shortHash = ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 8).ToLowerInvariant()
        $slug = $slug.Substring(0, 71) + '_' + $shortHash
    }
    return $slug
}

function Assert-SafePathSegment {
    <#
    .SYNOPSIS
        Rejects strings that would escape a Join-Path output root.
    .DESCRIPTION
        Used to validate values like -Context that become directory names in
        artifact paths (kustomize-build/<context>/<name>.yaml). Without this
        check, a caller passing -Context "../etc" would land the artifact
        outside the intended root.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [string] $Name
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name must not be empty."
    }
    if ($Value -match '[/\\]' -or $Value -eq '.' -or $Value -eq '..' -or $Value.Contains('..')) {
        throw "$Name '$Value' is unsafe: must not contain path separators or '..' segments."
    }
    if ([System.IO.Path]::IsPathRooted($Value)) {
        throw "$Name '$Value' is unsafe: must not be a rooted path."
    }
}
