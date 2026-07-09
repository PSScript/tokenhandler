# Quick-Win (C#) — „Weniger ist mehr": Write-Concurrency begrenzen

## Das Problem in einem Satz
Ein Read ist billig (ein `$top=25` holt 25 Mails in **einem** Request), aber jede
fertige Mail erzeugt **einen eigenen Move**. Viele parallele Tasks ⇒ viele gleichzeitige
Writes gegen **dasselbe Postfach** ⇒ das MailboxConcurrency-Limit (per App × Postfach)
kippt, 429 hagelt — **mehr Parallelität macht es schlechter**.

## Die eine Änderung
Write-Durchsatz global mit `SemaphoreSlim` auf die **gemessene** Carrier-Concurrency
begrenzen; einen Slot für den Poll reservieren.

**Vorher**
```csharp
// jeder Task feuert direkt seinen eigenen /move
var tasks = ids.Select(id => MoveMessageAsync(graph, id));
await Task.WhenAll(tasks);
```

**Nachher**
```csharp
int carrier = calib.CarrierConcurrency;               // aus calibration.json, gemessen
using var writeGate = new SemaphoreSlim(carrier);     // globaler Write-Durchsatz

var tasks = ids.Select(async id => {
    await writeGate.WaitAsync();
    try   { await MoveMessageAsync(graph, id); }
    finally { writeGate.Release(); }
});
await Task.WhenAll(tasks);
```

## Weitere Härtungspunkte (idiomatisch .NET)
- **Token:** `Azure.Identity.ClientSecretCredential` cached thread-sicher (MSAL darunter) —
  **nicht** per Hand `HttpClient`→`/token`. Das ist der Standardweg gegen die Token-Race.
- **Transport-Isolation:** `IHttpClientFactory` mit **benanntem Client je App** statt eines
  über beide Apps geteilten `static HttpClient`.
- **Retry-After:** Das **Microsoft.Graph-SDK** bringt einen Retry-Handler mit, der
  `Retry-After` ab Werk respektiert; alternativ **Polly** mit Retry-After-bewusster Policy.
- **403 nach Consent:** Token einmal forciert neu ziehen
  (`GetTokenAsync` mit neuem `TokenRequestContext`), dann erst permanent werten.
- **Hinweis MailKit (IMAP):** Wird statt Graph **MailKit/IMAP** genutzt, gilt ein anderes
  Modell (IMAP-Verbindungslimits pro Postfach, kein MailboxConcurrency) — dann Verbindungen
  poolen/begrenzen statt Graph-Concurrency.

## Warum „weniger ist mehr"
Durchsatz = **Goodput(N) = N · (1 − p(N))**. Weil die Grenze ein **Bucket-Overflow** ist
(Kapazität c), gilt `Goodput ≈ min(N, c)`: das Optimum liegt **bei c**, nicht darüber —
der Kalibrier-Sweep liefert es als Zahl.
