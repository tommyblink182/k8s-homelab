# K8s Local Cluster — Docker Desktop

Kubernetes 1.34.3 su Docker Desktop (Windows, WSL2 backend).  
Applicazioni: **n8n**, **Open-WebUI** (namespace `ollama`), **Qdrant**, **ingress-nginx**.

---

## Architettura — Cosa succede dietro le quinte

Docker Desktop su Windows usa **due VM separate** con filesystem completamente distinti:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Windows Host  C:\k8s-data\                                         │
│                                                                     │
│   ┌───────────────────────┐     ┌──────────────────────────────┐   │
│   │  docker-desktop WSL2  │     │  desktop-worker (nodo K8s)   │   │
│   │                       │     │                              │   │
│   │  - comandi `docker`   │     │  - kubelet, containerd       │   │
│   │  - wsl.exe commands   │     │  - PVC storage               │   │
│   │  - /mnt/host/c/ → C:\ │     │  - /var/local-path-          │   │
│   │    (9P mount Windows) │     │    provisioner/pvc-xxx/      │   │
│   │                       │     │    (disco locale VM)         │   │
│   └───────────────────────┘     └──────────────────────────────┘   │
│          filesystem A                    filesystem B               │
└─────────────────────────────────────────────────────────────────────┘
```

**Conseguenza pratica:**
- I mount 9P (Windows ↔ WSL2) esistono **solo** nel namespace di mount della WSL distro
- I pod K8s girano nel nodo `desktop-worker` con un namespace di mount isolato
- `hostPath` in un pod crea una directory sul disco della VM del K8s node, **non su Windows**
- Non esiste un modo nativo per far scrivere i pod direttamente su `C:\`

**I dati dei PVC vivono su:**
```
desktop-worker VM → /var/local-path-provisioner/pvc-<uuid>_<ns>_<nome>/
```
Quella directory **non è accessibile da Windows** e viene persa se Docker Desktop resetta la VM (aggiornamenti, "Reset to factory defaults", reinstallazione).

---

## Strategia di protezione dei dati

Il backup **non è permanente** su Windows. Le cartelle `volumes/` esistono solo nella finestra temporanea tra backup e restore.

```
[Cluster in esecuzione]
        │
        ▼  .\backup.ps1          ← prima di aggiornare Docker
[C:\k8s-data\*\volumes\]         ← file TEMPORANEI (~1-2 GB)
        │
        ▼  Aggiorna Docker Desktop  (cluster resettato, VM ripristinata)
        │
        ▼  .\restore.ps1         ← applica manifest + copia dati nei pod
[Cluster ripristinato]
        │
        ▼  (restore.ps1 cancella automaticamente volumes/)
[C:\k8s-data\ — solo manifest YAML, pochi KB]
```

**Cosa rimane sempre su Windows (permanente, pochi KB):**
- `*/manifest/*.json` — definizioni Kubernetes esportate dal cluster vivo (generate da `backup.ps1`; i vecchi `.yaml` vengono sostituiti)
- `backup.ps1` / `restore.ps1` — gli script

**Cosa è temporaneo (esiste solo backup→restore):**
- `*/volumes/` — dump dei dati dei pod via `kubectl cp`

---

## Struttura del repository

```
C:\k8s-data\
├── backup.ps1                    ← copia dati pod → Windows (prima di aggiornare Docker)
├── restore.ps1                   ← applica manifest + dati Windows → pod (dopo aggiornamento)
├── README.md
│
├── n8n\manifest\
│   ├── deployments.yaml
│   ├── services.yaml
│   ├── pvcs.yaml
│   ├── configmaps.yaml
│   ├── secrets.yaml
│   └── ingress.yaml
│
├── ollama\manifest\              ← namespace ollama, deployment: open-webui
│   └── (stessa struttura)
│
├── qdrant\manifest\
│   └── (stessa struttura)
│
└── ingress-nginx\manifest\       ← no PVC, solo manifest
    └── (stessa struttura)
