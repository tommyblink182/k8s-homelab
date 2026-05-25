# K8s Cluster Restore
# Auto-scopre i namespace da ripristinare (da BackupPath), applica i manifest
# e copia i dati dei PVC via kubectl cp (nessun namespace hardcoded).
# Flusso: backup.ps1  →  aggiorna Docker Desktop  →  .\restore.ps1
# Uso: .\restore.ps1 [-KeepBackup] [-DryRun]

param(
    [string]$BackupPath = "C:\k8s-data",
    [switch]$KeepBackup = $false,
    [switch]$DryRun     = $false
)

Write-Host "=== K8s Cluster Restore ===" -ForegroundColor Cyan
Write-Host "Backup Path: $BackupPath" -ForegroundColor Cyan
Write-Host "Keep Backup: $KeepBackup" -ForegroundColor Cyan
Write-Host "Dry Run:     $DryRun`n" -ForegroundColor Cyan

# ── Step 1: Verifica cluster ─────────────────────────────────────────────────
Write-Host "Step 1: Verifica accesso al cluster..." -ForegroundColor Yellow
kubectl get namespaces -o name 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Cluster non accessibile." -ForegroundColor Red; exit 1
}
Write-Host "  OK  Cluster accessibile." -ForegroundColor Green

# Auto-discover namespace da BackupPath (cartelle con sottocartella manifest/)
$app_ns = Get-ChildItem -Path $BackupPath -Directory |
          Where-Object { Test-Path "$($_.FullName)\manifest" } |
          Select-Object -ExpandProperty Name

if (-not $app_ns) {
    Write-Host "  ERROR: Nessun namespace trovato in $BackupPath" -ForegroundColor Red; exit 1
}
Write-Host "  Namespace da ripristinare: $($app_ns -join ', ')`n" -ForegroundColor Gray

# ── Step 2: Applica manifest ─────────────────────────────────────────────────
Write-Host "Step 2: Applying manifests..." -ForegroundColor Yellow
foreach ($ns in $app_ns) {
    Write-Host "  Namespace: $ns" -ForegroundColor Cyan
    $manifestPath = "$BackupPath\$ns\manifest"

    # Crea namespace se non esiste
    $nsExists = kubectl get namespace $ns 2>$null
    if (-not $nsExists) {
        Write-Host "    Creating namespace $ns..." -ForegroundColor Gray
        if (-not $DryRun) { kubectl create namespace $ns }
    }

    # Applica tutti i file nella cartella manifest (JSON e YAML)
    if ($DryRun) {
        Write-Host "    [DRY-RUN] kubectl apply -f $manifestPath" -ForegroundColor DarkGray
    } else {
        kubectl apply -f $manifestPath 2>&1 | ForEach-Object {
            if ($_) { Write-Host "    $_" -ForegroundColor DarkGray }
        }
    }
}

# Raccoglie tutti i deployment/statefulset da tutti i namespace
$workloads = [System.Collections.Generic.List[hashtable]]::new()
foreach ($ns in $app_ns) {
    foreach ($kind in @("deployment","statefulset")) {
        $names = kubectl get ${kind}s -n $ns -o jsonpath='{.items[*].metadata.name}' 2>$null
        if ($names) {
            $names -split ' ' | Where-Object { $_ } | ForEach-Object {
                $workloads.Add(@{ NS = $ns; Kind = $kind; Name = $_ })
            }
        }
    }
}

# ── Step 3: Attendi pod Running (storage vuoto, ma l'app deve partire) ────────
Write-Host "`nStep 3: Waiting for pods to be Running..." -ForegroundColor Yellow
foreach ($w in $workloads) {
    $ref = "$($w.Kind)/$($w.Name)"
    Write-Host "  $ref  ($($w.NS))..." -ForegroundColor Gray
    if (-not $DryRun) {
        kubectl rollout status $ref -n $w.NS --timeout=3m 2>&1 | Out-Null
        Write-Host "    OK" -ForegroundColor Green
    } else {
        Write-Host "    [DRY-RUN]" -ForegroundColor DarkGray
    }
}

