# k8s-data

Backup, verifica e ripristino del cluster Kubernetes di Docker Desktop (Windows, WSL2, kind a 2 nodi) prima di aggiornare Docker Desktop. Il cluster e' l'unica fonte di verita': nessun manifest originale.

## Regole che non si negoziano
- Ogni script richiede `-Context` e non cambia mai il contesto corrente. Sul PC esiste un contesto EKS di produzione: usa solo `docker-desktop`.
- Backup e ripristino reali agiscono su dati veri: non eseguirli per "provare". Verifica con analisi statica e `-DryRun`.
- Il backup sta fuori dal repo e dai dati di Docker Desktop (cartella scelta con `-BackupRoot`, sottocartella con timestamp). Non cancellare un backup senza conferma.
- Niente `Set-ExecutionPolicy`, elevazioni, `Invoke-Expression`, download dagli script (ambienti aziendali).

## Comandi
```powershell
.\backup.ps1 -Context docker-desktop -BackupRoot <BackupRoot> -DryRun          # piano senza modifiche
.\backup.ps1 -Context docker-desktop -BackupRoot <BackupRoot> [-IncludeDockerDesktop -PostgresContainer <nome>]
.\verify-backup.ps1 -BackupPath <cartella> [-Deep]
.\backup-vhdx.ps1 -BackupPath <cartella>              # a Docker Desktop chiuso
.\restore.ps1 -Context docker-desktop -BackupPath <cartella> -DryRun
.\verify-backup.ps1 -BackupPath <cartella> -CompareWithCluster -Context docker-desktop
```
Richiede PowerShell 7.4+, kubectl, helm (opzionale), docker.

## Struttura
`backup.ps1`, `restore.ps1`, `verify-backup.ps1`, `backup-vhdx.ps1` sono gli ingressi. La logica sta in `lib\` (Common, K8s, Pvc, DockerDesktop, Verify). Per estendere a nuove parti di Docker Desktop aggiungi funzioni in `lib\DockerDesktop.ps1` e un passo in `backup.ps1`.

## Documentazione
- `docs\architecture.md`: dove vivono i dati, inventario del cluster.
- `docs\backup-restore.md`: procedura completa di backup, ripristino, verifica.
- `docs\docker-desktop-upgrade.md`: aggiornamento, rischi delle release notes, rollback, installer.
- `docs\decisions.md`: decisioni, problemi risolti, compatibilita' con ambienti aziendali.
