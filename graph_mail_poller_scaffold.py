#!/usr/bin/env python3
"""
Orchestra Mail-Handler - Graph-Throttling-Scaffold (Python-Referenz)
====================================================================

Referenz-Geruest fuer die vier Korrekturen im Orchestra E-Mail-Handler:

  1. 401  -> gecachtes Token invalidieren, Refresh erzwingen, Retry mit
             EXPONENTIELLEM BACKOFF + Full Jitter (heute: enge Retry-
             Schleife, die Graph mit einem toten Token bombardiert).
  2. 503  -> Parallelitaet pro App reduzieren (AIMD: bei Drosselung
             halbieren, nach einer Serie sauberer Antworten +1 zurueck),
             zusaetzlich Backoff mit Jitter.
  3. Hartes Limit: Microsoft Graph erlaubt max. 4 GLEICHZEITIGE Requests
             pro App-ID und Postfach (Outlook-Service-Limits). Die
             Limiter-Obergrenze ist deshalb 4 - pro App, nicht global.
  4. App-ID-Pooling mit echter Trennung: jede App besitzt ihren EIGENEN
             - Token-Cache + Single-Flight-Refresh
             - adaptiven Concurrency-Limiter
             - Health-Zustand (Cooldown nach harten 429ern)
             Der Pool routet nur. Er waehlt pro Versuch die gesuendeste
             App und wechselt zwischen Retries auf die Schwester-App.

Zusaetzlich Variante B (per ENV umschaltbar, CLAIM_MODE=move):
  QoS-Polling-Lane + Mover. Jede Mail wird sofort Posteingang ->
  PROCESSING_FOLDER verschoben. Der Move IST der Claim: atomar pro Mail,
  der Verlierer eines Races bekommt 404 und ueberspringt. Die POLL-Lane
  haelt auf App-A einen reservierten Slot, damit das Polling auch unter
  Volllast/Drosselung nie hinter Worker-Traffic verhungert.

Outlook-via-Graph Service-Limits (pro App-ID *und Postfach*):
    - 4 gleichzeitige Requests
    - 10.000 Requests / 10 Minuten
    - Retry-After bei 429/503 ist IMMER zu respektieren.

Zwei App-Registrierungen verdoppeln die Pro-App-Kontingente (8 parallel),
der Mailbox-seitige Schutz bleibt aber bestehen -> Backoff bleibt Pflicht.

Konventionen aus PSScript/Resend-GraphReplay uebernommen:
    - Token-Cache mit 5-Minuten-Skew (wie Get-GraphToken)
    - Wellknown-Folder kleingeschrieben ("inbox")
    - Prefer: IdType='ImmutableId' auf ALLEN Message-Requests, damit die
      Message-ID den Move ueberlebt. Niemals gemischt verwenden!

Deps:   requests   (pip install requests)
Python: 3.9+
Konfig (ENV): TENANT_ID, MAILBOX_UPN, GRAPH_APP1_ID/SECRET,
    GRAPH_APP2_ID/SECRET, WORKER_THREADS, BATCH_SIZE,
    POLL_INTERVAL_SECONDS, CLAIM_MODE (isread|move),
    PROCESSING_FOLDER (Default: Processing)
"""

from __future__ import annotations

import os
import random
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from enum import Enum

import requests

GRAPH_ROOT = "https://graph.microsoft.com/v1.0"
LOGIN_ROOT = "https://login.microsoftonline.com"

MAX_CONCURRENCY_PER_APP = 4      # Graph/Outlook: hartes Limit pro App-ID und Postfach
MIN_CONCURRENCY = 1
GROW_AFTER_SUCCESSES = 25        # additive Erhoehung: +1 Slot nach N sauberen Antworten
MAX_ATTEMPTS = 6                 # pro logischem Request, ueber den gesamten Pool
BACKOFF_BASE = 1.0               # Sekunden
BACKOFF_CAP = 60.0               # Sekunden
RETRY_AFTER_CAP = 300.0          # dem Server vertrauen, aber absurde Werte kappen
COOLDOWN_THRESHOLD = 10.0        # verlangt ein 429 >= diese Wartezeit, wird die App geparkt
TOKEN_SKEW_SECONDS = 300         # 5-Minuten-Skew wie in Resend-GraphReplay/Get-GraphToken

