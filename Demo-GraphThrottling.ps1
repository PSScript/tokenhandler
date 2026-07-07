<#
.SYNOPSIS
    Interaktive Orchestra Graph-Throttling-Demo: Szenarien per Button (WPF)
    oder Taste (Konsole) gegen einen TESTTENANT ausloesen.

.DESCRIPTION
    Demonstriert die Mechanik aus GraphMailPollerScaffold.java /
    graph_mail_poller_scaffold.py in PowerShell. Nach dem Start (Ordner
    aufloesen, Tokens, optional Seed) laeuft ein Dispatcher - Szenarien
    werden per WPF-Button oder Konsolen-Taste ausgeloest:

      Seed        Demo-Mails in den Quellordner legen.
      Klonen x2   Jede Mail im aktuellen Quellordner per /copy duplizieren
                  -> aus 25 werden 50, 100, ... (Kontingent-Schutz bei 200).
      401 (ECHT)  Token korrumpieren -> Invalidate, Single-Flight-Refresh.
      404 (ECHT)  Claim-Race per Doppel-Move + Mutable-ID-Falle.
      Burst (ECHT) -BurstSize parallele Requests OHNE lokalen Limiter
                  verletzen das 4er-Limit pro App+Postfach -> Graph drosselt
                  echt (meist 429 "MailboxConcurrency", je nach Backend 503).
      Ping-Pong   Dauer-Mover a<>b<>a<>b: verschiebt ALLE Mails Quelle->Ziel,
                  dreht bei leerer Quelle die Richtung und faehrt weiter -
                  echte Dauerlast, bis zum Abschalten.
      Chaos       Simulierten 429/503-Strom (ChaosRate) an/aus schalten.
      Cleanup     Demo-Mails aus beiden Ordnern loeschen.

    Ausgabe-Konvention:
      GELB  = was passiert ist          (Fehler/Ereignis)
      CYAN  = "Resolving with: ..."     (die Gegenmassnahme)
      GRUEN = Erfolg,  ROT = permanent, MAGENTA = Phasen/Richtungswechsel

    Statusbars: WPF-Dashboard (InFlight, AIMD-Limit, Token-TTL, Counter,
    Ordnerstaende, Log) - Fallback ohne GUI: Write-Progress + Tastenmenue.

.PARAMETER NoGui
    Kein WPF-Fenster - Konsole, Write-Progress und Tastensteuerung.
.PARAMETER SkipSeed
    Beim Start keine Demo-Mails erzeugen.
.PARAMETER Cleanup
    Beim Beenden Demo-Mails aus beiden Ordnern loeschen.
.PARAMETER SeedCount
    Anzahl Demo-Mails pro Seed (Default 12).
.PARAMETER WorkerCount
    Worker-Runspaces (Default 6) - bewusst > 4, die Pro-App-Limiter sind
    die einzige Wahrheit fuer die Leitungs-Parallelitaet.
.PARAMETER BurstSize
    Parallele Requests fuer den ECHTEN Concurrency-Burst (Default 10;
    das Backend-Limit liegt bei 4 pro App+Postfach).
.PARAMETER ChaosRate
    Anteil simulierter 429/503, wenn Chaos eingeschaltet ist (Default 0.30).
.PARAMETER AutoRun
    Nach dem Start automatisch Seed, 401, 404-Race und Burst ausfuehren,
    danach interaktiv weiter.

.NOTES
    NUR GEGEN EINEN TESTTENANT AUSFUEHREN. Beide App-Registrierungen
    benoetigen Mail.ReadWrite (Application), idealerweise per Application
    Access Policy auf das Testpostfach eingeschraenkt.
    Windows PowerShell 5.1 oder PowerShell 7 (Windows; WPF ist Windows-only).
    Startwege: als Datei (.\Demo-GraphThrottling.ps1), per Konsolen-Paste
    oder Run Selection (F8) - bei Paste/F8 werden Parameter-Defaults
    automatisch gesetzt und eine evtl. noch offene Instanz derselben
    Session vorher aufgeraeumt.

    Tasten (Konsole, auch parallel zum WPF-Fenster):
      [S]eed  [K]lonen  [1]=401  [4]=404-Race  [B]urst
      [P]ing-Pong an/aus  [C]haos an/aus  [X]=Cleanup  [M]enue  [Q]=Beenden
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
    [ValidateRange(0.0, 0.9)] [double]$ChaosRate = 0.30,
    [switch]$AutoRun
)

# ---------------------------------------------------------------------------
#  Run Selection (F8) / Paste-Support: dort laeuft param() nicht als Skript-
#  Parameterblock, bzw. die Defaults gehen bei Zeile-fuer-Zeile-Paste nach dem
#  param-Statement wieder verloren. Deshalb werden alle Parameter hier robust
#  normalisiert - der Datei-Start bleibt davon unberuehrt.
# ---------------------------------------------------------------------------
if (-not $PSCommandPath) {
    Write-Host '[i] Run Selection / Paste erkannt - Parameter werden auf Defaults normalisiert.' -ForegroundColor DarkCyan
    if ($null -eq $SeedCount   -or $SeedCount   -lt 1)                        { $SeedCount   = 12 }
    if ($null -eq $WorkerCount -or $WorkerCount -lt 1)                        { $WorkerCount = 6 }
    if ($null -eq $BurstSize   -or $BurstSize   -lt 5)                        { $BurstSize   = 10 }
    if ($null -eq $ChaosRate   -or $ChaosRate   -le 0 -or $ChaosRate -gt 0.9) { $ChaosRate   = 0.30 }
    foreach ($sw in 'NoGui', 'SkipSeed', 'Cleanup', 'AutoRun') {
        if ($null -eq (Get-Variable -Name $sw -ValueOnly -ErrorAction SilentlyContinue)) {
            Set-Variable -Name $sw -Value $false
        }
    }
}

