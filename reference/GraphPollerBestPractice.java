import com.microsoft.graph.serviceclient.GraphServiceClient;
import com.microsoft.graph.models.Message;
import com.microsoft.graph.users.item.messages.item.move.MovePostRequestBody;
import com.microsoft.kiota.ApiException;
import com.microsoft.kiota.authentication.AccessTokenProvider;
import com.microsoft.kiota.authentication.AllowedHostsValidator;
import com.microsoft.kiota.authentication.BaseBearerTokenAuthenticationProvider;

import java.net.URI;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Semaphore;

/**
 * „Weniger ist mehr" — Graph-Mail-Poller mit dem offiziellen SDK,
 * jetzt MIT echtem 403-nach-Consent-Handler.
 *
 * Der schlanke Pfad `new GraphServiceClient(cred, scope)` kann KEIN forceRefresh
 * (das Token steckt in azure-identitys internem Cache). Für den echten 403-Fix
 * routen wir die Auth deshalb über TokenHandlerMsal (der kann forceRefresh),
 * verdrahtet über einen winzigen Kiota-AccessTokenProvider. Das ist der ehrliche
 * Preis für die eine echte Zeile — dafür wird der 403-Zweig lauffähig.
 *
 * Maven: com.microsoft.graph:microsoft-graph:6.x, com.microsoft.azure:msal4j
 * (SDK-Signaturen gegen v6 ausgerichtet; Versionen pinnen.)
 */
public final class GraphPollerBestPractice {

    private final GraphServiceClient graph;   // EIN Client PRO App
    private final Semaphore writeGate;        // Write-Concurrency = gemessener carrier
    private final TokenHandlerMsal handler;   // liefert Token; kann forceRefresh

    public GraphPollerBestPractice(String tenantId, String clientId, String secret,
                                   String scope, int carrier) throws Exception {
        // Token-Bezug über MSAL4J (thread-sicherer Cache + Single-Flight + forceRefresh).
        //   >>> fängt ab: Token-Refresh-Race + ermöglicht den echten 403-Handler unten
        this.handler = new TokenHandlerMsal(tenantId, clientId, secret, scope);

        // Winziger Provider: gibt dem Graph-Client das (gecachte) Token aus dem Handler.
        var authProvider = new BaseBearerTokenAuthenticationProvider(new MsalTokenProvider(handler));

        // Eigener Client je App -> eigener Connection-Pool, keine geteilte "static HttpClient".
        //   >>> fängt ab: fehlende Transport-Isolation (die zwei Lanes teilen sich keine Pipe)
        //   Der Retry-Handler des SDK beachtet 429/503 samt Retry-After ab Werk.
        //   >>> fängt ab: Retry-After nicht abschließend; transientes 429/503
        this.graph = new GraphServiceClient(authProvider);

        // Write-Durchsatz auf die gemessene Kapazität begrenzen (1 Slot bleibt fürs Pollen).
        //   >>> fängt ab: Write-Fanout / "Session-Stealing" (kein selbst erzeugtes 429)
        this.writeGate = new Semaphore(carrier);
    }

    /** Poll: ein Request holt 25 Mails -> billig, kein Fanout. */
    public List<Message> poll(String mailbox, String folderId) {
        return graph.users().byUserId(mailbox).mailFolders().byMailFolderId(folderId)
                .messages().get(cfg -> {
                    cfg.queryParameters.top = 25;
                    cfg.queryParameters.select = new String[]{"id", "subject"};
                }).getValue();
    }

    /** Move: gebündelt durch das Semaphore; 403-nach-Consent -> forceRefresh + GENAU EIN Retry. */
    public void move(String mailbox, String messageId, String targetFolderId) throws InterruptedException {
        writeGate.acquire();                                   // QoS: bounded write-concurrency
        try {
            try {
                doMove(mailbox, messageId, targetFolderId);
            } catch (ApiException e) {
                if (e.getResponseStatusCode() == 403) {
                    // Frisch erteilte Permission? Das gecachte Token kennt sie noch nicht.
                    //   >>> fängt ab: 403-nach-Consent (Stale Token) statt "permanent"
                    handler.getForceRefresh();                 // MSAL: neues Token, Cache aktualisiert
                    doMove(mailbox, messageId, targetFolderId); // genau EIN Retry; bleibt es 403 -> wirft weiter (echt permanent)
                } else {
                    throw e;
                }
            }
        } finally {
            writeGate.release();
        }
    }

    private void doMove(String mailbox, String messageId, String targetFolderId) {
        var body = new MovePostRequestBody();
        body.setDestinationId(targetFolderId);
        graph.users().byUserId(mailbox).messages().byMessageId(messageId).move().post(body);
    }

    /** Kiota-AccessTokenProvider: reicht das Token aus dem Handler durch. */
    private static final class MsalTokenProvider implements AccessTokenProvider {
        private final TokenHandlerMsal handler;
        private final AllowedHostsValidator validator = new AllowedHostsValidator("graph.microsoft.com");
        MsalTokenProvider(TokenHandlerMsal handler) { this.handler = handler; }
        @Override public String getAuthorizationToken(URI uri, Map<String, Object> additional) {
            return handler.get();                              // gecacht; forceRefresh läuft über den Handler
        }
        @Override public AllowedHostsValidator getAllowedHostsValidator() { return validator; }
    }
}

/*
 Was das SDK NICHT abnimmt — das bleibt dein Client-Job (der eigentliche Mehrwert):
   • ADAPTIVES LIMIT / ROLLING-FLOOR   Der SDK-Retry ist reaktiv (backoff nach 429),
       misst die Kante aber nicht und lernt sie nicht. carrier kommt aus calibration.json;
       der drift-folgende Rolling-Floor ist dein Code.
   • GETEILTER STATE ÜBER INSTANZEN    Mehrere Pods teilen sich den App×Postfach-Bucket.
       Der gelernte Floor gehört in einen gemeinsamen Store (Redis) — nur Limit-State, nie Tokens.
   • 503/504 VON 429 TRENNEN           Der SDK-RetryHandler behandelt 503 wie 429. Für
       "Auth/Concurrency" vs "Infra/LB" im Monitoring brauchst du einen eigenen Zähler.

 Neu abgedeckt: 403-nach-Consent — echte forceRefresh+1-Retry-Logik über TokenHandlerMsal.
 Der Preis dafür: die Auth geht über MSAL + winzigen Provider statt über den schlanken
 GraphServiceClient(cred, scope)-Konstruktor. Bewusster Trade: eine echte Zeile 403-Fix
 gegen ~10 Zeilen Auth-Verdrahtung.
*/
