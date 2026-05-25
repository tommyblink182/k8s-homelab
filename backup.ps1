# K8s Cluster Backup
# Auto-scopre tutti i namespace applicativi, esporta i manifest K8s aggiornati
# e copia i dati di TUTTI i PVC via kubectl cp (nessun namespace hardcoded).
# Flusso: .\backup.ps1  →  aggiorna Docker Desktop  →  .\restore.ps1
# Uso: .\backup.ps1 [-DryRun]

param(
    [string]$BackupPath = "C:\k8s-data",
    [switch]$DryRun     = $false
)

Write-Host "=== K8s Cluster Backup ===" -ForegroundColor Cyan
Write-Host "Backup Path: $BackupPath" -ForegroundColor Cyan
Write-Host "Dry Run:     $DryRun`n" -ForegroundColor Cyan

# ── Verifica cluster ─────────────────────────────────────────────────────────
kubectl get namespaces -o name 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Cluster non accessibile." -ForegroundColor Red; exit 1
}
Write-Host "Cluster accessibile." -ForegroundColor Green

# ── Auto-discover namespace applicativi (escludi quelli di sistema) ───────────
$SYSTEM_NS = @("kube-system","kube-public","kube-node-lease","local-path-storage","default")
$app_ns = (kubectl get ns -o jsonpath='{.items[*].metadata.name}') -split ' ' |
          Where-Object { $_ -notin $SYSTEM_NS }

if (-not $app_ns) {
    Write-Host "WARNING: Nessun namespace applicativo trovato." -ForegroundColor Yellow; exit 0
}
Write-Host "Namespace applicativi: $($app_ns -join ', ')`n" -ForegroundColor Gray

# ── Helper: esporta una risorsa K8s pulita (senza campi runtime) ──────────────
function Export-Resource {
    param([string]$Namespace, [string]$ResourceType, [string]$OutFile)

    $raw = kubectl get $ResourceType -n $Namespace -o json 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }

    $list = $raw | ConvertFrom-Json
    if (-not $list.items -or $list.items.Count -eq 0) { return $false }

    foreach ($item in $list.items) {
        # Rimuovi campi runtime (non servono per kubectl apply su cluster fresco)
        @('resourceVersion','uid','generation','selfLink','creationTimestamp','managedFields') |
            ForEach-Object { $item.metadata.PSObject.Properties.Remove($_) }
        if ($item.metadata.annotations) {
            $item.metadata.annotations.PSObject.Properties.Remove('kubectl.kubernetes.io/last-applied-configuration')
            $item.metadata.annotations.PSObject.Properties.Remove('deployment.kubernetes.io/revision')
        }
        $item.PSObject.Properties.Remove('status')
    }
    $list.PSObject.Properties.Remove('metadata')

    if (-not $DryRun) {
        $list | ConvertTo-Json -Depth 50 | Set-Content -Path $OutFile -Encoding UTF8
    }
    return $true
}

# ── Loop principale ───────────────────────────────────────────────────────────
foreach ($ns in $app_ns) {
    Write-Host "─── Namespace: $ns ───" -ForegroundColor Yellow

    $manifestPath = "$BackupPath\$ns\manifest"
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $manifestPath | Out-Null }

    # ── A. Esporta manifest aggiornati dal cluster (formato JSON) ─────────────
    Write-Host "  [Manifests]" -ForegroundColor Cyan
    $resources = [ordered]@{
        "persistentvolumeclaims" = "pvcs.json"
        "configmaps"             = "configmaps.json"
        "secrets"                = "secrets.json"
        "services"               = "services.json"
        "deployments"            = "deployments.json"
        "statefulsets"           = "statefulsets.json"
        "ingress"                = "ingress.json"
    }
    foreach ($res in $resources.Keys) {
        $outFile = "$manifestPath\$($resources[$res])"
        if ($DryRun) {
            Write-Host "    [DRY-RUN] kubectl get $res -n $ns → $($resources[$res])" -ForegroundColor DarkGray
        } else {
            $ok = Export-Resource -Namespace $ns -ResourceType $res -OutFile $outFile
            if ($ok) {
                # Rimuovi il vecchio .yaml con lo stesso nome base (evita duplicati nel restore)
                $oldYaml = $outFile -replace '\.json$', '.yaml'
                if (Test-Path $oldYaml) { Remove-Item $oldYaml -Force }
                Write-Host "    OK  $($resources[$res])" -ForegroundColor Green
            }
        }
    }

    # ── B. Backup volumi PVC (auto-discovery da tutti i pod Running) ──────────
    Write-Host "  [Volumes]" -ForegroundColor Cyan

    $pods_raw = kubectl get pods -n $ns -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    WARNING: impossibile ottenere i pod di $ns" -ForegroundColor Yellow
        continue
    }
    $running = ($pods_raw | ConvertFrom-Json).items |
               Where-Object { $_.status.phase -eq "Running" }

    if (-not $running) {
        Write-Host "    INFO: nessun pod Running in $ns — volumi saltati." -ForegroundColor DarkGray
        Write-Host ""
        continue
    }

    $backed = @{}   # evita di copiare lo stesso PVC più di una volta
    foreach ($pod in $running) {
        # Costruisci mappa: nome-volume → claimName
        $volMap = @{}
        foreach ($vol in $pod.spec.volumes) {
            if ($vol.persistentVolumeClaim) {
                $volMap[$vol.name] = $vol.persistentVolumeClaim.claimName
            }
        }
        if ($volMap.Count -eq 0) { continue }

        foreach ($container in $pod.spec.containers) {
            foreach ($mount in $container.volumeMounts) {
                if (-not $volMap.ContainsKey($mount.name)) { continue }
                $pvcName = $volMap[$mount.name]
                if ($backed[$pvcName]) { continue }   # già copiato

                $localPath = "$BackupPath\$ns\volumes\$pvcName"
                $src       = "$ns/$($pod.metadata.name):$($mount.mountPath)/."

                Write-Host "    PVC '$pvcName'  →  $localPath" -ForegroundColor Gray
                if ($DryRun) {
                    Write-Host "    [DRY-RUN] kubectl cp $src $localPath" -ForegroundColor DarkGray
                } else {
                    New-Item -ItemType Directory -Force -Path $localPath | Out-Null
                    kubectl cp $src $localPath 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "      OK" -ForegroundColor Green
                        $backed[$pvcName] = $true
                    } else {
                        Write-Host "      ERROR: kubectl cp fallito" -ForegroundColor Red
                    }
                }
            }
        }
    }
    Write-Host ""
}

Write-Host "=== Backup completato ===" -ForegroundColor Cyan
Write-Host "IMPORTANTE: I file in $BackupPath\*\volumes\ sono TEMPORANEI." -ForegroundColor Yellow
Write-Host "Dopo aver aggiornato Docker Desktop, esegui: .\restore.ps1" -ForegroundColor Yellow
Write-Host "I file di backup saranno eliminati automaticamente al termine del restore." -ForegroundColor Yellow