# ---------------------------------------------------------------------------
#  Session-Hygiene fuer wiederholtes F8: Reste eines frueheren Laufs in
#  DERSELBEN Session (Zombie-Fenster, offener RunspacePool) sauber abbauen,
#  bevor die neue Instanz startet.
# ---------------------------------------------------------------------------
if ($Global:DemoGraphThrottling) {
    $prev = $Global:DemoGraphThrottling
    try { if ($prev.Sync) { $prev.Sync.Running = $false; $prev.Sync.CloseUi = $true } } catch { }
    Start-Sleep -Milliseconds 300
    try { if ($prev.UiPs)       { $prev.UiPs.Dispose() } }                                  catch { }
    try { if ($prev.UiRunspace) { $prev.UiRunspace.Close(); $prev.UiRunspace.Dispose() } }  catch { }
    try { if ($prev.Pool)       { $prev.Pool.Close(); $prev.Pool.Dispose() } }              catch { }
    $Global:DemoGraphThrottling = $null
    Write-Host '[i] Vorherige Demo-Instanz dieser Session aufgeraeumt.' -ForegroundColor DarkCyan
}

# =============================================================================
#  VARIABLEN - TESTTENANT (hier anpassen)                <<< NUR TESTTENANT >>>
# =============================================================================
$TenantId         = '00000000-0000-0000-0000-000000000000'
$Mailbox          = 'orchestra@testtenant.onmicrosoft.com'
$App1Id           = '<app1-client-id>'      # App-A: POLL-Lane, 1 reservierter Slot
$App1Secret       = '<app1-secret>'
$App2Id           = '<app2-client-id>'      # App-B: WORK-Lane
$App2Secret       = '<app2-secret>'
$SourceFolderName = 'Eingehend'             # Ordner A - wird angelegt, falls fehlt
$TargetFolderName = 'Verarbeitet'           # Ordner B - wird angelegt, falls fehlt
$BatchSize        = 25
$GraphRoot        = 'https://graph.microsoft.com/v1.0'
$MaxMailsGuard    = 200                     # Klon-Obergrenze (Kontingent-Schutz)
# =============================================================================

