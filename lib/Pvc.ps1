# Backup e ripristino dei dati dei PVC. Richiede lib\Common.ps1.
# Metodo: app a 0 repliche -> pod helper col PVC -> tar in streaming binario -> ripristino delle repliche.
# I dati dei PVC (local-path) vivono dentro il nodo kind, che e' dentro docker_data.vhdx:
# non sono raggiungibili da Windows e si perdono con un reset del cluster.

Set-StrictMode -Version 1.0

function Get-PvcPlan {
    <# Per ogni PVC dei namespace indicati: quali Deployment/StatefulSet lo montano e con quante repliche. #>
    param([Parameter(Mandatory)][string[]]$Namespace)
    $plan = @()
    foreach ($ns in $Namespace) {
        $pvcs = Get-KubeJson -Arguments @('get', 'pvc', '-n', $ns)
        if (-not $pvcs -or @($pvcs.items).Count -eq 0) { continue }
        $workloads = Get-KubeJson -Arguments @('get', 'deployments,statefulsets', '-n', $ns)
        foreach ($pvc in @($pvcs.items)) {
            $users = @()
            foreach ($w in @($workloads.items)) {
                $claims = @($w.spec.template.spec.volumes | Where-Object { $_.persistentVolumeClaim } |
                        ForEach-Object { $_.persistentVolumeClaim.claimName })
                if ($pvc.metadata.name -notin $claims) { continue }
                $selector = ($w.spec.selector.matchLabels.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ','
                $users += [pscustomobject]@{
                    Kind = $w.kind.ToLower(); Name = $w.metadata.name
                    Replicas = [int]$w.spec.replicas; Selector = $selector
                }
            }
            $plan += [pscustomobject]@{ Namespace = $ns; Pvc = $pvc.metadata.name; Phase = $pvc.status.phase; Workloads = $users }
        }
    }
    return @($plan)
}

function Get-PodUsingPvc {
    param([Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$Pvc)
    $pods = Get-KubeJson -Arguments @('get', 'pods', '-n', $Namespace)
    return @($pods.items | Where-Object { $_.status.phase -notin 'Succeeded', 'Failed' } | Where-Object {
            @($_.spec.volumes | Where-Object { $_.persistentVolumeClaim -and $_.persistentVolumeClaim.claimName -eq $Pvc }).Count -gt 0
        } | ForEach-Object { $_.metadata.name })
}

function Wait-PodGone {
    param([Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$Selector, [int]$TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $left = @(Invoke-Kubectl -Arguments @('get', 'pods', '-n', $Namespace, '-l', $Selector, '-o', 'name') -AllowFailure)
        if ($left.Count -eq 0) { return }
        Start-Sleep -Seconds 3
    }
    throw "Pod con selettore '$Selector' ancora presenti in '$Namespace' dopo $TimeoutSec s."
}

function Get-PvcHelperName { return ('pvc-helper-{0:x6}' -f (Get-Random -Maximum 16777215)) }

function New-PvcHelperPod {
    <# Pod di servizio che monta il PVC su /data (sola lettura per il backup). #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$Pvc,
        [Parameter(Mandatory)][string]$Image,
        [switch]$ReadOnly
    )
    $ro = $ReadOnly.IsPresent.ToString().ToLower()
    $yaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: $Name
  namespace: $Namespace
  labels:
    app.kubernetes.io/managed-by: k8s-data-backup
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
  - name: helper
    image: $Image
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
      readOnly: $ro
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $Pvc
      readOnly: $ro
"@
    if (-not $PSCmdlet.ShouldProcess("$Namespace/$Name", "Creare il pod helper per il PVC $Pvc")) { return }
    $yaml | & kubectl --context (Get-KubeContextName) apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Creazione del pod helper $Namespace/$Name non riuscita." }
    $null = Invoke-Kubectl -Arguments @('wait', '--for=condition=Ready', "pod/$Name", '-n', $Namespace, '--timeout=180s')
}

function Remove-PvcHelperPod {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Namespace)
    if ($PSCmdlet.ShouldProcess("$Namespace/$Name", 'Eliminare il pod helper')) {
        $null = Invoke-Kubectl -Arguments @('delete', 'pod', $Name, '-n', $Namespace, '--ignore-not-found', '--timeout=60s') -AllowFailure
    }
}

function Backup-Pvc {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Image
    )
    $ns = $Item.Namespace
    $pvc = $Item.Pvc
    $base = Join-Path $Root "pvc\$ns-$pvc"
    $helper = Get-PvcHelperName
    $scaled = @()
    try {
        foreach ($w in $Item.Workloads) {
            if ($w.Replicas -le 0) { continue }
            $null = Invoke-Kubectl -Arguments @('scale', "$($w.Kind)/$($w.Name)", '-n', $ns, '--replicas=0')
            $scaled += $w
        }
        foreach ($w in $scaled) { Wait-PodGone -Namespace $ns -Selector $w.Selector }
        $left = @(Get-PodUsingPvc -Namespace $ns -Pvc $pvc)
        if ($left.Count -gt 0) { throw "PVC $ns/$pvc ancora montato da: $($left -join ', '). Backup saltato per non copiare dati in uso." }

        New-PvcHelperPod -Name $helper -Namespace $ns -Pvc $pvc -Image $Image -ReadOnly
        Invoke-NativeToFile -FilePath kubectl -OutFile "$base.tgz" -Arguments @(
            '--context', (Get-KubeContextName), 'exec', '-n', $ns, $helper, '--', 'tar', 'czf', '-', '-C', '/data', '.')
        $stats = @(Invoke-Kubectl -Arguments @('exec', '-n', $ns, $helper, '--', 'sh', '-c', 'find /data | wc -l; du -sb /data'))
        $stats | Set-Content -LiteralPath "$base.count" -Encoding utf8NoBOM
        Get-FileSha256 -Path "$base.tgz" | Set-Content -LiteralPath "$base.sha256" -Encoding utf8NoBOM
    }
    finally {
        Remove-PvcHelperPod -Name $helper -Namespace $ns
        foreach ($w in $scaled) {
            $null = Invoke-Kubectl -Arguments @('scale', "$($w.Kind)/$($w.Name)", '-n', $ns, "--replicas=$($w.Replicas)") -AllowFailure
            $null = Invoke-Kubectl -Arguments @('rollout', 'status', "$($w.Kind)/$($w.Name)", '-n', $ns, '--timeout=300s') -AllowFailure
        }
    }
}

