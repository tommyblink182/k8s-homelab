# Funzioni comuni. Incluso con dot-sourcing dagli script di ingresso.
# Non modifica mai il contesto kubectl corrente: ogni chiamata usa --context esplicito.

Set-StrictMode -Version 1.0

$script:KubeContext = $null
$script:SystemNamespaces = @('default', 'kube-system', 'kube-public', 'kube-node-lease', 'local-path-storage')

function Write-Log {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('step', 'info', 'ok', 'warn', 'error')][string]$Level = 'info'
    )
    $prefix = switch ($Level) {
        'step' { "`n==> " }
        'ok' { '    [OK] ' }
        'warn' { '    [ATTENZIONE] ' }
        'error' { '    [ERRORE] ' }
        default { '    ' }
    }
    Write-Information "$prefix$Message" -InformationAction Continue
}

function Assert-Tool {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Comando non trovato nel PATH: $Name"
    }
}

function Initialize-ToolEncoding {
    # kubectl e helm emettono UTF-8: evita caratteri alterati quando l'output viene catturato.
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) }
    catch { Write-Log 'Impossibile impostare la codifica UTF-8 della console.' -Level warn }
}

function Initialize-KubeContext {
    <#
    Imposta il contesto usato da tutte le chiamate kubectl/helm e verifica che il cluster risponda.
    Rifiuta qualunque contesto diverso da 'docker-desktop' senza -AllowNonDockerDesktop: sul PC
    possono esistere contesti di produzione (es. EKS) e il contesto corrente non e' quello locale.
    #>
    param(
        [Parameter(Mandatory)][string]$Context,
        [switch]$AllowNonDockerDesktop
    )
    Assert-Tool kubectl
    $known = @(& kubectl config get-contexts -o name)
    if ($LASTEXITCODE -ne 0) { throw 'kubectl config get-contexts non riuscito.' }
    if ($Context -notin $known) {
        throw "Contesto '$Context' non presente nel kubeconfig. Disponibili: $($known -join ', ')"
    }
    if ($Context -ne 'docker-desktop' -and -not $AllowNonDockerDesktop) {
        throw "Contesto '$Context' rifiutato: gli script sono pensati per 'docker-desktop'. Usa -AllowNonDockerDesktop solo se sai cosa stai facendo."
    }
    $script:KubeContext = $Context
    $current = (& kubectl config current-context) 2>$null
    if ($current -and $current -ne $Context) {
        Write-Log "Il contesto corrente e' '$current'. Gli script usano '$Context' e non cambiano quello corrente." -Level warn
    }
    $null = Invoke-Kubectl -Arguments @('get', 'nodes', '--request-timeout=15s')
}

function Get-KubeContextName { return $script:KubeContext }

function Invoke-Kubectl {
    <# Esegue kubectl sul contesto attivo e restituisce lo stdout. Racchiudere sempre la chiamata in @(...). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $raw = & kubectl --context $script:KubeContext @Arguments 2>&1
    $code = $LASTEXITCODE
    $stdout = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    if ($code -ne 0 -and -not $AllowFailure) {
        $stderr = ($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
        throw "kubectl $($Arguments -join ' ') ha restituito $code`n$stderr"
    }
    return $stdout
}

function Get-KubeJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $out = @(Invoke-Kubectl -Arguments ($Arguments + @('-o', 'json')) -AllowFailure:$AllowFailure)
    if ($out.Count -eq 0) { return $null }
    return (($out -join "`n") | ConvertFrom-Json)
}

function Invoke-NativeToFile {
    <#
    Esegue un eseguibile collegando stdout e/o stdin a un file a livello di sistema operativo.
    Serve per flussi binari (tar): la redirezione di PowerShell puo' alterare i byte.
    Gli argomenti non devono contenere spazi (Start-Process li concatena senza virgolette).
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$OutFile,
        [string]$InFile
    )
    $errFile = Join-Path $env:TEMP ('k8s-data-' + (Get-Random) + '.err')
    $params = @{
        FilePath = $FilePath
        ArgumentList = $Arguments
        NoNewWindow = $true
        Wait = $true
        PassThru = $true
        RedirectStandardError = $errFile
    }
    if ($OutFile) { $params.RedirectStandardOutput = $OutFile }
    if ($InFile) { $params.RedirectStandardInput = $InFile }
    try {
        $proc = Start-Process @params
        if ($proc.ExitCode -ne 0) {
            $stderr = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw } else { '' }
            throw "$FilePath ha restituito $($proc.ExitCode): $stderr"
        }
    }
    finally {
        if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force }
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Path
    )
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $Object | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Get-SafeName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[^A-Za-z0-9._-]', '_')
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-SafeBackupRoot {
    <# Il backup non deve stare nei dati di Docker Desktop, di WSL o nel repository: disinstallazione e reset li cancellano. #>
    param([Parameter(Mandatory)][string]$Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path).TrimEnd('\')
    $repoRoot = (Split-Path -Path $PSScriptRoot -Parent).TrimEnd('\')
    $forbidden = @(
        (Join-Path $env:LOCALAPPDATA 'Docker'),
        (Join-Path $env:APPDATA 'Docker'),
        (Join-Path $env:ProgramData 'DockerDesktop'),
        $repoRoot
    )
    foreach ($f in $forbidden) {
        if ($full -eq $f -or $full.StartsWith($f + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Percorso di backup non ammesso ($full): sta dentro '$f', che puo' essere cancellato da reset, disinstallazione o git."
        }
    }
}

function New-BackupFolder {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path $Root (Get-Date -Format 'yyyyMMdd-HHmm')
    if ($PSCmdlet.ShouldProcess($path, 'Creare la cartella di backup')) {
        foreach ($sub in 'inventory', 'k8s\full', 'k8s\restore', 'helm', 'pvc', 'docker-volumes', 'settings', 'vhdx') {
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $path $sub)
        }
    }
    return $path
}

function Confirm-Plan {
    <# Una sola conferma esplicita prima di qualunque modifica. Con -Yes la salta. #>
    param([switch]$Yes)
    if ($Yes) { return $true }
    $answer = Read-Host 'Procedere? (si/no)'
    return ($answer -eq 'si')
}
