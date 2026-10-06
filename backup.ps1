#Requires -Version 7.4
<#
.SYNOPSIS
    Backup del cluster Kubernetes di Docker Desktop (risorse, Helm, dati dei PVC) in una cartella con timestamp.
.DESCRIPTION
    Il contesto e' obbligatorio e non viene mai cambiato. Mostra il piano, chiede una sola conferma, poi:
    inventario -> export risorse -> valori Helm -> dati dei PVC (app a 0 repliche, poi ripristinate) -> verifica.
    Con -IncludeDockerDesktop salva anche impostazioni e volumi Docker non-K8s.
    La copia dei vhdx si fa con backup-vhdx.ps1 a Docker Desktop chiuso.
.EXAMPLE
    .\backup.ps1 -Context docker-desktop -DryRun
.EXAMPLE
    .\backup.ps1 -Context docker-desktop -IncludeDockerDesktop -PostgresContainer postgresql_uni
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Context,
    [string]$BackupRoot = 'C:\DockerBackups',
    [string[]]$Namespace,
    [switch]$IncludeDockerDesktop,
    [string]$PostgresContainer,
    [string]$PostgresUser = 'postgres',
    [string[]]$ExcludeVolume,
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
. (Join-Path $PSScriptRoot 'lib\DockerDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\Verify.ps1')

Initialize-ToolEncoding
Initialize-KubeContext -Context $Context -AllowNonDockerDesktop:$AllowNonDockerDesktop
Assert-SafeBackupRoot -Path $BackupRoot

Write-Log "Cluster: $Context" -Level step
$appNamespaces = @(Get-AppNamespace -Namespace $Namespace)
$pvcPlan = @(Get-PvcPlan -Namespace $appNamespaces)
$volumePlan = @()
if ($IncludeDockerDesktop) {
    Assert-Tool docker
    $volumePlan = @(Get-DockerVolumePlan -ExcludeVolume $ExcludeVolume)
}

Write-Log 'Piano' -Level step
Write-Log "Destinazione: $BackupRoot\<timestamp>"
Write-Log "Namespace: $($appNamespaces -join ', ')"
foreach ($p in $pvcPlan) {
    $stop = if ($p.Workloads.Count) { ($p.Workloads | ForEach-Object { "$($_.Kind)/$($_.Name) ($($_.Replicas) repliche)" }) -join ', ' } else { 'nessun workload' }
    Write-Log "PVC $($p.Namespace)/$($p.Pvc) [$($p.Phase)]: ferma temporaneamente $stop"
}
foreach ($v in $volumePlan) {
    $stop = if ($v.RunningContainers.Count) { "ferma $($v.RunningContainers -join ', ')" } else { 'nessun container attivo' }
    Write-Log "Volume Docker $($v.Volume): $stop"
}
if ($DryRun) { Write-Log 'DryRun: nessuna modifica eseguita.' -Level ok; return }
if (-not (Confirm-Plan -Yes:$Yes)) { Write-Log 'Annullato.' -Level warn; return }

$root = New-BackupFolder -Root $BackupRoot
Write-Log "Cartella di backup: $root" -Level step
$failures = @()
$kubeVersion = (@(Invoke-Kubectl -Arguments @('version', '-o', 'json') -AllowFailure) -join "`n")

Write-Log 'Inventario' -Level step
Get-ClusterInventory | Set-Content -LiteralPath (Join-Path $root 'inventory\inventory.tsv') -Encoding utf8NoBOM
Invoke-Kubectl -Arguments @('get', 'nodes,pv,pvc,sc,ingress', '-A', '-o', 'wide') -AllowFailure | Set-Content -LiteralPath (Join-Path $root 'inventory\cluster.txt') -Encoding utf8NoBOM
$kubeVersion | Set-Content -LiteralPath (Join-Path $root 'inventory\kubectl-version.json') -Encoding utf8NoBOM

Write-Log 'Export risorse' -Level step
$restorable = Export-ClusterState -Root $root -AppNamespace $appNamespaces
Write-Log "Manifest riapplicabili: $restorable" -Level ok

Write-Log 'Release Helm' -Level step
$helmReleases = @(Export-HelmRelease -Root $root)
Write-Log "Release salvate: $($helmReleases.Count)" -Level ok

Write-Log 'Dati dei PVC' -Level step
$savedPvcs = @()
foreach ($p in $pvcPlan) {
    try {
        Backup-Pvc -Item $p -Root $root -Image $HelperImage
        $savedPvcs += [pscustomobject]@{ namespace = $p.Namespace; pvc = $p.Pvc }
        Write-Log "$($p.Namespace)/$($p.Pvc)" -Level ok
    }
    catch {
        $failures += "PVC $($p.Namespace)/$($p.Pvc): $($_.Exception.Message)"
        Write-Log "$($p.Namespace)/$($p.Pvc): $($_.Exception.Message)" -Level error
    }
}

if ($IncludeDockerDesktop) {
    Write-Log 'Docker Desktop: impostazioni e volumi' -Level step
    try {
        Backup-DockerDesktopSetting -Root $root -Context $Context
        Backup-DockerVolume -Root $root -Plan $volumePlan -Image $HelperImage -PostgresContainer $PostgresContainer -PostgresUser $PostgresUser
        Write-Log "Volumi salvati: $($volumePlan.Count)" -Level ok
    }
    catch {
        $failures += "Docker Desktop: $($_.Exception.Message)"
        Write-Log $_.Exception.Message -Level error
    }
}

Write-JsonFile -Path (Join-Path $root 'manifest.json') -Object ([pscustomobject]@{
        createdAt = (Get-Date).ToString('o')
        context = $Context
        namespaces = $appNamespaces
        pvcs = $savedPvcs
        helmReleases = @($helmReleases | ForEach-Object { "$($_.namespace)/$($_.name)" })
        dockerDesktop = [bool]$IncludeDockerDesktop
        status = $(if ($failures.Count) { 'incomplete' } else { 'completed' })
        failures = @($failures)
    })

Write-Log 'Verifica del backup' -Level step
$results = Test-Backup -Root $root
foreach ($r in $results) { Write-Log "$($r.Name): $($r.Detail)" -Level $(if ($r.Passed) { 'ok' } else { 'error' }) }
if ($failures.Count -or ($results | Where-Object { -not $_.Passed })) {
    Write-Log "Backup NON valido: non aggiornare Docker Desktop. Cartella: $root" -Level error
    exit 1
}
Write-Log "Backup completato e verificato: $root" -Level ok
