# tokenhandler — Graph-Throttling-Scaffold für den Mail-Handler

Referenz-Gerüst (Java + Python, klassengleich) für die Ablösung des naiven
Polling-/Retry-Verhaltens im E-Mail-Handler gegen Microsoft Graph.
Die Dateien sind **Scaffolding zum Verstehen und Übertragen**, kein
Drop-in-Ersatz — die Fachlogik gehört in `InboxPoller.process()`.

## Problemstellung (Ist-Zustand)

1. **401 ohne Backoff** — enge Retry-Schleife mit abgelaufenem Token.
2. **503 ohne Lastreduktion** — die Thread-Anzahl bleibt konstant, obwohl der
   Dienst Gegendruck signalisiert.
3. **Graph-Limit ignoriert** — Outlook via Graph erlaubt **max. 4 gleichzeitige
   Requests pro App-ID und Postfach** sowie **10.000 Requests / 10 Minuten pro
   App-ID und Postfach**.
4. **App-ID-Pooling ohne Zustandstrennung** — Token-Cache, Drossel-Zustand und
   Parallelität werden zwischen beiden App-IDs geteilt; eine gedrosselte App
   vergiftet damit die zweite.

## Architektur

Beide Implementierungen (`GraphMailPollerScaffold.java`,
`graph_mail_poller_scaffold.py`) sind Klasse für Klasse identisch aufgebaut:

| Klasse | Aufgabe |
| --- | --- |
| `TokenProvider` | Client-Credentials-Cache **pro App**, Single-Flight-Refresh, 5-Minuten-Skew, Backoff auch gegen AAD, `invalidate()` bei 401 |
| `AdaptiveLimiter` | Concurrency-Gate **pro App**: AIMD (503 → halbieren, +1 nach 25 sauberen Antworten), Obergrenze 4, optional reservierter POLL-Slot |
| `GraphApp` | **Die Isolationsgrenze.** Genau ein HTTP-Versuch, Ergebnis klassifizieren, nur den eigenen Zustand anfassen |
| `GraphAppPool` | Routing (Lane-Affinität → Auslastung) und Retry-Schleife mit App-Hopping zwischen den Versuchen |
| `InboxPoller` | 25er-Batch aus dem Posteingang, Overlap-Guard, Variante A/B, Worker-Pool |

Kernentscheidung: **sämtlicher Drossel-Zustand lebt in `GraphApp`**, nie im
Pool. Ein 503 auf App-A halbiert nur A; App-B läuft mit vollen 4 Slots weiter.
Worker-Threads (Default 8) dürfen die Graph-Slots bewusst übersteigen — die
Pro-App-Limiter sind die einzige Wahrheit für die Leitungs-Parallelität, und
ein Slot wird nur während des laufenden Requests gehalten, nie beim Schlafen.

## Statuscode-Matrix

| Status | Verhalten |
| --- | --- |
| 401 | Token invalidieren, Refresh erzwingen, Retry mit Full-Jitter-Backoff (Backoff greift auch, wenn der Token-Endpoint selbst drosselt) |
| 429 | `Retry-After` strikt respektieren; verlangt der Server ≥ 10 s, wird die App **geparkt** und der Pool nutzt die Schwester-App |
| 503 / 504 | AIMD **auf dieser App**: Parallelität halbieren (Untergrenze 1) + Backoff; Erholung mit +1 nach 25 sauberen Antworten |
| übrige 5xx | Backoff mit Jitter, Retry (ggf. auf der Schwester-App) |
| übrige 4xx | permanent — `PermanentGraphError`/`-Exception`, sofortiger Abbruch der Retry-Schleife |

Backoff: `uniform(0, min(60 s, 1 s · 2^Versuch))` (Full Jitter),
`Retry-After` hat immer Vorrang und wird bei 300 s gekappt.

## Variante A — isRead-Claim (`CLAIM_MODE=isread`, Default)

`$filter=receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false` mit
`$orderby=receivedDateTime asc` (FIFO; zur `$filter`+`$orderby`-Eigenheit
siehe Encoding-Konventionen), In-Memory-Claim-Set gegen Poll-Überlappung
(Polling alle *n* Sekunden, `isRead` kippt erst nach der Verarbeitung),
nach Verarbeitung `PATCH isRead=true`.

## Variante B — QoS-Polling-Lane + Mover (`CLAIM_MODE=move`)

* Der Poller holt Top-25 aus dem Posteingang (**ohne Filter** — der
  Posteingang selbst ist die Warteschlange, `$orderby=receivedDateTime asc`
  macht daraus eine FIFO-Queue) und verschiebt jede Mail sofort nach
  `PROCESSING_FOLDER` (Default `Processing`, wird bei Bedarf angelegt).
