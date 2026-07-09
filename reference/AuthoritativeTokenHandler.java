import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.*;

/**
 * Autoritativer Token-Refresh-Handler (Client-Credentials, pro App x Scope).
 *
 * ZIEL: immun gegen parallele Anfragen (Single-Flight) - aber ohne ins
 * Gegenteil zu kippen (keine Über-Serialisierung, kein Dauer-Block, kein
 * Retry-Stampede, kein Hämmern von AAD). Token-Refreshs haben ein BUDGET
 * und RETRY.
 *
 * Die sieben Invarianten:
 *  1. FAST PATH LOCK-FREE   - gültiges Token => volatile-Read, kein Lock.
 *                             10k parallele Requests konkurrieren um nichts.
 *  2. SINGLE-FLIGHT         - im Refresh-Fall zieht GENAU EINER; die anderen
 *                             hängen sich an dieselbe Future (Coalescing).
 *  3. REFRESH-AHEAD         - im Skew-Fenster (Token noch gültig, läuft aber
 *                             bald ab) wird ASYNCHRON erneuert und das noch
 *                             gültige Token weiter ausgeliefert => Aufrufer
 *                             blockieren im Normalbetrieb NIE.
 *  4. BUDGET                - min. Abstand zwischen Refresh-STARTS; ein
 *                             kaputtes Secret hämmert AAD nicht.
 *  5. CIRCUIT BREAKER       - nach K Fehlern kurz "offen": fail-fast ohne
 *                             AAD-Call (schützt vor AAD-Lockout/Drosselung).
 *  6. RETRY + BACKOFF       - im Refresh: 429/5xx mit Retry-After respektieren,
 *                             Full-Jitter-Backoff, gedeckelte Versuche.
 *  7. WAIT-TIMEOUT + STALE  - Aufrufer warten auf die In-Flight-Future nur mit
 *                             Timeout; hängt der Refresh, wird (falls noch
 *                             gültig) das alte Token bedient statt ewig zu blocken.
 *
 * Der eigentliche Token-BEZUG (fetch) sollte an MSAL4J / azure-identity
 * (ClientSecretCredential) delegieren - die cachen selbst. Dieser Handler
 * legt die AUTORITATIVEN Garantien (Coalescing, Refresh-Ahead, Budget,
 * Circuit) obendrauf.
 */
public final class AuthoritativeTokenHandler {

    /** Unveränderlicher Token-Snapshot (value + harte Ablaufzeit). */
    public record Token(String value, Instant expiresAt) {}

    /** Vom Aufrufer gelieferter Token-Bezug. Wirft {@link RetryableAuthException}
     *  bei 429/5xx (transient), sonst eine beliebige Exception (permanent, z.B. 400/401). */
    @FunctionalInterface public interface TokenFetch { Token fetch() throws Exception; }

    /** Transienter Auth-Fehler mit optionalem Retry-After. */
    public static final class RetryableAuthException extends Exception {
        public final Duration retryAfter;              // null => eigener Backoff
        public RetryableAuthException(String m, Duration retryAfter) { super(m); this.retryAfter = retryAfter; }
    }

    // ---- Konfiguration (sinnvolle Defaults) --------------------------------
    private final Duration skew            = Duration.ofMinutes(5);   // Refresh-Ahead-Fenster
    private final Duration minRefreshGap   = Duration.ofSeconds(10);  // BUDGET: min. Abstand zw. Refresh-Starts
    private final int      maxAttempts     = 5;                       // Retry im Refresh
    private final Duration backoffBase     = Duration.ofSeconds(1);
    private final Duration backoffCap      = Duration.ofSeconds(30);
    private final Duration waitTimeout     = Duration.ofSeconds(30);  // max. Wartezeit auf In-Flight
    private final int      circuitThreshold= 4;                       // Fehler bis Circuit offen
    private final Duration circuitCooldown = Duration.ofSeconds(60);

    // ---- Zustand -----------------------------------------------------------
    private volatile Token current = null;                 // FAST PATH: lock-free lesbar
    private final Object lock = new Object();
    private CompletableFuture<Token> inFlight = null;      // SINGLE-FLIGHT (guarded by lock)
    private Instant lastRefreshStart = Instant.EPOCH;      // BUDGET     (guarded by lock)
    private int     consecutiveFailures = 0;               // CIRCUIT    (guarded by lock)
    private Instant circuitOpenUntil = Instant.EPOCH;      // CIRCUIT    (guarded by lock)

    private final TokenFetch fetch;
    private final ExecutorService refreshPool =
        Executors.newSingleThreadExecutor(r -> { Thread t = new Thread(r, "token-refresh"); t.setDaemon(true); return t; });

    public AuthoritativeTokenHandler(TokenFetch fetch) { this.fetch = fetch; }

