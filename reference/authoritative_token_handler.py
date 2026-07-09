"""
Autoritativer Token-Refresh-Handler (Client-Credentials, pro App x Scope).

Immun gegen parallele Anfragen (Single-Flight) — OHNE ins Gegenteil zu kippen
(keine Über-Serialisierung, kein Dauer-Block, kein Retry-Stampede, kein
AAD-Hämmern). Refreshs haben BUDGET + RETRY.

Sieben Invarianten (identisch zur Java-Referenz):
  1. Fast Path lock-frei      2. Single-Flight        3. Refresh-Ahead
  4. Budget (min. Abstand)    5. Circuit Breaker      6. Retry + Backoff (Retry-After)
  7. Wait-Timeout + Stale

Der eigentliche `fetch` sollte an MSAL / azure-identity (ClientSecretCredential)
delegieren — die cachen selbst. Dieser Handler legt die autoritativen Garantien
obendrauf.  Für den 15-Zeilen-Aha-Moment: siehe token_handler_minimal.py.
"""
import time
import random
import threading
from concurrent.futures import ThreadPoolExecutor, TimeoutError as _FutTimeout


class RetryableAuthError(Exception):
    """Transient (429/5xx). retry_after in Sekunden oder None (-> eigener Backoff)."""
    def __init__(self, msg, retry_after=None):
        super().__init__(msg)
        self.retry_after = retry_after


class AuthoritativeTokenHandler:
    def __init__(self, fetch, *, skew=300, min_refresh_gap=10, max_attempts=5,
                 backoff_base=1.0, backoff_cap=30.0, wait_timeout=30.0,
                 circuit_threshold=4, circuit_cooldown=60.0):
        # fetch: () -> (value: str, expires_at_epoch: float); RetryableAuthError bei 429/5xx,
        #        sonst beliebige Exception (permanent, z. B. 400/401 = falsches Secret).
        self._fetch = fetch
        self._skew, self._gap, self._max = skew, min_refresh_gap, max_attempts
        self._bbase, self._bcap, self._wait = backoff_base, backoff_cap, wait_timeout
        self._cth, self._ccd = circuit_threshold, circuit_cooldown

        self._current = None            # (value, exp) — atomarer Ref-Read = lock-frei (CPython)
        self._lock = threading.Lock()
        self._inflight = None           # Future | None  (Single-Flight)
        self._last_start = 0.0          # Budget
        self._fails = 0                 # Circuit
        self._circuit_until = 0.0       # Circuit
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="token-refresh")

    # ---- öffentliche API ---------------------------------------------------
    def get(self) -> str:
        cur, now = self._current, time.time()
        if cur and now < cur[1] - self._skew:        # (1) voll frisch -> lock-frei
            return cur[0]
        if cur and now < cur[1]:                     # (3) Refresh-Ahead: gültig, aber bald fällig
            with self._lock:
                self._start_if_eligible(now)
            return cur[0]                            #     altes Token weiter bedienen (nicht blocken)
        return self._await_refresh(now)              # hart abgelaufen -> warten

    def invalidate(self):                            # 401: Token wurde abgelehnt
        with self._lock:
            self._current = None

    def close(self):
        self._pool.shutdown(wait=False)

    # ---- intern ------------------------------------------------------------
    def _await_refresh(self, now):
        with self._lock:
            cur = self._current
            if cur and now < cur[1] - self._skew:            # Double-Check
                return cur[0]
            self._start_if_eligible(now)
            if self._inflight is None:                        # Budget/Circuit verweigern Start
                if cur and now < cur[1]:
                    return cur[0]                             # (7) Rest-gültiges Token bedienen
                raise RuntimeError("Token-Refresh gesperrt (Budget/Circuit) und kein gültiges Token")
            fut = self._inflight                              # (2) an laufenden Refresh anhängen
        try:
            return fut.result(timeout=self._wait)
        except _FutTimeout:
            cur = self._current
            if cur and time.time() < cur[1]:                  # (7) hängt -> stale bedienen
                return cur[0]
            raise RuntimeError("Token-Refresh Timeout")

    def _start_if_eligible(self, now):                        # MUSS unter _lock laufen
        if self._inflight is not None:            return      # (2) einer reicht
        if now < self._circuit_until:             return      # (5) Circuit offen -> kein AAD-Call
        if now < self._last_start + self._gap:    return      # (4) Budget: zu früh
        self._last_start = now
        fut = self._pool.submit(self._run_refresh_with_retry)
        fut.add_done_callback(self._on_done)                  # Future freigeben (kein Poisoned-Future)
        self._inflight = fut

    def _on_done(self, _fut):
        with self._lock:
            self._inflight = None

    def _run_refresh_with_retry(self) -> str:
        last = None
        for attempt in range(self._max):
            try:
                value, exp = self._fetch()                    # Delegat: MSAL / azure-identity
                with self._lock:
                    self._current = (value, exp)
                    self._fails = 0
                    self._circuit_until = 0.0
                return value                                  # Erfolg an alle Waiter
            except RetryableAuthError as re:                  # (6) 429/5xx
                last = re
                time.sleep(re.retry_after if re.retry_after is not None else self._backoff(attempt))
            except Exception as perm:                         # 400/401 = permanent -> nicht wiederholen
                last = perm
                break
        with self._lock:
            self._fails += 1
            if self._fails >= self._cth:                      # (5) Circuit öffnen
                self._circuit_until = time.time() + self._ccd
        raise last if last else RuntimeError("Refresh ohne Ergebnis")

    def _backoff(self, attempt):                              # Full-Jitter
        cap = min(self._bcap, self._bbase * (2 ** min(attempt, 20)))
        return random.uniform(0, cap)