* **Der Move ist der Claim**: atomar pro Mail. Verliert eine zweite Instanz
  das Race, antwortet Graph mit 404 (`ErrorItemNotFound`) — die Mail wird
  übersprungen. Damit ist Variante B ohne weiteres mehrinstanzfähig und
  überlebt Neustarts (kein In-Memory-Zustand nötig, das Set dient nur noch
  als Guard innerhalb des Fetch→Move-Fensters).
* **QoS**: Die POLL-Lane bevorzugt App-A und hält dort **einen reservierten
  Slot** — Worker (WORK-Lane, bevorzugt App-B) können den letzten Slot von
  App-A nie belegen. Selbst wenn App-A per AIMD auf Limit 1 gedrosselt ist,
  gehört dieser eine Slot exklusiv dem Polling: **das Polling verhungert
  nie**. Fällt die bevorzugte App aus (geparkt), greift automatisch die
  Schwester-App.
* **ID-Falle**: Die Message-ID **ändert sich beim Move** — außer man setzt
  durchgängig `Prefer: IdType='ImmutableId'` (Konvention aus
  `Resend-GraphReplay`, dort beim MIME-Create). Das Scaffold setzt den Header
  zentral auf **allen** Message-Requests und übernimmt die ID zusätzlich
  defensiv aus der Move-Response. Niemals Immutable- und Standard-IDs mischen.
* **Budget-Rechnung** (Worst Case, 15-s-Intervall, volle 25er-Batches):
  40 Polls + 1.000 Moves + 2.000 Worker-Calls ≈ **3.040 Requests / 10 min** —
  deutlich unter dem 10k-Kontingent *einer* App. Die Moves laufen im Scaffold
  sequenziell im Poller; bei Bedarf sind sie über die POLL-Lane parallelisierbar
  (bis zu 4 Slots auf App-A).
* Nach der Verarbeitung markiert das Scaffold `isRead=true` im
  Processing-Ordner; alternativ weiter nach `Done` verschieben oder löschen —
  bewusst identisch zu Variante A gehalten, damit `process()` austauschbar bleibt.

## Encoding-Konventionen (Referenz: `PSScript/Resend-GraphReplay`)

* Die Referenz-Skripte bauen OData-Parameter als **Roh-String mit
  Leerzeichen** (`$filter=receivedDateTime ge 2026-…Z and …`, Zeitstempel UTC
  `yyyy-MM-ddTHH:mm:ssZ`) — `Invoke-RestMethod` übernimmt das
  Percent-Encoding implizit.
* **Delta zu Java**: `java.net.http` / `URI.create` verweigert rohe
  Leerzeichen → Leerzeichen als `%20` (nie `+`), Werte mit Sonderzeichen über
  den `enc()`-Helper (`URLEncoder` + `+`→`%20`). Python `requests` encodiert
  über das `params=`-Dict selbst.
* Wellknown-Folder kleingeschrieben (`inbox`, `sentitems`, …) — wie die
  Ordnernamen-Normalisierung im Referenz-Skript.
* **`$orderby=receivedDateTime asc`** auf allen Poll-Queries — FIFO, älteste
  zuerst; ohne explizites `$orderby` ist die Reihenfolge nicht garantiert.
  Graph-Eigenheit bei `$filter` **+** `$orderby`: die `$orderby`-Properties
  müssen im `$filter` enthalten sein und dort **vor** den übrigen Bedingungen
  stehen — sonst HTTP 400 (`InefficientFilter`). Variante A löst das mit
  `receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false`.
* `Prefer: IdType='ImmutableId'` in Single-Quote-Schreibweise wie im
  Referenz-Skript, hier zentral in `GraphApp.singleAttempt()` gesetzt.
* Token-Handling wie `Get-GraphToken`: Cache mit 5-Minuten-Skew,
  `client_credentials` gegen `…/oauth2/v2.0/token` — hier erweitert um
  Single-Flight-Lock und Backoff gegen AAD-Drosselung.
* 429-Handling wie im Referenz-Skript (`Retry-After` respektieren), hier
  erweitert um 401-Refresh-Pfad, 503-AIMD und Full-Jitter-Backoff.

## Ownership-Modell (Rust-Analogie)

Das In-Memory-Claim-Set ist eine Ownership-Tabelle im Rust-Sinn: pro Mail-ID
existiert genau **ein** Owner. Der Poller nimmt Ownership per *move* (Claim),
transferiert sie beim Submit an einen Worker, und der Worker gibt sie im
`finally` wieder frei (*drop*) — ein Double-Claim scheitert wie ein zweiter
`&mut`-Borrow. Für Observability lässt sich das Set zu einer Hashtable
`{id → owner, since, state}` erweitern; genau so macht es
`Demo-GraphThrottling.ps1`. In Variante B übernimmt Graph selbst die Rolle
des Borrow-Checkers: ein verlorenes Move-Race wird nicht zum Compilerfehler,
sondern zu HTTP 404.

