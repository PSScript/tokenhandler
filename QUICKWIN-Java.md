# Quick-Win (Java) — „Weniger ist mehr": den Write-Fanout begrenzen

## Das Problem in einem Satz
Ein Read ist billig (ein `$top=25` holt 25 Mails in **einem** Request), aber jede
fertig verarbeitete Mail erzeugt **einen eigenen Move** (Posteingang → Verarbeitet).
N Worker ⇒ N gleichzeitige Writes gegen **dasselbe Postfach** ⇒ das
4er-MailboxConcurrency-Limit (per App × Postfach) kippt, 429 hagelt — und **jeder
zusätzliche parallele Write macht es schlechter, nicht besser**.

## Die eine Änderung
Worker-Pool **und** einen gemeinsamen `Semaphore` auf die **gemessene** Carrier-
Concurrency dimensionieren; einen Slot für den Poll reservieren.

**Vorher**
```java
this.workers = Executors.newFixedThreadPool(workerThreads);   // z.B. 12
// jeder Worker feuert direkt seinen eigenen /move
```

**Nachher**
```java
int carrier = cfg.carrierConcurrency;                 // aus calibration.json, gemessen
this.writeGate = new Semaphore(carrier);              // globaler Write-Durchsatz
this.workers   = Executors.newFixedThreadPool(carrier + 1);   // + 1 fuer den Poll

// im Worker, unmittelbar vor dem Move:
writeGate.acquire();
try {
    move(messageId, targetFolderId);
} finally {
    writeGate.release();
}
```

**Bonus (eine Zeile):** dem `HttpClient` einen gebundenen Executor geben, damit die
asynchronen Sends nicht selbst einen unbeschränkten Pool aufmachen:
```java
HttpClient.newBuilder()
    .executor(Executors.newFixedThreadPool(carrier + 1))
    .build();
```

## Warum das mehr Durchsatz bringt
Der Durchsatz ist **Goodput(N) = N · (1 − p(N))** — parallele Requests mal
Erfolgswahrscheinlichkeit. Diese Kurve hat ein **Maximum am Knick** der p(N)-Kurve
(≈ dem Limit), nicht an ihrem Ende. Jeder Move oberhalb des Limits kostet dich einen
Retry-Zyklus **plus** die Retry-After-Wartezeit; die verlorene Zeit ist größer als der
Gewinn durch mehr Parallelität. Weniger gleichzeitige Writes ⇒ weniger selbst erzeugte
429 ⇒ **mehr erfolgreiche Moves pro Minute**.

## Die Zahl kommt aus der Messung, nicht aus dem Bauch
`carrier` = `calibration.json → recommendedCarrierConcurrency` (aus dem Kalibrier-Sweep
gegen den Testtenant). Kein hartcodiertes 4 — der Rolling-Floor-Regler zieht die Zahl in
Produktion selbst nach, wenn das Backend sie über die Zeit verschiebt.
