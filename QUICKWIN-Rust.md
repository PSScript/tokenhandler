# Quick-Win (Rust) — „Weniger ist mehr": Write-Concurrency begrenzen

## Das Problem in einem Satz
Ein Read ist billig (ein `$top=25` holt 25 Mails in **einem** Request), aber jede
fertige Mail erzeugt **einen eigenen Move**. Viele parallele `tokio`-Tasks ⇒ viele
gleichzeitige Writes gegen **dasselbe Postfach** ⇒ das MailboxConcurrency-Limit
(per App × Postfach) kippt, 429 hagelt — **mehr Parallelität macht es schlechter**.

## Die eine Änderung
Write-Durchsatz global mit einem `Semaphore` auf die **gemessene** Carrier-Concurrency
begrenzen; einen Slot für den Poll reservieren.

**Vorher**
```rust
// jeder Task feuert direkt seinen eigenen /move
for id in ids { tokio::spawn(move_message(client.clone(), id)); }
```

**Nachher**
```rust
use std::sync::Arc;
use tokio::sync::Semaphore;

let carrier: usize = calib.carrier_concurrency;      // aus calibration.json, gemessen
let write_gate = Arc::new(Semaphore::new(carrier));  // globaler Write-Durchsatz

for id in ids {
    let permit = write_gate.clone().acquire_owned().await.unwrap();
    let c = client.clone();
    tokio::spawn(async move {
        let _p = permit;                    // hält den Slot bis Task-Ende
        move_message(&c, id).await;
    });
}
```

## Weitere Härtungspunkte (idiomatisch Rust)
- **Token:** `azure_identity::ClientSecretCredential` cached und serialisiert selbst —
  nicht per Hand gegen `/token` gehen. Falls doch: Single-Flight via
  `tokio::sync::Mutex` + `OnceCell`.
- **Transport-Isolation:** **eigener `reqwest::Client` pro App** (eigener Connection-Pool),
  `pool_max_idle_per_host` = App-Limit.
- **Retry-After:** `reqwest-retry` (`RetryTransientMiddleware`) bzw. eine `tower`-Retry-
  Schicht, die den `Retry-After`-Header respektiert — nicht zusätzlich backoffen.
- **Adaptives Limit:** `governor` (Rate) + eigener AIMD/Rolling-Floor; `tower::limit`.

## Warum „weniger ist mehr"
Durchsatz = **Goodput(N) = N · (1 − p(N))**. Weil die Grenze ein **Bucket-Overflow** ist
(Kapazität c, der (c+1)-te läuft über), gilt `Goodput ≈ min(N, c)`: unterhalb von c
gewinnst du linear, ab c nur noch Fehler + Wartezeit. Das Optimum liegt **bei c** — der
Kalibrier-Sweep liefert es als Zahl (`recommendedCarrierConcurrency`).
