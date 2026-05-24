<#
.SYNOPSIS
    Shared helpers for the multi-cluster fan-out wrappers.

.DESCRIPTION
    Reads config/clusters.yaml via `yq` (required) and parses the selector
    expression. Centralizes the prod-exclusion rule so every fan-out
    wrapper enforces it identically.

    Sourced by Get-Clusters.ps1 and the Invoke-*Across.ps1 wrappers:
        . "$PSScriptRoot/_lib/Registry.ps1"
#>

function Assert-YqAvailable {
    [CmdletBinding()]
    param()
    if (-not (Get-Command yq -ErrorAction SilentlyContinue)) {
        throw "yq not found in PATH. Install yq >= 4.0 (https://github.com/mikefarah/yq) for YAML registry parsing."
    }
    # mikefarah/yq v4 prints 'yq (https://...) version v4.x.y'. v3 used
    # different positional syntax (no separate expression arg). The
    # Python kislyuk/yq prints 'jq version ...' (jq under the hood).
    # Reject anything that looks like Python yq, and require a
    # 'version vN...' where N >= 4 so a future mikefarah v5 still passes
    # until/unless we explicitly need to gate against it.
    $verOut = (& yq --version 2>&1 | Out-String).Trim()
    if ($verOut -match '(?i)jq version') {
        throw "Unsupported yq implementation (got '$verOut' — looks like kislyuk/yq, which is a Python wrapper around jq). This wrapper requires mikefarah/yq v4+; install via your package manager or 'go install github.com/mikefarah/yq/v4@latest'."
    }
    if ($verOut -match '(?i)\bversion\s+v?(\d+)(?:\.\d+){0,2}') {
        $major = [int]$Matches[1]
        if ($major -lt 4) {
            throw "Unsupported yq major version (got '$verOut'). This wrapper requires mikefarah/yq v4+ because the 'eval <expr> <file>' syntax differs in v3."
        }
    }
    else {
        throw "Could not parse yq version from '$verOut'. This wrapper requires mikefarah/yq v4+."
    }
}

function Read-ClustersRegistry {
    <#
    .SYNOPSIS
        Parse config/clusters.yaml into a typed object array.
    .OUTPUTS
        Array of [pscustomobject] with: name, context, kubeconfig (nullable),
        tier, labels (hashtable, may be empty).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string] $RegistryPath = 'config/clusters.yaml'
    )
    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        throw "Cluster registry not found at '$RegistryPath'. Create one based on the example in config/clusters.yaml."
    }
    # Defend against -RegistryPath being interpreted as a yq flag (e.g.
    # a path starting with '-'). The path safety + non-flag check is
    # consistent with Assert-NonFlagArg used elsewhere in the repo.
    if ($RegistryPath.StartsWith('-')) {
        throw "RegistryPath '$RegistryPath' is unsafe: must not start with '-' (would be parsed as a CLI flag by yq)."
    }
    Assert-YqAvailable

    # Convert YAML to JSON via yq; capture stderr separately.
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        # mikefarah/yq v4: `eval` (alias `e`) takes an expression first
        # and one or more file paths after. Pass '.' as the identity
        # expression so the registry path is unambiguously a file argument.
        # Coerce multi-line output to a single string so ConvertFrom-Json
        # parses the whole document (piping a string[] would parse
        # line-by-line and fail on multi-line JSON).
        $json = (& yq -o=json eval '.' $RegistryPath 2>$errFile | Out-String)
        if ($LASTEXITCODE -ne 0) {
            $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
            throw "yq failed to parse '$RegistryPath' (exit $LASTEXITCODE): $err"
        }
    }
    finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }

    try {
        $doc = $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to parse registry JSON from '$RegistryPath': $($_.Exception.Message)"
    }

    if ($doc.schemaVersion -ne 1) {
        throw "Registry schemaVersion is '$($doc.schemaVersion)', expected 1."
    }
    # The schema requires a top-level `clusters` field. An entirely
    # missing field almost certainly indicates a malformed YAML (or a
    # YAML that was lost in a merge); silently returning [] would hide
    # the problem and let selectors match nothing without warning.
    if (-not $doc.PSObject.Properties.Match('clusters')) {
        throw "Registry '$RegistryPath' is missing the required top-level 'clusters' field. See config/clusters.schema.json."
    }
    if ($null -eq $doc.clusters) {
        # Field is present but null (e.g. `clusters: ~` or `clusters: []`
        # collapses to null in some yq paths). Treat empty list as
        # legitimate but log so empty fan-outs aren't a complete surprise.
        Write-Warning "Registry '$RegistryPath' has zero clusters. Fan-out wrappers will match nothing."
        return @()
    }

    $allowedTiers = @('dev', 'staging', 'prod')

    # Validate required fields FIRST so a missing 'name' produces a
    # clear "missing required field" error rather than colliding with
    # other entries in the duplicate-name check below.
    foreach ($c in $doc.clusters) {
        foreach ($field in @('name', 'context', 'tier')) {
            $v = $c.$field
            if ($null -eq $v -or ([string]$v).Trim() -eq '') {
                throw "Registry entry is missing required field '$field' (value '$v'). See config/clusters.schema.json."
            }
        }
        if ($c.tier -cnotin $allowedTiers) {
            throw "Registry entry '$($c.name)' has tier '$($c.tier)'; allowed: $($allowedTiers -join ', ')."
        }
    }

    # Now safe to detect duplicate cluster names. A duplicate name would
    # make name=<dup> match multiple rows (potentially including a prod
    # row), bypassing the explicit-name opt-in's safety intent.
    $names = $doc.clusters | ForEach-Object { [string]$_.name }
    $dups = $names | Group-Object | Where-Object { $_.Count -gt 1 } | Select-Object -ExpandProperty Name
    if ($dups) {
        throw "Registry contains duplicate cluster name(s): $($dups -join ', '). Names must be unique."
    }

    # foreach (...) yields $null if the input is empty; filter to keep
    # the result a clean array of cluster objects only.
    $result = foreach ($c in $doc.clusters) {
        $labels = @{}
        if ($c.labels) {
            foreach ($prop in $c.labels.PSObject.Properties) {
                $val = $prop.Value
                # Labels must be scalar strings (or string-coercible
                # primitives). Reject arrays/objects so selectors don't
                # silently match on a stringified hashtable.
                if ($val -is [array] -or $val -is [System.Collections.IDictionary] -or $val -is [pscustomobject]) {
                    throw "Registry entry '$($c.name)' label '$($prop.Name)' must be a scalar string; got $($val.GetType().FullName)."
                }
                $labels[$prop.Name] = [string]$val
            }
        }
        [pscustomobject]@{
            name       = [string]$c.name
            context    = [string]$c.context
            kubeconfig = if ($c.kubeconfig) { [string]$c.kubeconfig } else { $null }
            tier       = [string]$c.tier
            labels     = $labels
        }
    }
    # Force array context AND drop any $null elements (foreach yields a
    # single $null when the source is empty).
    return @($result | Where-Object { $null -ne $_ })
}