_session = requests.Session()


class Lane(Enum):
    """QoS-Lanes: POLL (Polling + Move/Claim) bevorzugt App-A und darf dort
    den reservierten Slot nutzen. WORK (Mail-Verarbeitung) bevorzugt App-B
    und kann den letzten Slot der Poll-App NIE belegen."""
    POLL = "poll"
    WORK = "work"


class ClaimMode(Enum):
    ISREAD = "isread"   # Variante A: $filter=isRead eq false + PATCH isRead
    MOVE = "move"       # Variante B: Move Posteingang -> Processing = Claim


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} [{threading.current_thread().name}] {msg}",
          flush=True)


def backoff_delay(attempt: int) -> float:
    """Exponentielles Backoff mit Full Jitter: uniform(0, min(cap, base * 2^n))."""
    return random.uniform(0.0, min(BACKOFF_CAP, BACKOFF_BASE * (2 ** attempt)))


def parse_retry_after(resp: requests.Response) -> float | None:
    raw = resp.headers.get("Retry-After")
    if raw is None:
        return None
    try:
        return min(float(raw), RETRY_AFTER_CAP)
    except ValueError:
        return None  # HTTP-Date-Form (selten bei Graph) -> eigenes Backoff nutzen


class TransientGraphError(Exception):
    """Wiederholbarer Fehler. Traegt das Retry-After des Servers, falls vorhanden."""

    def __init__(self, app_name: str, status: int, retry_after: float | None):
        super().__init__(f"[{app_name}] transienter HTTP {status}")
        self.app_name = app_name
        self.status = status
        self.retry_after = retry_after


class PermanentGraphError(Exception):
    """Nicht wiederholbarer Fehler (uebrige 4xx). Bricht die Retry-Schleife
    sofort ab; der Mover wertet status==404 als verlorenes Claim-Race aus."""

    def __init__(self, app_name: str, status: int, detail: str):
        super().__init__(f"[{app_name}] permanenter HTTP {status}: {detail[:300]}")
        self.status = status


class TokenProvider:
    """Client-Credentials-Token-Cache. Eine Instanz PRO App-Registrierung.

    Das Lock macht den Refresh single-flight: parallele Aufrufer warten auf
    den einen Refresh, statt AAD mit parallelen Token-Requests zu fluten.
    """

    def __init__(self, name: str, tenant_id: str, client_id: str, client_secret: str):
        self.name = name
        self.tenant_id = tenant_id
        self.client_id = client_id
        self.client_secret = client_secret
        self._lock = threading.Lock()
        self._token: str | None = None
        self._expires_at = 0.0

    def invalidate(self) -> None:
        """Bei 401 aufrufen: Cache verwerfen, damit das naechste get() refresht."""
        with self._lock:
            self._token = None
            self._expires_at = 0.0

    def get(self) -> str:
        with self._lock:
            if self._token and time.time() < self._expires_at - TOKEN_SKEW_SECONDS:
                return self._token
            return self._refresh_locked()

    def _refresh_locked(self) -> str:
        url = f"{LOGIN_ROOT}/{self.tenant_id}/oauth2/v2.0/token"
        data = {
            "grant_type": "client_credentials",
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "scope": "https://graph.microsoft.com/.default",
        }
        for attempt in range(MAX_ATTEMPTS):
            resp = _session.post(url, data=data, timeout=30)
            if resp.status_code == 200:
                payload = resp.json()
                self._token = payload["access_token"]
                self._expires_at = time.time() + int(payload.get("expires_in", 3599))
                log(f"[{self.name}] Token erneuert "
                    f"(expires_in={payload.get('expires_in')})")
                return self._token
            if resp.status_code == 429 or resp.status_code >= 500:
                # Auch AAD drosselt -> dieselbe Backoff-Disziplin wie gegen Graph.
                delay = parse_retry_after(resp) or backoff_delay(attempt)
                log(f"[{self.name}] Token-Endpoint HTTP {resp.status_code}, "
                    f"Retry in {delay:.1f}s")
                time.sleep(delay)
                continue
            # 400/401 hier = falsches Secret / falsche App -> permanent, laut scheitern.
            resp.raise_for_status()
        raise RuntimeError(
            f"[{self.name}] Token-Erwerb nach {MAX_ATTEMPTS} Versuchen gescheitert")


