# Aggiornamento di Docker Desktop, rischi e rollback

Esperienza reale: 4.78.0 -> 4.94.0 il 2026-10-06 (Windows, WSL2, installazione per-machine). **Il cluster e' sopravvissuto**: 2 nodi Ready, stessi PVC e dati, 19 volumi e 16 container Docker presenti. Il ripristino non e' servito.

## Rischi trovati nelle release notes (4.78.0 -> 4.94.0)

Fonti: https://docs.docker.com/desktop/release-notes/ , https://docs.docker.com/desktop/features/kubernetes/ , https://docs.docker.com/desktop/setup/install/windows-install/ , https://docs.docker.com/desktop/uninstall/

| Versione | Nota | Impatto |
|---|---|---|
| Doc Kubernetes | I cluster non vengono aggiornati con Docker Desktop; serve *Reset cluster* | Un aggiornamento in-place non dovrebbe toccare il cluster, ma il backup e' obbligatorio |
| 4.80.0 | Kubernetes predefinito 1.36.1, nuove immagini kind | Un eventuale reset crea un cluster 1.36, non 1.34.3 |
| 4.80.0 / 4.79.0 | Corretti `wsl --shutdown` di distro estranee e blocco su "Starting the Docker Engine" dopo un upgrade in-place | Fare comunque `wsl --shutdown` prima dell'installazione |
| 4.82.0 | Corretto kind che non partiva dopo un riavvio ("Failed to get API server port") | Positivo |
| 4.83, 4.84, 4.92 | Migrazione per-machine -> per-user; l'MSI blocca se esiste un'installazione per-user | L'installer propone **per-user** di default: per un upgrade in-place per-machine non usare `--user` |
| 4.84.0 | Corretta la disinstallazione che poteva bloccare l'accesso alle cartelle dati | Riguarda il rollback |
| 4.92.0 | Regressione WSL: timeout "waiting for ... to be automounted" | Corretta nella 4.94.0 (quindi 4.94.0, non 4.92/4.93) |
| Doc Uninstall | Disinstallare cancella container, immagini, volumi e dati locali | Rollback = perdita di tutto senza la copia del vhdx |
| Downgrade | Non esiste un downgrade in-place supportato | Disinstalla e installa la versione precedente |

## Procedura di aggiornamento

1. `backup.ps1` (con `-IncludeDockerDesktop`), `verify-backup.ps1 -Deep`: devono passare.
2. Chiudi Docker Desktop e spegni WSL: `docker desktop stop; wsl --shutdown`. Poi `backup-vhdx.ps1`.
3. Installa dalla PowerShell elevata, **per-machine** (UAC da accettare):
   ```powershell
   Start-Process 'C:\DockerBackups\installers\4.94.0\Docker Desktop Installer.exe' -Verb RunAs -Wait -ArgumentList 'install','--accept-license'
   ```
   L'installazione e' durata oltre 10 minuti, con la finestra "Installing..." ferma e CPU quasi nulla: non interromperla. I file erano gia' alla nuova versione prima della fine.
4. Avvia Docker Desktop e attendi motore e cluster (nell'esperienza reale: motore dopo ~10 s, API del cluster subito dopo).
5. Verifica: 2 nodi Ready, pod Running, PVC Bound, inventario identico (`verify-backup.ps1 -CompareWithCluster`), conteggi dei file nei PVC come nel backup, app su localhost.
6. I container Docker che prima erano accesi (es. `postgresql_uni`, `pgadmin_uni`) restano fermi dopo l'arresto di Docker: riavviali con `docker start`.

Nota: `DisableUpdate: true` in `%APPDATA%\Docker\settings-store.json` disattiva l'aggiornamento automatico; l'installer manuale funziona comunque.

## Rollback a una versione precedente

Con la copia a freddo del vhdx e l'installer della versione vecchia:
1. Chiudi Docker Desktop, `wsl --shutdown`, verifica gli hash in `vhdx\sha256.txt`.
2. Disinstalla la versione nuova (cancella `%LOCALAPPDATA%\Docker`).
3. Installa la vecchia (per-machine). Avvia una volta Docker Desktop, poi chiudilo e `wsl --shutdown`.
4. Sostituisci `%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx` e `wsl\main\ext4.vhdx` con le copie, verifica gli hash, ripristina `settings-store.json`.
5. Avvia: cluster, container e volumi tornano come al momento della copia.
6. Se il vhdx non viene accettato: cluster nuovo + `restore.ps1` + volumi Docker da tar.

La procedura di rollback non e' stata eseguita (non serviva). Il rollback identico non e' piu' possibile dopo aver cancellato la copia del vhdx.

## Installer

Cartella `C:\DockerBackups\installers\` (fuori dai dati di Docker, non si cancella con la disinstallazione). Servono per installare o tornare a quella versione.

| Versione | Build | SHA256 | URL |
|---|---|---|---|
| 4.78.0 | 229452 | `99e275b54ed50ad758b5c9f5d243d0d715b40f909a4e4249fa4c37c0f1735a5e` | https://desktop.docker.com/win/main/amd64/229452/Docker%20Desktop%20Installer.exe |
| 4.94.0 | 241994 | `a9814e31049d66156477a86614e83365669677733014ec72f74229623ff3890a` | https://desktop.docker.com/win/main/amd64/241994/Docker%20Desktop%20Installer.exe |

Ogni build ha anche `.../<build>/checksums.txt`. Le release precedenti sono elencate nelle release notes con lo stesso schema di URL.

## Liberare spazio e compattare

Vedi `backup-restore.md`, sezione 8. Esperienza del 2026-10-06: build cache -18,4 GB, immagini -7,4 GB, residuo del Model Runner (`%USERPROFILE%\.docker\models`, LLM non registrato) -4,8 GB, compattazione del vhdx 131,6 -> 110,5 GB (`Optimize-VHD` richiede una PowerShell elevata: la richiesta UAC va accettata, altrimenti il comando fallisce con "Operazione annullata dall'utente" senza modificare nulla).