function Restore-Pvc {
    <# Il PVC deve esistere ed essere vuoto (salvo -Force). Nessun workload deve montarlo. #>
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$Pvc,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Image,
        [switch]$Force
    )
    $base = Join-Path $Root "pvc\$Namespace-$Pvc"
    if (-not (Test-Path -LiteralPath "$base.tgz")) { throw "Archivio mancante: $base.tgz" }
    if ((Get-FileSha256 -Path "$base.tgz") -ne (Get-Content -LiteralPath "$base.sha256" -TotalCount 1).Trim()) {
        throw "SHA256 non corrispondente per $base.tgz: archivio alterato o corrotto."
    }
    $left = @(Get-PodUsingPvc -Namespace $Namespace -Pvc $Pvc)
    if ($left.Count -gt 0) { throw "PVC $Namespace/$Pvc montato da: $($left -join ', ')." }

    $helper = Get-PvcHelperName
    try {
        New-PvcHelperPod -Name $helper -Namespace $Namespace -Pvc $Pvc -Image $Image
        $existing = @(Invoke-Kubectl -Arguments @('exec', '-n', $Namespace, $helper, '--', 'sh', '-c', 'find /data -mindepth 1 | head -n 1'))
        if ($existing.Count -gt 0 -and -not $Force) {
            throw "PVC $Namespace/$Pvc non e' vuoto. Usa -Force solo se vuoi sovrascrivere i dati presenti."
        }
        Invoke-NativeToFile -FilePath kubectl -InFile "$base.tgz" -Arguments @(
            '--context', (Get-KubeContextName), 'exec', '-i', '-n', $Namespace, $helper, '--', 'tar', 'xzpf', '-', '-C', '/data')
        $expected = [int](Get-Content -LiteralPath "$base.count" -TotalCount 1)
        $actual = [int](@(Invoke-Kubectl -Arguments @('exec', '-n', $Namespace, $helper, '--', 'sh', '-c', 'find /data | wc -l'))[0])
        if ($actual -ne $expected) { throw "PVC $Namespace/${Pvc}: $actual voci dopo il ripristino, attese $expected." }
    }
    finally {
        Remove-PvcHelperPod -Name $helper -Namespace $Namespace
    }
}