class AdaptiveLimiter:
    """Concurrency-Gate mit AIMD-Anpassung. Eine Instanz PRO App.

      Obergrenze = 4  (hartes Graph-Limit pro App-ID und Postfach)
      bei 503    -> limit = max(1, limit // 2)   (multiplikative Reduktion)
      Erholung   -> +1 Slot nach GROW_AFTER_SUCCESSES sauberen Antworten

    reserved_for_priority > 0 reserviert Slots fuer die POLL-Lane: Worker
    (priority=False) koennen dann den letzten Slot nie belegen. Bei einem
    auf 1 gedrosselten Limit steht die App damit exklusiv der POLL-Lane
    zur Verfuegung - genau das gewuenschte QoS-Verhalten.
    """

    def __init__(self, name: str, reserved_for_priority: int = 0):
        self.name = name
        self._reserved = reserved_for_priority
        self._cv = threading.Condition()
        self._limit = MAX_CONCURRENCY_PER_APP
        self._in_flight = 0
        self._success_streak = 0

    def _threshold(self, priority: bool) -> int:
        return self._limit if priority else max(0, self._limit - self._reserved)

    def acquire(self, priority: bool = False) -> None:
        with self._cv:
            # Schwelle in der Schleife neu bewerten - das Limit kann sich
            # waehrend des Wartens durch on_throttle()/on_success() aendern.
            while self._in_flight >= self._threshold(priority):
                self._cv.wait()
            self._in_flight += 1

    def release(self) -> None:
        with self._cv:
            self._in_flight -= 1
            self._cv.notify_all()

    def on_success(self) -> None:
        with self._cv:
            self._success_streak += 1
            if (self._success_streak >= GROW_AFTER_SUCCESSES
                    and self._limit < MAX_CONCURRENCY_PER_APP):
                self._limit += 1
                self._success_streak = 0
                log(f"[{self.name}] erholt -> Parallelitaet {self._limit}")
                self._cv.notify_all()

    def on_throttle(self) -> None:
        with self._cv:
            new_limit = max(MIN_CONCURRENCY, self._limit // 2)
            if new_limit != self._limit:
                log(f"[{self.name}] 503 -> Parallelitaet "
                    f"{self._limit} -> {new_limit}")
                self._limit = new_limit
            self._success_streak = 0

    def utilization(self) -> float:
        with self._cv:
            return self._in_flight / self._limit


class GraphApp:
    """Eine App-Registrierung = Token-Cache + Limiter + Health. Voll isoliert.

    Das ist die Trennung, die dem aktuellen Handler fehlt: nichts hier drin
    wird mit der Schwester-App geteilt.
    """

    def __init__(self, name: str, tenant_id: str, client_id: str,
                 client_secret: str, reserved_poll_slots: int = 0):
        self.name = name
        self.tokens = TokenProvider(name, tenant_id, client_id, client_secret)
        self.limiter = AdaptiveLimiter(name, reserved_poll_slots)
        self._cooldown_until = 0.0
        self._cooldown_lock = threading.Lock()

    def available(self) -> bool:
        with self._cooldown_lock:
            return time.time() >= self._cooldown_until

    def _park(self, seconds: float) -> None:
        with self._cooldown_lock:
            until = time.time() + seconds
            if until > self._cooldown_until:
                self._cooldown_until = until
        log(f"[{self.name}] fuer {seconds:.0f}s geparkt (harte Drosselung) "
            f"-> Pool bevorzugt die Schwester-App")

    def single_attempt(self, priority: bool, method: str, url: str, *,
                       params: dict | None = None,
                       json_body: dict | None = None) -> requests.Response:
        """Genau EIN HTTP-Versuch.

        Klassifiziert das Ergebnis und aktualisiert NUR den Zustand dieser
        App. Transiente Fehler werfen TransientGraphError, damit der Pool
        backoffen und erneut versuchen kann - ggf. auf der Schwester-App.
        """
        token = self.tokens.get()
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            # Konvention aus Resend-GraphReplay: stabile IDs ueber
            # Ordnergrenzen hinweg - Pflicht fuer den Mover (Variante B).
            "Prefer": "IdType='ImmutableId'",
        }

        self.limiter.acquire(priority)
        try:
            resp = _session.request(method, url, headers=headers,
                                    params=params, json=json_body, timeout=45)
        finally:
            # Slot nur halten, solange die Leitung belegt ist - nie beim Schlafen.
            self.limiter.release()

        status = resp.status_code
        if status < 300:
            self.limiter.on_success()
            return resp

        retry_after = parse_retry_after(resp)

        if status == 401:
            # Abgelaufenes/abgelehntes Token: Refresh erzwingen;
            # das Backoff passiert Pool-seitig.
            self.tokens.invalidate()
            log(f"[{self.name}] 401 -> Token invalidiert, "
                f"Refresh beim naechsten Versuch")
            raise TransientGraphError(self.name, status, retry_after)

        if status == 429:
            # Pro-App-Kontingent erschoepft (4 parallel oder 10k/10min).
            # Retry-After strikt respektieren.
            if retry_after is not None and retry_after >= COOLDOWN_THRESHOLD:
                self._park(retry_after)
            raise TransientGraphError(self.name, status, retry_after)

        if status in (503, 504):
            # Service-Gegendruck: Last NUR auf dieser App abwerfen.
            self.limiter.on_throttle()
            raise TransientGraphError(self.name, status, retry_after)

        if status >= 500:
            raise TransientGraphError(self.name, status, retry_after)

        # Uebrige 4xx sind permanent (403 Berechtigungen, 400 Bad Request,
        # 404 z. B. verlorenes Move-Race in Variante B).
        raise PermanentGraphError(self.name, status,
                                  f"{method} {url} -> {resp.text}")


