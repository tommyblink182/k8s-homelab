# Inventario, export delle risorse Kubernetes e dei valori Helm. Richiede lib\Common.ps1.

Set-StrictMode -Version 1.0

# Tipi generati dal cluster o effimeri: non si esportano e non fanno parte dell'inventario.
$script:SkipTypePattern = '^(events|pods|replicasets|endpoints|endpointslices|leases|controllerrevisions)(\.|$)|^nodes\.metrics'

function Get-ResourceType {
    param([Parameter(Mandatory)][bool]$Namespaced)
    $flag = "--namespaced=$($Namespaced.ToString().ToLower())"
    return @(Invoke-Kubectl -Arguments @('api-resources', $flag, '--verbs=list', '-o', 'name')) |
        Where-Object { $_ -notmatch $script:SkipTypePattern }
}

function Get-AppNamespace {
    <# Tutti i namespace tranne quelli di sistema, oppure quelli richiesti esplicitamente. #>
    param([string[]]$Namespace)
    if ($Namespace) { return $Namespace }
    $all = @(Invoke-Kubectl -Arguments @('get', 'namespaces', '-o', 'jsonpath={.items[*].metadata.name}')) -join ' '
    return @($all -split '\s+' | Where-Object { $_ -and $_ -notin $script:SystemNamespaces })
}

function Get-ClusterInventory {
    <# Elenco "namespace|tipo|nome" costruito con chiamate indipendenti dall'export, cosi' il confronto ha senso. #>
    $rows = @()
    foreach ($namespaced in $true, $false) {
        foreach ($type in Get-ResourceType -Namespaced $namespaced) {
            $kubectlArgs = @('get', $type, '--no-headers', '-o', 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name')
            if ($namespaced) { $kubectlArgs += '-A' }
            $lines = @(Invoke-Kubectl -Arguments $kubectlArgs -AllowFailure)
            foreach ($line in $lines) {
                $fields = ($line.ToString().Trim() -split '\s+')
                if ($fields.Count -lt 2) { continue }
                $ns = if ($fields[0] -eq '<none>') { '' } else { $fields[0] }
                $rows += "$ns|$type|$($fields[1])"
            }
        }
    }
    return @($rows | Sort-Object -Unique)
}

function Clear-JsonProperty {
    param($Object, [string]$Name)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $null = $Object.PSObject.Properties.Remove($Name) }
}

function Test-HelmManaged {
    param($Item)
    $labels = $Item.metadata.labels
    $annotations = $Item.metadata.annotations
    if ($labels -and $labels.'app.kubernetes.io/managed-by' -eq 'Helm') { return $true }
    if ($annotations -and $annotations.'meta.helm.sh/release-name') { return $true }
    return $false
}

function Test-Restorable {
    <# Esclude cio' che il cluster ricrea da solo o che appartiene a Helm (si ripristina con Helm). #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string]$Type)
    $name = $Item.metadata.name
    if ($Type -eq 'configmaps' -and $name -eq 'kube-root-ca.crt') { return $false }
    if ($Type -eq 'serviceaccounts' -and $name -eq 'default') { return $false }
    if ($Type -eq 'secrets' -and $Item.type -in 'kubernetes.io/service-account-token', 'helm.sh/release.v1') { return $false }
    if (Test-HelmManaged -Item $Item) { return $false }
    return $true
}

function Convert-ToRestorable {
    <# Toglie i campi runtime cosi' il manifest si applica su un cluster nuovo senza conflitti. #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string]$Type)
    foreach ($field in 'uid', 'resourceVersion', 'generation', 'creationTimestamp', 'managedFields', 'selfLink', 'ownerReferences', 'deletionTimestamp') {
        Clear-JsonProperty -Object $Item.metadata -Name $field
    }
    if ($Item.metadata.annotations) {
        $drop = @($Item.metadata.annotations.PSObject.Properties.Name | Where-Object {
                $_ -in 'kubectl.kubernetes.io/last-applied-configuration', 'deployment.kubernetes.io/revision' -or
                $_ -like 'pv.kubernetes.io/*' -or $_ -like 'volume.kubernetes.io/*' -or $_ -like 'volume.beta.kubernetes.io/*'
            })
        foreach ($name in $drop) { Clear-JsonProperty -Object $Item.metadata.annotations -Name $name }
    }
    Clear-JsonProperty -Object $Item -Name 'status'
    if ($Type -eq 'services') {
        Clear-JsonProperty -Object $Item.spec -Name 'clusterIP'
        Clear-JsonProperty -Object $Item.spec -Name 'clusterIPs'
    }
    if ($Type -eq 'persistentvolumeclaims') { Clear-JsonProperty -Object $Item.spec -Name 'volumeName' }
    return $Item
}

