# Verifica di un backup (analisi dei file, nessuna modifica) e confronto con un cluster. Richiede lib\Common.ps1 e lib\K8s.ps1.

Set-StrictMode -Version 1.0

$script:CheckResults = @()

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [string]$Detail = ''
    )
    $script:CheckResults += [pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail }
}

function Test-Archive {
    <# Controlla un .tgz: SHA256 registrato, leggibilita' con tar e numero di voci uguale a quello rilevato al backup. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Deep
    )
    $base = $Path -replace '\.tgz$', ''
    $name = Split-Path $Path -Leaf
    if (-not (Test-Path -LiteralPath "$base.sha256") -or -not (Test-Path -LiteralPath "$base.count")) {
        Add-Check -Name $name -Passed $false -Detail 'manca .sha256 o .count'
        return
    }
    $recorded = (Get-Content -LiteralPath "$base.sha256" -TotalCount 1).Trim()
    $hashOk = (Get-FileSha256 -Path $Path) -eq $recorded
    $entries = @(& tar -tzf $Path 2>&1)
    $tarOk = ($LASTEXITCODE -eq 0)
    $expected = [int](Get-Content -LiteralPath "$base.count" -TotalCount 1)
    $countOk = ($entries.Count -eq $expected)
    $detail = "sha256=$hashOk tar=$tarOk voci=$($entries.Count)/$expected"
    $deepOk = $true
    if ($Deep -and $hashOk -and $tarOk) {
        $tmp = Join-Path $env:TEMP ('k8s-data-verify-' + (Get-Random))
        $null = New-Item -ItemType Directory -Path $tmp
        try {
            & tar -xzf $Path -C $tmp 2>&1 | Out-Null
            $extractOk = ($LASTEXITCODE -eq 0)
            $extracted = @(Get-ChildItem -LiteralPath $tmp -Recurse -Force).Count + 1
            $deepOk = ($extractOk -and $extracted -eq $expected)
            $detail += " estratte=$extracted"
        }
        finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }
    Add-Check -Name $name -Passed ($hashOk -and $tarOk -and $countOk -and $deepOk) -Detail $detail
}

function Get-ExportedInventory {
    param([Parameter(Mandatory)][string]$Root)
    $rows = @()
    $full = Join-Path $Root 'k8s\full'
    foreach ($file in Get-ChildItem -LiteralPath $full -Recurse -File -Filter *.json) {
        $ns = $file.Directory.Name
        if ($ns -eq '_cluster') { $ns = '' }
        $type = $file.BaseName
        foreach ($item in @((Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).items)) {
            $rows += "$ns|$type|$($item.metadata.name)"
        }
    }
    return @($rows | Sort-Object -Unique)
}

function Test-Backup {
    <#
    Restituisce l'elenco dei controlli. Il backup e' valido solo se tutti passano:
    file non vuoti, export = inventario, manifest riapplicabili, archivi dei PVC e dei volumi leggibili.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$Deep,
        [switch]$DeepVhdx
    )
    $script:CheckResults = @()

    $manifestFile = Join-Path $Root 'manifest.json'
    $manifest = $null
    if (Test-Path -LiteralPath $manifestFile) { $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json }
    Add-Check -Name 'manifest.json' -Passed ($null -ne $manifest) -Detail $manifestFile

    $empty = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
            Where-Object { $_.Length -eq 0 -and $_.FullName -notmatch '\\settings\\' -and $_.Name -ne '.gitkeep' })
    Add-Check -Name 'nessun file vuoto' -Passed ($empty.Count -eq 0) -Detail (($empty | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', ')

    $inventoryFile = Join-Path $Root 'inventory\inventory.tsv'
    if (Test-Path -LiteralPath $inventoryFile) {
        $inv = @(Get-Content -LiteralPath $inventoryFile)
        $exp = Get-ExportedInventory -Root $Root
        $diff = @(Compare-Object -ReferenceObject $inv -DifferenceObject $exp)
        Add-Check -Name 'export = inventario' -Passed ($diff.Count -eq 0) -Detail "inventario=$($inv.Count) export=$($exp.Count) differenze=$($diff.Count)"
    }
    else { Add-Check -Name 'export = inventario' -Passed $false -Detail 'inventory.tsv mancante' }

    $bad = @()
    $restoreFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'k8s\restore') -Recurse -File -Filter *.json)
    foreach ($f in $restoreFiles) {
        try {
            $o = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            $runtimeFields = @('uid', 'resourceVersion', 'managedFields' | Where-Object { $o.metadata.PSObject.Properties[$_] })
            $hasRuntime = [bool]$o.PSObject.Properties['status'] -or $runtimeFields.Count -gt 0
            if (-not ($o.apiVersion -and $o.kind -and $o.metadata.name) -or $hasRuntime) { $bad += $f.Name }
        }
        catch { $bad += $f.Name }
    }
    Add-Check -Name 'manifest riapplicabili' -Passed ($bad.Count -eq 0 -and $restoreFiles.Count -gt 0) -Detail "file=$($restoreFiles.Count) non validi=$($bad -join ', ')"

    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Root 'pvc') -Filter *.tgz -ErrorAction SilentlyContinue)) {
        Test-Archive -Path $f.FullName -Deep:$Deep
    }
    if ($manifest -and $manifest.PSObject.Properties['pvcs']) {
        $missing = @($manifest.pvcs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root "pvc\$($_.namespace)-$($_.pvc).tgz")) })
        Add-Check -Name 'PVC del manifest tutti salvati' -Passed ($missing.Count -eq 0) -Detail (($missing | ForEach-Object { "$($_.namespace)/$($_.pvc)" }) -join ', ')
    }
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Root 'docker-volumes') -Filter *.tgz -ErrorAction SilentlyContinue)) {
        Test-Archive -Path $f.FullName -Deep:$Deep
    }

    $vhdxSums = Join-Path $Root 'vhdx\sha256.txt'
    if (Test-Path -LiteralPath $vhdxSums) {
        $lines = @(Get-Content -LiteralPath $vhdxSums | Where-Object { $_ })
        $ok = $true
        foreach ($line in $lines) {
            $hash, $leaf = $line -split '\s+', 2
            $copy = Get-ChildItem -LiteralPath (Join-Path $Root 'vhdx') -Recurse -File -Filter $leaf | Select-Object -First 1
            if (-not $copy) { $ok = $false; continue }
            if ($DeepVhdx -and (Get-FileSha256 -Path $copy.FullName) -ne $hash) { $ok = $false }
        }
        Add-Check -Name 'vhdx' -Passed $ok -Detail "file=$($lines.Count) hash ricalcolato=$($DeepVhdx.IsPresent)"
    }
    return $script:CheckResults
}

function Compare-BackupWithCluster {
    <# Dopo un ripristino: differenze tra l'inventario del backup e quello del cluster attuale. #>
    param([Parameter(Mandatory)][string]$Root)
    $before = @(Get-Content -LiteralPath (Join-Path $Root 'inventory\inventory.tsv'))
    $after = Get-ClusterInventory
    return @(Compare-Object -ReferenceObject $before -DifferenceObject $after |
            ForEach-Object { [pscustomobject]@{ Side = $(if ($_.SideIndicator -eq '<=') { 'solo nel backup' } else { 'solo nel cluster' }); Resource = $_.InputObject } })
}
