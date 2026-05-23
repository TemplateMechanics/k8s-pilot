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
    Assert-YqAvailable

    # Convert YAML to JSON via yq; capture stderr separately.
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        # mikefarah/yq v4: `eval` (alias `e`) takes an expression first
        # and one or more file paths after. Pass '.' as the identity
        # expression so the registry path is unambiguously a file argument.
        $json = & yq -o=json eval '.' $RegistryPath 2>$errFile
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
    if ($null -eq $doc.clusters) {
        return @()
    }

    $allowedTiers = @('dev', 'staging', 'prod')
    $result = foreach ($c in $doc.clusters) {
        # Validate required fields are present + non-empty so silent
        # downstream failures don't happen.
        foreach ($field in @('name', 'context', 'tier')) {
            $v = $c.$field
            if ($null -eq $v -or ([string]$v).Trim() -eq '') {
                throw "Registry entry is missing required field '$field' (value '$v'). See config/clusters.schema.json."
            }
        }
        if ($c.tier -cnotin $allowedTiers) {
            throw "Registry entry '$($c.name)' has tier '$($c.tier)'; allowed: $($allowedTiers -join ', ')."
        }
        $labels = @{}
        if ($c.labels) {
            foreach ($prop in $c.labels.PSObject.Properties) {
                $labels[$prop.Name] = [string]$prop.Value
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
    return @($result)
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
    $parts = $Selector -split ','
    $result = foreach ($p in $parts) {
        $t = $p.Trim()
        if (-not $t) { continue }
        if ($t -match '^([A-Za-z0-9_./-]+)(!=|=)([A-Za-z0-9_./:-]+)$') {
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
