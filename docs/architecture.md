# Architettura e inventario

Stato rilevato il 2026-10-06 su Docker Desktop 4.78.0, prima dell'aggiornamento alla 4.94.0.

## Dove vivono i dati

```
Windows
  |- %LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx   ~121 GB   engine Docker, volumi, nodi kind
  |- %LOCALAPPDATA%\Docker\wsl\main\ext4.vhdx          ~0,1 GB   distro docker-desktop
  `- <BackupRoot>\                                     backup (fuori dai dati di Docker)

docker-desktop (WSL2)  ->  engine Docker  ->  container "nascosti" a 'docker ps -a':
  desktop-control-plane   volume anonimo montato su /var  (~1,4 GB: etcd, immagini)
  desktop-worker          volume anonimo montato su /var  (~57 GB: PVC, immagini containerd, log)
```

- I **nodi kind sono container** (immagine `kindest/node:<versione>`) non elencati da `docker ps -a`, ma visibili con `docker inspect desktop-worker`. I loro `/var` sono volumi anonimi: non vanno salvati con un tar a parte (quasi tutto e' cache di immagini).
- I **PVC** (storage class `standard`, provisioner `rancher.io/local-path`, reclaim `Delete`) stanno in `/var/local-path-provisioner/pvc-<uuid>_<ns>_<nome>/` del nodo worker. Windows non li vede. Un reset del cluster o la disinstallazione li cancella.
- `hostPath` in un pod scrive sul disco del nodo, non su Windows. Non esiste un modo nativo per far scrivere i pod direttamente su Windows.
- `kubectl cp` non conserva owner e permessi: per i dati si usa tar eseguito come root in un pod helper.
- Il file `docker_data.vhdx` **non si restringe da solo**: liberare spazio dentro Docker non libera spazio su SSD finche' non si compatta (vedi docker-desktop-upgrade.md).

## Contesti kubectl

Il PC puo' avere contesti EKS (sviluppo e produzione) accanto a `docker-desktop`. Al 2026-10-06 il contesto **corrente** era quello di produzione. Per questo ogni comando usa `--context docker-desktop` (`--kube-context` per Helm) e gli script rifiutano altri contesti.

## Inventario del cluster `docker-desktop`

- Kubernetes v1.34.3, nodi `desktop-control-plane` e `desktop-worker`, containerd 2.2.0.
- Namespace applicativi: `n8n`, `ollama`, `qdrant`, `ingress-nginx`. Di sistema: default, kube-system, kube-public, kube-node-lease, local-path-storage.
- CRD: nessuna. Tipi API: 33 namespaced, 32 cluster-scoped.

| Namespace | Workload | PVC (mount) | Note |
|---|---|---|---|
| n8n | `n8n` (`n8nio/n8n`, init container `install-custom-node-modules`) | `n8n-pvc` 5Gi (`/home/node/.n8n`, SQLite, uid 1000, ~96 MB) | Ingress `n8n.kubernetes.local` |
| ollama | `open-webui` (`openwebui/open-webui`) | `ollama-pvc` 1Gi (`/app/backend/data`, ~0,9 GB, root) | Ingress `open-webui.kubernetes.local`; punta a Ollama sull'host (`http://host.docker.internal:11434`), `svc-ollama` non ha endpoint |
| qdrant | `qdrant` (`qdrant/qdrant`) | `qdrant-pvc` 10Gi (`/qdrant/storage`, ~65 MB, file mmap sparsi) | Ingress `qdrant.kubernetes.local`, collection `midjourney`, `n8n_rag_hybrid`, `star_charts` |
| ingress-nginx | release Helm `nginx-ingress` (chart `ingress-nginx-4.15.1`, app 1.15.1) | - | Service LoadBalancer, IngressClass `nginx`, ValidatingWebhook |

Versioni delle immagini il 2026-10-06 durante il backup: n8n `2.37.3`, open-webui `0.11.0`, qdrant `v1.19.0`. Poche ore dopo n8n e' stato portato a `2.43.0` e open-webui a `0.11.4`: **i dati salvati nel backup sono quelli delle versioni vecchie**. In caso di ripristino da quel backup usa le immagini originali.

PV orfano `n8n-pv` (hostPath `/tmp/n8n-data`, Retain, Available): non usato da nessun PVC.

## Accesso da Windows

Le app sono raggiunte dal controller ingress su `localhost`. Nel file `%SystemRoot%\System32\drivers\etc\hosts` servono le righe:

```
127.0.0.1 n8n.kubernetes.local
127.0.0.1 open-webui.kubernetes.local
127.0.0.1 qdrant.kubernetes.local
```

## Altri dati in Docker (fuori dal cluster)

Container `postgresql_uni` e `pgadmin_uni` (volumi `postgressql_postgresql_uni`, `postgressql_pgadmin_data`), container fermi di Kafka/Flink (`cp_all_in_one_*`) e MongoDB (`mongodb_*`): 17 volumi, circa 400 MB. Una disinstallazione di Docker Desktop li cancella: `backup.ps1 -IncludeDockerDesktop` li salva. Tre container Confluent usano anche una cartella *bind* su Windows (`...\Confluent-platform\...\vol\config`) che non sta nel vhdx e sopravvive a aggiornamento e disinstallazione.