## Demo: `Demo-GraphThrottling.ps1` (PowerShell + WPF)

Interaktive Demo gegen einen **Testtenant** — alle Variablen (Tenant, Apps,
Postfach, Ordner) stehen oben im Skript. Der Mover verschiebt Mails von
`$SourceFolderName` (`Eingehend`) nach `$TargetFolderName` (`Verarbeitet`),
FIFO per `$orderby`, mit Runspace-Workern und der Ownership-Hashtable.

Provozierte Fehler und ihre sichtbare Behandlung:

| Fehler | Art | Demonstration |
| --- | --- | --- |
| 401 | **echt** | Token wird absichtlich korrumpiert → Invalidate, Single-Flight-Refresh, Backoff, Retry |
| 404 | **echt** | Doppel-Move derselben Mail (Claim-Race) — bewusst ohne `Prefer: IdType='ImmutableId'`, um die Mutable-ID-Falle zu zeigen |
| 429 / 503 | **echt** | Concurrency-Burst: `-BurstSize` (Default 10) parallele Requests **ohne** lokalen Limiter verletzen das 4er-Limit pro App+Postfach — Graph drosselt echt (meist 429 `MailboxConcurrency`, je nach Backend/Operation 503) |
| 429 / 503 | **simuliert** | Chaos-Injektion (`-ChaosRate`, Default 30 %) liefert den anhaltenden Drossel-Strom für die Mover-Phase — AIMD-Halbierung, Retry-After-Parken, App-Hopping — ohne das Limit dauerhaft zu verletzen |

Ausgabe-Konvention: **Gelb** = was passiert ist, **Cyan** = `Resolving with: …`
(die Gegenmaßnahme), Grün = Erfolg, Rot = permanent, Magenta = Phasen.
Statusbars: WPF-Dashboard (InFlight-Threads, AIMD-Limit, Token-Restlaufzeit
pro App, Counter, Live-Log) in einem eigenen STA-Runspace; parallel dazu
`Write-Progress`-Balken in der Konsole. `-NoGui` für Server Core,
`-SkipSeed` nutzt vorhandene Mails, `-Cleanup` räumt die Demo-Mails ab,
`-BurstSize`/`-NoBurst` steuern den echten Concurrency-Burst.

```powershell
.\Demo-GraphThrottling.ps1                     # WPF + Konsole, 12 Mails, Chaos 30 %
.\Demo-GraphThrottling.ps1 -NoGui -ChaosRate 0.5
.\Demo-GraphThrottling.ps1 -SkipSeed -Cleanup
```

## Konfiguration (ENV)

| Variable | Default | Bedeutung |
| --- | --- | --- |
| `TENANT_ID` | `<tenant-guid>` | Entra-ID-Tenant |
| `MAILBOX_UPN` | `test@contoso.com` | Überwachtes Postfach |
| `GRAPH_APP1_ID` / `GRAPH_APP1_SECRET` | Platzhalter | App-A (POLL-Lane bevorzugt, 1 reservierter Slot) |
| `GRAPH_APP2_ID` / `GRAPH_APP2_SECRET` | Platzhalter | App-B (WORK-Lane bevorzugt) |
| `WORKER_THREADS` | `8` | Verarbeitungs-Threads (≠ Graph-Parallelität!) |
| `BATCH_SIZE` | `25` | `$top` pro Poll |
| `POLL_INTERVAL_SECONDS` | `15` | Poll-Intervall |
| `CLAIM_MODE` | `isread` | `isread` = Variante A, `move` = Variante B |
| `PROCESSING_FOLDER` | `Processing` | Zielordner des Movers (Variante B) |

Beide App-Registrierungen benötigen `Mail.ReadWrite` (Application) — idealerweise
per Application Access Policy auf das Postfach eingeschränkt.

## Build & Run

```bash
# Java (JDK 11+, Jackson nur für JSON)
javac -encoding UTF-8 \
      -cp jackson-databind-2.17.2.jar:jackson-core-2.17.2.jar:jackson-annotations-2.17.2.jar \
      GraphMailPollerScaffold.java
java  -cp .:jackson-databind-2.17.2.jar:jackson-core-2.17.2.jar:jackson-annotations-2.17.2.jar \
      GraphMailPollerScaffold

# Python (3.9+)
pip install requests
python3 graph_mail_poller_scaffold.py
```

## Einordnung

Zwei App-Registrierungen verdoppeln die **Pro-App-Kontingente** (effektiv
8 parallele Requests und 2 × 10k/10 min gegen dasselbe Postfach). Der
Mailbox-seitige Schutz von Microsoft existiert darüber hinaus weiterhin —
App-Pooling ist Kapazität, kein Freibrief: `Retry-After` bleibt in jedem
Fall bindend.