    /** Liefert ein gültiges Bearer-Token. Blockiert im Normalbetrieb nie. */
    public String get() {
        Token t = current;                                 // (1) volatile-Read, lock-free
        Instant now = Instant.now();

        // Voll frisch (außerhalb des Skew-Fensters) -> sofort zurück, keinerlei Arbeit.
        if (t != null && now.isBefore(t.expiresAt.minus(skew))) return t.value;

        // Skew-Fenster: noch gültig, aber bald fällig -> (3) REFRESH-AHEAD asynchron, altes Token bedienen.
        if (t != null && now.isBefore(t.expiresAt)) { synchronized (lock) { startRefreshIfEligible(now); } return t.value; }

        // Hart abgelaufen oder kein Token -> muss auf einen Refresh warten.
        return awaitRefresh(now).value();
    }

    /** 401: Token wurde abgelehnt -> hart invalidieren, nächster get() erneuert (koalesziert). */
    public void invalidate() { synchronized (lock) { current = null; } }

    private Token awaitRefresh(Instant now) {
        CompletableFuture<Token> f;
        synchronized (lock) {
            // Double-Check: evtl. hat ein anderer Thread inzwischen erneuert.
            Token t = current;
            if (t != null && now.isBefore(t.expiresAt.minus(skew))) return t;
            startRefreshIfEligible(now);
            if (inFlight == null) {
                // Budget/Circuit verweigern einen neuen Start UND kein Refresh läuft:
                // (7) noch gültiges (Rest-)Token bedienen, sonst laut scheitern.
                if (t != null && now.isBefore(t.expiresAt)) return t;
                throw new IllegalStateException("Token-Refresh gesperrt (Budget/Circuit offen), kein gültiges Token vorhanden");
            }
            f = inFlight;                                  // (2) an laufenden Refresh anhängen
        }
        try {
            return f.get(waitTimeout.toMillis(), TimeUnit.MILLISECONDS);
        } catch (TimeoutException e) {                      // (7) hängender Refresh: nicht ewig blocken
            Token t = current;
            if (t != null && Instant.now().isBefore(t.expiresAt)) return t;
            throw new RuntimeException("Token-Refresh Timeout", e);
        } catch (ExecutionException e) {                    // Refresh fehlgeschlagen (koalesziert an alle Waiter)
            throw new RuntimeException("Token-Refresh fehlgeschlagen: " + e.getCause(), e.getCause());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt(); throw new RuntimeException(e);
        }
    }

    /** MUSS unter {@code lock} laufen. Startet höchstens EINEN Refresh, respektiert Budget + Circuit. */
    private void startRefreshIfEligible(Instant now) {
        if (inFlight != null) return;                                  // (2) einer reicht
        if (now.isBefore(circuitOpenUntil)) return;                    // (5) Circuit offen -> kein AAD-Call
        if (now.isBefore(lastRefreshStart.plus(minRefreshGap))) return;// (4) Budget: zu früh
        lastRefreshStart = now;
        CompletableFuture<Token> f = new CompletableFuture<>();
        inFlight = f;
        refreshPool.submit(() -> runRefreshWithRetry(f));
    }

    private void runRefreshWithRetry(CompletableFuture<Token> f) {
        Exception last = null;
        for (int attempt = 0; attempt < maxAttempts; attempt++) {
            try {
                Token t = fetch.fetch();                    // Delegat: MSAL4J / azure-identity
                synchronized (lock) { current = t; consecutiveFailures = 0; circuitOpenUntil = Instant.EPOCH; inFlight = null; }
                f.complete(t);                              // Erfolg an alle Waiter
                return;
            } catch (RetryableAuthException re) {           // (6) 429/5xx: Retry-After ODER Backoff
                last = re;
                sleep(re.retryAfter != null ? re.retryAfter : backoff(attempt));
            } catch (Exception permanent) {                 // 400/401 (falsches Secret) etc. -> nicht wiederholen
                last = permanent; break;
            }
        }
        synchronized (lock) {
            consecutiveFailures++;
            if (consecutiveFailures >= circuitThreshold)    // (5) Circuit öffnen
                circuitOpenUntil = Instant.now().plus(circuitCooldown);
            inFlight = null;                                 // (Kein Poisoned-Future!) späterer Request darf – budgetiert – erneut
        }
        f.completeExceptionally(last != null ? last : new IllegalStateException("Refresh ohne Ergebnis"));
    }

    // Full-Jitter-Backoff: uniform(0, min(cap, base*2^attempt))
    private Duration backoff(int attempt) {
        long cap = Math.min(backoffCap.toMillis(), backoffBase.toMillis() * (1L << Math.min(attempt, 20)));
        return Duration.ofMillis(ThreadLocalRandom.current().nextLong(cap + 1));
    }
    private static void sleep(Duration d) { try { Thread.sleep(Math.max(0, d.toMillis())); } catch (InterruptedException e) { Thread.currentThread().interrupt(); } }

    public void close() { refreshPool.shutdownNow(); }
}