function Export-ClusterState {
    <#
    k8s\full     : dump grezzo di tutto (archivio, non per l'apply), tutti i namespace e i tipi cluster-scoped.
    k8s\restore  : copia ripulita e riapplicabile dei soli namespace applicativi, ordinata per cartelle.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$AppNamespace
    )
    $full = Join-Path $Root 'k8s\full'
    $restore = Join-Path $Root 'k8s\restore'
    $restorableCount = 0

    foreach ($type in Get-ResourceType -Namespaced $true) {
        $list = Get-KubeJson -Arguments @('get', $type, '-A') -AllowFailure
        if (-not $list -or @($list.items).Count -eq 0) { continue }
        foreach ($group in (@($list.items) | Group-Object { $_.metadata.namespace })) {
            $ns = $group.Name
            Write-JsonFile -Object ([pscustomobject]@{ apiVersion = 'v1'; kind = 'List'; items = @($group.Group) }) -Path (Join-Path $full "$ns\$type.json")
            if ($ns -notin $AppNamespace) { continue }
            foreach ($item in $group.Group) {
                if (-not (Test-Restorable -Item $item -Type $type)) { continue }
                $clean = Convert-ToRestorable -Item $item -Type $type
                $file = Join-Path $restore ("20-$ns\" + (Get-SafeName "${type}_$($clean.metadata.name)") + '.json')
                Write-JsonFile -Object $clean -Path $file
                $restorableCount++
            }
        }
    }

    foreach ($type in Get-ResourceType -Namespaced $false) {
        $list = Get-KubeJson -Arguments @('get', $type) -AllowFailure
        if (-not $list -or @($list.items).Count -eq 0) { continue }
        Write-JsonFile -Object ([pscustomobject]@{ apiVersion = 'v1'; kind = 'List'; items = @($list.items) }) -Path (Join-Path $full "_cluster\$type.json")
        if ($type -ne 'persistentvolumes') { continue }
        # Solo i PV non legati a un PVC (quelli dinamici li ricrea il provisioner insieme al PVC).
        foreach ($pv in @($list.items | Where-Object { -not $_.spec.claimRef })) {
            $clean = Convert-ToRestorable -Item $pv -Type $type
            Write-JsonFile -Object $clean -Path (Join-Path $restore ('10-cluster\' + (Get-SafeName "${type}_$($clean.metadata.name)") + '.json'))
            $restorableCount++
        }
    }

    foreach ($ns in $AppNamespace) {
        $obj = Get-KubeJson -Arguments @('get', 'namespace', $ns)
        foreach ($field in 'uid', 'resourceVersion', 'creationTimestamp', 'managedFields') { Clear-JsonProperty -Object $obj.metadata -Name $field }
        Clear-JsonProperty -Object $obj -Name 'status'
        Write-JsonFile -Object $obj -Path (Join-Path $restore "00-namespaces\$(Get-SafeName $ns).json")
        $restorableCount++
    }
    return $restorableCount
}

function Export-HelmRelease {
    <# Salva values (utente e completi), manifest e metadati di ogni release. Restituisce l'elenco delle release. #>
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
        Write-Log 'helm non trovato: salto il backup delle release Helm.' -Level warn
        return @()
    }
    $json = & helm --kube-context (Get-KubeContextName) list -A -o json
    if ($LASTEXITCODE -ne 0) { throw 'helm list non riuscito.' }
    $releases = @(($json -join "`n") | ConvertFrom-Json)
    $dir = Join-Path $Root 'helm'
    foreach ($r in $releases) {
        $base = Join-Path $dir (Get-SafeName "$($r.namespace)_$($r.name)")
        & helm --kube-context (Get-KubeContextName) get values $r.name -n $r.namespace -o yaml | Set-Content -LiteralPath "$base.values.yaml" -Encoding utf8NoBOM
        & helm --kube-context (Get-KubeContextName) get values $r.name -n $r.namespace --all -o yaml | Set-Content -LiteralPath "$base.values-all.yaml" -Encoding utf8NoBOM
        & helm --kube-context (Get-KubeContextName) get manifest $r.name -n $r.namespace | Set-Content -LiteralPath "$base.manifest.yaml" -Encoding utf8NoBOM
    }
    Write-JsonFile -Object $releases -Path (Join-Path $dir 'releases.json')
    & helm repo list 2>&1 | Set-Content -LiteralPath (Join-Path $dir 'repos.txt') -Encoding utf8NoBOM
    return $releases
}
