<#
.SYNOPSIS
    Orchestra Graph-Throttling-Demo: provoziert 401/404/429/503 gegen einen
    TESTTENANT und zeigt live, wie der tokenhandler-Scaffold reagiert.

.DESCRIPTION
    Demonstriert die Mechanik aus GraphMailPollerScaffold.java /
    graph_mail_poller_scaffold.py in PowerShell:

      - 401 (ECHT):       Token wird absichtlich korrumpiert -> Graph lehnt ab
                          -> Invalidate + Single-Flight-Refresh + Backoff.
      - 404 (ECHT):       Claim-Race per Doppel-Move. Nebenbei die Mutable-ID-
                          Falle: ohne Prefer IdType='ImmutableId' ist die alte
                          ID nach dem Move ungueltig.
      - 429/503 (ECHT):   Concurrency-Burst: -BurstSize (Default 10) parallele
                          Requests OHNE lokalen Limiter verletzen das 4er-Limit
                          pro App+Postfach -> Graph drosselt echt (meist 429
                          "MailboxConcurrency", je nach Backend/Operation 503).
      - 429/503 (SIMULIERT): Chaos-Injektion liefert zusaetzlich den anhaltenden
                          Drossel-Strom fuer die Mover-Phase (AIMD, Retry-After-
                          Parken, App-Hopping), ohne das Limit dauerhaft zu
                          verletzen.

    Ownership-Modell wie von Rust geliehen: eine synchronisierte Hashtable
    haelt pro Mail-ID genau EINEN Owner (poller -> worker-N -> Release).
    Der Mover verschiebt Mails von $SourceFolderName nach $TargetFolderName
    ("Eingehend" -> "Verarbeitet"), FIFO per $orderby=receivedDateTime asc.

    Ausgabe-Konvention:
      GELB  = was passiert ist          (Fehler/Ereignis)
      CYAN  = "Resolving with: ..."     (die Gegenmassnahme)
      GRUEN = Erfolg,  ROT = permanent, MAGENTA = Phasen

    Statusbars: WPF-Dashboard (Threads/InFlight, AIMD-Limit, Token-TTL,
    Counter, Log) - Fallback ohne GUI: Write-Progress (-NoGui).

.PARAMETER NoGui
    Kein WPF-Fenster (z. B. Server Core) - nur Konsole + Write-Progress.
.PARAMETER SkipSeed
    Keine Demo-Mails erzeugen, vorhandene Mails in 'Eingehend' verwenden.
.PARAMETER Cleanup
    Demo-Mails ('Orchestra-Demo*', 'Race-Kandidat*') am Ende aus dem
    Zielordner loeschen.
.PARAMETER SeedCount
    Anzahl Demo-Mails (Default 12).
.PARAMETER WorkerCount
    Worker-Runspaces (Default 6) - bewusst > 4, die Pro-App-Limiter sind
    die einzige Wahrheit fuer die Leitungs-Parallelitaet.
.PARAMETER BurstSize
    Parallele Requests fuer den ECHTEN Concurrency-Burst in Phase 4
    (Default 10; das Backend-Limit liegt bei 4 pro App+Postfach).
.PARAMETER NoBurst
    Phase 4 (echter 429/503-Burst) ueberspringen.
.PARAMETER ChaosRate
    Anteil simulierter 429/503-Antworten in der Mover-Phase (Default 0.30).

.NOTES
    NUR GEGEN EINEN TESTTENANT AUSFUEHREN. Beide App-Registrierungen
    benoetigen Mail.ReadWrite (Application), idealerweise per Application
    Access Policy auf das Testpostfach eingeschraenkt.
    Windows PowerShell 5.1 oder PowerShell 7 (Windows; WPF ist Windows-only).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$NoGui,
    [switch]$SkipSeed,
    [switch]$Cleanup,
    [ValidateRange(1, 100)] [int]$SeedCount = 12,
    [ValidateRange(1, 16)]  [int]$WorkerCount = 6,
    [ValidateRange(5, 20)]  [int]$BurstSize = 10,
    [switch]$NoBurst,
    [ValidateRange(0.0, 0.9)] [double]$ChaosRate = 0.30
)

# =============================================================================
#  VARIABLEN - TESTTENANT (hier anpassen)                <<< NUR TESTTENANT >>>
# =============================================================================
$TenantId         = '00000000-0000-0000-0000-000000000000'
$Mailbox          = 'orchestra@testtenant.onmicrosoft.com'
$App1Id           = '<app1-client-id>'      # App-A: POLL-Lane, 1 reservierter Slot
$App1Secret       = '<app1-secret>'
$App2Id           = '<app2-client-id>'      # App-B: WORK-Lane
$App2Secret       = '<app2-secret>'
$SourceFolderName = 'Eingehend'             # Quelle - wird angelegt, falls fehlt
$TargetFolderName = 'Verarbeitet'           # Ziel   - wird angelegt, falls fehlt
$BatchSize        = 25
$GraphRoot        = 'https://graph.microsoft.com/v1.0'
# =============================================================================

# ---------------------------------------------------------------------------
#  Geteilter Zustand (synchronisiert - wird von Main, Workern und UI gelesen)
# ---------------------------------------------------------------------------
$Sync = [hashtable]::Synchronized(@{})
$Sync.Config = [hashtable]::Synchronized(@{
    TenantId  = $TenantId;  Mailbox = $Mailbox;  GraphRoot = $GraphRoot
    ChaosRate = 0.0                       # wird erst in der Mover-Phase scharf
    MaxAttempts = 6
    BackoffBase = 1.0; BackoffCap = 8.0   # Demo verkuerzt (Scaffold: 60 s)
    RetryAfterCap = 300.0; CooldownThreshold = 10.0
    GrowAfter = 8                         # Demo-Wert (Scaffold: 25) - Erholung sichtbar
})
$Sync.Counters  = [hashtable]::Synchronized(@{
    Processed = 0; Seeded = 0; Queue = 0; E401 = 0; E404 = 0; E429 = 0; E503 = 0
})
# Ownership-Tabelle (Rust-Analogie): Mail-ID -> @{Owner; Since; State}.
# Genau EIN Owner pro Mail. Transfer poller -> worker-N, Release im finally.
$Sync.Ownership = [hashtable]::Synchronized(@{})
$Sync.LogQueue  = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$Sync.UiLines   = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
$Sync.Running   = $true
$Sync.CloseUi   = $false
$Sync.Phase     = 'Initialisierung'

