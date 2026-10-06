# Procedura di backup, verifica e ripristino

Ogni comando usa `-Context docker-desktop`. Gli script non cambiano mai il contesto corrente.

## 1. Prima di iniziare
- Tool: `kubectl`, `docker`, `helm` (opzionale), PowerShell 7.4+.
- Spazio libero su C: almeno quanto il backup. I dati dei PVC sono piccoli (~1 GB); la copia dei vhdx e' ~121 GB.
- Cartella di backup fuori dai dati di Docker Desktop, di WSL e dal repo. `Assert-SafeBackupRoot` rifiuta i percorsi sbagliati.
- Per la copia dei vhdx serve che Docker Desktop si possa chiudere (si fermano cluster e container).

## 2. Backup

```powershell
.\backup.ps1 -Context docker-desktop -BackupRoot <BackupRoot> -DryRun        # solo piano
.\backup.ps1 -Context docker-desktop -BackupRoot <BackupRoot> -IncludeDockerDesktop -PostgresContainer postgresql_uni
```

Il piano elenca i namespace, i PVC con i workload che verranno **fermati temporaneamente**, e i volumi Docker con i container da fermare. Una sola conferma (`si`), poi per ogni PVC:

1. Scala a 0 i Deployment/StatefulSet che lo montano (copia consistente: n8n usa SQLite, qdrant ha un WAL) e attende la scomparsa dei pod.
2. Rifiuta il PVC se un altro pod lo usa ancora.
3. Crea un pod helper (`alpine:3.20`, parametro `-HelperImage`) con il PVC in **sola lettura** e fa `tar czf -` in streaming binario su file.
4. Registra numero di voci (`.count`) e SHA256 (`.sha256`).
5. In ogni caso (anche in errore) elimina l'helper e **riporta le repliche al valore originale**.

Prima dei PVC: inventario indipendente, export delle risorse (dump grezzo + manifest ripuliti), valori Helm. Con `-IncludeDockerDesktop`: impostazioni, kubeconfig del solo contesto `docker-desktop`, tar dei volumi Docker non-K8s (esclusi quelli dei nodi kind), `pg_dumpall`. I container attivi che usano un volume vengono fermati e **riavviati** a fine copia.

Al termine il backup viene verificato; l'esito e' 0 solo se tutti i controlli passano.

## 3. Verifica

```powershell
.\verify-backup.ps1 -BackupPath <BackupRoot>\<timestamp>          # veloce
.\verify-backup.ps1 -BackupPath <BackupRoot>\<timestamp> -Deep    # estrae gli archivi in una cartella temporanea
```

Controlli: `manifest.json` presente; nessun file vuoto; **export = inventario** (stessi namespace, tipi e nomi); manifest di `k8s\restore` validi e privi di campi runtime (`status`, `uid`, `resourceVersion`, `managedFields`); ogni archivio con SHA256 corretto, leggibile da `tar -tzf` e con lo stesso numero di voci rilevato nel pod; tutti i PVC del manifest salvati; hash dei vhdx. Un backup non verificato equivale a nessun backup: se un controllo fallisce non si aggiorna Docker Desktop.

Un'eventuale differenza tra inventario e export puo' dipendere da risorse create o cancellate durante il backup: rilancia il backup.

## 4. Copia a freddo dei dischi (rollback identico)

```powershell
docker desktop stop
wsl --shutdown
.\backup-vhdx.ps1 -BackupPath <BackupRoot>\<timestamp>
```

Lo script verifica che il motore sia fermo e la distro non in esecuzione, controlla lo spazio, copia con `robocopy /J` e confronta gli SHA256 di sorgente e copia. Non ferma nulla da solo.

## 5. Ripristino (cluster nuovo e vuoto)

