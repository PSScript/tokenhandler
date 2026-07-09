/*
 * Mail-Handler - Graph-Throttling-Scaffold (Java-Referenz)
 * ===================================================================
 *
 * Referenz-Geruest fuer die vier Korrekturen im E-Mail-Handler:
 *
 *   1. 401  -> gecachtes Token invalidieren, Refresh erzwingen, Retry mit
 *              EXPONENTIELLEM BACKOFF + Full Jitter (heute: enge Retry-
 *              Schleife, die Graph mit einem toten Token bombardiert).
 *   2. 503  -> Parallelitaet pro App reduzieren (AIMD: bei Drosselung
 *              halbieren, nach einer Serie sauberer Antworten +1 zurueck),
 *              zusaetzlich Backoff mit Jitter.
 *   3. Hartes Limit: Microsoft Graph erlaubt max. 4 GLEICHZEITIGE Requests
 *              pro App-ID und Postfach (Outlook-Service-Limits). Die
 *              Limiter-Obergrenze ist deshalb 4 - pro App, nicht global.
 *   4. App-ID-Pooling mit echter Trennung: jede App besitzt ihren EIGENEN
 *              - Token-Cache + Single-Flight-Refresh
 *              - adaptiven Concurrency-Limiter
 *              - Health-Zustand (Cooldown nach harten 429ern)
 *              Der Pool routet nur. Er waehlt pro Versuch die gesuendeste
 *              App und wechselt zwischen Retries auf die Schwester-App.
 *
 * Zusaetzlich Variante B (per ENV umschaltbar, CLAIM_MODE=move):
 *   QoS-Polling-Lane + Mover. Jede Mail wird sofort Posteingang ->
 *   PROCESSING_FOLDER verschoben. Der Move IST der Claim: atomar pro Mail,
 *   der Verlierer eines Races bekommt 404 und ueberspringt. Die POLL-Lane
 *   haelt auf App-A einen reservierten Slot, damit das Polling auch unter
 *   Volllast/Drosselung nie hinter Worker-Traffic verhungert.
 *
 * Outlook-via-Graph Service-Limits (pro App-ID *und Postfach*):
 *     - 4 gleichzeitige Requests
 *     - 10.000 Requests / 10 Minuten
 *     - Retry-After bei 429/503 ist IMMER zu respektieren.
 *
 * Zwei App-Registrierungen verdoppeln die Pro-App-Kontingente (8 parallel),
 * der Mailbox-seitige Schutz bleibt aber bestehen -> Backoff bleibt Pflicht.
 *
 * Konventionen aus PSScript/Resend-GraphReplay uebernommen:
 *     - Token-Cache mit 5-Minuten-Skew (wie Get-GraphToken)
 *     - Wellknown-Folder kleingeschrieben ("inbox")
 *     - Prefer: IdType='ImmutableId' auf ALLEN Message-Requests, damit die
 *       Message-ID den Move ueberlebt. Niemals gemischt verwenden!
 *     - Encoding-Delta zu PowerShell: Invoke-RestMethod encodiert OData-
 *       Roh-Strings mit Leerzeichen implizit; java.net.http/URI.create
 *       verweigert rohe Leerzeichen -> %20 bzw. enc()-Helper verwenden.
 *
 * JDK  : 11+  (java.net.http.HttpClient)
 * Deps : com.fasterxml.jackson.core:jackson-databind:2.17.x  (nur JSON)
 * Build: javac -encoding UTF-8 \
 *              -cp jackson-databind-2.17.2.jar:jackson-core-2.17.2.jar:jackson-annotations-2.17.2.jar \
 *              GraphMailPollerScaffold.java
 * Konfig (ENV): TENANT_ID, MAILBOX_UPN, GRAPH_APP1_ID/SECRET,
 *     GRAPH_APP2_ID/SECRET, WORKER_THREADS, BATCH_SIZE,
 *     POLL_INTERVAL_SECONDS, CLAIM_MODE (isread|move),
 *     PROCESSING_FOLDER (Default: Processing)
 */

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Comparator;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.OptionalDouble;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicInteger;