class GraphAppPool:
    """Routet jeden Request auf die passende, nicht geparkte App und
    wiederholt transiente Fehler mit exponentiellem Backoff - mit
    App-Hopping zwischen den Versuchen.

    Lane-Affinitaet schlaegt Auslastung: POLL bevorzugt App-A (mit
    reserviertem Slot), WORK bevorzugt App-B. Faellt die bevorzugte App
    aus (geparkt), greift automatisch die Schwester-App.

    Saemtlicher Drossel-Zustand lebt in GraphApp, nie im Pool - eine
    gedrosselte App kann die andere daher nicht vergiften.
    """

    def __init__(self, apps: list[GraphApp]):
        self.apps = apps

    def _pick(self, lane: Lane) -> GraphApp | None:
        candidates = [a for a in self.apps if a.available()]
        if not candidates:
            return None
        preferred = self.apps[0] if lane is Lane.POLL else self.apps[-1]
        return min(candidates,
                   key=lambda a: (0 if a is preferred else 1,
                                  a.limiter.utilization()))

    def request(self, lane: Lane, method: str, url: str, *,
                params: dict | None = None,
                json_body: dict | None = None) -> requests.Response:
        last_error: TransientGraphError | None = None
        for attempt in range(MAX_ATTEMPTS):
            app = self._pick(lane)
            if app is None:
                delay = backoff_delay(attempt)
                log(f"[pool] alle Apps geparkt, warte {delay:.1f}s")
                time.sleep(delay)
                continue
            try:
                return app.single_attempt(lane is Lane.POLL, method, url,
                                          params=params, json_body=json_body)
            except TransientGraphError as err:
                last_error = err
                delay = (err.retry_after if err.retry_after is not None
                         else backoff_delay(attempt))
                log(f"[pool] Versuch {attempt + 1}/{MAX_ATTEMPTS}: {err} "
                    f"-> Backoff {delay:.1f}s")
                time.sleep(delay)
        raise RuntimeError(
            f"{method} {url} nach {MAX_ATTEMPTS} Versuchen "
            f"gescheitert") from last_error