1. Crea il cluster da Docker Desktop (Settings > Kubernetes, kind, 2 nodi). La versione di default puo' essere piu' recente di quella del backup (con la 4.80.0 e' la 1.36): scegli la 1.34.x se il dialog lo permette.
2. Prova a secco e poi esegui:
   ```powershell
   .\restore.ps1 -Context docker-desktop -BackupPath <BackupRoot>\<timestamp> -DryRun
   .\restore.ps1 -Context docker-desktop -BackupPath <BackupRoot>\<timestamp>
   ```
3. Il ripristino verifica prima il backup, poi applica in ordine: namespace, PV non legati a PVC, release Helm, risorse **senza i workload**, dati dei PVC (helper in scrittura, rifiuta PVC non vuoti salvo `-Force`, confronta il numero di voci), infine i workload. Le app partono cosi' solo dopo che i dati sono al loro posto.
4. Helm: il repo del chart viene dedotto da `repos.txt` quando ha il nome del chart (es. `ingress-nginx/ingress-nginx`); altrimenti aggiungilo con `helm repo add` e passa `-HelmChart @{ '<release>' = '<repo>/<chart>' }`.
5. Confronta: `.\verify-backup.ps1 -BackupPath ... -CompareWithCluster -Context docker-desktop`. Differenze attese: nomi di pod e ReplicaSet, ClusterIP, UID dei PV, pod `node-debugger`. Poi apri le app su localhost.
6. Il backup non viene mai cancellato dagli script.

Se il backup contiene immagini applicative piu' vecchie di quelle in uso (vedi architecture.md), il ripristino riporta i Deployment alle immagini salvate.

## 6. Ripristino manuale (non automatizzato)

**Volumi Docker non-K8s**
```powershell
docker volume create <volume>
docker run --rm -v "<volume>:/v" -v "<BackupRoot>\<timestamp>\docker-volumes:/b:ro" alpine:3.20 sh -c "tar xzpf /b/<volume>.tgz -C /v"
```
Per Postgres e' preferibile ricreare il container e rieseguire `pg_dumpall.sql` con `psql`.

**Disco intero (rollback identico alla versione precedente)**: vedi docker-desktop-upgrade.md.

## 7. Il backup manuale del 2026-10-06 (formato diverso)

E' un backup locale (non nel repo, ignorato da git) creato **a mano**, seguendo la stessa procedura prima di scrivere gli script, quindi il layout differisce:

| Elemento | Backup manuale | Nuovi script |
|---|---|---|
| Inventario | `inventory-pre\inventory.tsv` | `inventory\inventory.tsv` |
| `manifest.json` | assente | richiesto da verify e restore |
| Release Helm | `helm\nginx-ingress.*.yaml`, `repos.txt` (niente `releases.json`) | `helm\releases.json` + file per release |
| `.sha256` dei volumi Docker | assenti (solo `.count`) | presenti |
| `vhdx\sha256.txt` | righe `nome: OK <hash>`; i vhdx sono stati cancellati dopo la compattazione | righe `<hash>  <nome>` |
| Kubeconfig | `settings\kube-config` (contiene anche le credenziali EKS) | solo il contesto `docker-desktop` |

`verify-backup.ps1` e `restore.ps1` **non accettano** questo formato cosi' com'e'. Per usarlo servirebbe un adattatore (suggerimento in fondo alla sintesi). Intanto il ripristino si fa a mano, con gli stessi passi della sezione 5:

```powershell
$B = '<cartella-del-backup>'; $K = @('--context','docker-desktop')
kubectl @K apply -f "$B\k8s\restore\00-namespaces"; kubectl @K apply -f "$B\k8s\restore\10-cluster"
helm --kube-context docker-desktop install nginx-ingress ingress-nginx/ingress-nginx --version 4.15.1 -n ingress-nginx --create-namespace -f "$B\helm\nginx-ingress.values.yaml"
# poi, per ogni namespace: i file 20-<ns> tranne deployments.apps_*; i dati dei PVC (pvc\<ns>-<pvc>.tgz) con un pod helper; infine i Deployment
```

Le immagini nei Deployment del backup sono n8n `2.37.3`, open-webui `0.11.0`, qdrant `v1.19.0`. In cluster ora girano n8n `2.43.0` e open-webui `0.11.4`.

Le credenziali EKS in `settings\kube-config`: cancella quel file quando non serve piu' (il backup resta valido).

## 8. Compattare il disco dopo le pulizie

```powershell
docker builder prune -a -f        # build cache
docker image prune -a -f          # immagini non usate da alcun container (anche nascosto)
docker desktop stop; wsl --shutdown
Optimize-VHD -Path "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx" -Mode Full   # PowerShell elevata
```
`docker image prune -a` e' sicuro per i nodi kind: Docker li conta come container reali. Non togliere a mano `kindest/node`, `desktop-cloud-provider-kind`, `envoyproxy/envoy`, `desktop-containerd-registry-mirror`. Compatta il vhdx **prima** di cancellare la copia di backup. Il 2026-10-06: 131,6 -> 110,5 GB.
