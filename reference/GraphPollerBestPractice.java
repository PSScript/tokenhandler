import com.azure.identity.ClientSecretCredentialBuilder;
import com.microsoft.graph.serviceclient.GraphServiceClient;
import java.util.concurrent.Semaphore;

/**
 * „Weniger ist mehr" — Graph-Mail-Poller-Setup mit dem OFFIZIELLEN SDK.
 * Jede Zeile ist kommentiert mit dem, was sie abfängt. Der Punkt: der Großteil
 * der Härtungs-Matrix kostet mit dem SDK fast keinen Code, weil das Schwierige
 * schon im Framework liegt.  Maven: com.azure:azure-identity, com.microsoft.graph:microsoft-graph
 * (API-Namen je Graph-SDK-Version leicht unterschiedlich — es geht ums Muster.)
 */
public final class GraphPollerBestPractice {

    private final GraphServiceClient graph;   // EIN Client PRO App (nicht statisch geteilt!)
    private final Semaphore writeGate;        // Write-Concurrency = gemessener carrier

    public GraphPollerBestPractice(String tenantId, String clientId, String secret, int carrier) {
        // azure-identity: thread-sicherer Token-Cache + Single-Flight-Refresh (MSAL darunter).
        //   >>> fängt ab: Token-Refresh-Race (kein "Bearer null"-Fenster) + Retry-After am /token-Endpoint
        var cred = new ClientSecretCredentialBuilder()
                .tenantId(tenantId).clientId(clientId).clientSecret(secret).build();

        // Der Graph-Client bringt einen Retry-Handler mit, der 429/503 samt Retry-After ab Werk beachtet.
        //   >>> fängt ab: Retry-After nicht abschließend (kein Über-Warten/Hämmern); transientes 429/503
        // Ein EIGENER Client je App -> eigener Connection-Pool, keine geteilte "static HttpClient".
        //   >>> fängt ab: fehlende Transport-Isolation (die zwei Lanes teilen sich keine Pipe)
        this.graph = new GraphServiceClient(cred, "https://graph.microsoft.com/.default");

        // Write-Durchsatz auf die GEMESSENE Kapazität begrenzen (1 Slot bleibt implizit fürs Pollen).
        //   >>> fängt ab: Write-Fanout / "Session-Stealing" (kein selbst erzeugtes MailboxConcurrency-429)
        this.writeGate = new Semaphore(carrier);
    }

    /** Poll: ein Request holt 25 Mails -> billig, kein Fanout. */
    public Object poll(String mailbox, String folderId) {
        return graph.users().byUserId(mailbox).mailFolders().byMailFolderId(folderId)
                .messages().get(cfg -> {
                    cfg.queryParameters.top = 25;                       // Batch-Read: 1 Call, 25 Mails
                    cfg.queryParameters.select = new String[]{"id", "subject"};
                });
    }

    /** Move: gebündelt durch das Semaphore -> nie mehr als `carrier` gleichzeitig. */
    public void move(String mailbox, String messageId, String targetFolderId) throws InterruptedException {
        writeGate.acquire();                                           // QoS: bounded write-concurrency
        try {
            var body = new com.microsoft.graph.users.item.messages.item.move.MovePostRequestBody();
            body.setDestinationId(targetFolderId);
            graph.users().byUserId(mailbox).messages().byMessageId(messageId).move().post(body);
        } catch (com.microsoft.kiota.ApiException e) {
            if (e.getResponseStatusCode() == 403) {
                // Frisch erteilte Permission? Das gecachte Token kennt sie noch nicht.
                //   >>> fängt ab: 403-nach-Consent (Stale Token) statt "permanent"
                // azure-identity cached -> für den erzwungenen Refresh MSAL4J .forceRefresh(true)
                // nehmen (siehe TokenHandlerMsal.getForceRefresh()), dann move() genau EINMAL wiederholen.
            }
            throw e;
        } finally {
            writeGate.release();
        }
    }
}

/*
 Was das SDK NICHT abnimmt — das bleibt dein Client-Job (der eigentliche Mehrwert):

   • ADAPTIVES LIMIT / ROLLING-FLOOR   Der SDK-Retry ist reaktiv (backoff nach 429),
       aber er MISST die Kante nicht und lernt sie nicht. carrier kommt aus deiner
       calibration.json; der drift-folgende Rolling-Floor ist dein Code.
   • GETEILTER STATE ÜBER INSTANZEN    Mehrere Pods teilen sich den App×Postfach-Bucket.
       Der gelernte Floor gehört in einen gemeinsamen Store (Redis) — nur Limit-State,
       nie Tokens.
   • 503/504 VON 429 TRENNEN           Der SDK-RetryHandler behandelt 503 wie 429.
       Willst du "Auth/Concurrency" vs "Infra/LB" (z.B. LB-Schwenk) im Monitoring
       trennen, brauchst du einen eigenen Zähler/Handler dafür.

 Kurz: das SDK deckt Token-Race, Retry-After, 429/503-Backoff und (bei einem Client
 je App) die Transport-Isolation ab. Selbstmessung, Adaption und geteiltes Gedächtnis
 bleiben im Client — genau die vier Dinge, die die API sich nicht selbst misst.
*/