function ConvertFrom-ClusterSelector {
    <#
    .SYNOPSIS
        Parse a Kubernetes-style label selector into a structured form.
    .DESCRIPTION
        Supports: 'k=v', 'k!=v', 'k=v,k2=v2'. Recognized special keys
        (matched against the top-level cluster fields, not labels):
            name     -> cluster.name
            context  -> cluster.context
            tier     -> cluster.tier
        Anything else is treated as a label match against
        cluster.labels[key].
    .OUTPUTS
        Array of [pscustomobject]@{ Key; Op (=|!=); Value }.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Selector
    )
    if ([string]::IsNullOrWhiteSpace($Selector)) {
        # Reject empty selectors. An empty parsed selector would make
        # Test-ClusterMatchesSelector return $true for every cluster, which
        # is too easy to do by accident. Operators wanting "all clusters"
        # should write an explicit tautology like 'tier!=__none__' or
        # call Get-Clusters with a real label expression.
        throw "Selector must not be empty. Use an explicit term like 'tier=staging' or 'name=<cluster>'."
    }
    $parts = $Selector -split ','
    $result = foreach ($p in $parts) {
        $t = $p.Trim()
        if (-not $t) {
            # Reject empty terms instead of silently dropping them. A
            # selector like 'tier=staging,' (trailing comma) or ',,'
            # almost certainly indicates an editing mistake; failing loud
            # is better than producing a selector with fewer terms than
            # the operator wrote.
            throw "Selector '$Selector' contains an empty term. Remove stray commas."
        }
        # Allow '@' in values for kubeconfig context names like
        # 'user@cluster.example.com'. Keys remain conservative.
        if ($t -match '^([A-Za-z0-9_./-]+)(!=|=)([A-Za-z0-9_./:@-]+)$') {
            [pscustomobject]@{
                Key   = $Matches[1]
                Op    = $Matches[2]
                Value = $Matches[3]
            }
        }
        else {
            throw "Selector term '$t' is not in the form 'k=v' or 'k!=v'."
        }
    }
    return @($result)
}

function Test-ClusterMatchesSelector {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Cluster,
        [Parameter(Mandatory)] [object[]]        $ParsedSelector
    )
    foreach ($term in $ParsedSelector) {
        $actual = switch ($term.Key) {
            'name'    { $Cluster.name }
            'context' { $Cluster.context }
            'tier'    { $Cluster.tier }
            default   { if ($Cluster.labels.ContainsKey($term.Key)) { $Cluster.labels[$term.Key] } else { $null } }
        }
        $matched = if ($null -eq $actual) {
            # Missing key: '!=' matches (the key isn't equal to anything), '=' doesn't.
            $term.Op -eq '!='
        }
        elseif ($term.Op -eq '=') { $actual -ceq $term.Value }
        else                      { $actual -cne $term.Value }
        if (-not $matched) { return $false }
    }
    return $true
}

function Select-ClustersBySelector {
    <#
    .SYNOPSIS
        Apply a selector to the registry with the prod-exclusion rule.
    .PARAMETER Selector
        Label selector string (e.g. 'tier=staging,region=us-east-1').
    .PARAMETER IncludeProd
        Allow tier=prod clusters in selector matches that did not name
        them explicitly via a `name=` term.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Selector,
        [string] $RegistryPath = 'config/clusters.yaml',
        [switch] $IncludeProd
    )
    $registry = Read-ClustersRegistry -RegistryPath $RegistryPath
    $parsed = ConvertFrom-ClusterSelector -Selector $Selector

    # Prod-inclusion exception: if the selector explicitly names a cluster
    # via 'name=' AND that named cluster is prod, allow it without
    # requiring -IncludeProd. This matches CLAUDE.md R4.
    $explicitNames = @($parsed | Where-Object { $_.Key -eq 'name' -and $_.Op -eq '=' } | Select-Object -ExpandProperty Value)

    $matches = foreach ($c in $registry) {
        if (-not (Test-ClusterMatchesSelector -Cluster $c -ParsedSelector $parsed)) { continue }
        if ($c.tier -ceq 'prod' -and -not $IncludeProd -and ($c.name -notin $explicitNames)) {
            continue
        }
        $c
    }
    return @($matches)
}
