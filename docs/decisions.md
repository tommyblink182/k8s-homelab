# Decisioni, problemi risolti, compatibilita'

## Scelta della procedura Docker Desktop

Adottata la procedura **collaudata il 2026-10-06** (backup e aggiornamento 4.78.0 -> 4.94.0), al posto di quella dichiarata nel vecchio README di `k8s-data`. Mantenute dalla vecchia versione l'auto-scoperta dei namespace (nessun nome fisso), l'auto-scoperta dei PVC dai workload, la spiegazione dell'architettura a due VM e le opzioni di prova a secco.

| Aspetto | Vecchia procedura | Procedura adottata | Motivo |
|---|---|---|---|
| Contesto kubectl | Implicito (contesto corrente) | `-Context` obbligatorio, rifiuta contesti diversi da `docker-desktop` | Il contesto corrente era EKS di **produzione**: gli script vecchi avrebbero esportato e applicato li' |
| Copia dei dati | `kubectl cp` con app accesa | App a 0 repliche, pod helper in sola lettura, `tar` come root in streaming binario | `kubectl cp` perde owner e permessi, richiede tar nel pod e copia SQLite/WAL in modo incoerente |
| Cartella di backup | Dentro il repo, cancellata dal ripristino | Cartella con timestamp fuori da repo e dati di Docker; il ripristino non cancella nulla | La cartella condivisa con Docker e il repo sono rischiosi; il ripristino distruggeva l'unica copia |
| Tipi di risorsa | Lista fissa di 7 tipi | Tutti i tipi da `api-resources`, dump grezzo + copia ripulita | Perdeva ServiceAccount, Role, CronJob, PV, ecc. |
| Helm | Manifest grezzi, Secret `sh.helm.release.*` inclusi | Valori e manifest Helm; ingress-nginx si reinstalla con Helm; oggetti Helm esclusi dalla copia riapplicabile | Evitare conflitti con Helm e Secret inutili |
| Campi runtime | Tolti solo alcuni; restavano `ownerReferences`, `clusterIP`, `volumeName` | Tolti tutti | Un PVC con `volumeName` resta Pending su un cluster nuovo; i Service con `clusterIP` possono confliggere |
| Esito | Stampava "OK" a prescindere | Controllo dei codici di uscita e gate di verifica | Un backup non verificato equivale a nessun backup |
| Oltre il cluster | Niente | Impostazioni, volumi Docker non-K8s, `pg_dumpall`, copia a freddo dei vhdx | Disinstallare Docker Desktop cancella tutto il resto; il vhdx permette il rollback identico |
| Kubeconfig | - | Si salva solo il contesto `docker-desktop` | Il kubeconfig intero contiene credenziali EKS |

Pulizia del 2026-10-06: cancellati gli export del vecchio formato (`ingress-nginx\`, `n8n\`, `ollama\`, `qdrant\`, 23 file non tracciati, Secret inclusi): il loro contenuto e' nel nuovo backup. I vecchi script restano nella storia git (commit `f1db775`, `30799ec`).

## Problemi risolti nel vecchio `backup.ps1`/`restore.ps1`

1. Nessun `--context`: agiva sul cluster corrente (EKS produzione).
2. Backup a caldo con `kubectl cp`: dati incoerenti, owner e permessi persi (n8n gira come uid 1000).
3. Export parziale e con campi runtime residui (`volumeName`, `clusterIP`, `ownerReferences`).
4. Export di `secrets` incluso i Secret delle release Helm (153 KB in `ingress-nginx`), senza `.gitignore`: rischio di commit di Secret in chiaro.
5. Backup dentro il repo e `restore.ps1` che cancellava `volumes\` a fine ripristino.
6. Nessun controllo degli esiti: i passi stampavano "OK" anche in errore.
7. Nessuna verifica del backup, nessun valore Helm, nessun backup dei volumi Docker non-K8s.
8. README non allineato: affermava che il cluster viene resettato a ogni aggiornamento (la documentazione ufficiale dice di no) e indicava un nome di Deployment errato nel troubleshooting.

## Decisioni sulla strumentazione

- **Velero: scartato.** Richiede un object storage (es. MinIO) e il node-agent per tre PVC piccoli (~1 GB). Tar dei PVC e copia del vhdx danno piu' garanzie con meno parti.
- **Flusso binario**: `Start-Process -RedirectStandardOutput/-RedirectStandardInput` collega i file a livello di sistema operativo (verificato con un round-trip tar di 3 MB casuali: SHA256 identico). La redirezione `>` di PowerShell 5.1 altera i byte.
- **Tutte le modifiche dopo una sola conferma**: il piano elenca cosa verra' fermato; con `-DryRun` non si scrive nulla.
- **Rete di sicurezza in `finally`**: helper eliminato e repliche ripristinate anche in caso di errore.
- **Compattare prima di cancellare il backup**: `Optimize-VHD` e' l'unica operazione rischiosa sul disco originale.
- **Aggiornamenti dei Deployment fuori dal backup**: se le immagini cambiano tra backup e ripristino, il ripristino usa quelle salvate (documentato in architecture.md).

## Compatibilita' con ambienti aziendali (revisione degli script)

PSScriptAnalyzer non era installato e non e' stato installato. Revisione con il parser PowerShell (sintassi, verbi approvati, nomi singolari, `ShouldProcess`) e una ricerca mirata di comandi sensibili alle policy: 0 rilievi.

Cosa gli script **non fanno**, cosi' da stare dentro le policy:
- non cambiano la execution policy (`Set-ExecutionPolicy`, `-ExecutionPolicy Bypass`) ne' usano `-EncodedCommand`;
- non si elevano (`-Verb RunAs`): l'installazione di Docker Desktop e `Optimize-VHD` si eseguono a mano da una console elevata;
- non usano `Invoke-Expression`, `Add-Type`, download di file, task schedulati, registro o servizi;
- non installano moduli o strumenti;
- non usano `cmd /c` ne' `Write-Host` (log con `Write-Information`);
- usano solo costrutti .NET compatibili con il Constrained Language Mode, tranne l'impostazione della codifica UTF-8 della console (in `try/catch`) e `[regex]::Escape`, consentito in CLM.

Esecuzione: se la execution policy blocca gli script non firmati, firma i file con il certificato aziendale oppure sblocca i file scaricati con `Unblock-File` e usa `RemoteSigned`. Non aggirare la policy con `-ExecutionPolicy Bypass` negli ambienti gestiti. Gli script non vanno eseguiti su cluster di produzione: usano `-Context` e rifiutano contesti diversi da `docker-desktop`.

I comandi `docker`, `kubectl`, `helm`, `robocopy`, `tar`, `wsl` devono essere consentiti. L'immagine helper `alpine:3.20` viene scaricata da Docker Hub: in ambienti isolati usa `-HelperImage` con un'immagine del registry interno.

## Limiti noti

- Backup e ripristino non sono stati eseguiti dopo la riscrittura degli script: verificati solo con analisi statica e un test locale del flusso binario. La procedura equivalente e' stata eseguita a mano il 2026-10-06 (backup, aggiornamento, verifica); il ripristino non e' mai servito.
- Il ripristino dei volumi Docker e dei vhdx e' documentato ma non automatizzato.
- Un backup creato a mano il 2026-10-06 (solo locale, ignorato da git) e' in formato manuale: `verify-backup.ps1` e `restore.ps1` non lo accettano senza un adattatore (vedi backup-restore.md, sezione 7). `Assert-SafeBackupRoot` rifiuta le cartelle di backup dentro il repo.
- `ConvertFrom-Json` puo' fallire con manifest che hanno chiavi uguali a meno delle maiuscole.
