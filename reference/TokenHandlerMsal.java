import com.microsoft.aad.msal4j.*;
import java.util.Collections;
import java.util.Set;

/**
 * Weniger ist mehr — MIT MS-SDK (MSAL4J).
 *
 * Der Witz: das Single-Flight-Token-Caching aus TokenHandlerMinimal steckt
 * SCHON in MSAL. `acquireToken(...)` liefert bei gültigem Cache-Eintrag sofort,
 * zieht bei Ablauf genau einmal neu und ist thread-sicher (synchronisierter
 * Token-Cache). Du schreibst KEIN Double-Checked Locking mehr — das ist der
 * eigentliche „weniger ist mehr"-Effekt: weniger Code, weil die Race schon
 * gelöst ist.
 *
 * WICHTIG: die ConfidentialClientApplication EINMAL bauen und wiederverwenden —
 * sie hält den Token-Cache. Pro Aufruf neu bauen würde den Cache wegwerfen.
 *
 * Maven: com.microsoft.azure:msal4j
 */
public final class TokenHandlerMsal {

    private final ConfidentialClientApplication app;   // hält den Cache -> Singleton
    private final Set<String> scope;                   // z.B. ".../.default"

    public TokenHandlerMsal(String tenantId, String clientId, String clientSecret, String scope)
            throws Exception {
        this.scope = Collections.singleton(scope);
        this.app = ConfidentialClientApplication.builder(
                clientId, ClientCredentialFactory.createFromSecret(clientSecret))
            .authority("https://login.microsoftonline.com/" + tenantId)
            .build();
    }

    /** Gültiges Bearer-Token — MSAL cached und koalesziert selbst. */
    public String get() {
        ClientCredentialParameters p = ClientCredentialParameters.builder(scope)
                .build();                                  // forceRefresh default false => Cache bevorzugen
        return app.acquireToken(p).join().accessToken();
    }

    /** 401 / frisch erteilte Permission: einmal am Cache vorbei neu ziehen. */
    public String getForceRefresh() {
        ClientCredentialParameters p = ClientCredentialParameters.builder(scope)
                .forceRefresh(true)
                .build();
        return app.acquireToken(p).join().accessToken();
    }
}

/*
 Vergleich in einem Satz:
   OHNE SDK  -> du schreibst das Double-Checked Locking (TokenHandlerMinimal).
   MIT  SDK  -> du rufst acquireToken(); die Race ist schon in MSAL gelöst.
 Beides „minimal" — aber mit SDK ist minimal = fast nichts, weil das
 Schwierige (thread-sicherer Cache, Single-Flight) bereits im Framework liegt.
 Für 401/Consent-Änderungen: forceRefresh(true) statt eigener Invalidate-Logik.
*/