```

---

## Flusso: prima di aggiornare Docker Desktop

### 1. Fai il backup (cluster ancora in piedi)

```powershell
cd C:\k8s-data
.\backup.ps1
```

Lo script **auto-scopre tutti i namespace applicativi** (esclude i namespace di sistema), poi per ognuno:
- Esporta manifest aggiornati dal cluster (`pvcs.json`, `secrets.json`, `deployments.json`, ecc.) nella cartella `manifest/`, sostituendo i vecchi `.yaml`
- Trova tutti i PVC montati nei pod Running e li copia in `volumes/<pvc-name>/` via `kubectl cp`

Non ci sono namespace hardcoded: aggiungere una nuova app in un nuovo namespace e il prossimo backup la includerà automaticamente. Richiede che i pod siano Running.

Dry-run (solo verifica, nessuna scrittura):
```powershell
.\backup.ps1 -DryRun
```

### 2. Aggiorna Docker Desktop

Il cluster viene resettato. I dati dei PVC sul nodo K8s vengono persi. Normale.

### 3. Restore (cluster nuovo e vuoto)

```powershell
.\restore.ps1
```

Lo script esegue in ordine:
1. Verifica che il cluster sia accessibile
2. Auto-scopre i namespace da `C:\k8s-data\*/manifest/`, ricrea quelli mancanti e applica tutti i file manifest (JSON e YAML)
3. Attende che i pod siano in Running (con storage vuoto)
4. Copia i dati da `volumes\` ai pod via `kubectl cp`
5. Esegue `kubectl rollout restart` per ricaricare i dati
6. Attende i rollout e verifica l'accesso ai dati
7. **Cancella automaticamente le cartelle `volumes\`** (spazio liberato)

Opzioni:
```powershell
.\restore.ps1 -DryRun          # simula senza applicare nulla
.\restore.ps1 -KeepBackup      # non cancella volumes/ al termine
```

---

## Applicazioni e URL locali

| App | Namespace | Deployment | URL locale |
|-----|-----------|------------|------------|
| n8n | `n8n` | `n8n` | http://n8n.kubernetes.local |
| Open-WebUI | `ollama` | `open-webui` | http://open-webui.kubernetes.local |
| Qdrant | `qdrant` | `qdrant` | http://qdrant.kubernetes.local |

Le voci DNS devono essere nel file `hosts` di Windows (`C:\Windows\System32\drivers\etc\hosts`):
```
127.0.0.1  n8n.kubernetes.local
127.0.0.1  open-webui.kubernetes.local
127.0.0.1  qdrant.kubernetes.local
```

---

## Comandi utili

```powershell
# Stato generale cluster
kubectl get pods -A
kubectl get ingress -A
kubectl get pvc -A

# Verifica dati accessibili in un pod
kubectl exec -n n8n deployment/n8n -- ls -la /home/node/.n8n/
kubectl exec -n ollama deployment/open-webui -- ls -la /app/backend/data/
kubectl exec -n qdrant deployment/qdrant -- ls -la /qdrant/storage/

# Dove vivono fisicamente i dati sul nodo K8s (dietro le quinte)
kubectl debug node/desktop-worker -it --image=busybox:1.36 -- sh
# poi dentro la shell: ls /host/var/local-path-provisioner/

# Forza restart di un deployment
kubectl rollout restart deployment/n8n -n n8n
kubectl rollout restart deployment/open-webui -n ollama
kubectl rollout restart deployment/qdrant -n qdrant

# Stato rollout
kubectl rollout status deployment/n8n -n n8n
```

---

## Troubleshooting

**Pod in CrashLoopBackOff dopo restore**
```powershell
kubectl logs <pod-name> -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
```

**`backup.ps1` fallisce su un namespace** — verifica che il pod sia Running:
```powershell
kubectl get pods -A
```

**`kubectl cp` lento o si blocca** — normale per volumi grandi (Open-WebUI può essere >800 MB). Attendere.

**Restore parziale — ripeti solo un namespace**
```powershell
# Esempio per n8n
$pod = kubectl get pod -n n8n -l app=n8n -o jsonpath='{.items[0].metadata.name}'
kubectl cp "C:\k8s-data\n8n\volumes\n8n-data\." "n8n/${pod}:/home/node/.n8n"
kubectl rollout restart deployment/n8n -n n8n
kubectl rollout status deployment/n8n -n n8n
```

**Ingress non risponde dopo restore**
```powershell
kubectl get deployment -n ingress-nginx
kubectl rollout status deployment/ingress-nginx -n ingress-nginx
kubectl logs -n ingress-nginx deployment/ingress-nginx
```

**Verificare che il file `hosts` sia configurato**
```powershell
Get-Content "C:\Windows\System32\drivers\etc\hosts" | Select-String "kubernetes.local"
```

---

## Versione cluster

| Componente | Versione |
|---|---|
| Kubernetes | 1.34.3 |
| Docker Desktop | Windows, WSL2 backend |
| n8n | 2.21.7 |
| Storage class | `standard` (local-path-provisioner, gestito da Docker Desktop) |
