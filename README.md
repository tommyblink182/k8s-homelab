# k8s-data - backup e ripristino del cluster Kubernetes di Docker Desktop

Kubernetes integrato di Docker Desktop (Windows, backend WSL2, provisioner kind, 2 nodi). Gli script salvano risorse, release Helm e dati dei PVC **prima** di aggiornare o resettare Docker Desktop, e li ripristinano dopo. Il cluster e' l'unica fonte di verita': i manifest si esportano dal cluster vivo.

> **Attenzione al contesto kubectl.** Sul PC puo' essere configurato un cluster di produzione (EKS) come contesto corrente. Tutti gli script richiedono `-Context` esplicito (`docker-desktop`) e non modificano mai il contesto corrente.

## Dove vivono i dati

Docker Desktop usa due ambienti con filesystem separati: la distro WSL `docker-desktop` (comandi `docker`, mount di `C:\`) e i **nodi kind**, che sono container dentro quella VM. I dati dei PVC (storage class `standard`/`hostpath`, local-path) stanno nel nodo worker in `/var/local-path-provisioner/pvc-<uuid>_<ns>_<nome>/`, quindi dentro `docker_data.vhdx`: non sono raggiungibili da Windows e si perdono con un reset del cluster o una disinstallazione. Dettagli in [docs/architecture.md](docs/architecture.md).

## Uso

Richiede PowerShell 7.4+, `kubectl`, `docker` e (opzionale) `helm`. Gli script non sono firmati: vedi [docs/decisions.md](docs/decisions.md) per le regole sulla execution policy.

```powershell
# 1. Piano senza modifiche
.\backup.ps1 -Context docker-desktop -DryRun

# 2. Backup (una sola conferma; le app si fermano una alla volta e vengono riavviate)
.\backup.ps1 -Context docker-desktop -IncludeDockerDesktop -PostgresContainer postgresql_uni

# 3. Verifica approfondita (estrae gli archivi in una cartella temporanea)
.\verify-backup.ps1 -BackupPath C:\DockerBackups\<timestamp> -Deep

# 4. Copia a freddo dei dischi, a Docker Desktop chiuso (rollback identico)
.\backup-vhdx.ps1 -BackupPath C:\DockerBackups\<timestamp>

# 5. Dopo l'aggiornamento, se il cluster non e' sopravvissuto
.\restore.ps1 -Context docker-desktop -BackupPath C:\DockerBackups\<timestamp> -DryRun
.\restore.ps1 -Context docker-desktop -BackupPath C:\DockerBackups\<timestamp>
.\verify-backup.ps1 -BackupPath C:\DockerBackups\<timestamp> -CompareWithCluster -Context docker-desktop
```

Non aggiornare Docker Desktop se la verifica del backup non passa.

## Cosa contiene un backup

```
C:\DockerBackups\<yyyyMMdd-HHmm>\
  manifest.json      contesto, namespace, PVC, release Helm, esito
  inventory\         inventory.tsv (namespace|tipo|nome), versioni, stato del cluster
  k8s\full\          dump grezzo di tutto (archivio)
  k8s\restore\       manifest ripuliti e riapplicabili (00-namespaces, 10-cluster, 20-<ns>)
  helm\              values, values-all, manifest, releases.json, repos.txt
  pvc\               <ns>-<pvc>.tgz + .sha256 + .count
  docker-volumes\    volumi Docker non-K8s (.tgz) e pg_dumpall.sql (con -IncludeDockerDesktop)
  settings\          impostazioni Docker Desktop, kubeconfig del solo docker-desktop, hosts
  vhdx\              copia a freddo di docker_data.vhdx e ext4.vhdx + sha256.txt
```

Il backup manuale del 2026-10-06 e' in `backups\20261006-0013` (ignorata da git, formato diverso: vedi [docs/backup-restore.md](docs/backup-restore.md), sezione 7).

La cartella contiene Secret in chiaro e dati reali: tienila fuori da git e da cartelle condivise. Resta fuori dai dati di Docker Desktop e di WSL, cosi' disinstallazione e reset non la toccano.

## Documentazione

| File | Contenuto |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Dove vivono i dati, inventario del cluster, accesso da Windows |
| [docs/backup-restore.md](docs/backup-restore.md) | Procedura di backup, verifica, ripristino, ripristino manuale di volumi e vhdx |
| [docs/docker-desktop-upgrade.md](docs/docker-desktop-upgrade.md) | Aggiornamento, rischi delle release notes, rollback, installer |
| [docs/decisions.md](docs/decisions.md) | Decisioni, problemi risolti, compatibilita' con ambienti aziendali |

## Struttura del repository

```
backup.ps1  restore.ps1  verify-backup.ps1  backup-vhdx.ps1    punti di ingresso
lib\        Common.ps1  K8s.ps1  Pvc.ps1  DockerDesktop.ps1  Verify.ps1
docs\       documentazione
CLAUDE.md   contesto per Claude Code
```

## Risoluzione problemi

- **Il contesto viene rifiutato**: usa `docker-desktop`. Altri contesti richiedono `-AllowNonDockerDesktop`.
- **Un PVC e' saltato "ancora montato"**: un pod senza Deployment/StatefulSet lo usa. Fermalo a mano e rilancia.
- **`kubectl logs` sull'ingress**: il Deployment si chiama `nginx-ingress-ingress-nginx-controller` (namespace `ingress-nginx`).
- **Pod in CrashLoopBackOff dopo il ripristino**: `kubectl --context docker-desktop logs <pod> -n <ns>` e `describe pod`.
