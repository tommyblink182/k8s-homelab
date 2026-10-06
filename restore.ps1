#Requires -Version 7.4
<#
.SYNOPSIS
    Ripristina su un cluster Docker Desktop nuovo cio' che backup.ps1 ha salvato.
.DESCRIPTION
    Ordine: namespace -> PV -> release Helm -> risorse (workload esclusi) -> dati dei PVC -> workload.
    I workload partono solo dopo il ripristino dei dati. Non cancella mai il backup.
    I PVC non vuoti vengono rifiutati salvo -Force. Il ripristino dei volumi Docker e dei vhdx e' manuale (docs\).
.EXAMPLE
    .\restore.ps1 -Context docker-desktop -BackupPath <BackupRoot>\<timestamp> -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Context,
    [Parameter(Mandatory)][string]$BackupPath,
    [string[]]$Namespace,
    [hashtable]$HelmChart = @{},
    [switch]$SkipHelm,
    [switch]$SkipData,
    [switch]$Force,
    [string]$HelperImage = 'alpine:3.20',
    [switch]$AllowNonDockerDesktop,
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\K8s.ps1')
. (Join-Path $PSScriptRoot 'lib\Pvc.ps1')
. (Join-Path $PSScriptRoot 'lib\Verify.ps1')

Initialize-ToolEncoding
Initialize-KubeContext -Context $Context -AllowNonDockerDesktop:$AllowNonDockerDesktop
$root = (Resolve-Path -LiteralPath $BackupPath).Path

Write-Log 'Verifica del backup' -Level step
$results = Test-Backup -Root $root
$failed = @($results | Where-Object { -not $_.Passed })
foreach ($r in $results) { Write-Log "$($r.Name): $($r.Detail)" -Level $(if ($r.Passed) { 'ok' } else { 'error' }) }
if ($failed.Count) { throw 'Il backup non e'' valido: ripristino interrotto.' }

$manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
$namespaces = if ($Namespace) { $Namespace } else { @($manifest.namespaces) }
$restoreRoot = Join-Path $root 'k8s\restore'
$workloadPattern = '^(deployments|statefulsets|daemonsets|cronjobs|jobs)\.'

Write-Log 'Piano' -Level step
Write-Log "Cluster di destinazione: $Context"
Write-Log "Backup: $root (creato il $($manifest.createdAt))"
Write-Log "Namespace: $($namespaces -join ', ')"
Write-Log "Release Helm: $(if ($SkipHelm) { 'saltate' } else { (@($manifest.helmReleases) -join ', ') })"
Write-Log "Dati dei PVC: $(if ($SkipData) { 'saltati' } else { (@($manifest.pvcs | Where-Object { $_.namespace -in $namespaces } | ForEach-Object { "$($_.namespace)/$($_.pvc)" }) -join ', ') })"
if ($DryRun) { Write-Log 'DryRun: nessuna modifica eseguita.' -Level ok; return }
if (-not (Confirm-Plan -Yes:$Yes)) { Write-Log 'Annullato.' -Level warn; return }

function Invoke-ApplyFile {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$File)
    if ($File.Count -eq 0) { return }
    $kubectlArgs = @('apply')
    foreach ($f in $File) { $kubectlArgs += @('-f', $f.FullName) }
    Invoke-Kubectl -Arguments $kubectlArgs | ForEach-Object { Write-Log $_ }
}

Write-Log 'Namespace e PV' -Level step
Invoke-ApplyFile -File @(Get-ChildItem -LiteralPath (Join-Path $restoreRoot '00-namespaces') -Filter *.json -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -in $namespaces })
Invoke-ApplyFile -File @(Get-ChildItem -LiteralPath (Join-Path $restoreRoot '10-cluster') -Filter *.json -ErrorAction SilentlyContinue)

if (-not $SkipHelm -and @($manifest.helmReleases).Count -gt 0) {
    Write-Log 'Release Helm' -Level step
    $releases = @(Get-Content -LiteralPath (Join-Path $root 'helm\releases.json') -Raw | ConvertFrom-Json)
    $repos = if (Test-Path -LiteralPath (Join-Path $root 'helm\repos.txt')) { Get-Content -LiteralPath (Join-Path $root 'helm\repos.txt') } else { @() }
    foreach ($r in $releases) {
        $chartName = $r.chart -replace '-\d+\.\d+\.\d+.*$', ''
        $version = ($r.chart -replace '^.*-(\d+\.\d+\.\d+.*)$', '$1')
        $ref = if ($HelmChart.ContainsKey($r.name)) { $HelmChart[$r.name] } elseif ($repos -match "^$([regex]::Escape($chartName))\s") { "$chartName/$chartName" } else { $null }
        if (-not $ref) {
            Write-Log "Release $($r.namespace)/$($r.name): repo del chart '$($r.chart)' sconosciuto. Aggiungilo con 'helm repo add' e rilancia con -HelmChart @{ '$($r.name)' = '<repo>/<chart>' }." -Level warn
            continue
        }
        $values = Join-Path $root ('helm\' + (Get-SafeName "$($r.namespace)_$($r.name)") + '.values.yaml')
        & helm --kube-context $Context install $r.name $ref --version $version -n $r.namespace --create-namespace -f $values --wait --timeout 5m
        if ($LASTEXITCODE -ne 0) { throw "helm install di $($r.name) non riuscito." }
    }
}

Write-Log 'Risorse (workload esclusi)' -Level step
$workloads = @()
foreach ($ns in $namespaces) {
    $dir = Join-Path $restoreRoot "20-$ns"
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter *.json)
    Invoke-ApplyFile -File @($files | Where-Object { $_.Name -notmatch $workloadPattern })
    $workloads += @($files | Where-Object { $_.Name -match $workloadPattern })
}

if (-not $SkipData) {
    Write-Log 'Dati dei PVC' -Level step
    foreach ($p in @($manifest.pvcs | Where-Object { $_.namespace -in $namespaces })) {
        Restore-Pvc -Namespace $p.namespace -Pvc $p.pvc -Root $root -Image $HelperImage -Force:$Force
        Write-Log "$($p.namespace)/$($p.pvc)" -Level ok
    }
}

Write-Log 'Workload' -Level step
Invoke-ApplyFile -File $workloads
foreach ($w in $workloads) {
    $o = Get-Content -LiteralPath $w.FullName -Raw | ConvertFrom-Json
    if ($o.kind -in 'Deployment', 'StatefulSet') {
        $null = Invoke-Kubectl -Arguments @('rollout', 'status', "$($o.kind.ToLower())/$($o.metadata.name)", '-n', $o.metadata.namespace, '--timeout=300s') -AllowFailure
    }
}

Write-Log 'Ripristino terminato. Confronta con il backup: .\verify-backup.ps1 -BackupPath <cartella> -CompareWithCluster -Context <contesto>' -Level ok