class InboxPoller:
    """Pollt den Posteingang, beansprucht bis zu batch_size Mails und
    uebergibt sie an den Worker-Pool.

    Worker-Threads duerfen die Graph-Slots bewusst uebersteigen - die
    Pro-App-Limiter sind die einzige Wahrheit fuer die Leitungs-Parallelitaet.
    """

    def __init__(self, pool: GraphAppPool, mailbox: str, *,
                 claim_mode: ClaimMode = ClaimMode.ISREAD,
                 processing_folder: str = "Processing",
                 workers: int = 8, batch_size: int = 25, interval: float = 15.0):
        self.pool = pool
        self.mailbox = mailbox
        self.claim_mode = claim_mode
        self.processing_folder = processing_folder
        self.batch_size = batch_size
        self.interval = interval
        self.executor = ThreadPoolExecutor(max_workers=workers,
                                           thread_name_prefix="mail-worker")
        self._claimed: set[str] = set()   # Schutz gegen Poll-Ueberlappung
        self._claimed_lock = threading.Lock()
        self._processing_folder_id: str | None = None

    # ---- Claim-Verwaltung (In-Memory) ------------------------------------
    def _claim(self, message_id: str) -> bool:
        with self._claimed_lock:
            if message_id in self._claimed:
                return False
            self._claimed.add(message_id)
            return True

    def _unclaim(self, message_id: str) -> None:
        with self._claimed_lock:
            self._claimed.discard(message_id)

    # ---- Variante B: Zielordner aufloesen/anlegen -------------------------
    def _folder_id(self) -> str:
        """Loest den Processing-Ordner einmalig auf (legt ihn ggf. an)."""
        if self._processing_folder_id:
            return self._processing_folder_id
        base = f"{GRAPH_ROOT}/users/{self.mailbox}/mailFolders"
        resp = self.pool.request(
            Lane.POLL, "GET", base,
            params={"$filter": f"displayName eq '{self.processing_folder}'",
                    "$select": "id,displayName"})
        hits = resp.json().get("value", [])
        if hits:
            self._processing_folder_id = hits[0]["id"]
        else:
            created = self.pool.request(
                Lane.POLL, "POST", base,
                json_body={"displayName": self.processing_folder})
            self._processing_folder_id = created.json()["id"]
            log(f"[poller] Ordner '{self.processing_folder}' angelegt")
        return self._processing_folder_id

    # ---- Poll-Zyklen -------------------------------------------------------
    def poll_once(self) -> None:
        if self.claim_mode is ClaimMode.MOVE:
            self._poll_move()
        else:
            self._poll_isread()

    def _poll_isread(self) -> None:
        """Variante A: ungelesene Mails holen, Claim per In-Memory-Set,
        nach Verarbeitung PATCH isRead=true."""
        url = f"{GRAPH_ROOT}/users/{self.mailbox}/mailFolders/inbox/messages"
        params = {
            "$filter": "isRead eq false",
            "$top": str(self.batch_size),
            "$select": "id,subject,receivedDateTime",
        }
        resp = self.pool.request(Lane.POLL, "GET", url, params=params)
        messages = resp.json().get("value", [])
        log(f"[poller] {len(messages)} ungelesene Mail(s) geholt")
        for message in messages:
            if self._claim(message["id"]):
                self.executor.submit(self._process_guarded,
                                     message["id"], message.get("subject", "?"))

    def _poll_move(self) -> None:
        """Variante B: Top-N aus dem Posteingang, sofort nach Processing
        verschieben. Der Move ist der Claim - verliert eine zweite Instanz
        das Race, quittiert Graph mit 404 und die Mail wird uebersprungen.

        Kein isRead-Filter noetig: der Posteingang selbst ist die Queue."""
        folder_id = self._folder_id()
        url = f"{GRAPH_ROOT}/users/{self.mailbox}/mailFolders/inbox/messages"
        resp = self.pool.request(Lane.POLL, "GET", url,
                                 params={"$top": str(self.batch_size),
                                         "$select": "id,subject"})
        messages = resp.json().get("value", [])
        log(f"[poller] {len(messages)} Mail(s) im Posteingang")
        for message in messages:
            mid = message["id"]
            subject = message.get("subject", "?")
            if not self._claim(mid):
                continue
            try:
                moved = self.pool.request(
                    Lane.POLL, "POST",
                    f"{GRAPH_ROOT}/users/{self.mailbox}/messages/{mid}/move",
                    json_body={"destinationId": folder_id})
                # Dank Prefer: IdType='ImmutableId' bleibt die ID ueber den
                # Move stabil - wir uebernehmen sie trotzdem defensiv aus
                # der Move-Response (ohne den Header AENDERT sie sich!).
                moved_id = moved.json().get("id", mid)
                self.executor.submit(self._process_guarded_no_claim,
                                     moved_id, subject)
            except PermanentGraphError as err:
                if err.status == 404:
                    log(f"[mover] '{subject}' bereits von anderer "
                        f"Instanz beansprucht (404)")
                else:
                    log(f"[mover] Move fehlgeschlagen fuer '{subject}': {err}")
            finally:
                # Nach dem Move taucht die Mail im Posteingang nicht mehr
                # auf - der In-Memory-Claim wird sofort wieder frei.
                self._unclaim(mid)

    # ---- Worker -------------------------------------------------------------
    def _process_guarded(self, message_id: str, subject: str) -> None:
        try:
            self.process(message_id, subject)
        except Exception as err:  # Scaffold: loggen, nicht sterben
            log(f"[worker] Fehler bei '{subject}': {err}")
        finally:
            self._unclaim(message_id)

    def _process_guarded_no_claim(self, message_id: str, subject: str) -> None:
        try:
            self.process(message_id, subject)
        except Exception as err:  # Scaffold: loggen, nicht sterben
            log(f"[worker] Fehler bei '{subject}': {err}")

    def process(self, message_id: str, subject: str) -> None:
        """Hier gehoert die Orchestra-Fachlogik hin. Zwei Graph-Calls als
        Demo-Last (Volltext holen, dann als gelesen markieren)."""
        base = f"{GRAPH_ROOT}/users/{self.mailbox}/messages/{message_id}"
        full = self.pool.request(Lane.WORK, "GET", base,
                                 params={"$select": "subject,from,body"})
        payload = full.json()
        sender = (payload.get("from", {})
                  .get("emailAddress", {})
                  .get("address", "?"))
        # ... parsen, in Orchestra routen, Ticket erzeugen, etc. ...
        # Variante B: statt PATCH alternativ weiter nach 'Done' verschieben
        # oder loeschen - hier bewusst identisch zu Variante A gehalten.
        self.pool.request(Lane.WORK, "PATCH", base, json_body={"isRead": True})
        log(f"[worker] '{payload.get('subject')}' von {sender} verarbeitet")

    def run_forever(self) -> None:
        log(f"[poller] alle {self.interval:.0f}s, Batch={self.batch_size}, "
            f"Postfach={self.mailbox}, Modus={self.claim_mode.value}")
        while True:
            started = time.time()
            try:
                self.poll_once()
            except Exception as err:
                log(f"[poller] Poll-Zyklus fehlgeschlagen: {err}")
            time.sleep(max(0.0, self.interval - (time.time() - started)))


