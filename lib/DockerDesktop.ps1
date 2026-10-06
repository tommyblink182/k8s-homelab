# Parte Docker Desktop del backup: impostazioni, volumi Docker non-K8s, copia a freddo del vhdx.
# Richiede lib\Common.ps1. I volumi dei nodi kind (/var) non si salvano qui: i dati dei PVC li copia lib\Pvc.ps1,
# il resto e' coperto dalla copia del vhdx.

Set-StrictMode -Version 1.0

function Get-DockerDesktopVhdxPath {
    return @(
        (Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'),
        (Join-Path $env:LOCALAPPDATA 'Docker\wsl\main\ext4.vhdx')
    )
}

function Backup-DockerDesktopSetting {
    <# Copia impostazioni e configurazione. Del kubeconfig salva solo il contesto indicato (niente credenziali di altri cluster). #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Context)
    $dest = Join-Path $Root 'settings'
    $null = New-Item -ItemType Directory -Force -Path $dest
    $targets = @(
        @{ Src = (Join-Path $env:APPDATA 'Docker'); Dst = 'AppData-Roaming-Docker' },
        @{ Src = (Join-Path $env:USERPROFILE '.docker'); Dst = 'dot-docker' }
    )
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.Src)) { continue }
        # La cartella models contiene gli LLM del Model Runner (GB), riscaricabili: non fa parte della configurazione.
        & robocopy $t.Src (Join-Path $dest $t.Dst) /E /XD models /NP /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy di $($t.Src) non riuscito (codice $LASTEXITCODE)." }
    }
    & kubectl config view --minify --flatten --context $Context | Set-Content -LiteralPath (Join-Path $dest 'kubeconfig-docker-desktop.yaml') -Encoding utf8NoBOM
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') -Destination (Join-Path $dest 'hosts')
    (& wsl -l -v) -replace "`0", '' | Set-Content -LiteralPath (Join-Path $dest 'wsl-list.txt') -Encoding utf8NoBOM
    & docker version 2>&1 | Set-Content -LiteralPath (Join-Path $dest 'docker-version.txt') -Encoding utf8NoBOM
    & docker info 2>&1 | Set-Content -LiteralPath (Join-Path $dest 'docker-info.txt') -Encoding utf8NoBOM
    & docker images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}' | Set-Content -LiteralPath (Join-Path $dest 'docker-images.txt') -Encoding utf8NoBOM
}

function Get-KindNodeVolume {
    <# Volumi montati dai nodi kind (container nascosti a 'docker ps -a'): vanno esclusi dal tar dei volumi. #>
    $nodes = @(Invoke-Kubectl -Arguments @('get', 'nodes', '-o', 'jsonpath={.items[*].metadata.name}') -AllowFailure) -join ' ' -split '\s+' | Where-Object { $_ }
    $volumes = @()
    foreach ($node in $nodes) {
        $names = & docker inspect $node --format '{{range .Mounts}}{{.Name}} {{end}}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $names) { $volumes += ($names -split '\s+' | Where-Object { $_ }) }
    }
    return @($volumes)
}

function Get-DockerVolumePlan {
    <# Volumi da salvare e container in esecuzione che li usano (da fermare per una copia consistente). #>
    param([string[]]$ExcludeVolume)
    $exclude = @($ExcludeVolume) + (Get-KindNodeVolume)
    $plan = foreach ($v in @(& docker volume ls -q)) {
        if ($v -in $exclude) { continue }
        $running = @(& docker ps --filter "volume=$v" --format '{{.Names}}')
        [pscustomobject]@{ Volume = $v; RunningContainers = $running }
    }
    return @($plan)
}

function Backup-DockerVolume {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [Parameter(Mandatory)][string]$Image,
        [string]$PostgresContainer,
        [string]$PostgresUser = 'postgres'
    )
    $dest = Join-Path $Root 'docker-volumes'
    if ($PostgresContainer) {
        # Dump logico a container acceso: copia piu' portabile del volume.
        Invoke-NativeToFile -FilePath docker -OutFile (Join-Path $dest 'pg_dumpall.sql') -Arguments @(
            'exec', $PostgresContainer, 'pg_dumpall', '-U', $PostgresUser)
    }
    $stopped = @($Plan | ForEach-Object { $_.RunningContainers } | Sort-Object -Unique)
    try {
        foreach ($c in $stopped) { & docker stop $c | Out-Null }
        foreach ($item in $Plan) {
            $v = $item.Volume
            $cmd = "tar czf /b/$v.tgz -C /v . && (find /v | wc -l; du -sb /v) > /b/$v.count"
            & docker run --rm -v "${v}:/v:ro" -v "${dest}:/b" $Image sh -c $cmd
            if ($LASTEXITCODE -ne 0) { throw "Backup del volume $v non riuscito." }
            Get-FileSha256 -Path (Join-Path $dest "$v.tgz") | Set-Content -LiteralPath (Join-Path $dest "$v.sha256") -Encoding utf8NoBOM
        }
    }
    finally {
        foreach ($c in $stopped) { & docker start $c | Out-Null }
    }
}

function Backup-DockerDesktopVhdx {
    <# Copia a freddo dei vhdx. Docker Desktop e WSL devono essere gia' fermi: lo script non li ferma. #>
    param([Parameter(Mandatory)][string]$Root)
    $engine = & docker info --format '{{.ServerVersion}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $engine) { throw "Docker risponde ancora (engine $engine). Chiudi Docker Desktop prima della copia." }
    $wsl = (& wsl -l -v) -replace "`0", ''
    if ($wsl -match 'docker-desktop\s+Running') { throw "La distro docker-desktop e' ancora in esecuzione. Esegui 'wsl --shutdown' (con Docker Desktop chiuso)." }

    $vhdx = @(Get-DockerDesktopVhdxPath | Where-Object { Test-Path -LiteralPath $_ })
    $needed = ($vhdx | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum
    $drive = Get-PSDrive -Name ((Split-Path -Path (Resolve-Path -LiteralPath $Root).Path -Qualifier).TrimEnd(':'))
    if ($drive.Free -lt ($needed * 1.1)) { throw 'Spazio libero insufficiente per la copia dei vhdx.' }

    $dest = Join-Path $Root 'vhdx'
    $report = foreach ($src in $vhdx) {
        $sub = Join-Path $dest (Split-Path (Split-Path $src -Parent) -Leaf)
        & robocopy (Split-Path $src -Parent) $sub (Split-Path $src -Leaf) /J /NP /NJH | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy di $src non riuscito (codice $LASTEXITCODE)." }
        $copy = Join-Path $sub (Split-Path $src -Leaf)
        $a = Get-FileSha256 -Path $src
        $b = Get-FileSha256 -Path $copy
        if ($a -ne $b) { throw "SHA256 diverso tra $src e $copy." }
        "{0}  {1}" -f $a, (Split-Path $src -Leaf)
    }
    $report | Set-Content -LiteralPath (Join-Path $dest 'sha256.txt') -Encoding utf8NoBOM
}