public final class GraphMailPollerScaffold {

    // ---- Limits & Tuning -----------------------------------------------------
    static final int    MAX_CONCURRENCY_PER_APP = 4;    // hartes Graph-Limit pro App-ID und Postfach
    static final int    MIN_CONCURRENCY         = 1;
    static final int    GROW_AFTER_SUCCESSES    = 25;   // additive Erhoehung: +1 Slot nach N sauberen Antworten
    static final int    MAX_ATTEMPTS            = 6;    // pro logischem Request, ueber den gesamten Pool
    static final double BACKOFF_BASE_SECONDS    = 1.0;
    static final double BACKOFF_CAP_SECONDS     = 60.0;
    static final double RETRY_AFTER_CAP_SECONDS = 300.0; // dem Server vertrauen, aber absurde Werte kappen
    static final double COOLDOWN_THRESHOLD_S    = 10.0;  // 429 mit Wartezeit >= X parkt die App
    static final long   TOKEN_SKEW_MS           = 300_000; // 5-Minuten-Skew wie in Resend-GraphReplay

    static final String GRAPH_ROOT = "https://graph.microsoft.com/v1.0";
    static final String LOGIN_ROOT = "https://login.microsoftonline.com";

    static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(15))
            .build();
    static final ObjectMapper JSON = new ObjectMapper();

    /** QoS-Lanes: POLL (Polling + Move/Claim) bevorzugt App-A und darf dort
     *  den reservierten Slot nutzen. WORK (Mail-Verarbeitung) bevorzugt
     *  App-B und kann den letzten Slot der Poll-App NIE belegen. */
    enum Lane { POLL, WORK }

    /** Variante A: isRead-Filter + PATCH. Variante B: Move = Claim. */
    enum ClaimMode { ISREAD, MOVE }

    static void log(String fmt, Object... args) {
        System.out.printf("%tT [%s] %s%n",
                new Date(), Thread.currentThread().getName(), String.format(fmt, args));
    }

    /** Exponentielles Backoff mit Full Jitter: uniform(0, min(cap, base * 2^n)). */
    static double backoffDelaySeconds(int attempt) {
        double cap = Math.min(BACKOFF_CAP_SECONDS,
                BACKOFF_BASE_SECONDS * Math.pow(2, attempt));
        return ThreadLocalRandom.current().nextDouble(0.0, cap);
    }

    static void sleepSeconds(double seconds) {
        if (seconds <= 0) return;
        try {
            Thread.sleep((long) (seconds * 1000));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException("beim Backoff unterbrochen", e);
        }
    }

    static OptionalDouble parseRetryAfter(HttpResponse<?> resp) {
        Optional<String> raw = resp.headers().firstValue("Retry-After");
        if (raw.isEmpty()) return OptionalDouble.empty();
        try {
            return OptionalDouble.of(
                    Math.min(Double.parseDouble(raw.get()), RETRY_AFTER_CAP_SECONDS));
        } catch (NumberFormatException e) {
            return OptionalDouble.empty(); // HTTP-Date-Form (selten) -> eigenes Backoff
        }
    }

    /** Query-Teile encodieren: PowerShell/Invoke-RestMethod toleriert rohe
     *  Leerzeichen, URI.create nicht -> Leerzeichen als %20 (nicht '+'). */
    static String enc(String s) {
        return URLEncoder.encode(s, StandardCharsets.UTF_8).replace("+", "%20");
    }

    // ---------------------------------------------------------------------------
    /** Wiederholbarer Fehler. Traegt das Retry-After des Servers, falls vorhanden. */
    static final class TransientGraphException extends Exception {
        final int status;
        final OptionalDouble retryAfterSeconds;

        TransientGraphException(String app, int status, OptionalDouble retryAfter) {
            super("[" + app + "] transienter HTTP " + status);
            this.status = status;
            this.retryAfterSeconds = retryAfter;
        }
    }

    /** Nicht wiederholbarer Fehler (uebrige 4xx). Bricht die Retry-Schleife
     *  sofort ab; der Mover wertet status==404 als verlorenes Claim-Race aus. */
    static final class PermanentGraphException extends IOException {
        final int status;

        PermanentGraphException(String app, int status, String detail) {
            super("[" + app + "] permanenter HTTP " + status + ": "
                    + (detail.length() > 300 ? detail.substring(0, 300) : detail));
            this.status = status;
        }
    }

    // ---------------------------------------------------------------------------
    /**
     * Client-Credentials-Token-Cache. Eine Instanz PRO App-Registrierung.
     *
     * synchronized = Single-Flight-Refresh: parallele Aufrufer warten auf den
     * einen Refresh, statt AAD mit parallelen Token-Requests zu fluten.
     */
    static final class TokenProvider {
        private final String name, tenantId, clientId, clientSecret;
        private String token;                // guarded by this
        private long   expiresAtEpochMs;     // guarded by this

        TokenProvider(String name, String tenantId, String clientId, String clientSecret) {
            this.name = name;
            this.tenantId = tenantId;
            this.clientId = clientId;
            this.clientSecret = clientSecret;
        }

        /** Bei 401 aufrufen: Cache verwerfen, damit das naechste get() refresht. */
        synchronized void invalidate() {
            token = null;
            expiresAtEpochMs = 0;
        }

        synchronized String get() throws IOException {
            if (token != null
                    && System.currentTimeMillis() < expiresAtEpochMs - TOKEN_SKEW_MS) {
                return token;
            }
            return refreshLocked();
        }

        private String refreshLocked() throws IOException {
            String form = "grant_type=client_credentials"
                    + "&client_id=" + urlEnc(clientId)
                    + "&client_secret=" + urlEnc(clientSecret)
                    + "&scope=" + urlEnc("https://graph.microsoft.com/.default");
            HttpRequest req = HttpRequest.newBuilder(
                            URI.create(LOGIN_ROOT + "/" + tenantId + "/oauth2/v2.0/token"))
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .POST(HttpRequest.BodyPublishers.ofString(form))
                    .timeout(Duration.ofSeconds(30))
                    .build();

            for (int attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
                HttpResponse<String> resp;
                try {
                    resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw new IOException("waehrend Token-Refresh unterbrochen", e);
                }
                int sc = resp.statusCode();
                if (sc == 200) {
                    JsonNode node = JSON.readTree(resp.body());
                    token = node.get("access_token").asText();
                    long ttl = node.path("expires_in").asLong(3599);
                    expiresAtEpochMs = System.currentTimeMillis() + ttl * 1000;
                    log("[%s] Token erneuert (expires_in=%d)", name, ttl);
                    return token;
                }
                if (sc == 429 || sc >= 500) {
                    // Auch AAD drosselt -> dieselbe Backoff-Disziplin wie gegen Graph.
                    double delay = parseRetryAfter(resp)
                            .orElse(backoffDelaySeconds(attempt));
                    log("[%s] Token-Endpoint HTTP %d, Retry in %.1fs", name, sc, delay);
                    sleepSeconds(delay);
                    continue;
                }
                // 400/401 hier = falsches Secret / falsche App -> permanent, laut scheitern.
                throw new IOException("[" + name + "] Token-Endpoint HTTP " + sc
                        + " (permanent): " + resp.body());
            }
            throw new IOException("[" + name + "] Token-Erwerb nach "
                    + MAX_ATTEMPTS + " Versuchen gescheitert");
        }

        private static String urlEnc(String s) {
            return URLEncoder.encode(s, StandardCharsets.UTF_8);
        }
    }

    // ---------------------------------------------------------------------------
    /**
     * Concurrency-Gate mit AIMD-Anpassung. Eine Instanz PRO App.
     *
     *   Obergrenze = 4  (hartes Graph-Limit pro App-ID und Postfach)
     *   bei 503    -> limit = max(1, limit / 2)   (multiplikative Reduktion)
     *   Erholung   -> +1 Slot nach GROW_AFTER_SUCCESSES sauberen Antworten
     *
     * reservedForPriority > 0 reserviert Slots fuer die POLL-Lane: Worker
     * (priority=false) koennen dann den letzten Slot nie belegen. Bei einem
     * auf 1 gedrosselten Limit steht die App damit exklusiv der POLL-Lane
     * zur Verfuegung - genau das gewuenschte QoS-Verhalten.
     */
    static final class AdaptiveLimiter {
        private final String name;
        private final int reservedForPriority;
        private int limit = MAX_CONCURRENCY_PER_APP;
        private int inFlight = 0;
        private int successStreak = 0;

        AdaptiveLimiter(String name, int reservedForPriority) {
            this.name = name;
            this.reservedForPriority = reservedForPriority;
        }

        private int threshold(boolean priority) {
            return priority ? limit : Math.max(0, limit - reservedForPriority);
        }

        synchronized void acquire(boolean priority) throws InterruptedException {
            // Schwelle in der Schleife neu bewerten - das Limit kann sich
            // waehrend des Wartens durch onThrottle()/onSuccess() aendern.
            while (inFlight >= threshold(priority)) {
                wait();
            }
            inFlight++;
        }

        synchronized void release() {
            inFlight--;
            notifyAll();
        }

        synchronized void onSuccess() {
            successStreak++;
            if (successStreak >= GROW_AFTER_SUCCESSES && limit < MAX_CONCURRENCY_PER_APP) {
                limit++;
                successStreak = 0;
                log("[%s] erholt -> Parallelitaet %d", name, limit);
                notifyAll();
            }
        }

        synchronized void onThrottle() {
            int next = Math.max(MIN_CONCURRENCY, limit / 2);
            if (next != limit) {
                log("[%s] 503 -> Parallelitaet %d -> %d", name, limit, next);
                limit = next;
            }
            successStreak = 0;
        }

        synchronized double utilization() {
            return (double) inFlight / limit;
        }
    }

    // ---------------------------------------------------------------------------
    /**
     * Eine App-Registrierung = Token-Cache + Limiter + Health. Voll isoliert.
     * Das ist die Trennung, die dem aktuellen Handler fehlt: nichts hier drin
     * wird mit der Schwester-App geteilt.
     */
    static final class GraphApp {
        final String name;
        final TokenProvider tokens;
        final AdaptiveLimiter limiter;
        private volatile long cooldownUntilMs = 0;

        GraphApp(String name, String tenantId, String clientId,
                 String clientSecret, int reservedPollSlots) {
            this.name = name;
            this.tokens = new TokenProvider(name, tenantId, clientId, clientSecret);
            this.limiter = new AdaptiveLimiter(name, reservedPollSlots);
        }

        boolean available() {
            return System.currentTimeMillis() >= cooldownUntilMs;
        }

        private void park(double seconds) {
            long until = System.currentTimeMillis() + (long) (seconds * 1000);
            if (until > cooldownUntilMs) cooldownUntilMs = until;
            log("[%s] fuer %.0fs geparkt (harte Drosselung) "
                    + "-> Pool bevorzugt die Schwester-App", name, seconds);
        }

        /**
         * Genau EIN HTTP-Versuch. Klassifiziert das Ergebnis und aktualisiert
         * NUR den Zustand dieser App. Transiente Fehler werfen
         * TransientGraphException, damit der Pool backoffen und erneut
         * versuchen kann - ggf. auf der Schwester-App.
         */
        HttpResponse<String> singleAttempt(boolean pollPriority, String method,
                                           String url, String jsonBody)
                throws IOException, InterruptedException, TransientGraphException {
            String bearer = tokens.get();
            HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(url))
                    .header("Authorization", "Bearer " + bearer)
                    .header("Accept", "application/json")
                    // Konvention aus Resend-GraphReplay: stabile IDs ueber
                    // Ordnergrenzen hinweg - Pflicht fuer den Mover (Variante B).
                    .header("Prefer", "IdType='ImmutableId'")
                    .timeout(Duration.ofSeconds(45));
            if (jsonBody == null) {
                builder.method(method, HttpRequest.BodyPublishers.noBody());
            } else {
                builder.header("Content-Type", "application/json")
                       // HttpClient hat kein patch()-Convenience -> generisches method()
                       .method(method, HttpRequest.BodyPublishers.ofString(jsonBody));
            }

            HttpResponse<String> resp;
            limiter.acquire(pollPriority);
            try {
                resp = HTTP.send(builder.build(), HttpResponse.BodyHandlers.ofString());
            } finally {
                // Slot nur halten, solange die Leitung belegt ist - nie beim Schlafen.
                limiter.release();
            }

            int sc = resp.statusCode();
            if (sc < 300) {
                limiter.onSuccess();
                return resp;
            }

            OptionalDouble retryAfter = parseRetryAfter(resp);

            if (sc == 401) {
                // Abgelaufenes/abgelehntes Token: Refresh erzwingen;
                // das Backoff passiert Pool-seitig.
                tokens.invalidate();
                log("[%s] 401 -> Token invalidiert, Refresh beim naechsten Versuch", name);
                throw new TransientGraphException(name, sc, retryAfter);
            }
            if (sc == 429) {
                // Pro-App-Kontingent erschoepft (4 parallel oder 10k/10min).
                // Retry-After strikt respektieren.
                if (retryAfter.isPresent()
                        && retryAfter.getAsDouble() >= COOLDOWN_THRESHOLD_S) {
                    park(retryAfter.getAsDouble());
                }
                throw new TransientGraphException(name, sc, retryAfter);
            }
            if (sc == 503 || sc == 504) {
                // Service-Gegendruck: Last NUR auf dieser App abwerfen.
                limiter.onThrottle();
                throw new TransientGraphException(name, sc, retryAfter);
            }
            if (sc >= 500) {
                throw new TransientGraphException(name, sc, retryAfter);
            }

            // Uebrige 4xx sind permanent (403 Berechtigungen, 400 Bad Request,
            // 404 z. B. verlorenes Move-Race in Variante B).
            throw new PermanentGraphException(name, sc,
                    method + " " + url + " -> " + resp.body());
        }
    }

    // ---------------------------------------------------------------------------
    /**
     * Routet jeden Request auf die passende, nicht geparkte App und wiederholt
     * transiente Fehler mit exponentiellem Backoff - mit App-Hopping zwischen
     * den Versuchen.
     *
     * Lane-Affinitaet schlaegt Auslastung: POLL bevorzugt App-A (mit
     * reserviertem Slot), WORK bevorzugt App-B. Faellt die bevorzugte App aus
     * (geparkt), greift automatisch die Schwester-App.
     *
     * Saemtlicher Drossel-Zustand lebt in GraphApp, nie im Pool - eine
     * gedrosselte App kann die andere daher nicht vergiften.
     */
    static final class GraphAppPool {
        private final List<GraphApp> apps;

        GraphAppPool(List<GraphApp> apps) {
            this.apps = apps;
        }

        private Optional<GraphApp> pick(Lane lane) {
            GraphApp preferred = (lane == Lane.POLL)
                    ? apps.get(0) : apps.get(apps.size() - 1);
            return apps.stream()
                    .filter(GraphApp::available)
                    .min(Comparator
                            .comparingInt((GraphApp a) -> a == preferred ? 0 : 1)
                            .thenComparingDouble(a -> a.limiter.utilization()));
        }

        HttpResponse<String> request(Lane lane, String method, String url, String jsonBody)
                throws IOException, InterruptedException {
            TransientGraphException last = null;
            for (int attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
                Optional<GraphApp> app = pick(lane);
                if (app.isEmpty()) {
                    double delay = backoffDelaySeconds(attempt);
                    log("[pool] alle Apps geparkt, warte %.1fs", delay);
                    sleepSeconds(delay);
                    continue;
                }
                try {
                    return app.get().singleAttempt(lane == Lane.POLL, method, url, jsonBody);
                } catch (TransientGraphException e) {
                    last = e;
                    double delay = e.retryAfterSeconds
                            .orElse(backoffDelaySeconds(attempt));
                    log("[pool] Versuch %d/%d: %s -> Backoff %.1fs",
                            attempt + 1, MAX_ATTEMPTS, e.getMessage(), delay);
                    sleepSeconds(delay);
                }
            }
            throw new IOException(method + " " + url + " nach "
                    + MAX_ATTEMPTS + " Versuchen gescheitert", last);
        }
    }

    // ---------------------------------------------------------------------------
    /**
     * Pollt den Posteingang, beansprucht bis zu batchSize Mails und uebergibt
     * sie an den Worker-Pool.
     *
     * Worker-Threads duerfen die Graph-Slots bewusst uebersteigen - die
     * Pro-App-Limiter sind die einzige Wahrheit fuer die Leitungs-Parallelitaet.
     */
    static final class InboxPoller {
        private static final AtomicInteger WORKER_SEQ = new AtomicInteger();

        private final GraphAppPool pool;
        private final String mailbox;
        private final ClaimMode claimMode;
        private final String processingFolderName;
        private final int batchSize;
        private final double intervalSeconds;
        private final ExecutorService workers;
        // Ownership-Tabelle im Rust-Sinn: genau EIN Owner pro Mail-ID.
        // Claim = move (Poller uebernimmt), Release im finally des Workers.
        // Fuer Observability als Map<Id, Owner/Since/State> erweiterbar -
        // so macht es Demo-GraphThrottling.ps1. In Variante B ist Graph
        // selbst der Borrow-Checker: verlorenes Move-Race = 404.
        private final Set<String> claimed = ConcurrentHashMap.newKeySet();
        private String processingFolderIdCache;   // nur vom Poller-Thread genutzt

        InboxPoller(GraphAppPool pool, String mailbox, ClaimMode claimMode,
                    String processingFolderName, int workerThreads,
                    int batchSize, double intervalSeconds) {
            this.pool = pool;
            this.mailbox = mailbox;
            this.claimMode = claimMode;
            this.processingFolderName = processingFolderName;
            this.batchSize = batchSize;
            this.intervalSeconds = intervalSeconds;
            this.workers = Executors.newFixedThreadPool(workerThreads,
                    r -> new Thread(r, "mail-worker-" + WORKER_SEQ.incrementAndGet()));
        }

        // ---- Variante B: Zielordner aufloesen/anlegen -----------------------
        private String processingFolderId() throws IOException, InterruptedException {
            if (processingFolderIdCache != null) return processingFolderIdCache;
            String base = GRAPH_ROOT + "/users/" + mailbox + "/mailFolders";
            String url = base + "?$filter="
                    + enc("displayName eq '" + processingFolderName + "'")
                    + "&$select=id,displayName";
            JsonNode hits = JSON.readTree(
                    pool.request(Lane.POLL, "GET", url, null).body()).path("value");
            if (hits.size() > 0) {
                processingFolderIdCache = hits.get(0).path("id").asText();
            } else {
                HttpResponse<String> created = pool.request(Lane.POLL, "POST", base,
                        JSON.writeValueAsString(Map.of("displayName", processingFolderName)));
                processingFolderIdCache = JSON.readTree(created.body()).path("id").asText();
                log("[poller] Ordner '%s' angelegt", processingFolderName);
            }
            return processingFolderIdCache;
        }

        // ---- Poll-Zyklen -------------------------------------------------------
        void pollOnce() throws IOException, InterruptedException {
            if (claimMode == ClaimMode.MOVE) {
                pollMove();
            } else {
                pollIsRead();
            }
        }

        /** Variante A: ungelesene Mails holen, Claim per In-Memory-Set,
         *  nach Verarbeitung PATCH isRead=true. */
        private void pollIsRead() throws IOException, InterruptedException {
            // Graph-Eigenheit bei $filter + $orderby: die $orderby-Properties
            // muessen im $filter enthalten sein und dort VOR den uebrigen
            // Bedingungen stehen - sonst HTTP 400 ("InefficientFilter").
            // Der ge-1900-Dummy erfuellt genau diese Regel.
            String url = GRAPH_ROOT + "/users/" + mailbox + "/mailFolders/inbox/messages"
                    + "?$filter=" + enc("receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false")
                    + "&$orderby=" + enc("receivedDateTime asc")   // FIFO: aelteste zuerst
                    + "&$top=" + batchSize
                    + "&$select=id,subject,receivedDateTime";
            HttpResponse<String> resp = pool.request(Lane.POLL, "GET", url, null);
            JsonNode messages = JSON.readTree(resp.body()).path("value");
            log("[poller] %d ungelesene Mail(s) geholt", messages.size());
            for (JsonNode message : messages) {
                String id = message.path("id").asText();
                String subject = message.path("subject").asText("?");
                if (claimed.add(id)) {
                    workers.submit(() -> processGuarded(id, subject));
                }
            }
        }

        /**
         * Variante B: Top-N aus dem Posteingang, sofort nach Processing
         * verschieben. Der Move ist der Claim - verliert eine zweite Instanz
         * das Race, quittiert Graph mit 404 und die Mail wird uebersprungen.
         *
         * Kein isRead-Filter noetig: der Posteingang selbst ist die Queue.
         */
        private void pollMove() throws IOException, InterruptedException {
            String folderId = processingFolderId();
            String url = GRAPH_ROOT + "/users/" + mailbox + "/mailFolders/inbox/messages"
                    + "?$top=" + batchSize
                    + "&$orderby=" + enc("receivedDateTime asc")   // FIFO: aelteste zuerst
                    + "&$select=id,subject";
            HttpResponse<String> resp = pool.request(Lane.POLL, "GET", url, null);
            JsonNode messages = JSON.readTree(resp.body()).path("value");
            log("[poller] %d Mail(s) im Posteingang", messages.size());
            for (JsonNode message : messages) {
                String id = message.path("id").asText();
                String subject = message.path("subject").asText("?");
                if (!claimed.add(id)) continue;
                try {
                    HttpResponse<String> moved = pool.request(Lane.POLL, "POST",
                            GRAPH_ROOT + "/users/" + mailbox + "/messages/" + id + "/move",
                            JSON.writeValueAsString(Map.of("destinationId", folderId)));
                    // Dank Prefer: IdType='ImmutableId' bleibt die ID ueber den
                    // Move stabil - wir uebernehmen sie trotzdem defensiv aus
                    // der Move-Response (ohne den Header AENDERT sie sich!).
                    String movedId = JSON.readTree(moved.body()).path("id").asText(id);
                    workers.submit(() -> processGuardedNoClaim(movedId, subject));
                } catch (PermanentGraphException e) {
                    if (e.status == 404) {
                        log("[mover] '%s' bereits von anderer Instanz beansprucht (404)",
                                subject);
                    } else {
                        log("[mover] Move fehlgeschlagen fuer '%s': %s",
                                subject, e.getMessage());
                    }
                } finally {
                    // Nach dem Move taucht die Mail im Posteingang nicht mehr
                    // auf - der In-Memory-Claim wird sofort wieder frei.
                    claimed.remove(id);
                }
            }
        }

        // ---- Worker -------------------------------------------------------------
        private void processGuarded(String id, String subject) {
            try {
                process(id, subject);
            } catch (Exception e) {          // Scaffold: loggen, nicht sterben
                log("[worker] Fehler bei '%s': %s", subject, e);
            } finally {
                claimed.remove(id);
            }
        }

        private void processGuardedNoClaim(String id, String subject) {
            try {
                process(id, subject);
            } catch (Exception e) {          // Scaffold: loggen, nicht sterben
                log("[worker] Fehler bei '%s': %s", subject, e);
            }
        }

        /** Hier gehoert die Fachlogik hin. Zwei Graph-Calls als
         *  Demo-Last (Volltext holen, dann als gelesen markieren). */
        private void process(String id, String subject) throws Exception {
            String base = GRAPH_ROOT + "/users/" + mailbox + "/messages/" + id;
            JsonNode full = JSON.readTree(
                    pool.request(Lane.WORK, "GET",
                            base + "?$select=subject,from,body", null).body());
            String sender = full.path("from").path("emailAddress")
                    .path("address").asText("?");
            // ... parsen, weiterrouten, Ticket erzeugen, etc. ...
            // Variante B: statt PATCH alternativ weiter nach 'Done' verschieben
            // oder loeschen - hier bewusst identisch zu Variante A gehalten.
            pool.request(Lane.WORK, "PATCH", base,
                    JSON.writeValueAsString(Map.of("isRead", true)));
            log("[worker] '%s' von %s verarbeitet", subject, sender);
        }

        void runForever() {
            log("[poller] alle %.0fs, Batch=%d, Postfach=%s, Modus=%s",
                    intervalSeconds, batchSize, mailbox, claimMode);
            while (true) {
                long started = System.currentTimeMillis();
                try {
                    pollOnce();
                } catch (Exception e) {
                    log("[poller] Poll-Zyklus fehlgeschlagen: %s", e);
                }
                double elapsed = (System.currentTimeMillis() - started) / 1000.0;
                sleepSeconds(Math.max(0.0, intervalSeconds - elapsed));
            }
        }
    }

    // ---------------------------------------------------------------------------
    public static void main(String[] args) {
        String tenant  = env("TENANT_ID", "<tenant-guid>");
        String mailbox = env("MAILBOX_UPN", "poller@contoso.com");
        ClaimMode claimMode = "move".equalsIgnoreCase(env("CLAIM_MODE", "isread").trim())
                ? ClaimMode.MOVE : ClaimMode.ISREAD;

        List<GraphApp> apps = List.of(
                // App-A: bevorzugte POLL-Lane, 1 Slot fuer das Polling reserviert.
                new GraphApp("app-a", tenant,
                        env("GRAPH_APP1_ID", "<app1-client-id>"),
                        env("GRAPH_APP1_SECRET", "<app1-secret>"), 1),
                // App-B: bevorzugte WORK-Lane, keine Reservierung.
                new GraphApp("app-b", tenant,
                        env("GRAPH_APP2_ID", "<app2-client-id>"),
                        env("GRAPH_APP2_SECRET", "<app2-secret>"), 0)
        );
        GraphAppPool pool = new GraphAppPool(apps);
        log("[main] Variante %s aktiv",
                claimMode == ClaimMode.MOVE ? "B (QoS-Lane + Mover)" : "A (isRead-Claim)");
        new InboxPoller(pool, mailbox, claimMode,
                env("PROCESSING_FOLDER", "Processing"),
                Integer.parseInt(env("WORKER_THREADS", "8")),
                Integer.parseInt(env("BATCH_SIZE", "25")),
                Double.parseDouble(env("POLL_INTERVAL_SECONDS", "15")))
                .runForever();
    }

    private static String env(String key, String fallback) {
        String value = System.getenv(key);
        return (value == null || value.isBlank()) ? fallback : value;
    }
}