def main() -> None:
    tenant = os.environ.get("TENANT_ID", "<tenant-guid>")
    mailbox = os.environ.get("MAILBOX_UPN", "orchestra@contoso.com")
    claim_mode = ClaimMode(os.environ.get("CLAIM_MODE", "isread").strip().lower())

    apps = [
        # App-A: bevorzugte POLL-Lane, 1 Slot fuer das Polling reserviert.
        GraphApp("app-a", tenant,
                 os.environ.get("GRAPH_APP1_ID", "<app1-client-id>"),
                 os.environ.get("GRAPH_APP1_SECRET", "<app1-secret>"),
                 reserved_poll_slots=1),
        # App-B: bevorzugte WORK-Lane, keine Reservierung.
        GraphApp("app-b", tenant,
                 os.environ.get("GRAPH_APP2_ID", "<app2-client-id>"),
                 os.environ.get("GRAPH_APP2_SECRET", "<app2-secret>")),
    ]
    pool = GraphAppPool(apps)
    variante = "B (QoS-Lane + Mover)" if claim_mode is ClaimMode.MOVE \
        else "A (isRead-Claim)"
    log(f"[main] Variante {variante} aktiv")
    InboxPoller(
        pool, mailbox,
        claim_mode=claim_mode,
        processing_folder=os.environ.get("PROCESSING_FOLDER", "Processing"),
        workers=int(os.environ.get("WORKER_THREADS", "8")),
        batch_size=int(os.environ.get("BATCH_SIZE", "25")),
        interval=float(os.environ.get("POLL_INTERVAL_SECONDS", "15")),
    ).run_forever()


if __name__ == "__main__":
    main()
