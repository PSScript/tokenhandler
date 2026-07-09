# Graph Mail-Poller — Härtungs-Matrix (Python)

Client-seitige Muster für einen Microsoft-Graph-Postfach-Poller (Poll → Verarbeitung → Move), grob nach Wirkung/Aufwand. **QW** = Quick Win (klein, sofort), **H** = Härtung (strukturell). SDK-Spalte auf den **Python**-Stack gemünzt.

> **Leitsatz:** Die Graph-API ist Transport, kein Regelsystem — sie meldet Fehler (429/Retry-After), verhindert keine. Selbstmessung, Konfidenz, Adaption und Elastizität leben im Client.

> **Python:** `msal` (thread-sicherer Token-Cache) bzw. `azure-identity` `ClientSecretCredential` nehmen — nicht per Hand `requests.post` gegen `/token`. `urllib3 Retry(respect_retry_after_header=True)` respektiert Retry-After ab Werk.

| Fehlerklasse | Symptom | Wo schauen | Beheben (Code) | Gegensteuern | SDK (Python) | Anwendung |
|---|---|---|---|---|---|---|
| **Token-Refresh-Race** (Cache-Stampede) | ~2-Min-Fenster mit 401, „Bearer None", Cluster an der Token-Ablaufgrenze | Lock um Check+Refresh? Hand-`requests.post /token`? | Single-Flight-Lock (`threading.Lock`) um Check-and-Refresh | AAD-Token-Endpoint nicht fluten | `msal.ConfidentialClientApplication` / `azure-identity` | QW: Lock · H: MSAL |
| **403 nach Consent als „permanent"** | ~1h-Fenster mit 403 nach Permission-/Cert-Wechsel, selbstheilend | Statusmatrix: 403 permanent? Löst 403 Refresh aus? | Bei 403 **einmal** invalidieren + neu ziehen + retry, dann permanent | Nach Änderungen proaktiv invalidieren | msal `acquire_token_for_client` (Cache leeren) | QW: 403→Refresh-once · H: Hooks |
| **Fehlende Transport-Isolation** | Effektive Parallelität < Limiter-Annahme; Lanes bremsen sich | Ein modul-globaler `requests.Session` für beide Apps? `pool_maxsize`? | Eigene `Session`/`httpx.Client` je App | Lanes physisch trennen | `requests.Session` + `HTTPAdapter(pool_maxsize=limit)` je App | QW: Session pro App · H: Lane-Isolation |
| **Hartcodiertes Concurrency-Limit** | Durchsatz lässt Reserve liegen (Kante ~8, Cap 4) — oder Überlauf | `MAX_CONCURRENCY_PER_APP`: gemessen oder geraten? | Fixen Cap durch Rolling-Floor ersetzen (probet hoch + backt ab) | `calibration.json` als Startwert, drift-folgend | eigener AIMD/Rolling-Floor; `aiolimiter` (Rate) | QW: messen&setzen · H: Rolling-Floor+SD |
| **Kein Gedächtnis / kein geteilter State** | Lernt bei jedem Neustart neu; N Instanzen überziehen den geteilten Bucket | State nur im Speicher? Kein gemeinsamer Store? | Limit-State (Mittel/SD/Floor) persistieren + laden | Geteilter Floor über die Flotte | `redis-py` — **nur Limit-State, nie Tokens** | QW: Redis-Persistenz · H: geteilter State |
| **429 vs 503/504 vermischt** | Parallelität schrumpft bei Infra-/LB-Ereignissen | Rufen 503/504 dasselbe AIMD wie 429? | 429=AIMD; 503/504=Infra transient (nur Backoff, eigener Zähler) | Getrennte Metriken (Auth vs. Infra) | eigene Klassifikation im Retry-Layer | QW: Zweig trennen · H: getrennte Telemetrie |
| **Retry-After nicht abschließend** | Über-Warten oder Hämmern | Wartezeit-Berechnung: Retry-After verbindlich? | Retry-After **ersetzt** Backoff; eigener Backoff nur Fallback | — | `urllib3 Retry(respect_retry_after_header=True)` / `tenacity` | QW: 1-Zeilen-Fix · H: Retry-Policy |
| **Write-Fanout ohne QoS** | Moves throtteln unter Last; Poll verhungert | Move pro Worker vs. gebündelt? Poll-Slot reserviert? | `threading.Semaphore(carrier)` / `asyncio.Semaphore` + Poll-Slot | Writes bündeln; 2-App-Lane-Trennung | Semaphore; ggf. Graph `$batch` (JSON) | QW: Semaphore · H: Batch-Writer |
| **App-Hopping verwischt Lane** *(gering)* | WORK-Requests auf POLL-App bei Dauer-Parken | Pool-Routing: hoppt WORK auf App-A? | Reserve-Slot schützt den Poll bereits | Hopping für POLL-Lane optional aus | Lane-Affinität mit Reserve-Threshold | H: bewusst konfigurieren |

**Querschnitt:** *Messen statt raten* — Kanten (Bucket-Kapazität, Retry-After-Verteilung, Drift) sind tenant-/lastabhängig und unveröffentlicht; die client-seitige Kalibrierung ist die einzige Quelle der Wahrheit. Buckets sind **per App × Postfach** (zwei Apps = zwei unabhängige Buckets; nicht ungeprüft summieren). 503/504 oft Infrastruktur (LB), nicht Graph-Throttling.
