//! Autoritativer Token-Refresh-Handler (Client-Credentials, pro App x Scope).
//!
//! Immun gegen parallele Anfragen (Single-Flight) — ohne ins Gegenteil zu kippen.
//! Refreshs haben BUDGET + RETRY. Sieben Invarianten wie in der Java/Python-Referenz:
//!   1. Fast Path lock-frei*   2. Single-Flight   3. Refresh-Ahead
//!   4. Budget                 5. Circuit Breaker 6. Retry+Backoff (Retry-After)
//!   7. Wait via Rest-gültiges Token statt Dauer-Block
//!
//! (*Fast Path via kurzem std-RwLock-Read; der eigentliche Refresh serialisiert
//!  über eine tokio::Mutex — nur der Lock-Halter zieht, der Rest sieht per
//!  Double-Check das frische Token. Der `fetch` sollte an azure_identity
//!  (ClientSecretCredential) delegieren.)
//!
//! Abhängigkeiten: tokio (rt, time, sync), fastrand (Jitter).

use std::future::Future;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

#[derive(Clone)]
pub struct Token {
    pub value: String,
    pub expires_at: Instant,
}

/// Fehler des Fetch: `permanent` => 400/401 (nicht wiederholen);
/// sonst transient (429/5xx), `retry_after` optional.
pub struct FetchError {
    pub retry_after: Option<Duration>,
    pub permanent: bool,
    pub msg: String,
}

struct Guard {
    last_start: Instant,
    failures: u32,
    circuit_until: Instant,
}

pub struct AuthoritativeTokenHandler<F> {
    current: RwLock<Option<Token>>, // Fast Path: kurzer Read-Lock
    guard: Mutex<Guard>,            // serialisiert NUR den Refresh (Single-Flight via Double-Check)
    fetch: F,
    skew: Duration,
    min_gap: Duration,
    max_attempts: u32,
    circuit_threshold: u32,
    circuit_cooldown: Duration,
    backoff_base: Duration,
    backoff_cap: Duration,
}

impl<F, Fut> AuthoritativeTokenHandler<F>
where
    F: Fn() -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<Token, FetchError>> + Send,
{
    pub fn new(fetch: F) -> Arc<Self> {
        let past = Instant::now() - Duration::from_secs(3600);
        Arc::new(Self {
            current: RwLock::new(None),
            guard: Mutex::new(Guard { last_start: past, failures: 0, circuit_until: past }),
            fetch,
            skew: Duration::from_secs(300),
            min_gap: Duration::from_secs(10),
            max_attempts: 5,
            circuit_threshold: 4,
            circuit_cooldown: Duration::from_secs(60),
            backoff_base: Duration::from_secs(1),
            backoff_cap: Duration::from_secs(30),
        })
    }

    /// Liefert ein gültiges Bearer-Token. Blockiert im Normalbetrieb nie.
    pub async fn get(self: &Arc<Self>) -> Result<String, String> {
        let now = Instant::now();
        // (1) Fast Path + (3) Refresh-Ahead in einem kurzen Read-Lock.
        {
            let cur = self.current.read().unwrap();
            if let Some(t) = cur.as_ref() {
                if now < t.expires_at - self.skew {
                    return Ok(t.value.clone()); // voll frisch
                }
                if now < t.expires_at {
                    let value = t.value.clone();
                    drop(cur);
                    let me = self.clone(); // (3) async erneuern, altes Token bedienen
                    tokio::spawn(async move { let _ = me.refresh_single_flight().await; });
                    return Ok(value);
                }
            }
        }
        // hart abgelaufen -> auf Refresh warten
        self.refresh_single_flight().await
    }

    /// 401: Token wurde abgelehnt -> hart invalidieren.
    pub fn invalidate(&self) {
        *self.current.write().unwrap() = None;
    }

    async fn refresh_single_flight(self: &Arc<Self>) -> Result<String, String> {
        let mut g = self.guard.lock().await; // (2) serialisiert den Refresh
        let now = Instant::now();

        // Double-Check: hat ein anderer Task inzwischen erneuert? -> Single-Flight.
        if let Some(t) = self.current.read().unwrap().as_ref() {
            if now < t.expires_at - self.skew {
                return Ok(t.value.clone());
            }
        }
        if now < g.circuit_until {
            return self.stale_or_err("Circuit offen"); // (5)
        }
        if now < g.last_start + self.min_gap {
            return self.stale_or_err("Budget: zu früh"); // (4)
        }
        g.last_start = now;

        // (6) Retry + Backoff, Retry-After respektieren
        let mut last = String::from("unbekannt");
        for attempt in 0..self.max_attempts {
            match (self.fetch)().await {
                Ok(t) => {
                    let v = t.value.clone();
                    *self.current.write().unwrap() = Some(t);
                    g.failures = 0;
                    g.circuit_until = now;
                    return Ok(v); // Erfolg an alle Waiter (die queuen am Lock)
                }
                Err(e) if !e.permanent => {
                    last = e.msg;
                    let d = e.retry_after.unwrap_or_else(|| self.backoff(attempt));
                    tokio::time::sleep(d).await;
                }
                Err(e) => { last = e.msg; break; } // permanent (400/401)
            }
        }
        g.failures += 1;
        if g.failures >= self.circuit_threshold {
            g.circuit_until = Instant::now() + self.circuit_cooldown; // (5) Circuit öffnen
        }
        Err(format!("Token-Refresh fehlgeschlagen: {last}"))
    }

    fn stale_or_err(&self, why: &str) -> Result<String, String> {
        if let Some(t) = self.current.read().unwrap().as_ref() {
            if Instant::now() < t.expires_at {
                return Ok(t.value.clone()); // (7) Rest-gültig bedienen statt blocken
            }
        }
        Err(format!("kein gültiges Token ({why})"))
    }

    fn backoff(&self, attempt: u32) -> Duration {
        let factor = 1u64 << attempt.min(20);
        let cap_ms = self.backoff_cap.as_millis().min(self.backoff_base.as_millis() * factor as u128) as u64;
        Duration::from_millis(fastrand::u64(0..=cap_ms)) // Full Jitter
    }
}
