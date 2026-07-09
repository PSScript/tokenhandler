"""
Weniger ist mehr — der KERN eines Single-Flight-Token-Caches in ~15 Zeilen.
Das ist der „Klick": N parallele Aufrufer  ->  GENAU EIN Refresh.

Die ganze Idee sind drei Schritte:

  1. Gültiges Token da?  ->  ohne Lock zurück.        (der Normalfall, ~99 %)
  2. Nein -> Lock nehmen und NOCHMAL prüfen.          (Double-Check!)
     Jemand war in der Zwischenzeit schneller und hat schon erneuert
     -> dessen frisches Token einfach mitnehmen.
  3. Immer noch nichts -> selbst ziehen.
     Weil das UNTER dem Lock passiert, zieht von 100 Threads nur EINER;
     die anderen bekommen in Schritt 2 das frische Token.

Das ist „Double-Checked Locking". Mehr braucht der Kern nicht.
Budget, Retry, Refresh-Ahead und Circuit-Breaker sind Härtung obendrauf
(siehe authoritative_token_handler.py) — aber DAS hier ist der Aha-Moment.
"""
import time
import threading


class TokenHandler:
    def __init__(self, fetch, skew=300):
        self._fetch = fetch          # callable: () -> (token: str, expires_at_epoch: float)
        self._skew = skew            # so viele Sekunden VOR Ablauf schon erneuern
        self._token, self._exp = None, 0.0
        self._lock = threading.Lock()

    def get(self) -> str:
        # (1) FAST PATH — gültig? -> lock-frei zurück. Der 99-%-Fall.
        if self._token and time.time() < self._exp - self._skew:
            return self._token

        # (2)+(3) SLOW PATH — nur EINER zieht, der Rest wartet am Lock.
        with self._lock:
            if self._token and time.time() < self._exp - self._skew:
                return self._token                     # (2) jemand war schneller
            self._token, self._exp = self._fetch()     # (3) genau ein Refresh
            return self._token


# ---------------------------------------------------------------------------
# Warum das reicht (und warum es klickt):
#   - Der Fast Path braucht KEIN Lock -> 10k gleichzeitige Requests mit
#     gültigem Token konkurrieren um nichts.
#   - Der Slow Path ist durch den Lock serialisiert, ABER die zweite Prüfung
#     sorgt dafür, dass trotzdem nur EIN echter Refresh passiert.
#   - Kein `if expired: fetch()` ohne Lock -> genau das wäre die Race, bei der
#     100 Threads gleichzeitig 100 Tokens ziehen und sich gegenseitig den Cache
#     überschreiben ("Bearer None"-Fenster).
# ---------------------------------------------------------------------------