function New-DemoApp {
    param($Name, $ClientId, $Secret, [int]$Reserved, [int]$ProgressId)
    # Eine App = eigener Token-Cache + eigener AIMD-Limiter + eigener Health-
    # Zustand. Exakt die Isolationsgrenze aus dem Scaffold (Klasse GraphApp).
    return [hashtable]::Synchronized(@{
        Name = $Name; ClientId = $ClientId; Secret = $Secret
        Token = $null; TokenExpiry = (Get-Date).AddYears(-1); TokenTtl = 3599
        Limit = 4; InFlight = 0; Streak = 0; Reserved = $Reserved
        ParkedUntil = (Get-Date).AddYears(-1); PId = $ProgressId
    })
}
$Sync.Apps = [hashtable]::Synchronized(@{})
$Sync.Apps['A'] = New-DemoApp 'app-a' $App1Id $App1Secret 1 1
$Sync.Apps['B'] = New-DemoApp 'app-b' $App2Id $App2Secret 0 2

# ---------------------------------------------------------------------------
#  Logging: Producer (Main + Worker) -> Queue -> Konsole (Main) + WPF (Timer)
# ---------------------------------------------------------------------------
function Add-DemoLog {
    param([string]$Text, [string]$Color = 'Gray')
    $Sync.LogQueue.Enqueue(@{ T = (Get-Date).ToString('HH:mm:ss'); Text = $Text; Color = $Color })
}
function Write-Happened  { param([string]$m) Add-DemoLog "  [!] $m" 'Yellow' }
function Write-Resolving { param([string]$m) Add-DemoLog "  Resolving with: $m" 'Cyan' }
function Write-Ok        { param([string]$m) Add-DemoLog "  [ok] $m" 'Green' }
function Write-Phase {
    param([string]$m)
    $Sync.Phase = $m
    Add-DemoLog ('=' * 72) 'Magenta'
    Add-DemoLog "  PHASE: $m" 'Magenta'
    Add-DemoLog ('=' * 72) 'Magenta'
}
function Flush-DemoLog {
    # Einziger Konsolen-Konsument ist der Main-Thread -> keine Farbraces.
    while ($Sync.LogQueue.Count -gt 0) {
        $e = $Sync.LogQueue.Dequeue()
        Write-Host ("{0} {1}" -f $e.T, $e.Text) -ForegroundColor $e.Color
        [void]$Sync.UiLines.Add($e)
    }
}
function Step-DemoCounter {
    param([string]$Name, [int]$Delta = 1)
    $c = $Sync.Counters
    [System.Threading.Monitor]::Enter($c.SyncRoot)
    try { $c[$Name] = [int]$c[$Name] + $Delta }
    finally { [System.Threading.Monitor]::Exit($c.SyncRoot) }
}

# ---------------------------------------------------------------------------
#  Backoff / Statusauswertung
# ---------------------------------------------------------------------------
function Get-DemoBackoff {
    param([int]$Attempt)
    # Full Jitter: uniform(0, min(Cap, Base * 2^Versuch)) - wie im Scaffold.
    $cap = [math]::Min($Sync.Config.BackoffCap, $Sync.Config.BackoffBase * [math]::Pow(2, $Attempt))
    return [math]::Round((Get-Random -Minimum 0.05 -Maximum ([double]$cap)), 2)
}
function Get-DemoStatus {
    param($ErrorRecord)
    try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}
function Get-DemoRetryAfter {
    param($ErrorRecord)
    # 5.1: HttpWebResponse.Headers['Retry-After'] / 7: HttpResponseMessage
    try { $h = $ErrorRecord.Exception.Response.Headers['Retry-After']
          if ($h) { return [math]::Min([double][string]$h, $Sync.Config.RetryAfterCap) } } catch { }
    try { $v = $ErrorRecord.Exception.Response.Headers.GetValues('Retry-After')
          if ($v) { return [math]::Min([double]$v[0], $Sync.Config.RetryAfterCap) } } catch { }
    return $null
}

