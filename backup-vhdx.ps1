#Requires -Version 7.4
<#
.SYNOPSIS
    Copia a freddo dei dischi di Docker Desktop (docker_data.vhdx, ext4.vhdx) nella cartella di backup.
.DESCRIPTION
    E' la rete di sicurezza per il rollback identico alla versione precedente. Non ferma Docker Desktop
    e non esegue 'wsl --shutdown': chiudi Docker Desktop e spegni WSL prima (vedi docs\docker-desktop-upgrade.md).
    Verifica SHA256 di sorgente e copia.
.EXAMPLE
    .\backup-vhdx.ps1 -BackupPath <BackupRoot>\<timestamp>
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$BackupPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\DockerDesktop.ps1')

$root = (Resolve-Path -LiteralPath $BackupPath).Path
Assert-SafeBackupRoot -Path $root
Write-Log "Copia a freddo dei vhdx in $root\vhdx" -Level step
Backup-DockerDesktopVhdx -Root $root
Write-Log 'Copia completata e SHA256 verificato (vedi vhdx\sha256.txt).' -Level ok