# ---------------------------------------------------------------------------
#  Geteilter Zustand (synchronisiert - Main, Worker und UI lesen/schreiben)
# ---------------------------------------------------------------------------
$Sync = [hashtable]::Synchronized(@{})
$Sync.Config = [hashtable]::Synchronized(@{
    TenantId  = $TenantId;  Mailbox = $Mailbox;  GraphRoot = $GraphRoot
    ChaosRate = 0.0                       # Toggle - Button/Taste schaltet auf $ChaosRate
    MaxAttempts = 6
    BackoffBase = 1.0; BackoffCap = 8.0   # Demo verkuerzt (Scaffold: 60 s)
    RetryAfterCap = 300.0; CooldownThreshold = 10.0
    GrowAfter = 8                         # Demo-Wert (Scaffold: 25) - Erholung sichtbar
})
$Sync.Counters  = [hashtable]::Synchronized(@{
    Processed = 0; Seeded = 0; Cloned = 0; Sweeps = 0; Queue = 0
    E401 = 0; E404 = 0; E429 = 0; E503 = 0
})
# Ownership-Tabelle (Rust-Analogie): Mail-ID -> @{Owner; Since; State}.
# Genau EIN Owner pro Mail. Transfer poller -> worker-N, Release im finally.
$Sync.Ownership    = [hashtable]::Synchronized(@{})
$Sync.LogQueue     = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$Sync.Commands     = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$Sync.UiLines      = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
$Sync.FolderIds    = [hashtable]::Synchronized(@{ A = ''; B = '' })
$Sync.FolderNames  = [hashtable]::Synchronized(@{ A = $SourceFolderName; B = $TargetFolderName })
$Sync.FolderCounts = [hashtable]::Synchronized(@{ A = 0; B = 0 })
$Sync.Direction    = 'AB'      # AB: A->B, BA: B->A (Ping-Pong dreht das um)
$Sync.PingPong     = $false
$Sync.Running      = $true
$Sync.Fatal        = $false
$Sync.CloseUi      = $false
$Sync.Phase        = 'Initialisierung'

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
#  Logging: Producer (Main + Worker + UI) -> Queue -> Konsole (Main) + WPF
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
    Add-DemoLog "  SZENARIO: $m" 'Magenta'
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
        [switch]$NoImmutableId     # nur fuer die Mutable-ID-Falle im 404-Szenario
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
                #     Call. Der ECHTE 429/503 kommt aus dem Burst-Szenario
                #     (Concurrency > 4). Chaos liefert den anhaltenden
                #     Drossel-Strom fuer den Ping-Pong-Mover, ohne das Limit
                #     dauerhaft zu verletzen.
                $sc = if ((Get-Random -Maximum 3) -eq 0) { 429 } else { 503 }
                if ($sc -eq 429) { $ra = [double](Get-Random -Minimum 3 -Maximum 15) }
                $simTag = ' (simuliert)'
            } else {
                $token = Get-DemoToken $App
                $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
                if (-not $NoImmutableId) {
                    # Konvention aus Resend-GraphReplay: stabile IDs ueber den
                    # Move hinweg. Das 404-Szenario laesst den Header bewusst weg.
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
                # verlorenes Claim-Race aus (Variante B) und bleibt hier still.
                $short = if ($detail.Length -gt 300) { $detail.Substring(0, 300) + ' ...' } else { $detail }
                if ($sc -ne 404) {
                    Write-Happened "[$($App.Name)] HTTP ${sc} permanent - $short"
                    if ($sc -eq 403) {
                        Write-Resolving "Berechtigung pruefen: Mail.ReadWrite (Application) mit Admin Consent; greift eine Application Access Policy, muss das Testpostfach in der Policy-Gruppe sein"
                    }
                }
                $ex = New-Object System.InvalidOperationException(
                    ("permanenter HTTP {0}: {1}" -f $sc, $short))
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
#  Richtung (Ping-Pong): AB = A->B, BA = B->A
# ---------------------------------------------------------------------------
function Get-DemoDirection {
    if ($Sync.Direction -eq 'AB') {
        return @{ SrcKey = 'A'; DstKey = 'B'
                  SrcId = $Sync.FolderIds['A']; DstId = $Sync.FolderIds['B']
                  SrcName = $Sync.FolderNames['A']; DstName = $Sync.FolderNames['B'] }
    }
    return @{ SrcKey = 'B'; DstKey = 'A'
              SrcId = $Sync.FolderIds['B']; DstId = $Sync.FolderIds['A']
              SrcName = $Sync.FolderNames['B']; DstName = $Sync.FolderNames['A'] }
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
    $dir = Get-DemoDirection
    $pp = if ($Sync.PingPong) { 'AN' } else { 'aus' }
    Write-Progress -Id 9 -Activity ("Ping-Pong [{0}]: {1} ({2}) -> {3} ({4})" -f `
            $pp, $dir.SrcName, $Sync.FolderCounts[$dir.SrcKey], $dir.DstName, $Sync.FolderCounts[$dir.DstKey]) `
        -Status ("moves={0} | Sweeps={1} | Queue={2} | Ownership={3} | 401={4} 404={5} 429={6} 503={7}" -f `
                 $c.Processed, $c.Sweeps, $c.Queue, $Sync.Ownership.Count, $c.E401, $c.E404, $c.E429, $c.E503) `
        -PercentComplete 0
}
function Wait-DemoSeconds {
    param([double]$Seconds)
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) { Flush-DemoLog; Show-DemoBars; Start-Sleep -Milliseconds 150 }
}

# ---------------------------------------------------------------------------
#  Graph-Helfer. OData bewusst als Roh-String mit Leerzeichen -
#  Invoke-RestMethod encodiert implizit (Konvention Resend-GraphReplay).
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
function Update-DemoFolderCounts {
    # totalItemCount ist ein billiger Ordner-Property-Read - 2 Requests.
    foreach ($key in 'A', 'B') {
        try {
            $r = Invoke-DemoGraphRequest -Method GET -Lane POLL `
                    -Uri "$($Sync.Config.GraphRoot)/users/$($Sync.Config.Mailbox)/mailFolders/$($Sync.FolderIds[$key])?`$select=totalItemCount"
            $Sync.FolderCounts[$key] = [int]$r.totalItemCount
        } catch { }
    }
}
function Add-DemoMails {
    param([string]$FolderId, [int]$Count)
    # Drafts direkt im Ordner erzeugen - kein Mailflow noetig, Move geht trotzdem.
    for ($i = 1; $i -le $Count; $i++) {
        $body = @{
            subject = ('Orchestra-Demo #{0:d3}' -f ([int]$Sync.Counters.Seeded + 1))
            body    = @{ contentType = 'Text'; content = "Durchstich - erzeugt $(Get-Date -Format s)" }
            toRecipients = @(@{ emailAddress = @{ address = $Sync.Config.Mailbox } })
        } | ConvertTo-Json -Depth 5
        [void](Invoke-DemoGraphRequest -Method POST -Lane WORK `
                 -Uri "$($Sync.Config.GraphRoot)/users/$($Sync.Config.Mailbox)/mailFolders/$FolderId/messages" `
                 -Body $body)
        Step-DemoCounter 'Seeded'
        if ($i % 4 -eq 0) { Flush-DemoLog; Show-DemoBars }
    }
    Write-Ok "$Count Demo-Mails erzeugt"
    Update-DemoFolderCounts
}
function Copy-DemoMails {
    param([string]$FolderId)
    # Lastvervielfachung aus wenig Material: /copy erzeugt eine neue Message
    # (neue ID) im selben Ordner -> Bestand verdoppelt sich pro Klick.
    Update-DemoFolderCounts
    $dir = Get-DemoDirection
    $current = [int]$Sync.FolderCounts[$dir.SrcKey]
    if ($current -ge $MaxMailsGuard) {
        Write-Happened "Klon-Schutz: $current Mails >= Obergrenze $MaxMailsGuard - kein weiteres Klonen"
        Write-Resolving "Ping-Pong laufen lassen oder Cleanup - der Schutz haelt das 10k-Kontingent sauber"
        return
    }
    $uri = "$($Sync.Config.GraphRoot)/users/$($Sync.Config.Mailbox)/mailFolders/$FolderId/messages?`$top=100&`$orderby=receivedDateTime asc&`$select=id,subject"
    $r = Invoke-DemoGraphRequest -Method GET -Lane WORK -Uri $uri
    $items = @($r.value)
    if ($items.Count -eq 0) { Add-DemoLog '  [i] Klonen: Quellordner ist leer' 'Gray'; return }
    $n = 0
    foreach ($m in $items) {
        [void](Invoke-DemoGraphRequest -Method POST -Lane WORK `
                 -Uri "$($Sync.Config.GraphRoot)/users/$($Sync.Config.Mailbox)/messages/$($m.id)/copy" `
                 -Body (@{ destinationId = $FolderId } | ConvertTo-Json))
        Step-DemoCounter 'Cloned'
        $n++
        if ($n % 5 -eq 0) { Flush-DemoLog; Show-DemoBars }
    }
    Update-DemoFolderCounts
    Write-Ok ("Klonen: {0} Mails dupliziert -> '{1}' haelt jetzt {2}" -f `
              $n, $dir.SrcName, $Sync.FolderCounts[$dir.SrcKey])
}
function Remove-DemoMails {
    param([string]$FolderId)
    $uri = "$($Sync.Config.GraphRoot)/users/$($Sync.Config.Mailbox)/mailFolders/$FolderId/messages?`$top=100&`$orderby=receivedDateTime asc&`$select=id,subject"
    $n = 0
    do {
        $r = Invoke-DemoGraphRequest -Method GET -Lane WORK -Uri $uri
        $hits = @($r.value | Where-Object { $_.subject -like 'Orchestra-Demo*' -or $_.subject -like 'Race-Kandidat*' })
        foreach ($m in $hits) {
            [void](Invoke-DemoGraphRequest -Method DELETE -Lane WORK `
                     -Uri "$($Sync.Config.GraphRoot)/users/$($Sync.Config.Mailbox)/messages/$($m.id)")
            $n++
            if ($n % 5 -eq 0) { Flush-DemoLog; Show-DemoBars }
        }
    } while ($hits.Count -gt 0)
    return $n
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
                Write-Resolving "Retry-After respektiert - warte ${ra}s vor dem naechsten Szenario"
                Wait-DemoSeconds $ra
            }
        } else {
            Add-DemoLog "  [i] ${ok}/${Count} ok, ${failed} Fehler - Backend hat den Burst diesmal toleriert (Timing). Erneut ausloesen oder -BurstSize erhoehen." 'Gray'
        }
    } finally { $client.Dispose() }
}

# ---------------------------------------------------------------------------
#  Szenarien (Button/Taste -> Command-Queue -> Dispatcher)
# ---------------------------------------------------------------------------
function Invoke-Scenario401 {
    Write-Phase '401 provozieren (ECHT): Token absichtlich korrumpieren'
    $appA = $Sync.Apps['A']
    [System.Threading.Monitor]::Enter($appA.SyncRoot)
    try {
        $appA.Token = 'eyJkaputt.' + (Get-Random)          # kaputtes Bearer-Token
        $appA.TokenExpiry = (Get-Date).AddHours(1)         # Skew-Check austricksen
    } finally { [System.Threading.Monitor]::Exit($appA.SyncRoot) }
    Add-DemoLog '  Token von app-a korrumpiert - der naechste Aufruf laeuft in ein echtes 401 ...' 'Gray'
    [void](Invoke-DemoGraphRequest -Method GET -Lane POLL `
             -Uri "$GraphRoot/users/$Mailbox/mailFolders/$($Sync.FolderIds['A'])?`$select=id,displayName")
    Write-Ok '401-Pfad durchlaufen: Invalidate -> Refresh -> Retry erfolgreich'
}
function Invoke-Scenario404Race {
    Write-Phase '404 Claim-Race provozieren (ECHT) + Mutable-ID-Falle'
    $srcId = $Sync.FolderIds['A']; $dstId = $Sync.FolderIds['B']
    $raceBody = @{
        subject = 'Race-Kandidat'
        body    = @{ contentType = 'Text'; content = 'Zwei Instanzen, ein Move.' }
        toRecipients = @(@{ emailAddress = @{ address = $Mailbox } })
    } | ConvertTo-Json -Depth 5
    [void](Invoke-DemoGraphRequest -Method POST -Lane WORK -NoImmutableId `
             -Uri "$GraphRoot/users/$Mailbox/mailFolders/$srcId/messages" -Body $raceBody)
    # Bewusst OHNE Prefer-Header lesen -> wir bekommen die MUTABLE ID.
    $probe = Invoke-DemoGraphRequest -Method GET -Lane POLL -NoImmutableId `
                 -Uri "$GraphRoot/users/$Mailbox/mailFolders/$srcId/messages?`$top=1&`$orderby=receivedDateTime desc&`$select=id,subject"
    $raceId = $probe.value[0].id
    Add-DemoLog "  Instanz 1 verschiebt '$($probe.value[0].subject)' ..." 'Gray'
    [void](Invoke-DemoGraphRequest -Method POST -Lane WORK -NoImmutableId `
             -Uri "$GraphRoot/users/$Mailbox/messages/$raceId/move" `
             -Body (@{ destinationId = $dstId } | ConvertTo-Json))
    Write-Ok 'Instanz 1 hat den Move gewonnen'
    Add-DemoLog '  Instanz 2 versucht denselben Move mit der ALTEN (mutable) ID ...' 'Gray'
    try {
        [void](Invoke-DemoGraphRequest -Method POST -Lane WORK -NoImmutableId `
                 -Uri "$GraphRoot/users/$Mailbox/messages/$raceId/move" `
                 -Body (@{ destinationId = $dstId } | ConvertTo-Json))
        Add-DemoLog '  [?] Unerwartet: zweiter Move ohne 404 durchgelaufen' 'Red'
    } catch {
        if ($_.Exception.Data['Status'] -eq 404) {
            Step-DemoCounter 'E404'
            Write-Happened '404 ItemNotFound - Instanz 2 verliert das Claim-Race (alte ID nach Move ungueltig)'
            Write-Resolving "Skip - Ownership liegt beim Gewinner. Schutz im Scaffold: Prefer IdType='ImmutableId' + ID aus der Move-Response"
        } else { throw }
    }
    Update-DemoFolderCounts
}
function Invoke-ScenarioCleanup {
    Write-Phase 'Cleanup: Demo-Mails aus beiden Ordnern loeschen'
    $n = 0
    foreach ($key in 'A', 'B') { $n += Remove-DemoMails -FolderId $Sync.FolderIds[$key] }
    Write-Ok "Cleanup: $n Demo-Mail(s) geloescht"
    Update-DemoFolderCounts
}
function Show-DemoMenu {
    Add-DemoLog '  ----------------------------------------------------------------' 'White'
    Add-DemoLog '  [S]eed   [K]lonen x2   [1]=401   [4]=404-Race   [B]urst 429/503' 'White'
    Add-DemoLog '  [P]ing-Pong an/aus   [C]haos an/aus   [X]=Cleanup   [Q]=Beenden' 'White'
    Add-DemoLog '  ----------------------------------------------------------------' 'White'
}

# ---------------------------------------------------------------------------
#  WPF-Dashboard mit Szenario-Buttons (eigener STA-Runspace)
#  Buttons schreiben NUR in die Command-Queue - ausgefuehrt wird im Main-
#  Dispatcher. Die UI bleibt dadurch reaktiv, egal was ein Szenario tut.
# ---------------------------------------------------------------------------
$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="tokenhandler - Orchestra Graph-Throttling-Demo"
        Height="720" Width="960" WindowStartupLocation="CenterScreen"
        Background="#FF1B1B1B" Foreground="#FFEAEAEA" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Padding" Value="10,5"/>
      <Setter Property="Background" Value="#FF2D2D2D"/>
      <Setter Property="Foreground" Value="#FFEAEAEA"/>
      <Setter Property="BorderBrush" Value="#FF555555"/>
    </Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,8">
      <TextBlock Text="Graph-Throttling-Demo" FontSize="20" FontWeight="Bold"/>
      <TextBlock x:Name="PhaseText" Text="Initialisierung" FontSize="14" Foreground="#FFE2001A" Margin="0,2,0,0"/>
    </StackPanel>

    <StackPanel Grid.Row="1" Margin="0,0,0,8">
      <WrapPanel>
        <Button x:Name="BtnSeed"    Content="Seed"/>
        <Button x:Name="BtnClone"   Content="Klonen x2"/>
        <Button x:Name="Btn401"     Content="401 (echt)"/>
        <Button x:Name="BtnRace"    Content="404-Race (echt)"/>
        <Button x:Name="BtnBurst"   Content="Burst 429/503 (echt)"/>
        <Button x:Name="BtnPing"    Content="Ping-Pong: AUS" FontWeight="Bold"/>
        <Button x:Name="BtnChaos"   Content="Chaos: AUS"/>
        <Button x:Name="BtnCleanup" Content="Cleanup"/>
        <Button x:Name="BtnQuit"    Content="Beenden"/>
      </WrapPanel>
      <TextBlock x:Name="DirText" FontFamily="Consolas" FontSize="13" Margin="0,2,0,0" Text="-"/>
    </StackPanel>

    <UniformGrid Grid.Row="2" Columns="2">
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

    <TextBlock Grid.Row="3" x:Name="CountersText" FontFamily="Consolas" FontSize="13"
               Margin="0,10,0,8" Text="-"/>

    <ListBox Grid.Row="4" x:Name="LogList" Background="#FF101010" BorderBrush="#FF333333"
             Foreground="#FFB8B8B8" FontFamily="Consolas" FontSize="12"
             ScrollViewer.HorizontalScrollBarVisibility="Auto"/>
  </Grid>
</Window>
'@

$UiRunspace = $null; $UiPs = $null; $UiHandle = $null
$UseGui = -not $NoGui
if ($UseGui) {
    try { Add-Type -AssemblyName PresentationFramework -ErrorAction Stop } catch {
        Write-Host 'WPF nicht verfuegbar - Fallback auf -NoGui (Write-Progress + Tasten).' -ForegroundColor Yellow
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
                          'BarInFlightB','BarLimitB','BarTokenB','CountersText','LogList','DirText',
                          'BtnSeed','BtnClone','Btn401','BtnRace','BtnBurst','BtnPing','BtnChaos',
                          'BtnCleanup','BtnQuit') {
            $ctl[$name] = $window.FindName($name)
        }
        # Buttons -> Command-Queue (der Main-Dispatcher fuehrt aus)
        $ctl['BtnSeed'].Add_Click({    $Sync.Commands.Enqueue('seed') })
        $ctl['BtnClone'].Add_Click({   $Sync.Commands.Enqueue('clone') })
        $ctl['Btn401'].Add_Click({     $Sync.Commands.Enqueue('p401') })
        $ctl['BtnRace'].Add_Click({    $Sync.Commands.Enqueue('race') })
        $ctl['BtnBurst'].Add_Click({   $Sync.Commands.Enqueue('burst') })
        $ctl['BtnPing'].Add_Click({    $Sync.Commands.Enqueue('pingpong') })
        $ctl['BtnChaos'].Add_Click({   $Sync.Commands.Enqueue('chaos') })
        $ctl['BtnCleanup'].Add_Click({ $Sync.Commands.Enqueue('cleanup') })
        $ctl['BtnQuit'].Add_Click({    $Sync.Commands.Enqueue('quit') })
        $window.Add_Closed({           $Sync.Commands.Enqueue('quit') })
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
            $ctl['CountersText'].Text = ("moves {0}   Sweeps {1}   Queue {2}   Ownership {3}   |   401={4}  404={5}  429={6}  503={7}   |   geseedet {8}  geklont {9}" -f `
                $c.Processed, $c.Sweeps, $c.Queue, $Sync.Ownership.Count, $c.E401, $c.E404, $c.E429, $c.E503, $c.Seeded, $c.Cloned)
            $ctl['PhaseText'].Text = $Sync.Phase
            $ctl['BtnPing'].Content = if ($Sync.PingPong) { 'Ping-Pong: AN' } else { 'Ping-Pong: AUS' }
            $ctl['BtnChaos'].Content = if ($Sync.Config.ChaosRate -gt 0) { ('Chaos: {0:P0}' -f $Sync.Config.ChaosRate) } else { 'Chaos: AUS' }
            if ($Sync.Direction -eq 'AB') { $srcKey = 'A'; $dstKey = 'B' } else { $srcKey = 'B'; $dstKey = 'A' }
            $ctl['DirText'].Text = ("Richtung: {0} ({1})  ->  {2} ({3})" -f `
                $Sync.FolderNames[$srcKey], $Sync.FolderCounts[$srcKey], $Sync.FolderNames[$dstKey], $Sync.FolderCounts[$dstKey])
            while ($script:uiIx -lt $Sync.UiLines.Count) {
                $e = $Sync.UiLines[$script:uiIx]; $script:uiIx++
                $item = New-Object Windows.Controls.ListBoxItem
                $item.Content = ("{0} {1}" -f $e.T, $e.Text)
                $hex = $colorMap[$e.Color]; if (-not $hex) { $hex = '#FFB8B8B8' }
                $item.Foreground = $bc.ConvertFromString($hex)
                [void]$ctl['LogList'].Items.Add($item)
                if ($ctl['LogList'].Items.Count -gt 800) { $ctl['LogList'].Items.RemoveAt(0) }
            }
            if ($ctl['LogList'].Items.Count -gt 0) {
                $ctl['LogList'].ScrollIntoView($ctl['LogList'].Items[$ctl['LogList'].Items.Count - 1])
            }
            if (-not $Sync.Running -and -not $Sync.Fatal) { $ctl['PhaseText'].Text = 'Demo beendet - Fenster kann geschlossen werden' }
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

# Handle fuer die Session-Hygiene beim naechsten F8-Lauf (siehe Skriptkopf)
$Global:DemoGraphThrottling = @{ Sync = $Sync; UiPs = $UiPs; UiRunspace = $UiRunspace; Pool = $Pool }

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
        Start-Sleep -Milliseconds (Get-Random -Minimum 150 -Maximum 600)   # Fachlogik-Attrappe
        Step-DemoCounter 'Processed'
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
#  DISPATCHER
# =============================================================================
$jobs = [System.Collections.Generic.List[object]]::new()
try {
    Write-Phase 'Start - Ordner aufloesen, Tokens holen'
    Flush-DemoLog
    Add-DemoLog "  pruefe/erzeuge Ordner '$SourceFolderName' ..." 'Gray'
    $Sync.FolderIds['A'] = Get-DemoFolderId $SourceFolderName
    Flush-DemoLog
    Add-DemoLog "  pruefe/erzeuge Ordner '$TargetFolderName' ..." 'Gray'
    $Sync.FolderIds['B'] = Get-DemoFolderId $TargetFolderName
    Flush-DemoLog
    foreach ($key in 'A', 'B') { [void](Get-DemoToken $Sync.Apps[$key]) }   # Token-Bars fuellen
    Update-DemoFolderCounts
    Flush-DemoLog; Show-DemoBars

    if (-not $SkipSeed) { $Sync.Commands.Enqueue('seed') }
    if ($AutoRun) {
        Add-DemoLog '  AutoRun: 401 -> 404-Race -> Burst werden automatisch ausgefuehrt' 'White'
        foreach ($cmd in 'p401', 'race', 'burst') { $Sync.Commands.Enqueue($cmd) }
    }
    $Sync.Phase = 'Bereit - Szenario per Button oder Taste ausloesen'
    Show-DemoMenu
    Flush-DemoLog

    $lastCountRefresh = Get-Date
    while ($Sync.Running) {

        # --- 1) Kommandos aus Buttons/Tasten abarbeiten -------------------
        while ($Sync.Commands.Count -gt 0 -and $Sync.Running) {
            $cmd = [string]$Sync.Commands.Dequeue()
            try {
                switch ($cmd) {
                    'seed'  { Write-Phase "Seed: $SeedCount Demo-Mails"
                              $dir = Get-DemoDirection
                              Add-DemoMails -FolderId $dir.SrcId -Count $SeedCount }
                    'clone' { Write-Phase 'Klonen x2: Bestand im Quellordner verdoppeln'
                              $dir = Get-DemoDirection
                              Copy-DemoMails -FolderId $dir.SrcId }
                    'p401'  { Invoke-Scenario401 }
                    'race'  { Invoke-Scenario404Race }
                    'burst' { Write-Phase ("Burst (ECHT): {0} parallele Zugriffe gegen das 4er-Concurrency-Limit" -f $BurstSize)
                              $dir = Get-DemoDirection
                              Invoke-DemoConcurrencyBurst -FolderId $dir.SrcId -Count $BurstSize }
                    'pingpong' {
                        $Sync.PingPong = -not $Sync.PingPong
                        if ($Sync.PingPong) {
                            $dir = Get-DemoDirection
                            Write-Phase ("Ping-Pong AN: {0} <-> {1} - Dauerlast bis zum Abschalten" -f $dir.SrcName, $dir.DstName)
                        } else {
                            Write-Phase 'Ping-Pong AUS - laufende Worker ziehen noch durch'
                        }
                    }
                    'chaos' {
                        if ($Sync.Config.ChaosRate -gt 0) {
                            $Sync.Config.ChaosRate = 0.0
                            Write-Phase 'Chaos AUS - nur noch echte Antworten'
                        } else {
                            $Sync.Config.ChaosRate = $ChaosRate
                            Write-Phase ("Chaos AN ({0:P0} simulierte 429/503)" -f $ChaosRate)
                        }
                    }
                    'cleanup' { Invoke-ScenarioCleanup }
                    'quit'    { $Sync.Running = $false }
                }
            } catch {
                Add-DemoLog "  [x] Szenario '$cmd' fehlgeschlagen: $($_.Exception.Message)" 'Red'
            }
            Flush-DemoLog; Show-DemoBars
        }
        if (-not $Sync.Running) { break }

        # --- 2) Ping-Pong-Mover: a<>b<>a<>b ------------------------------
        if ($Sync.PingPong) {
            $dir = Get-DemoDirection
            $msgs = @()
            try {
                # FIFO: aelteste zuerst ($orderby). Der Ordner selbst ist die Queue.
                $uri = "$GraphRoot/users/$Mailbox/mailFolders/$($dir.SrcId)/messages?`$top=$BatchSize&`$orderby=receivedDateTime asc&`$select=id,subject"
                $msgs = @((Invoke-DemoGraphRequest -Method GET -Lane POLL -Uri $uri).value)
            } catch {
                Add-DemoLog "  [x] Poll fehlgeschlagen: $($_.Exception.Message)" 'Red'
            }
            foreach ($m in $msgs) {
                if (Lock-DemoMail $m.id 'poller') {           # TryAcquire - genau ein Owner
                    Step-DemoCounter 'Queue'
                    $ps = [powershell]::Create()
                    $ps.RunspacePool = $Pool
                    [void]$ps.AddScript($WorkerScript).AddArgument($m.id).AddArgument($m.subject).AddArgument($dir.DstId)
                    $jobs.Add(@{ PS = $ps; H = $ps.BeginInvoke() })
                }
            }
            if ($msgs.Count -eq 0 -and $jobs.Count -eq 0 -and $Sync.Ownership.Count -eq 0) {
                # Quelle leer, alles verarbeitet -> Richtung drehen und weiter.
                $Sync.Direction = if ($Sync.Direction -eq 'AB') { 'BA' } else { 'AB' }
                Step-DemoCounter 'Sweeps'
                Update-DemoFolderCounts
                $ndir = Get-DemoDirection
                Add-DemoLog ("  Richtungswechsel (Sweep #{0}): jetzt {1} ({2}) -> {3} ({4})" -f `
                    [int]$Sync.Counters.Sweeps, $ndir.SrcName, $Sync.FolderCounts[$ndir.SrcKey], `
                    $ndir.DstName, $Sync.FolderCounts[$ndir.DstKey]) 'Magenta'
            }
        }

        # --- 3) fertige Worker einsammeln ---------------------------------
        for ($j = $jobs.Count - 1; $j -ge 0; $j--) {
            if ($jobs[$j].H.IsCompleted) {
                try { [void]$jobs[$j].PS.EndInvoke($jobs[$j].H) }
                catch { Add-DemoLog "  [x] Worker-Abschluss: $($_.Exception.Message)" 'Red' }
                $jobs[$j].PS.Dispose()
                $jobs.RemoveAt($j)
            }
        }

        # --- 4) Konsolen-Tasten (auch parallel zum WPF-Fenster) -----------
        try {
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true).Key
                switch ($k) {
                    'S' { $Sync.Commands.Enqueue('seed') }
                    'K' { $Sync.Commands.Enqueue('clone') }
                    'D1' { $Sync.Commands.Enqueue('p401') };  'NumPad1' { $Sync.Commands.Enqueue('p401') }
                    'D4' { $Sync.Commands.Enqueue('race') };  'NumPad4' { $Sync.Commands.Enqueue('race') }
                    'B' { $Sync.Commands.Enqueue('burst') }
                    'P' { $Sync.Commands.Enqueue('pingpong') }
                    'C' { $Sync.Commands.Enqueue('chaos') }
                    'X' { $Sync.Commands.Enqueue('cleanup') }
                    'M' { Show-DemoMenu }
                    'Q' { $Sync.Commands.Enqueue('quit') }
                }
            }
        } catch {
            # Host ohne interaktive Konsole (z. B. ISE bei F8): Tasten aus,
            # einmalig sichtbar machen - die Buttons uebernehmen.
            if (-not $script:KeysUnavailableNoted) {
                $script:KeysUnavailableNoted = $true
                Add-DemoLog '  [i] Tastensteuerung in diesem Host nicht verfuegbar - Szenarien ueber die WPF-Buttons ausloesen' 'Gray'
            }
        }

        Flush-DemoLog; Show-DemoBars
        if (((Get-Date) - $lastCountRefresh).TotalSeconds -ge 5) {
            Update-DemoFolderCounts
            $lastCountRefresh = Get-Date
        }
        Start-Sleep -Milliseconds ($(if ($Sync.PingPong) { 400 } else { 200 }))
    }

    # --- laufende Worker sauber ausziehen lassen (max. 30 s) --------------
    $deadline = (Get-Date).AddSeconds(30)
    while ($jobs.Count -gt 0 -and (Get-Date) -lt $deadline) {
        for ($j = $jobs.Count - 1; $j -ge 0; $j--) {
            if ($jobs[$j].H.IsCompleted) {
                try { [void]$jobs[$j].PS.EndInvoke($jobs[$j].H) } catch { }
                $jobs[$j].PS.Dispose()
                $jobs.RemoveAt($j)
            }
        }
        Flush-DemoLog; Show-DemoBars
        Start-Sleep -Milliseconds 200
    }

    if ($Cleanup) { Invoke-ScenarioCleanup }

    $c = $Sync.Counters
    Update-DemoFolderCounts
    Write-Phase 'Zusammenfassung'
    Add-DemoLog ("  moves: {0}   Sweeps: {1}   geseedet: {2}   geklont: {3}" -f `
                 $c.Processed, $c.Sweeps, $c.Seeded, $c.Cloned) 'White'
    Add-DemoLog ("  401={0}  404={1}  429={2}  503={3}  (Burst echt + Chaos simuliert)" -f `
                 $c.E401, $c.E404, $c.E429, $c.E503) 'White'
    Add-DemoLog ("  {0}: {1} Mails   |   {2}: {3} Mails   |   App-A Limit={4}/4  App-B Limit={5}/4" -f `
                 $SourceFolderName, $Sync.FolderCounts['A'], $TargetFolderName, $Sync.FolderCounts['B'], `
                 $Sync.Apps['A'].Limit, $Sync.Apps['B'].Limit) 'White'
    Flush-DemoLog
}
catch {
    # Zentraler Abbruch-Handler: der Grund muss VOR dem Enter-Prompt auf dem
    # Schirm stehen - vorher verschluckte das finally/Read-Host die Meldung.
    $Sync.Fatal = $true
    $Sync.Phase = 'ABBRUCH - siehe Log'
    Add-DemoLog ('=' * 72) 'Red'
    Add-DemoLog "  ABBRUCH: $($_.Exception.Message)" 'Red'
    if ($_.ScriptStackTrace) {
        Add-DemoLog ('  bei: ' + (($_.ScriptStackTrace -split "`n")[0]).Trim()) 'DarkGray'
    }
    Add-DemoLog '  Checkliste: TenantId/Secrets korrekt? Mailbox-UPN existiert? Mail.ReadWrite (Application) mit Admin Consent erteilt? Application Access Policy schliesst das Testpostfach ein?' 'White'
    Add-DemoLog ('=' * 72) 'Red'
}
finally {
    $Sync.Running = $false
    Flush-DemoLog
    foreach ($id in 1, 2, 9) { Write-Progress -Id $id -Activity 'fertig' -Completed }
    if ($UseGui -and $UiPs) {
        if (-not $UiHandle.IsCompleted) {
            Read-Host 'Enter schliesst das WPF-Fenster'
            $Sync.CloseUi = $true
            Start-Sleep -Milliseconds 400
        }
        try { $UiPs.EndInvoke($UiHandle) } catch { }
        $UiPs.Dispose(); $UiRunspace.Close(); $UiRunspace.Dispose()
    }
    $Pool.Close(); $Pool.Dispose()
    $Global:DemoGraphThrottling = $null
}