# ── Step 4: Restore dati PVC via kubectl cp (auto-discovery) ─────────────────
Write-Host "`nStep 4: Restoring volume data via kubectl cp..." -ForegroundColor Yellow
foreach ($ns in $app_ns) {
    $volumesBase = "$BackupPath\$ns\volumes"
    if (-not (Test-Path $volumesBase)) {
        Write-Host "  INFO: Nessun volume backup per '$ns' — saltato." -ForegroundColor DarkGray
        continue
    }

    $pods_raw = kubectl get pods -n $ns -o json 2>&1
    if ($LASTEXITCODE -ne 0) { continue }
    $running = ($pods_raw | ConvertFrom-Json).items |
               Where-Object { $_.status.phase -eq "Running" }

    if (-not $running) {
        Write-Host "  WARNING: Nessun pod Running in '$ns' — saltato." -ForegroundColor Yellow
        continue
    }

    $restored = @{}
    foreach ($pod in $running) {
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
                if ($restored[$pvcName]) { continue }

                $localPath = "$volumesBase\$pvcName"
                if (-not (Test-Path $localPath)) {
                    Write-Host "  WARNING: Backup non trovato per PVC '$pvcName' in '$ns'" -ForegroundColor Yellow
                    continue
                }

                $dest = "$ns/$($pod.metadata.name):$($mount.mountPath)"
                Write-Host "  $ns/$pvcName → $dest..." -ForegroundColor Gray
                if ($DryRun) {
                    Write-Host "    [DRY-RUN] kubectl cp $localPath/. $dest" -ForegroundColor DarkGray
                } else {
                    kubectl cp "$localPath/." $dest 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    OK" -ForegroundColor Green
                        $restored[$pvcName] = $true
                    } else {
                        Write-Host "    ERROR: kubectl cp fallito" -ForegroundColor Red
                    }
                }
            }
        }
    }
}

# ── Step 5: Restart pod per ricaricare i dati ripristinati ───────────────────
Write-Host "`nStep 5: Restarting pods to load restored data..." -ForegroundColor Yellow
foreach ($w in $workloads) {
    $ref = "$($w.Kind)/$($w.Name)"
    Write-Host "  Restart $ref ($($w.NS))..." -ForegroundColor Gray
    if ($DryRun) {
        Write-Host "    [DRY-RUN]" -ForegroundColor DarkGray
    } else {
        kubectl rollout restart $ref -n $w.NS 2>&1 | Out-Null
    }
}

# ── Step 6: Attendi rollout finali ───────────────────────────────────────────
Write-Host "`nStep 6: Waiting for final rollouts..." -ForegroundColor Yellow
foreach ($w in $workloads) {
    $ref = "$($w.Kind)/$($w.Name)"
    Write-Host "  $ref ($($w.NS))..." -ForegroundColor Gray
    if ($DryRun) {
        Write-Host "    [DRY-RUN]" -ForegroundColor DarkGray
    } else {
        kubectl rollout status $ref -n $w.NS --timeout=3m 2>&1 | Out-Null
        Write-Host "    OK" -ForegroundColor Green
    }
}

# ── Step 7: Verifica accesso ai dati ────────────────────────────────────────
Write-Host "`nStep 7: Verifying data access..." -ForegroundColor Yellow
if (-not $DryRun) {
    foreach ($ns in $app_ns) {
        $pods_raw = kubectl get pods -n $ns -o json 2>&1
        if ($LASTEXITCODE -ne 0) { continue }
        $running = ($pods_raw | ConvertFrom-Json).items |
                   Where-Object { $_.status.phase -eq "Running" }
        foreach ($pod in $running) {
            foreach ($vol in $pod.spec.volumes) {
                if (-not $vol.persistentVolumeClaim) { continue }
                $mountPath = ($pod.spec.containers[0].volumeMounts |
                              Where-Object { $_.name -eq $vol.name } |
                              Select-Object -First 1).mountPath
                if (-not $mountPath) { continue }
                $ok = (kubectl exec -n $ns $pod.metadata.name -- ls $mountPath 2>&1 | Measure-Object).Count -gt 0
                $color = if ($ok) { "Green" } else { "Yellow" }
                $icon  = if ($ok) { "OK" } else { "WARN" }
                Write-Host "  $icon  $ns/$($vol.persistentVolumeClaim.claimName) → $mountPath" -ForegroundColor $color
            }
        }
    }
    Write-Host ""
    kubectl get ingress -A 2>&1
}

# ── Step 8: Cleanup backup temporanei ────────────────────────────────────────
Write-Host "`nStep 8: Cleanup temporary backup files..." -ForegroundColor Yellow
if ($KeepBackup) {
    Write-Host "  -KeepBackup specificato: file mantenuti in $BackupPath" -ForegroundColor Gray
} else {
    foreach ($ns in $app_ns) {
        $p = "$BackupPath\$ns\volumes"
        if (Test-Path $p) {
            if ($DryRun) {
                Write-Host "  [DRY-RUN] Remove-Item -Recurse $p" -ForegroundColor DarkGray
            } else {
                Remove-Item -Recurse -Force $p
                Write-Host "  OK  Rimosso: $p" -ForegroundColor Green
            }
        }
    }
}

Write-Host "`n=== Restore Completato ===" -ForegroundColor Green
Write-Host "kubectl get pods -A" -ForegroundColor Gray
Write-Host "kubectl get ingress -A" -ForegroundColor Gray
