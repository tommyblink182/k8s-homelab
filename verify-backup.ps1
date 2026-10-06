#Requires -Version 7.4
<#
.SYNOPSIS
    Verifica un backup (solo lettura) e, con -CompareWithCluster, confronta l'inventario con il cluster attuale.
.EXAMPLE
    .\verify-backup.ps1 -BackupPath <BackupRoot>\<timestamp> -Deep
.EXAMPLE
    .\verify-backup.ps1 -BackupPath <BackupRoot>\<timestamp> -CompareWithCluster -Context docker-desktop
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackupPath,
    [switch]$Deep,
    [switch]$DeepVhdx,
    [switch]$CompareWithCluster,
    [string]$Context,
    [switch]$AllowNonDockerDesktop
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\K8s.ps1')
. (Join-Path $PSScriptRoot 'lib\Verify.ps1')

$root = (Resolve-Path -LiteralPath $BackupPath).Path
Write-Log "Verifica di $root" -Level step
$results = Test-Backup -Root $root -Deep:$Deep -DeepVhdx:$DeepVhdx
foreach ($r in $results) { Write-Log "$($r.Name): $($r.Detail)" -Level $(if ($r.Passed) { 'ok' } else { 'error' }) }
$failed = @($results | Where-Object { -not $_.Passed })

if ($CompareWithCluster) {
    if (-not $Context) { throw '-CompareWithCluster richiede -Context.' }
    Initialize-ToolEncoding
    Initialize-KubeContext -Context $Context -AllowNonDockerDesktop:$AllowNonDockerDesktop
    Write-Log 'Confronto con il cluster' -Level step
    $diff = @(Compare-BackupWithCluster -Root $root)
    if ($diff.Count -eq 0) { Write-Log 'Inventario identico.' -Level ok }
    else { $diff | Sort-Object Resource | ForEach-Object { Write-Log "$($_.Side): $($_.Resource)" -Level warn } }
}

if ($failed.Count) { Write-Log "Controlli falliti: $($failed.Count)" -Level error; exit 1 }
Write-Log 'Backup valido.' -Level ok