# ---------------------------------------------------------------------------
#  Token (pro App): 5-Minuten-Skew + Single-Flight - wie Get-GraphToken in
#  Resend-GraphReplay, erweitert um Backoff gegen AAD-Drosselung.
# ---------------------------------------------------------------------------
function Get-DemoToken {
    param($App)
    [System.Threading.Monitor]::Enter($App.SyncRoot)   # Single-Flight-Refresh
    try {
        if ($App.Token -and $App.TokenExpiry -gt (Get-Date).AddMinutes(5)) { return $App.Token }
        $body = @{
            client_id = $App.ClientId; client_secret = $App.Secret
            scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials'
        }
        $uri = "https://login.microsoftonline.com/$($Sync.Config.TenantId)/oauth2/v2.0/token"
        for ($a = 0; $a -lt $Sync.Config.MaxAttempts; $a++) {
            try {
                $r = Invoke-RestMethod -Method Post -Uri $uri `
                        -ContentType 'application/x-www-form-urlencoded' -Body $body
                $App.Token = $r.access_token
                $App.TokenTtl = [int]$r.expires_in
                $App.TokenExpiry = (Get-Date).AddSeconds([int]$r.expires_in)
                Add-DemoLog "  [$($App.Name)] Token erneuert (expires_in=$($r.expires_in))" 'DarkGreen'
                return $App.Token
            } catch {
                $sc = Get-DemoStatus $_
                if ($sc -eq 429 -or $sc -ge 500) {
                    $d = Get-DemoBackoff $a
                    Write-Happened "[$($App.Name)] Token-Endpoint HTTP ${sc} - auch AAD drosselt"
                    Write-Resolving "Backoff ${d}s gegen AAD, dann erneuter Versuch"
                    Start-Sleep -Seconds $d
                    continue
                }
                throw   # 400/401 hier = falsches Secret -> permanent, laut scheitern
            }
        }
        throw "[$($App.Name)] Token-Erwerb nach $($Sync.Config.MaxAttempts) Versuchen gescheitert"
    } finally { [System.Threading.Monitor]::Exit($App.SyncRoot) }
}

# ---------------------------------------------------------------------------
#  AIMD-Limiter (pro App) + Health/Parken - Spiegel des Scaffold-Limiters
# ---------------------------------------------------------------------------
function Enter-AppSlot {
    param($App, [bool]$Priority)
    while ($true) {
        [System.Threading.Monitor]::Enter($App.SyncRoot)
        try {
            # Reservierter POLL-Slot: Worker koennen den letzten Slot der
            # Poll-App NIE belegen -> das Polling verhungert nie (QoS).
            $threshold = if ($Priority) { $App.Limit } else { [math]::Max(0, $App.Limit - $App.Reserved) }
            if ($App.InFlight -lt $threshold) { $App.InFlight++; return }
        } finally { [System.Threading.Monitor]::Exit($App.SyncRoot) }
        Start-Sleep -Milliseconds 40
    }
}
function Exit-AppSlot {
    param($App)
    [System.Threading.Monitor]::Enter($App.SyncRoot)
    try { $App.InFlight = [math]::Max(0, $App.InFlight - 1) }
    finally { [System.Threading.Monitor]::Exit($App.SyncRoot) }
}
function Register-AppSuccess {
    param($App)
    [System.Threading.Monitor]::Enter($App.SyncRoot)
    try {
        $App.Streak++
        if ($App.Streak -ge $Sync.Config.GrowAfter -and $App.Limit -lt 4) {
            $App.Limit++; $App.Streak = 0
            Add-DemoLog "  [ok] [$($App.Name)] erholt -> Parallelitaet $($App.Limit)" 'Green'
        }
    } finally { [System.Threading.Monitor]::Exit($App.SyncRoot) }
}
function Register-AppThrottle {
    param($App)
    [System.Threading.Monitor]::Enter($App.SyncRoot)
    try {
        $old = $App.Limit
        $App.Limit = [math]::Max(1, [math]::Floor($App.Limit / 2))
        $App.Streak = 0
        return $old
    } finally { [System.Threading.Monitor]::Exit($App.SyncRoot) }
}
function Test-AppAvailable { param($App) return ((Get-Date) -ge $App.ParkedUntil) }
function Set-AppParked {
    param($App, [double]$Seconds)
    $App.ParkedUntil = (Get-Date).AddSeconds($Seconds)
}
function Select-DemoApp {
    param([string]$Lane)
    # Lane-Affinitaet schlaegt Auslastung: POLL -> app-a, WORK -> app-b.
    # Ist die bevorzugte App geparkt, greift automatisch die Schwester-App.
    $avail = @($Sync.Apps['A'], $Sync.Apps['B']) | Where-Object { Test-AppAvailable $_ }
    if (-not $avail) { return $null }
    $pref = if ($Lane -eq 'POLL') { $Sync.Apps['A'] } else { $Sync.Apps['B'] }
    return ($avail | Sort-Object `
        @{ Expression = { if ($_.Name -eq $pref.Name) { 0 } else { 1 } } },
        @{ Expression = { $_.InFlight / [math]::Max(1, $_.Limit) } })[0]
}

# ---------------------------------------------------------------------------
#  Der eine Graph-Aufruf: Slot -> (Chaos|HTTP) -> klassifizieren -> Retry-
#  Schleife mit App-Hopping. Statuscode-Matrix identisch zum Scaffold.
# ---------------------------------------------------------------------------
function Invoke-DemoGraphRequest {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)] [string]$Uri,
        $Body = $null,
        [ValidateSet('POLL', 'WORK')] [string]$Lane = 'WORK',
        [switch]$NoImmutableId     # nur fuer die Mutable-ID-Falle in Phase 3
    )
    $cfg = $Sync.Config
    for ($attempt = 0; $attempt -lt $cfg.MaxAttempts; $attempt++) {
        $App = Select-DemoApp -Lane $Lane
        if (-not $App) {
            $d = Get-DemoBackoff $attempt
            Write-Happened 'Alle Apps geparkt - kein Kandidat im Pool'
            Write-Resolving "warte ${d}s, dann erneute App-Auswahl"
            Start-Sleep -Seconds $d
            continue
        }
        $priority = ($Lane -eq 'POLL')
        Enter-AppSlot $App $priority
        $sc = 0; $ra = $null; $result = $null; $simTag = ''; $detail = ''
        try {
            if ($cfg.ChaosRate -gt 0 -and (Get-Random -Minimum 0.0 -Maximum 1.0) -lt $cfg.ChaosRate) {
                # --- Chaos-Injektion: gefaelschte Drossel-Antwort, KEIN echter
                #     Call. Der ECHTE 429/503 kommt einmalig aus Phase 4
                #     (Concurrency-Burst > 4). Chaos liefert den anhaltenden
                #     Drossel-Strom fuer die Mover-Phase, ohne das Limit
                #     dauerhaft zu verletzen.
                $sc = if ((Get-Random -Maximum 3) -eq 0) { 429 } else { 503 }
                if ($sc -eq 429) { $ra = [double](Get-Random -Minimum 3 -Maximum 15) }
                $simTag = ' (simuliert)'
            } else {
                $token = Get-DemoToken $App
                $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
                if (-not $NoImmutableId) {
                    # Konvention aus Resend-GraphReplay: stabile IDs ueber den
                    # Move hinweg. Phase 3 laesst den Header bewusst weg.
                    $headers['Prefer'] = "IdType='ImmutableId'"
                }
                $result = Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers `
                              -ContentType 'application/json' -Body $Body
                $sc = 200
            }
        } catch {
            $sc = Get-DemoStatus $_
            $ra = Get-DemoRetryAfter $_
            $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            if ($sc -eq 0) { throw }   # Netzwerk-/DNS-Fehler: unveraendert eskalieren
        } finally {
            Exit-AppSlot $App          # Slot nur waehrend der Leitungszeit halten
        }

        switch ($true) {
            ($sc -lt 300) {
                Register-AppSuccess $App
                return $result
            }
            ($sc -eq 401) {
                Step-DemoCounter 'E401'
                [System.Threading.Monitor]::Enter($App.SyncRoot)
                try { $App.Token = $null; $App.TokenExpiry = (Get-Date).AddYears(-1) }
                finally { [System.Threading.Monitor]::Exit($App.SyncRoot) }
                $d = Get-DemoBackoff $attempt
                Write-Happened "[$($App.Name)] 401 Unauthorized - Token abgelehnt"
                Write-Resolving "Token invalidiert, Single-Flight-Refresh, Backoff ${d}s"
                Start-Sleep -Seconds $d
                continue
            }
            ($sc -eq 429) {
                Step-DemoCounter 'E429'
                Write-Happened "[$($App.Name)] 429 TooManyRequests${simTag} - Retry-After=${ra}s"
                if ($ra -ne $null -and $ra -ge $cfg.CooldownThreshold) {
                    Set-AppParked $App $ra
                    Write-Resolving "App '$($App.Name)' ${ra}s geparkt - Pool nutzt die Schwester-App"
                } else {
                    Write-Resolving "Retry-After strikt respektiert - warte ${ra}s"
                }
                $wait = if ($ra -ne $null) { $ra } else { Get-DemoBackoff $attempt }
                Start-Sleep -Seconds $wait
                continue
            }
            ($sc -eq 503 -or $sc -eq 504) {
                Step-DemoCounter 'E503'
                $old = Register-AppThrottle $App
                $d = Get-DemoBackoff $attempt
                Write-Happened "[$($App.Name)] ${sc} ServiceUnavailable${simTag}"
                Write-Resolving "AIMD: Parallelitaet ${old} -> $($App.Limit) (nur diese App), Backoff ${d}s"
                Start-Sleep -Seconds $d
                continue
            }
            ($sc -ge 500) {
                $d = Get-DemoBackoff $attempt
                Write-Happened "[$($App.Name)] HTTP ${sc}${simTag}"
                Write-Resolving "Backoff ${d}s, Retry ggf. auf der Schwester-App"
                Start-Sleep -Seconds $d
                continue
            }
            default {
                # Uebrige 4xx = permanent. 404 wertet der Aufrufer als
                # verlorenes Claim-Race aus (Variante B).
                $ex = New-Object System.InvalidOperationException(
                    ("permanenter HTTP {0}: {1}" -f $sc, $detail))
                $ex.Data['Status'] = $sc
                throw $ex
            }
        }
    }
    throw ("{0} {1} nach {2} Versuchen gescheitert" -f $Method, $Uri, $cfg.MaxAttempts)
}

# ---------------------------------------------------------------------------
#  Ownership (Rust-Analogie): TryAcquire / Transfer / Release
# ---------------------------------------------------------------------------
function Lock-DemoMail {
    param([string]$Id, [string]$Owner)
    $o = $Sync.Ownership
    [System.Threading.Monitor]::Enter($o.SyncRoot)
    try {
        if ($o.ContainsKey($Id)) { return $false }   # Borrow verweigert
        $o[$Id] = @{ Owner = $Owner; Since = Get-Date; State = 'queued' }
        return $true
    } finally { [System.Threading.Monitor]::Exit($o.SyncRoot) }
}
function Set-DemoMailState {
    param([string]$Id, [string]$Owner, [string]$State)
    $o = $Sync.Ownership
    [System.Threading.Monitor]::Enter($o.SyncRoot)
    try { if ($o.ContainsKey($Id)) { $o[$Id] = @{ Owner = $Owner; Since = (Get-Date); State = $State } } }
    finally { [System.Threading.Monitor]::Exit($o.SyncRoot) }
}
function Unlock-DemoMail {
    param([string]$Id)
    $o = $Sync.Ownership
    [System.Threading.Monitor]::Enter($o.SyncRoot)
    try { $o.Remove($Id) }
    finally { [System.Threading.Monitor]::Exit($o.SyncRoot) }
}

# ---------------------------------------------------------------------------
#  Konsolen-Statusbars (immer aktiv; im GUI-Modus zusaetzlich zum Fenster)
# ---------------------------------------------------------------------------
function Show-DemoBars {
    foreach ($key in 'A', 'B') {
        $app = $Sync.Apps[$key]
        $pct = [math]::Min(100, [int](($app.InFlight / 4) * 100))
        $tokenPct = 0
        if ($app.TokenExpiry -gt (Get-Date)) {
            $tokenPct = [math]::Min(100, [int]((($app.TokenExpiry - (Get-Date)).TotalSeconds / [math]::Max(1, $app.TokenTtl)) * 100))
        }
        $state = if (Test-AppAvailable $app) { 'aktiv' }
                 else { 'GEPARKT bis ' + $app.ParkedUntil.ToString('HH:mm:ss') }
        Write-Progress -Id $app.PId -Activity ("App {0}  [{1}]" -f $app.Name, $state) `
            -Status ("InFlight {0}/{1}  |  AIMD-Limit {1}/4  |  Token {2}%" -f $app.InFlight, $app.Limit, $tokenPct) `
            -PercentComplete $pct
    }
    $c = $Sync.Counters
    $done = if ($c.Seeded -gt 0) { [math]::Min(100, [int](($c.Processed / $c.Seeded) * 100)) } else { 0 }
    Write-Progress -Id 9 -Activity ("Mover {0} -> {1}" -f $SourceFolderName, $TargetFolderName) `
        -Status ("{0}/{1} verarbeitet | Queue {2} | Ownership {3} | 401={4} 404={5} 429={6} 503={7}" -f `
                 $c.Processed, $c.Seeded, $c.Queue, $Sync.Ownership.Count, $c.E401, $c.E404, $c.E429, $c.E503) `
        -PercentComplete $done
}
function Wait-DemoSeconds {
    param([double]$Seconds)
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) { Flush-DemoLog; Show-DemoBars; Start-Sleep -Milliseconds 150 }
}

# ---------------------------------------------------------------------------
#  Graph-Helfer: Ordner aufloesen/anlegen, Mails seeden, Cleanup
#  OData bewusst als Roh-String mit Leerzeichen - Invoke-RestMethod encodiert
#  implizit (Konvention Resend-GraphReplay). In Java waere das %20/enc().
# ---------------------------------------------------------------------------
function Get-DemoFolderId {
    param([string]$Name)
    $base = "$($Sync.Config.GraphRoot)/users/$($Sync.Config.Mailbox)/mailFolders"
    $r = Invoke-DemoGraphRequest -Method GET -Lane POLL `
            -Uri "${base}?`$filter=displayName eq '$Name'&`$select=id,displayName"
    if ($r.value.Count -gt 0) {
        Write-Ok "Ordner '$Name' gefunden"
        return $r.value[0].id
    }
    $created = Invoke-DemoGraphRequest -Method POST -Lane POLL -Uri $base `
                   -Body (@{ displayName = $Name } | ConvertTo-Json)
    Write-Ok "Ordner '$Name' angelegt"
    return $created.id
}
function Add-DemoMails {
    param([string]$FolderId, [int]$Count)
    # Drafts direkt im Ordner erzeugen - kein Mailflow noetig, Move geht trotzdem.
    for ($i = 1; $i -le $Count; $i++) {
        $body = @{
            subject = ('Orchestra-Demo #{0:d3}' -f $i)
            body    = @{ contentType = 'Text'; content = "Durchstich $i - erzeugt $(Get-Date -Format s)" }
            toRecipients = @(@{ emailAddress = @{ address = $Sync.Config.Mailbox } })
        } | ConvertTo-Json -Depth 5
        [void](Invoke-DemoGraphRequest -Method POST -Lane WORK `
                 -Uri "$($Sync.Config.GraphRoot)/users/$($Sync.Config.Mailbox)/mailFolders/$FolderId/messages" `
                 -Body $body)
        Step-DemoCounter 'Seeded'
        if ($i % 4 -eq 0) { Flush-DemoLog; Show-DemoBars }
    }
    Write-Ok "$Count Demo-Mails in '$SourceFolderName' erzeugt"
}
function Remove-DemoMails {
    param([string]$FolderId)
    $uri = "$($Sync.Config.GraphRoot)/users/$($Sync.Config.Mailbox)/mailFolders/$FolderId/messages?`$top=100&`$orderby=receivedDateTime asc&`$select=id,subject"
    $r = Invoke-DemoGraphRequest -Method GET -Lane WORK -Uri $uri
    $n = 0
    foreach ($m in @($r.value)) {
        if ($m.subject -like 'Orchestra-Demo*' -or $m.subject -like 'Race-Kandidat*') {
            [void](Invoke-DemoGraphRequest -Method DELETE -Lane WORK `
                     -Uri "$($Sync.Config.GraphRoot)/users/$($Sync.Config.Mailbox)/messages/$($m.id)")
            $n++
        }
    }
    Write-Ok "Cleanup: $n Demo-Mail(s) geloescht"
}

# ---------------------------------------------------------------------------
#  ECHTE 429/503 provozieren: Concurrency-Burst ueber das 4er-Limit
#  Das Outlook-Backend erlaubt 4 gleichzeitige Requests pro App+Postfach.
#  Wir feuern $Count Requests parallel und BEWUSST am lokalen Limiter
#  (Enter-AppSlot) vorbei - Graph drosselt dann echt: meist 429 mit
#  "MailboxConcurrency", je nach Backend/Operation auch 503. Genau der
#  Fall, fuer den der AdaptiveLimiter existiert. Ein einzelner, kleiner
#  Burst - kein Fluten des 10k-Kontingents.
# ---------------------------------------------------------------------------
function Invoke-DemoConcurrencyBurst {
    param([Parameter(Mandatory)] [string]$FolderId, [int]$Count = 10)
    $app = $Sync.Apps['A']
    $token = Get-DemoToken $app
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }   # 5.1; in PS 7 bereits geladen
    $client = New-Object System.Net.Http.HttpClient
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(100)
        $client.DefaultRequestHeaders.Authorization =
            New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Prefer', "IdType='ImmutableId'")
        $uri = "$($Sync.Config.GraphRoot)/users/$($Sync.Config.Mailbox)/mailFolders/$FolderId/messages?`$top=25&`$orderby=receivedDateTime asc&`$select=id,subject"
        Add-DemoLog "  feuere $Count parallele GETs mit app-a - lokaler Limiter bewusst umgangen ..." 'Gray'
        $tasks = @(1..$Count | ForEach-Object { $client.GetAsync($uri) })
        try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks) } catch { }
        $ok = 0; $failed = 0; $throttled = @{}; $ra = $null
        foreach ($t in $tasks) {
            if ($t.Status -ne 'RanToCompletion') { $failed++; continue }
            $resp = $t.Result
            $sc = [int]$resp.StatusCode
            if ($sc -lt 300) { $ok++ }
            elseif ($sc -eq 429 -or $sc -eq 503 -or $sc -eq 504) {
                $throttled[$sc] = 1 + [int]$throttled[$sc]
                if ($sc -eq 429) { Step-DemoCounter 'E429' } else { Step-DemoCounter 'E503' }
                if ($null -eq $ra -and $resp.Headers.RetryAfter) {
                    try {
                        if ($resp.Headers.RetryAfter.Delta) {
                            $ra = [math]::Round($resp.Headers.RetryAfter.Delta.Value.TotalSeconds, 0)
                        } elseif ($resp.Headers.RetryAfter.Date) {
                            $ra = [math]::Round(($resp.Headers.RetryAfter.Date.Value.LocalDateTime - (Get-Date)).TotalSeconds, 0)
                        }
                    } catch { }
                }
            } else { $failed++ }
            $resp.Dispose()
        }
        if ($throttled.Count -gt 0) {
            $mix = ($throttled.GetEnumerator() | Sort-Object Name |
                    ForEach-Object { "{0}x HTTP {1}" -f $_.Value, $_.Name }) -join ', '
            $raText = if ($null -ne $ra) { " - Retry-After=${ra}s" } else { '' }
            Write-Happened "Concurrency-Limit verletzt (ECHT): ${ok}/${Count} ok, ${mix}${raText}"
            $old = Register-AppThrottle $app
            Write-Resolving "AIMD: app-a Parallelitaet ${old} -> $($app.Limit) - genau dafuer kappt Enter-AppSlot normalerweise bei 4"
            if ($null -ne $ra -and $ra -ge $Sync.Config.CooldownThreshold) {
                Set-AppParked $app ([math]::Min($ra, $Sync.Config.RetryAfterCap))
                Write-Resolving "Retry-After respektiert: app-a ${ra}s geparkt - Pool weicht auf app-b aus"
            } elseif ($null -ne $ra) {
                Write-Resolving "Retry-After respektiert - warte ${ra}s vor der naechsten Phase"
                Wait-DemoSeconds $ra
            }
        } else {
            Add-DemoLog "  [i] ${ok}/${Count} ok, ${failed} Fehler - Backend hat den Burst diesmal toleriert (Timing). Erneut mit hoeherem -BurstSize versuchen." 'Gray'
        }
    } finally { $client.Dispose() }
}

# ---------------------------------------------------------------------------
#  WPF-Dashboard (eigener STA-Runspace, liest nur $Sync)
# ---------------------------------------------------------------------------
$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="tokenhandler - Orchestra Graph-Throttling-Demo"
        Height="620" Width="900" WindowStartupLocation="CenterScreen"
        Background="#FF1B1B1B" Foreground="#FFEAEAEA" FontFamily="Segoe UI">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,10">
      <TextBlock Text="Graph-Throttling-Demo" FontSize="20" FontWeight="Bold"/>
      <TextBlock x:Name="PhaseText" Text="Initialisierung" FontSize="14" Foreground="#FFE2001A" Margin="0,2,0,0"/>
    </StackPanel>

    <UniformGrid Grid.Row="1" Columns="2">
      <GroupBox Header="App-A (POLL-Lane, 1 Slot reserviert)" Foreground="#FFEAEAEA" Margin="0,0,7,0" BorderBrush="#FF444444">
        <StackPanel Margin="8">
          <TextBlock x:Name="StatusA" Text="-" Margin="0,0,0,6"/>
          <TextBlock Text="InFlight (Threads auf der Leitung)" FontSize="11" Foreground="#FF9E9E9E"/>
          <ProgressBar x:Name="BarInFlightA" Height="16" Maximum="4" Foreground="#FF4FC3F7" Background="#FF2A2A2A" Margin="0,2,0,6"/>
          <TextBlock Text="AIMD-Limit" FontSize="11" Foreground="#FF9E9E9E"/>
          <ProgressBar x:Name="BarLimitA" Height="8" Maximum="4" Foreground="#FFFFC66D" Background="#FF2A2A2A" Margin="0,2,0,6"/>
          <TextBlock Text="Token-Restlaufzeit" FontSize="11" Foreground="#FF9E9E9E"/>
          <ProgressBar x:Name="BarTokenA" Height="8" Maximum="100" Foreground="#FF7CCB6B" Background="#FF2A2A2A" Margin="0,2,0,0"/>
        </StackPanel>
      </GroupBox>
      <GroupBox Header="App-B (WORK-Lane)" Foreground="#FFEAEAEA" Margin="7,0,0,0" BorderBrush="#FF444444">
        <StackPanel Margin="8">
          <TextBlock x:Name="StatusB" Text="-" Margin="0,0,0,6"/>
          <TextBlock Text="InFlight (Threads auf der Leitung)" FontSize="11" Foreground="#FF9E9E9E"/>
          <ProgressBar x:Name="BarInFlightB" Height="16" Maximum="4" Foreground="#FF4FC3F7" Background="#FF2A2A2A" Margin="0,2,0,6"/>
          <TextBlock Text="AIMD-Limit" FontSize="11" Foreground="#FF9E9E9E"/>
          <ProgressBar x:Name="BarLimitB" Height="8" Maximum="4" Foreground="#FFFFC66D" Background="#FF2A2A2A" Margin="0,2,0,6"/>
          <TextBlock Text="Token-Restlaufzeit" FontSize="11" Foreground="#FF9E9E9E"/>
          <ProgressBar x:Name="BarTokenB" Height="8" Maximum="100" Foreground="#FF7CCB6B" Background="#FF2A2A2A" Margin="0,2,0,0"/>
        </StackPanel>
      </GroupBox>
    </UniformGrid>

    <TextBlock Grid.Row="2" x:Name="CountersText" FontFamily="Consolas" FontSize="13"
               Margin="0,10,0,8" Text="-"/>

    <ListBox Grid.Row="3" x:Name="LogList" Background="#FF101010" BorderBrush="#FF333333"
             Foreground="#FFB8B8B8" FontFamily="Consolas" FontSize="12"
             ScrollViewer.HorizontalScrollBarVisibility="Auto"/>
  </Grid>
</Window>
'@

$UiRunspace = $null; $UiPs = $null; $UiHandle = $null
$UseGui = -not $NoGui
if ($UseGui) {
    try { Add-Type -AssemblyName PresentationFramework -ErrorAction Stop } catch {
        Write-Host 'WPF nicht verfuegbar - Fallback auf -NoGui (Write-Progress).' -ForegroundColor Yellow
        $UseGui = $false
    }
}
if ($UseGui) {
    $UiRunspace = [runspacefactory]::CreateRunspace()
    $UiRunspace.ApartmentState = 'STA'
    $UiRunspace.ThreadOptions = 'ReuseThread'
    $UiRunspace.Open()
    $UiRunspace.SessionStateProxy.SetVariable('Sync', $Sync)
    $UiRunspace.SessionStateProxy.SetVariable('Xaml', $Xaml)
    $UiPs = [powershell]::Create()
    $UiPs.Runspace = $UiRunspace
    [void]$UiPs.AddScript({
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $window = [Windows.Markup.XamlReader]::Parse($Xaml)
        $ctl = @{}
        foreach ($name in 'PhaseText','StatusA','StatusB','BarInFlightA','BarLimitA','BarTokenA',
                          'BarInFlightB','BarLimitB','BarTokenB','CountersText','LogList') {
            $ctl[$name] = $window.FindName($name)
        }
        $bc = New-Object Windows.Media.BrushConverter
        $colorMap = @{
            Yellow = '#FFFFD75F'; Cyan = '#FF4FC3F7'; Green = '#FF7CCB6B'; DarkGreen = '#FF6BA96B'
            Red = '#FFFF6B6B'; Magenta = '#FFC586C0'; Gray = '#FFB8B8B8'; DarkGray = '#FF8A8A8A'; White = '#FFF0F0F0'
        }
        $script:uiIx = 0
        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(150)
        $timer.Add_Tick({
            foreach ($key in 'A', 'B') {
                $app = $Sync.Apps[$key]
                $parked = (Get-Date) -lt $app.ParkedUntil
                $tokenPct = 0
                if ($app.TokenExpiry -gt (Get-Date)) {
                    $tokenPct = [math]::Min(100, (($app.TokenExpiry - (Get-Date)).TotalSeconds / [math]::Max(1, $app.TokenTtl)) * 100)
                }
                $ctl["BarInFlight$key"].Value = $app.InFlight
                $ctl["BarLimit$key"].Value = $app.Limit
                $ctl["BarToken$key"].Value = $tokenPct
                if ($parked) {
                    $ctl["Status$key"].Text = 'GEPARKT bis ' + $app.ParkedUntil.ToString('HH:mm:ss')
                    $ctl["Status$key"].Foreground = $bc.ConvertFromString('#FFFF6B6B')
                } else {
                    $ctl["Status$key"].Text = ("aktiv | InFlight {0}/{1} | Limit {1}/4" -f $app.InFlight, $app.Limit)
                    $ctl["Status$key"].Foreground = $bc.ConvertFromString('#FF7CCB6B')
                }
            }
            $c = $Sync.Counters
            $ctl['CountersText'].Text = ("verarbeitet {0}/{1}   Queue {2}   Ownership {3}   |   401={4}  404={5}  429={6}  503={7}" -f `
                $c.Processed, $c.Seeded, $c.Queue, $Sync.Ownership.Count, $c.E401, $c.E404, $c.E429, $c.E503)
            $ctl['PhaseText'].Text = $Sync.Phase
            while ($script:uiIx -lt $Sync.UiLines.Count) {
                $e = $Sync.UiLines[$script:uiIx]; $script:uiIx++
                $item = New-Object Windows.Controls.ListBoxItem
                $item.Content = ("{0} {1}" -f $e.T, $e.Text)
                $hex = $colorMap[$e.Color]; if (-not $hex) { $hex = '#FFB8B8B8' }
                $item.Foreground = $bc.ConvertFromString($hex)
                [void]$ctl['LogList'].Items.Add($item)
                if ($ctl['LogList'].Items.Count -gt 800) { $ctl['LogList'].Items.RemoveAt(0); $script:uiIx-- }
            }
            if ($ctl['LogList'].Items.Count -gt 0) {
                $ctl['LogList'].ScrollIntoView($ctl['LogList'].Items[$ctl['LogList'].Items.Count - 1])
            }
            if (-not $Sync.Running) { $ctl['PhaseText'].Text = 'Demo beendet - Enter in der Konsole schliesst das Fenster' }
            if ($Sync.CloseUi) { $window.Close() }
        })
        $window.Add_ContentRendered({ $timer.Start() })
        [void]$window.ShowDialog()
    })
    $UiHandle = $UiPs.BeginInvoke()
}

# ---------------------------------------------------------------------------
#  Worker-Runspaces: Funktionen + $Sync in die InitialSessionState heben
# ---------------------------------------------------------------------------
$FnNames = @('Add-DemoLog','Write-Happened','Write-Resolving','Write-Ok','Step-DemoCounter',
             'Get-DemoBackoff','Get-DemoStatus','Get-DemoRetryAfter','Get-DemoToken',
             'Enter-AppSlot','Exit-AppSlot','Register-AppSuccess','Register-AppThrottle',
             'Test-AppAvailable','Set-AppParked','Select-DemoApp','Invoke-DemoGraphRequest',
             'Set-DemoMailState','Unlock-DemoMail')
$Iss = [initialsessionstate]::CreateDefault()
foreach ($fn in $FnNames) {
    $Iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new(
        $fn, (Get-Content "function:\$fn")))
}
$Iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
    'Sync', $Sync, 'geteilter Demo-Zustand'))
$Pool = [runspacefactory]::CreateRunspacePool(1, $WorkerCount, $Iss, $Host)
$Pool.Open()

# Worker: Ownership-Transfer -> Move -> "Fachlogik" -> Release (Rust: drop)
$WorkerScript = {
    param([string]$Id, [string]$Subject, [string]$TargetFolderId)
    $owner = 'worker-' + [System.Threading.Thread]::CurrentThread.ManagedThreadId
    Set-DemoMailState $Id $owner 'moving'    # Transfer: poller -> worker (move semantics)
    try {
        $cfg = $Sync.Config
        $moved = Invoke-DemoGraphRequest -Method POST -Lane WORK `
                     -Uri "$($cfg.GraphRoot)/users/$($cfg.Mailbox)/messages/$Id/move" `
                     -Body (@{ destinationId = $TargetFolderId } | ConvertTo-Json)
        Set-DemoMailState $Id $owner 'processing'
        Start-Sleep -Milliseconds (Get-Random -Minimum 250 -Maximum 900)   # Fachlogik-Attrappe
        Step-DemoCounter 'Processed'
        Add-DemoLog "  [ok] [$owner] '$Subject' -> verschoben & verarbeitet" 'Green'
    } catch {
        if ($_.Exception.Data['Status'] -eq 404) {
            Step-DemoCounter 'E404'
            Add-DemoLog "  [!] [$owner] 404 - '$Subject' bereits von anderer Instanz beansprucht" 'Yellow'
            Add-DemoLog "  Resolving with: Skip - Ownership liegt beim Gewinner des Move-Race" 'Cyan'
        } else {
            Add-DemoLog "  [x] [$owner] '$Subject': $($_.Exception.Message)" 'Red'
        }
    } finally {
        Unlock-DemoMail $Id                  # Release (drop) - immer, auch im Fehlerfall
        Step-DemoCounter 'Queue' -1
    }
}

# =============================================================================
#  ABLAUF
# =============================================================================
try {
    Write-Phase 'Phase 0 - Ordner aufloesen, Tokens holen'
    Flush-DemoLog
    $SourceFolderId = Get-DemoFolderId $SourceFolderName
    $TargetFolderId = Get-DemoFolderId $TargetFolderName
    foreach ($key in 'A', 'B') { [void](Get-DemoToken $Sync.Apps[$key]) }   # Token-Bars fuellen
    Flush-DemoLog; Show-DemoBars

    if (-not $SkipSeed) {
        Write-Phase "Phase 1 - $SeedCount Demo-Mails nach '$SourceFolderName' seeden"
        Add-DemoMails -FolderId $SourceFolderId -Count $SeedCount
        Flush-DemoLog; Show-DemoBars
    } else {
        Write-Phase "Phase 1 - Seed uebersprungen, vorhandene Mails in '$SourceFolderName' werden verwendet"
        Flush-DemoLog
    }

    Write-Phase 'Phase 2 - 401 provozieren (ECHT): Token absichtlich korrumpieren'
    $appA = $Sync.Apps['A']
    [System.Threading.Monitor]::Enter($appA.SyncRoot)
    try {
        $appA.Token = 'eyJkaputt.' + (Get-Random)          # kaputtes Bearer-Token
        $appA.TokenExpiry = (Get-Date).AddHours(1)         # Skew-Check austricksen
    } finally { [System.Threading.Monitor]::Exit($appA.SyncRoot) }
    Add-DemoLog '  Token von app-a korrumpiert - der naechste Aufruf laeuft in ein echtes 401 ...' 'Gray'
    [void](Invoke-DemoGraphRequest -Method GET -Lane POLL `
             -Uri "$GraphRoot/users/$Mailbox/mailFolders/$SourceFolderId?`$select=id,displayName")
    Write-Ok '401-Pfad durchlaufen: Invalidate -> Refresh -> Retry erfolgreich'
    Flush-DemoLog; Show-DemoBars

    Write-Phase 'Phase 3 - 404 Claim-Race provozieren (ECHT) + Mutable-ID-Falle'
    $raceBody = @{
        subject = 'Race-Kandidat'
        body    = @{ contentType = 'Text'; content = 'Zwei Instanzen, ein Move.' }
        toRecipients = @(@{ emailAddress = @{ address = $Mailbox } })
    } | ConvertTo-Json -Depth 5
    [void](Invoke-DemoGraphRequest -Method POST -Lane WORK -NoImmutableId `
             -Uri "$GraphRoot/users/$Mailbox/mailFolders/$SourceFolderId/messages" -Body $raceBody)
    # Bewusst OHNE Prefer-Header lesen -> wir bekommen die MUTABLE ID.
    $probe = Invoke-DemoGraphRequest -Method GET -Lane POLL -NoImmutableId `
                 -Uri "$GraphRoot/users/$Mailbox/mailFolders/$SourceFolderId/messages?`$top=1&`$orderby=receivedDateTime desc&`$select=id,subject"
    $raceId = $probe.value[0].id
    Add-DemoLog "  Instanz 1 verschiebt '$($probe.value[0].subject)' ..." 'Gray'
    [void](Invoke-DemoGraphRequest -Method POST -Lane WORK -NoImmutableId `
             -Uri "$GraphRoot/users/$Mailbox/messages/$raceId/move" `
             -Body (@{ destinationId = $TargetFolderId } | ConvertTo-Json))
    Write-Ok 'Instanz 1 hat den Move gewonnen'
    Add-DemoLog '  Instanz 2 versucht denselben Move mit der ALTEN (mutable) ID ...' 'Gray'
    try {
        [void](Invoke-DemoGraphRequest -Method POST -Lane WORK -NoImmutableId `
                 -Uri "$GraphRoot/users/$Mailbox/messages/$raceId/move" `
                 -Body (@{ destinationId = $TargetFolderId } | ConvertTo-Json))
        Add-DemoLog '  [?] Unerwartet: zweiter Move ohne 404 durchgelaufen' 'Red'
    } catch {
        if ($_.Exception.Data['Status'] -eq 404) {
            Step-DemoCounter 'E404'
            Write-Happened '404 ItemNotFound - Instanz 2 verliert das Claim-Race (alte ID nach Move ungueltig)'
            Write-Resolving "Skip - Ownership liegt beim Gewinner. Schutz im Scaffold: Prefer IdType='ImmutableId' + ID aus der Move-Response"
        } else { throw }
    }
    Flush-DemoLog; Show-DemoBars

    if (-not $NoBurst) {
        Write-Phase ("Phase 4 - 429/503 provozieren (ECHT): {0} parallele Zugriffe gegen das 4er-Concurrency-Limit" -f $BurstSize)
        Invoke-DemoConcurrencyBurst -FolderId $SourceFolderId -Count $BurstSize
        Flush-DemoLog; Show-DemoBars
    } else {
        Write-Phase 'Phase 4 - Concurrency-Burst uebersprungen (-NoBurst)'
        Flush-DemoLog
    }

    Write-Phase ("Phase 5 - Mover '{0}' -> '{1}' mit {2} Workern, Chaos {3:P0} (429/503 simuliert)" -f `
                 $SourceFolderName, $TargetFolderName, $WorkerCount, $ChaosRate)
    $Sync.Config.ChaosRate = $ChaosRate
    $jobs = [System.Collections.Generic.List[object]]::new()
    $idleRounds = 0
    while ($true) {
        $msgs = @()
        try {
            # FIFO: aelteste zuerst ($orderby). Der Ordner selbst ist die Queue.
            $uri = "$GraphRoot/users/$Mailbox/mailFolders/$SourceFolderId/messages?`$top=$BatchSize&`$orderby=receivedDateTime asc&`$select=id,subject"
            $msgs = @((Invoke-DemoGraphRequest -Method GET -Lane POLL -Uri $uri).value)
        } catch {
            Add-DemoLog "  [x] Poll fehlgeschlagen: $($_.Exception.Message)" 'Red'
        }
        foreach ($m in $msgs) {
            if (Lock-DemoMail $m.id 'poller') {           # TryAcquire - genau ein Owner
                Step-DemoCounter 'Queue'
                $ps = [powershell]::Create()
                $ps.RunspacePool = $Pool
                [void]$ps.AddScript($WorkerScript).AddArgument($m.id).AddArgument($m.subject).AddArgument($TargetFolderId)
                $jobs.Add(@{ PS = $ps; H = $ps.BeginInvoke() })
            }
        }
        for ($j = $jobs.Count - 1; $j -ge 0; $j--) {
            if ($jobs[$j].H.IsCompleted) {
                try { [void]$jobs[$j].PS.EndInvoke($jobs[$j].H) }
                catch { Add-DemoLog "  [x] Worker-Abschluss: $($_.Exception.Message)" 'Red' }
                $jobs[$j].PS.Dispose()
                $jobs.RemoveAt($j)
            }
        }
        Flush-DemoLog; Show-DemoBars
        if ($msgs.Count -eq 0 -and $jobs.Count -eq 0 -and $Sync.Ownership.Count -eq 0) {
            $idleRounds++
            if ($idleRounds -ge 2) { break }
        } else { $idleRounds = 0 }
        Start-Sleep -Milliseconds 600
    }

    Write-Phase 'Phase 6 - Chaos aus, AIMD-Erholung beobachten (+1 Slot je Erfolgsserie)'
    $Sync.Config.ChaosRate = 0.0
    for ($i = 1; $i -le 20; $i++) {
        $lane = if ($i % 2 -eq 0) { 'POLL' } else { 'WORK' }
        [void](Invoke-DemoGraphRequest -Method GET -Lane $lane `
                 -Uri "$GraphRoot/users/$Mailbox/mailFolders/$TargetFolderId?`$select=id")
        Flush-DemoLog; Show-DemoBars
        Start-Sleep -Milliseconds 120
    }

    if ($Cleanup) {
        Write-Phase 'Phase 7 - Cleanup: Demo-Mails aus dem Zielordner loeschen'
        Remove-DemoMails -FolderId $TargetFolderId
    }

    $c = $Sync.Counters
    Write-Phase 'Zusammenfassung'
    Add-DemoLog ("  verarbeitet: {0}/{1}   |   401={2}  404={3}  429={4}  503={5}  (429/503: Burst echt + Chaos simuliert)" -f `
                 $c.Processed, $c.Seeded, $c.E401, $c.E404, $c.E429, $c.E503) 'White'
    Add-DemoLog ("  App-A Limit={0}/4  |  App-B Limit={1}/4  |  offene Ownership: {2}" -f `
                 $Sync.Apps['A'].Limit, $Sync.Apps['B'].Limit, $Sync.Ownership.Count) 'White'
    Flush-DemoLog; Show-DemoBars
}
finally {
    $Sync.Running = $false
    Flush-DemoLog
    foreach ($id in 1, 2, 9) { Write-Progress -Id $id -Activity 'fertig' -Completed }
    if ($UseGui -and $UiPs) {
        Read-Host 'Enter beendet die Demo (WPF-Fenster schliesst)'
        $Sync.CloseUi = $true
        Start-Sleep -Milliseconds 400
        try { $UiPs.EndInvoke($UiHandle) } catch { }
        $UiPs.Dispose(); $UiRunspace.Close(); $UiRunspace.Dispose()
    }
    $Pool.Close(); $Pool.Dispose()
}
