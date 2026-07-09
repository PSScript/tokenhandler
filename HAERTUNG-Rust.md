# Graph Mail-Poller — Härtungs-Matrix (Rust)

Client-seitige Muster für einen Microsoft-Graph-Postfach-Poller (Poll → Verarbeitung → Move), grob nach Wirkung/Aufwand. **QW** = Quick Win (klein, sofort), **H** = Härtung (strukturell). SDK-Spalte auf den **Rust**-Stack gemünzt.

> **Leitsatz:** Die Graph-API ist Transport, kein Regelsystem — sie meldet Fehler (429/Retry-After), verhindert keine. Selbstmessung, Konfidenz, Adaption und Elastizität leben im Client.

> **Rust:** `azure_identity::ClientSecretCredential` cached/serialisiert Tokens selbst — nicht per Hand gegen `/token`. `reqwest-retry` bzw. eine `tower`-Retry-Schicht respektiert `Retry-After`.

| Fehlerklasse | Symptom | Wo schauen | Beheben (Code) | Gegensteuern | SDK (Rust) | Anwendung |
|---|---|---|---|---|---|---|
| **Token-Refresh-Race** (Cache-Stampede) | ~2-Min-Fenster mit 401, „Bearer null", Cluster an der Token-Ablaufgrenze | Lock um Check+Refresh? Hand-Roll gegen `/token`? | Single-Flight via `tokio::sync::Mutex` + `OnceCell` | AAD-Token-Endpoint nicht fluten | `azure_identity::ClientSecretCredential` | QW: Mutex · H: azure_identity |
| **403 nach Consent als „permanent"** | ~1h-Fenster mit 403 nach Permission-/Cert-Wechsel, selbstheilend | Statusmatrix: 403 permanent? Löst 403 Refresh aus? | Bei 403 **einmal** Cache leeren + neu ziehen + retry, dann permanent | Nach Änderungen proaktiv invalidieren | Credential-Token forciert neu holen | QW: 403→Refresh-once · H: Hooks |
| **Fehlende Transport-Isolation** | Effektive Parallelität < Limiter-Annahme; Lanes bremsen sich | Ein geteilter `reqwest::Client` für beide Apps? Pool? | **Eigener `reqwest::Client` je App** | Lanes physisch trennen | `reqwest::Client` mit `pool_max_idle_per_host = limit` je App | QW: Client pro App · H: Lane-Isolation |
| **Hartcodiertes Concurrency-Limit** | Durchsatz lässt Reserve liegen (Kante ~8, Cap 4) — oder Überlauf | Konstante gemessen oder geraten? | Fixen Cap durch Rolling-Floor ersetzen (probet hoch + backt ab) | `calibration.json` als Startwert, drift-folgend | `governor` (Rate) + eigener AIMD; `tower::limit` | QW: messen&setzen · H: Rolling-Floor+SD |
| **Kein Gedächtnis / kein geteilter State** | Lernt bei jedem Neustart neu; N Instanzen überziehen den geteilten Bucket | State nur im Speicher? Kein gemeinsamer Store? | Limit-State (Mittel/SD/Floor) persistieren + laden | Geteilter Floor über die Flotte | `redis` / `deadpool-redis` — **nur Limit-State, nie Tokens** | QW: Redis-Persistenz · H: geteilter State |
| **429 vs 503/504 vermischt** | Parallelität schrumpft bei Infra-/LB-Ereignissen | Rufen 503/504 dasselbe AIMD wie 429? | 429=AIMD; 503/504=Infra transient (nur Backoff, eigener Zähler) | Getrennte Metriken (Auth vs. Infra) | `match resp.status()` — distinkte Klassifikation | QW: Zweig trennen · H: getrennte Telemetrie |
| **Retry-After nicht abschließend** | Über-Warten oder Hämmern | Wartezeit-Berechnung: Retry-After verbindlich? | Retry-After **ersetzt** Backoff; eigener Backoff nur Fallback | — | `reqwest-retry` (`RetryTransientMiddleware`) / `tower` retry | QW: 1-Zeilen-Fix · H: Retry-Policy |
| **Write-Fanout ohne QoS** | Moves throtteln unter Last; Poll verhungert | Move pro Task vs. gebündelt? Poll-Slot reserviert? | `tokio::sync::Semaphore(carrier)` + Poll-Slot | Writes bündeln; 2-App-Lane-Trennung | `tokio::sync::Semaphore`; ggf. Graph `$batch` | QW: Semaphore · H: Batch-Writer |
| **App-Hopping verwischt Lane** *(gering)* | WORK-Requests auf POLL-App bei Dauer-Parken | Routing: hoppt WORK auf App-A? | Reserve-Slot schützt den Poll bereits | Hopping für POLL-Lane optional aus | Lane-Affinität mit Reserve-Threshold | H: bewusst konfigurieren |

**Querschnitt:** *Messen statt raten* — Kanten (Bucket-Kapazität, Retry-After-Verteilung, Drift) sind tenant-/lastabhängig und unveröffentlicht; die client-seitige Kalibrierung ist die einzige Quelle der Wahrheit. Buckets sind **per App × Postfach** (zwei Apps = zwei unabhängige Buckets; nicht ungeprüft summieren). 503/504 oft Infrastruktur (LB), nicht Graph-Throttling.
