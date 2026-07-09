import java.net.URI;
import java.net.http.*;
import java.time.Instant;
import java.util.function.Supplier;

/**
 * Weniger ist mehr — Single-Flight-Token-Cache OHNE MS-SDK, ~12 Zeilen Kern.
 * N parallele Aufrufer  ->  GENAU EIN Refresh (Double-Checked Locking).
 *
 * Der „Klick" sind drei Schritte:
 *   1. Gültig?           -> volatile-Read, lock-frei zurück (der 99-%-Fall).
 *   2. Nein -> synchronized, NOCHMAL prüfen (jemand war schneller).
 *   3. Immer noch nichts -> selbst ziehen. Weil das im synchronized-Block
 *      passiert, zieht von 100 Threads nur EINER.
 *
 * Das Anti-Pattern, das die Prod-Race erzeugt, wäre:  if (expired) fetch();
 * OHNE Lock -> 100 Threads ziehen gleichzeitig 100 Tokens und überschreiben
 * sich den Cache ("Bearer null"-Fenster).
 */
public final class TokenHandlerMinimal {

    public record Token(String value, Instant expiresAt) {}

    private final Supplier<Token> fetch;   // () -> Token  (der eigentliche Bezug, s. unten)
    private final long skewSeconds;        // so viele Sekunden VOR Ablauf schon erneuern
    private volatile Token current;        // volatile => Fast Path ohne Lock

    public TokenHandlerMinimal(Supplier<Token> fetch, long skewSeconds) {
        this.fetch = fetch;
        this.skewSeconds = skewSeconds;
    }

    public String get() {
        Token t = current;                                            // (1) lock-frei
        if (t != null && Instant.now().isBefore(t.expiresAt().minusSeconds(skewSeconds)))
            return t.value();
        synchronized (this) {                                         // (2)+(3) nur EINER zieht
            t = current;
            if (t != null && Instant.now().isBefore(t.expiresAt().minusSeconds(skewSeconds)))
                return t.value();                                     //     jemand war schneller
            current = fetch.get();                                    //     genau ein Refresh
            return current.value();
        }
    }

    // -----------------------------------------------------------------------
    // „Ohne SDK" heißt auch: den Token-Bezug selbst schreiben. Illustrativer
    // hand-gerollter Client-Credentials-POST (java.net.http). In echt: JSON
    // sauber parsen (Jackson) statt der naiven Extraktion hier.
    // -----------------------------------------------------------------------
    static Token fetchViaHttp(String tenantId, String clientId, String secret, String scope) {
        try {
            String body = "client_id=" + clientId
                        + "&client_secret=" + secret
                        + "&scope=" + java.net.URLEncoder.encode(scope, "UTF-8")
                        + "&grant_type=client_credentials";
            HttpResponse<String> r = HttpClient.newHttpClient().send(
                HttpRequest.newBuilder(URI.create(
                    "https://login.microsoftonline.com/" + tenantId + "/oauth2/v2.0/token"))
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .POST(HttpRequest.BodyPublishers.ofString(body)).build(),
                HttpResponse.BodyHandlers.ofString());
            if (r.statusCode() != 200) throw new RuntimeException("token endpoint " + r.statusCode());
            String access = between(r.body(), "\"access_token\":\"", "\"");
            long ttl = Long.parseLong(between(r.body(), "\"expires_in\":", ",").trim());
            return new Token(access, Instant.now().plusSeconds(ttl));
        } catch (Exception e) { throw new RuntimeException(e); }
    }
    private static String between(String s, String a, String b) {
        int i = s.indexOf(a) + a.length();
        return s.substring(i, s.indexOf(b, i));
    }
}
