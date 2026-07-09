<#
.SYNOPSIS
    Kalibrier-Pruefstand fuer das Graph MailboxConcurrency-Limit gegen einen
    TESTTENANT. Misst die Throttle-Grenze statistisch und bewertet, ob ein
    adaptiver Rolling-Floor-Regler gegenueber einem statischen Limit hilft.

.DESCRIPTION
    Drei Modi (-Mode):

      Sweep     Rampt die Concurrency Min..Max, feuert pro Stufe echte,
                UEBERLAPPENDE parallele Requests (ServicePoint-Fix), ueber
                mehrere Sweeps. Ergebnis:
                  - Kurve Throttle-Wahrscheinlichkeit p(N) je Stufe mit
                    WILSON-95%-Konfidenzintervall (Fehlerbalken).
                  - Grenze N* als Verteilung: Mittel, Standardabweichung,
                    t-basiertes 95%-Konfidenzintervall.
                  - calibration.json als Startkonfig fuer den Prod-Handler.
                  - kalibrierung.html (portable SVG-Kurve) + PNG (WinForms,
                    falls verfuegbar).

      Adaptive  Faehrt den Rolling-Floor-Regler ueber -AdaptiveOps Ticks:
                EWMA-Mittel + EW-Standardabweichung der sicheren Concurrency,
                Floor = max(1, floor(Mittel - k*SD)). Fail-fast beim Throttle,
                recover-slow bei Erfolg. Loggt die Floor-Trajektorie und
                rendert sie (floor-trajectory.html).

      AB        Versiegeltes A/B-Fenster: identische Last einmal unter einem
                STATISCHEN Limit (Control) und einmal unter dem Rolling-Floor
                (Treatment), interleaved in Bloecken gegen Zeitdrift. Wertet
                Throttle-Rate (Zwei-Proportionen-z-Test) und Goodput aus und
                sagt, OB und WIE SIGNIFIKANT die Adaption hilft.

    NUR GEGEN EINEN TESTTENANT. Der Sweep provoziert absichtlich Throttling.
    App braucht Mail.Read (bzw. Mail.ReadWrite fuer -Operation Copy),
    Application-Permission mit Admin Consent, idealerweise Application Access
    Policy auf das Testpostfach. Vorher genug Mails im Postfach (z.B. via der
    Ping-Pong-Demo "Klonen x2"), damit die Reads schwer genug sind.

.NOTES
    Windows PowerShell 5.1 oder PowerShell 7. Secret bitte rotieren /
    ueber $env:GRAPH_APP_SECRET setzen - der Klartext hier ist Testtenant.
#>
[CmdletBinding()]
param(
    [ValidateSet('Sweep','Adaptive','AB')] [string]$Mode = 'Sweep',

    # --- Testtenant: per Umgebungsvariablen setzen, NIE hart eintragen ------
    #   $env:GRAPH_TENANT_ID / GRAPH_MAILBOX / GRAPH_APP_ID / GRAPH_APP_SECRET
    [string]$TenantId  = $(if ($env:GRAPH_TENANT_ID)  { $env:GRAPH_TENANT_ID }  else { '<TENANT-ID>' }),
    [string]$Mailbox   = $(if ($env:GRAPH_MAILBOX)    { $env:GRAPH_MAILBOX }    else { '<mailbox@example.com>' }),
    [string]$AppId     = $(if ($env:GRAPH_APP_ID)     { $env:GRAPH_APP_ID }     else { '<APP-ID>' }),
    [string]$AppSecret = $(if ($env:GRAPH_APP_SECRET) { $env:GRAPH_APP_SECRET } else { '' }),

    # --- Sweep -------------------------------------------------------------
    [ValidateRange(1,64)]  [int]$MinN   = 1,
    [ValidateRange(2,64)]  [int]$MaxN   = 12,
    [ValidateRange(3,200)] [int]$Sweeps = 15,     # zugleich n fuer Wilson-CI je Stufe
    [double]$Cooldown = 1.5,                       # s zwischen Bursts (Concurrency clearen)
    [ValidateSet('Read','Copy')] [string]$Operation = 'Read',

    # --- Rolling-Floor-Regler ---------------------------------------------
    [double]$SdMargin = 1.0,     # k in Floor = Mittel - k*SD  (Konfidenzabstand)
    [double]$AlphaUp   = 0.15,   # recover slow  (kleiner)
    [double]$AlphaDown = 0.50,   # fail fast     (groesser)
    [int]$ProbeEvery = 5,        # jede n-te Tick tastet Floor+1

    # --- Adaptive / AB -----------------------------------------------------
    [int]$AdaptiveOps = 120,     # Ticks im Adaptive-Modus
    [int]$ControlLimit = 8,      # statisches Limit im AB-Control (bewusst > echt)
    [int]$AbBlock = 20,          # Ops je Block
    [int]$AbRounds = 4,          # interleavte Control/Treatment-Runden

    [string]$OutDir = "$PSScriptRoot\calib_$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
)

# --- Umgebung ---------------------------------------------------------------
[System.Net.ServicePointManager]::DefaultConnectionLimit = 256   # >> sonst nur 2 parallel in 5.1
[System.Net.ServicePointManager]::Expect100Continue      = $false
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }
$GraphRoot = 'https://graph.microsoft.com/v1.0'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ===========================================================================
#  Statistik
# ===========================================================================
function Get-WilsonCI {
    # 95%-Konfidenzintervall einer Proportion (k von n), Wilson-Score.
    param([int]$k, [int]$n, [double]$z = 1.959964)
    if ($n -le 0) { return [pscustomobject]@{ P=0.0; Lo=0.0; Hi=0.0 } }
    $p = $k / $n; $z2 = $z*$z; $den = 1 + $z2/$n
    $center = ($p + $z2/(2*$n)) / $den
    $half   = ($z * [math]::Sqrt(($p*(1-$p) + $z2/(4*$n)) / $n)) / $den
    [pscustomobject]@{ P=$p; Lo=[math]::Max(0,$center-$half); Hi=[math]::Min(1,$center+$half) }
}
$Script:TTable = @{ 1=12.706;2=4.303;3=3.182;4=2.776;5=2.571;6=2.447;7=2.365;8=2.306;9=2.262;10=2.228;
    11=2.201;12=2.179;13=2.160;14=2.145;15=2.131;16=2.120;17=2.110;18=2.101;19=2.093;20=2.086;
    21=2.080;22=2.074;23=2.069;24=2.064;25=2.060;26=2.056;27=2.052;28=2.048;29=2.045;30=2.042 }
function Get-TCrit { param([int]$df)
    if ($df -le 0) { return 12.706 }
    if ($Script:TTable.ContainsKey($df)) { return $Script:TTable[$df] }
    return 1.96
}
function Get-MeanSd {
    param([double[]]$x)
    $n = $x.Count
    if ($n -eq 0) { return [pscustomobject]@{ N=0;Mean=0;Sd=0 } }
    $m = ($x | Measure-Object -Average).Average
    $sd = if ($n -lt 2) { 0.0 } else { [math]::Sqrt((($x | ForEach-Object { ($_-$m)*($_-$m) }) | Measure-Object -Sum).Sum / ($n-1)) }
    [pscustomobject]@{ N=$n; Mean=$m; Sd=$sd }
}
function Get-TwoPropZ {
    # Zwei-Proportionen-z-Test: p1 (control) vs p2 (treatment).
    param([int]$k1,[int]$n1,[int]$k2,[int]$n2)
    if ($n1 -le 0 -or $n2 -le 0) { return [pscustomobject]@{ P1=0;P2=0;Z=0;PValue=1;Diff=0 } }
    $p1=$k1/$n1; $p2=$k2/$n2; $pp=($k1+$k2)/($n1+$n2)
    $se=[math]::Sqrt($pp*(1-$pp)*(1.0/$n1+1.0/$n2))
    $z= if ($se -gt 0) { ($p1-$p2)/$se } else { 0.0 }
    # zweiseitiger p-Wert aus Normal-CDF (Abramowitz-Stegun-Approx.)
    $az=[math]::Abs($z); $t=1/(1+0.2316419*$az)
    $d=0.3989423*[math]::Exp(-$az*$az/2)
    $pv=$d*($t*(0.3193815+$t*(-0.3565638+$t*(1.781478+$t*(-1.821256+$t*1.330274)))))
    $pTwo=2*$pv
    [pscustomobject]@{ P1=$p1; P2=$p2; Z=$z; PValue=[math]::Min(1,$pTwo); Diff=($p1-$p2) }
}

# ===========================================================================
#  Token + der eine Burst
# ===========================================================================
function Get-Token {
    $body = @{ client_id=$AppId; client_secret=$AppSecret
               scope='https://graph.microsoft.com/.default'; grant_type='client_credentials' }
    $uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    (Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/x-www-form-urlencoded' -Body $body).access_token
}

function Invoke-ConcurrencyBurst {
    # Feuert $N ECHT parallele Requests. Klassifiziert Concurrency-429 (billig)
    # vs. Rate-429-mit-Retry-After (teuer) vs. 503/504. Gibt Zaehler + Wall-Zeit.
    param([int]$N, [string]$Token, [string]$SourceFolderId, [string]$TargetFolderId)
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(100)
    try {
        # Read: schwerer GET (Body mitziehen -> laenger auf der Leitung -> echte Ueberlappung).
        # Copy: Write gegen dasselbe Postfach (garantiert die Concurrency-Wand).
        $mk = {
            if ($Operation -eq 'Copy') {
                $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post,
                    "$GraphRoot/users/$Mailbox/mailFolders/$SourceFolderId/messages/delta")
            } else {
                $uri = "$GraphRoot/users/$Mailbox/mailFolders/$SourceFolderId/messages?`$top=50&`$select=id,subject,body,receivedDateTime&`$orderby=receivedDateTime desc"
                $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $uri)
            }
            [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token")
            [void]$req.Headers.TryAddWithoutValidation('Prefer', "IdType='ImmutableId'")
            [void]$req.Headers.TryAddWithoutValidation('Accept', 'application/json')
            $req
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tasks = @(1..$N | ForEach-Object { $client.SendAsync((& $mk)) })
        try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks) } catch { }
        $sw.Stop()
        $ok=0; $conc=0; $rate=0; $e503=0; $fail=0; $raMax=0.0
        foreach ($t in $tasks) {
            if ($t.Status -ne 'RanToCompletion') { $fail++; continue }
            $resp = $t.Result; $sc = [int]$resp.StatusCode
            if ($sc -lt 300) { $ok++ }
            elseif ($sc -eq 429 -or $sc -eq 503 -or $sc -eq 504) {
                $ra = 0.0
                if ($resp.Headers.RetryAfter) {
                    try {
                        if ($resp.Headers.RetryAfter.Delta) { $ra = $resp.Headers.RetryAfter.Delta.Value.TotalSeconds }
                        elseif ($resp.Headers.RetryAfter.Date) { $ra = ($resp.Headers.RetryAfter.Date.Value.UtcDateTime - [datetime]::UtcNow).TotalSeconds }
                    } catch { }
                }
                if ($ra -gt $raMax) { $raMax = $ra }
                $blob = ''
                try { $blob = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
                $diag = $null
                try { if ($resp.Headers.TryGetValues('x-ms-diagnostics', [ref]$diag)) { $blob += ' ' + ($diag -join ';') } } catch { }
                if ($sc -eq 503 -or $sc -eq 504) { $e503++ }
                elseif ($ra -gt 0 -or $blob -match 'budget|rate') { $rate++ }
                else { $conc++ }   # 429 ohne Retry-After / MailboxConcurrency = billig
            } else { $fail++ }
            $resp.Dispose()
        }
        [pscustomobject]@{
            N=$N; DurationMs=[int]$sw.Elapsed.TotalMilliseconds; Ok=$ok
            Conc429=$conc; Rate429=$rate; E503=$e503; Fail=$fail; RetryAfter=$raMax
            AnyThrottle= (($conc+$rate+$e503) -gt 0)
        }
    } finally { $client.Dispose() }
}

function Resolve-Folder {
    param([string]$Token,[string]$Name)
    $uri = "$GraphRoot/users/$Mailbox/mailFolders?`$filter=displayName eq '$Name'&`$select=id"
    $h = @{ Authorization = "Bearer $Token" }
    $r = Invoke-RestMethod -Method GET -Uri $uri -Headers $h
    if ($r.value.Count -gt 0) { return $r.value[0].id }
    throw "Ordner '$Name' nicht gefunden - bitte anlegen/seeden (Ping-Pong-Demo)."
}

# ===========================================================================
#  Rolling-Floor-Regler (EWMA-Mittel + EW-Varianz -> Floor mit SD-Abstand)
# ===========================================================================
function New-RollingFloor {
    param([double]$Init = 4.0)
    [pscustomobject]@{ Mean=$Init; Var=1.0; Floor=[math]::Max(1,[math]::Floor($Init-$SdMargin)) }
}
function Update-RollingFloor {
    param($State, [int]$Concurrency, [bool]$Throttled)
    # Asymmetrischer Schaetzer der sicheren Decke:
    #  Throttle bei c -> Decke < c: Mittel schnell Richtung c-1 (fail fast), Var weiten.
    #  Erfolg   bei c -> Decke >= c: NUR nach oben ziehen wenn c ueber dem Mittel
    #                    (recover slow); Erfolg unterhalb ist kein Abwaerts-Signal,
    #                    sondern hebt die Konfidenz (Var schrumpft -> Floor steigt).
    $varFloor = 0.25
    if ($Throttled) {
        $target = [double]([math]::Max(1, $Concurrency - 1))
        $diff = $target - $State.Mean
        $State.Mean = $State.Mean + $AlphaDown * $diff
        $State.Var  = (1 - $AlphaDown) * ($State.Var + $AlphaDown * $diff * $diff) + 0.5
    } else {
        if ($Concurrency -gt $State.Mean) {
            $State.Mean = $State.Mean + $AlphaUp * ($Concurrency - $State.Mean)
        }
        $State.Var = [math]::Max($varFloor, $State.Var * 0.9)
    }
    $sd = [math]::Sqrt([math]::Max($varFloor, $State.Var))
    $State.Floor = [math]::Max(1, [math]::Floor($State.Mean - $SdMargin * $sd))
    $State | Add-Member -NotePropertyName Sd -NotePropertyValue $sd -Force
    $State
}

# ===========================================================================
#  SVG-Kurven (portabel, keine Assembly noetig)
# ===========================================================================
function New-SweepCurveSvg {
    param($Levels, [double]$BMean, [double]$BLo, [double]$BHi, [string]$Path, [string]$Subtitle)
    $W=1120; $H=640; $ML=90; $MR=40; $MT=70; $MB=70
    $pw=$W-$ML-$MR; $ph=$H-$MT-$MB
    $minN=($Levels | Measure-Object N -Minimum).Minimum
    $maxN=($Levels | Measure-Object N -Maximum).Maximum
    $xs = { param($n) $ML + ($n-$minN)/[math]::Max(1,($maxN-$minN)) * $pw }
    $ys = { param($p) $MT + (1-$p) * $ph }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg xmlns='http://www.w3.org/2000/svg' width='$W' height='$H' font-family='Segoe UI,Arial'>")
    [void]$sb.Append("<rect width='$W' height='$H' fill='#1b1b1b'/>")
    [void]$sb.Append("<text x='$ML' y='34' fill='#f0f0f0' font-size='22' font-weight='bold'>MailboxConcurrency - Throttle-Wahrscheinlichkeit p(N)</text>")
    [void]$sb.Append("<text x='$ML' y='56' fill='#e2001a' font-size='14'>$Subtitle</text>")
    # Gitter/Y
    foreach ($p in 0,0.25,0.5,0.75,1.0) {
        $y=(& $ys $p); [void]$sb.Append("<line x1='$ML' y1='$y' x2='$($ML+$pw)' y2='$y' stroke='#333' stroke-width='1'/>")
        [void]$sb.Append("<text x='$($ML-12)' y='$($y+4)' fill='#9e9e9e' font-size='12' text-anchor='end'>$([int]($p*100))%</text>")
    }
    # X-Ticks
    for ($n=$minN; $n -le $maxN; $n++) { $x=(& $xs $n)
        [void]$sb.Append("<line x1='$x' y1='$($MT+$ph)' x2='$x' y2='$($MT+$ph+5)' stroke='#666'/>")
        [void]$sb.Append("<text x='$x' y='$($MT+$ph+22)' fill='#9e9e9e' font-size='12' text-anchor='middle'>$n</text>")
    }
    [void]$sb.Append("<text x='$($ML+$pw/2)' y='$($H-18)' fill='#cfcfcf' font-size='14' text-anchor='middle'>parallele Requests N (app x mailbox)</text>")
    # Grenz-CI-Band (vertikal) + Mittel-Linie
    $bx1=(& $xs $BLo); $bx2=(& $xs $BHi); $bxm=(& $xs $BMean)
    [void]$sb.Append("<rect x='$bx1' y='$MT' width='$([math]::Max(1,$bx2-$bx1))' height='$ph' fill='#4fc3f7' opacity='0.12'/>")
    [void]$sb.Append("<line x1='$bxm' y1='$MT' x2='$bxm' y2='$($MT+$ph)' stroke='#4fc3f7' stroke-width='2' stroke-dasharray='6 4'/>")
    [void]$sb.Append("<text x='$($bxm+6)' y='$($MT+16)' fill='#4fc3f7' font-size='13'>Grenze N* = $([math]::Round($BMean,2))</text>")
    # CI-Ribbon p(N)
    $up=''; $dn=''
    foreach ($l in ($Levels | Sort-Object N)) { $up += "$(& $xs $l.N),$(& $ys $l.Hi) " }
    foreach ($l in ($Levels | Sort-Object N -Descending)) { $dn += "$(& $xs $l.N),$(& $ys $l.Lo) " }
    [void]$sb.Append("<polygon points='$up$dn' fill='#7ccb6b' opacity='0.18'/>")
    # Mittel-Linie + Punkte + Fehlerbalken
    $pl=''
    foreach ($l in ($Levels | Sort-Object N)) { $pl += "$(& $xs $l.N),$(& $ys $l.P) " }
    [void]$sb.Append("<polyline points='$pl' fill='none' stroke='#7ccb6b' stroke-width='2.5'/>")
    foreach ($l in ($Levels | Sort-Object N)) {
        $x=(& $xs $l.N); $yp=(& $ys $l.P); $yl=(& $ys $l.Lo); $yh=(& $ys $l.Hi)
        [void]$sb.Append("<line x1='$x' y1='$yh' x2='$x' y2='$yl' stroke='#7ccb6b' stroke-width='1.5'/>")
        [void]$sb.Append("<line x1='$($x-4)' y1='$yh' x2='$($x+4)' y2='$yh' stroke='#7ccb6b'/>")
        [void]$sb.Append("<line x1='$($x-4)' y1='$yl' x2='$($x+4)' y2='$yl' stroke='#7ccb6b'/>")
        [void]$sb.Append("<circle cx='$x' cy='$yp' r='4' fill='#ffd75f'/>")
    }
    [void]$sb.Append("<text x='$($ML+12)' y='$($MT+18)' fill='#7ccb6b' font-size='12'>Punkt=p(N), Balken=Wilson-95%-CI, Band(vertikal)=Grenze N* 95%-t-CI</text>")
    [void]$sb.Append("</svg>")
    $html = "<!doctype html><html><head><meta charset='utf-8'><title>Kalibrierung</title></head><body style='margin:0;background:#1b1b1b'>$($sb.ToString())</body></html>"
    Set-Content -Path $Path -Value $html -Encoding UTF8
    Set-Content -Path ([System.IO.Path]::ChangeExtension($Path,'svg')) -Value $sb.ToString() -Encoding UTF8
}

function New-FloorTrajectorySvg {
    param($Trace, [string]$Path)
    $W=1120; $H=560; $ML=70; $MR=40; $MT=60; $MB=60
    $pw=$W-$ML-$MR; $ph=$H-$MT-$MB
    $maxT=$Trace.Count; $maxY=[math]::Max(2,($Trace | Measure-Object Mean -Maximum).Maximum + 2)
    $xs={param($i) $ML + ($i)/[math]::Max(1,$maxT-1)*$pw}
    $ys={param($v) $MT + (1-$v/$maxY)*$ph}
    $sb=New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg xmlns='http://www.w3.org/2000/svg' width='$W' height='$H' font-family='Segoe UI,Arial'>")
    [void]$sb.Append("<rect width='$W' height='$H' fill='#1b1b1b'/>")
    [void]$sb.Append("<text x='$ML' y='34' fill='#f0f0f0' font-size='20' font-weight='bold'>Rolling-Floor-Trajektorie (Mittel +/- k*SD, Floor, Throttles)</text>")
    for ($v=0;$v -le $maxY;$v++){ $y=(& $ys $v); [void]$sb.Append("<line x1='$ML' y1='$y' x2='$($ML+$pw)' y2='$y' stroke='#2a2a2a'/><text x='$($ML-10)' y='$($y+4)' fill='#9e9e9e' font-size='11' text-anchor='end'>$v</text>") }
    # SD-Band
    $up='';$dn=''
    for($i=0;$i -lt $Trace.Count;$i++){ $up += "$(& $xs $i),$(& $ys ($Trace[$i].Mean+$SdMargin*$Trace[$i].Sd)) " }
    for($i=$Trace.Count-1;$i -ge 0;$i--){ $dn += "$(& $xs $i),$(& $ys ([math]::Max(0,$Trace[$i].Mean-$SdMargin*$Trace[$i].Sd))) " }
    [void]$sb.Append("<polygon points='$up$dn' fill='#4fc3f7' opacity='0.15'/>")
    # Mean + Floor
    $pm='';$pf=''
    for($i=0;$i -lt $Trace.Count;$i++){ $pm += "$(& $xs $i),$(& $ys $Trace[$i].Mean) "; $pf += "$(& $xs $i),$(& $ys $Trace[$i].Floor) " }
    [void]$sb.Append("<polyline points='$pm' fill='none' stroke='#4fc3f7' stroke-width='2'/>")
    [void]$sb.Append("<polyline points='$pf' fill='none' stroke='#7ccb6b' stroke-width='2.5'/>")
    # Throttle-Marker
    for($i=0;$i -lt $Trace.Count;$i++){ if($Trace[$i].Throttled){ [void]$sb.Append("<circle cx='$(& $xs $i)' cy='$(& $ys $Trace[$i].OpN)' r='3.5' fill='#ff6b6b'/>") } }
    [void]$sb.Append("<text x='$($ML+12)' y='$($MT+18)' fill='#7ccb6b' font-size='12'>gruen=Floor(Betriebspunkt)  blau=Mittel+/-SD  rot=Throttle-Tick</text>")
    [void]$sb.Append("<text x='$($ML+$pw/2)' y='$($H-16)' fill='#cfcfcf' font-size='13' text-anchor='middle'>Tick</text>")
    [void]$sb.Append("</svg>")
    Set-Content -Path $Path -Value "<!doctype html><html><body style='margin:0;background:#1b1b1b'>$($sb.ToString())</body></html>" -Encoding UTF8
}

# ===========================================================================
#  MODI
# ===========================================================================
Write-Host "== Token holen ==" -ForegroundColor Cyan
$token = Get-Token
$srcId = Resolve-Folder -Token $token -Name 'Eingehend'
$dstId = $srcId
Write-Host "Tenant/Mailbox ok, Ordner aufgeloest. Modus: $Mode" -ForegroundColor DarkGreen

if ($Mode -eq 'Sweep') {
    Write-Host "== Sweep: N=$MinN..$MaxN, $Sweeps Sweeps, Operation=$Operation ==" -ForegroundColor Cyan
    $rows = New-Object System.Collections.Generic.List[object]
    $boundaries = New-Object System.Collections.Generic.List[double]
    $throttleCountByN = @{}; for ($n=$MinN;$n -le $MaxN;$n++){ $throttleCountByN[$n]=0 }
    $censored = 0
    for ($k=1; $k -le $Sweeps; $k++) {
        $firstThrottle = 0
        for ($n=$MinN; $n -le $MaxN; $n++) {
            $b = Invoke-ConcurrencyBurst -N $n -Token $token -SourceFolderId $srcId -TargetFolderId $dstId
            $rows.Add([pscustomobject]@{ Sweep=$k; N=$n; Throttled=[int]$b.AnyThrottle; Conc=$b.Conc429; Rate=$b.Rate429; E503=$b.E503; DurationMs=$b.DurationMs; RetryAfter=$b.RetryAfter })
            if ($b.AnyThrottle) { $throttleCountByN[$n]++ ; if ($firstThrottle -eq 0) { $firstThrottle = $n } }
            if ($b.RetryAfter -gt 0) { Start-Sleep -Seconds ([math]::Min(30,$b.RetryAfter)) }  # teurer Rate-Throttle: aussitzen
            Start-Sleep -Seconds $Cooldown
        }
        if ($firstThrottle -eq 0) { $boundaries.Add([double]($MaxN+1)); $censored++ }
        else { $boundaries.Add([double]$firstThrottle) }
        Write-Host ("Sweep {0}/{1}: erste Throttle-Stufe = {2}" -f $k,$Sweeps, ($(if($firstThrottle){$firstThrottle}else{'>'+$MaxN}))) -ForegroundColor Gray
        Start-Sleep -Seconds ([math]::Max(2,$Cooldown))
    }
    # Aggregation: p(N) + Wilson-CI
    $levels = for ($n=$MinN;$n -le $MaxN;$n++) {
        $ci = Get-WilsonCI -k $throttleCountByN[$n] -n $Sweeps
        [pscustomobject]@{ N=$n; K=$throttleCountByN[$n]; n=$Sweeps; P=$ci.P; Lo=$ci.Lo; Hi=$ci.Hi }
    }
    # Grenze: Mittel/SD/t-CI
    $bs = Get-MeanSd -x ($boundaries.ToArray())
    $tc = Get-TCrit ($bs.N-1); $se = if ($bs.N -gt 1){ $bs.Sd/[math]::Sqrt($bs.N) } else { 0 }
    $bLo = $bs.Mean - $tc*$se; $bHi = $bs.Mean + $tc*$se
    $safe = [math]::Max(1, [math]::Floor($bLo) - 1)

    Write-Host "`n===== ERGEBNIS =====" -ForegroundColor Magenta
    "{0,3}  {1,6}  {2,7}  {3,7}" -f 'N','p','CI-lo','CI-hi' | Write-Host
    foreach ($l in $levels) { "{0,3}  {1,6:P0}  {2,7:P0}  {3,7:P0}" -f $l.N,$l.P,$l.Lo,$l.Hi | Write-Host }
    Write-Host ("`nGrenze N*: Mittel={0:n2}  SD={1:n2}  95%-t-CI=[{2:n2}, {3:n2}]  (n={4}{5})" -f `
        $bs.Mean,$bs.Sd,$bLo,$bHi,$bs.N, $(if($censored){", $censored zensiert >MaxN"}else{''})) -ForegroundColor Yellow
    Write-Host ("Empfohlener Carrier-Betriebspunkt (konservativ): {0} parallel" -f $safe) -ForegroundColor Green

    # Exporte
    $rows | Export-Csv -Path "$OutDir\sweep_raw.csv" -NoTypeInformation -Encoding UTF8
    $levels | Export-Csv -Path "$OutDir\sweep_levels.csv" -NoTypeInformation -Encoding UTF8
    $ras = ($rows | Where-Object RetryAfter -gt 0 | Select-Object -Expand RetryAfter)
    $raStat = Get-MeanSd -x ([double[]]$ras)
    $calib = [pscustomobject]@{
        measuredAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        tenant = $TenantId; mailbox = $Mailbox; operation = $Operation; sweeps = $Sweeps
        boundaryMean = [math]::Round($bs.Mean,3); boundarySd = [math]::Round($bs.Sd,3)
        boundaryCi95 = @([math]::Round($bLo,3), [math]::Round($bHi,3)); boundaryCensored = $censored
        recommendedCarrierConcurrency = $safe
        recommendedProbeConcurrency = [math]::Max(1,[math]::Round($bs.Mean))
        retryAfterMeanSec = [math]::Round($raStat.Mean,1); retryAfterSdSec = [math]::Round($raStat.Sd,1)
        rollingFloor = @{ sdMargin=$SdMargin; alphaUp=$AlphaUp; alphaDown=$AlphaDown; initMean=[math]::Round($bs.Mean,2) }
        levels = $levels
    }
    $calib | ConvertTo-Json -Depth 6 | Set-Content -Path "$OutDir\calibration.json" -Encoding UTF8
    New-SweepCurveSvg -Levels $levels -BMean $bs.Mean -BLo $bLo -BHi $bHi -Path "$OutDir\kalibrierung.html" `
        -Subtitle ("Tenant $Mailbox | $Sweeps Sweeps | Grenze N*=$([math]::Round($bs.Mean,2)) +/- SD $([math]::Round($bs.Sd,2)) | Carrier=$safe")
    # Bonus: PNG via WinForms, falls vorhanden
    try {
        Add-Type -AssemblyName System.Windows.Forms.DataVisualization -ErrorAction Stop
        $ch = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
        $ch.Width=1120; $ch.Height=640
        $ca = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
        $ca.AxisX.Title='parallele Requests N'; $ca.AxisY.Title='p(Throttle)'; $ca.AxisY.Minimum=0; $ca.AxisY.Maximum=1
        $ch.ChartAreas.Add($ca)
        $s = New-Object System.Windows.Forms.DataVisualization.Charting.Series
        $s.ChartType=[System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::ErrorBar
        foreach ($l in $levels) { $idx=$s.Points.AddXY($l.N,$l.P); $s.Points[$idx].YValues=@($l.P,$l.Lo,$l.Hi) }
        $ch.Series.Add($s)
        $ch.SaveImage("$OutDir\kalibrierung.png",[System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
        Write-Host "PNG geschrieben: kalibrierung.png" -ForegroundColor DarkGreen
    } catch { Write-Host "(WinForms-Charting nicht verfuegbar - SVG/HTML reicht.)" -ForegroundColor DarkGray }
    Write-Host "`nArtefakte in: $OutDir" -ForegroundColor Cyan
}
elseif ($Mode -eq 'Adaptive') {
    Write-Host "== Adaptive: Rolling-Floor ueber $AdaptiveOps Ticks ==" -ForegroundColor Cyan
    $rf = New-RollingFloor -Init ([double]([math]::Max(2,$MinN+3)))
    $trace = New-Object System.Collections.Generic.List[object]
    for ($i=1; $i -le $AdaptiveOps; $i++) {
        $probe = ($i % $ProbeEvery -eq 0)
        $opN = if ($probe) { [int]$rf.Floor + 1 } else { [int]$rf.Floor }
        if ($opN -lt 1) { $opN = 1 }
        $b = Invoke-ConcurrencyBurst -N $opN -Token $token -SourceFolderId $srcId -TargetFolderId $dstId
        $rf = Update-RollingFloor -State $rf -Concurrency $opN -Throttled ([bool]$b.AnyThrottle)
        $trace.Add([pscustomobject]@{ Tick=$i; OpN=$opN; Probe=[int]$probe; Throttled=[int]$b.AnyThrottle; Mean=$rf.Mean; Sd=$rf.Sd; Floor=$rf.Floor })
        if ($b.RetryAfter -gt 0) { Start-Sleep -Seconds ([math]::Min(30,$b.RetryAfter)) }
        Start-Sleep -Seconds $Cooldown
    }
    $trace | Export-Csv -Path "$OutDir\floor_trace.csv" -NoTypeInformation -Encoding UTF8
    New-FloorTrajectorySvg -Trace $trace -Path "$OutDir\floor-trajectory.html"
    $thr = ($trace | Measure-Object Throttled -Sum).Sum
    Write-Host ("Ticks={0}  Throttles={1} ({2:P0})  End-Floor={3}  Mittel={4:n2}  SD={5:n2}" -f `
        $trace.Count,$thr,($thr/$trace.Count),$rf.Floor,$rf.Mean,$rf.Sd) -ForegroundColor Yellow
    Write-Host "Trajektorie: $OutDir\floor-trajectory.html" -ForegroundColor Cyan
}
elseif ($Mode -eq 'AB') {
    Write-Host "== A/B: Control(statisch=$ControlLimit) vs Treatment(Rolling-Floor), $AbRounds Runden x $AbBlock Ops ==" -ForegroundColor Cyan
    $cThr=0;$cOps=0;$cOkT=0.0;  $tThr=0;$tOps=0;$tOkT=0.0
    $rf = New-RollingFloor -Init ([double]([math]::Max(2,$MinN+3)))
    for ($r=1; $r -le $AbRounds; $r++) {
        # --- Control-Block: festes Limit, kein Lernen ---
        $sw=[System.Diagnostics.Stopwatch]::StartNew()
        for ($i=1;$i -le $AbBlock;$i++){
            $b = Invoke-ConcurrencyBurst -N $ControlLimit -Token $token -SourceFolderId $srcId -TargetFolderId $dstId
            $cOps++; if ($b.AnyThrottle){ $cThr++ } else { $cOkT += $b.DurationMs }
            if ($b.RetryAfter -gt 0){ Start-Sleep -Seconds ([math]::Min(30,$b.RetryAfter)) }
            Start-Sleep -Seconds $Cooldown
        }
        $sw.Stop()
        Start-Sleep -Seconds ([math]::Max(2,$Cooldown))
        # --- Treatment-Block: Rolling-Floor ---
        for ($i=1;$i -le $AbBlock;$i++){
            $probe = ($i % $ProbeEvery -eq 0)
            $opN = if ($probe){ [int]$rf.Floor+1 } else { [int]$rf.Floor }; if($opN -lt 1){$opN=1}
            $b = Invoke-ConcurrencyBurst -N $opN -Token $token -SourceFolderId $srcId -TargetFolderId $dstId
            $rf = Update-RollingFloor -State $rf -Concurrency $opN -Throttled ([bool]$b.AnyThrottle)
            $tOps++; if ($b.AnyThrottle){ $tThr++ } else { $tOkT += $b.DurationMs }
            if ($b.RetryAfter -gt 0){ Start-Sleep -Seconds ([math]::Min(30,$b.RetryAfter)) }
            Start-Sleep -Seconds $Cooldown
        }
        Start-Sleep -Seconds ([math]::Max(2,$Cooldown))
        Write-Host ("Runde $r: Control-Throttle=$cThr/$cOps  Treatment-Throttle=$tThr/$tOps") -ForegroundColor Gray
    }
    $test = Get-TwoPropZ -k1 $cThr -n1 $cOps -k2 $tThr -n2 $tOps
    $cGood = if ($cOps -gt $cThr){ ($cOps-$cThr) } else { 0 }
    $tGood = if ($tOps -gt $tThr){ ($tOps-$tThr) } else { 0 }
    Write-Host "`n===== A/B-URTEIL =====" -ForegroundColor Magenta
    Write-Host ("Control  (statisch {0}): Throttle-Rate {1:P1}  Goodput {2}/{3}" -f $ControlLimit,$test.P1,$cGood,$cOps) -ForegroundColor Yellow
    Write-Host ("Treatment(Rolling-Floor, End-Floor {0}): Throttle-Rate {1:P1}  Goodput {2}/{3}" -f $rf.Floor,$test.P2,$tGood,$tOps) -ForegroundColor Yellow
    Write-Host ("Differenz Throttle-Rate: {0:P1}  (z={1:n2}, p={2:n4})" -f $test.Diff,$test.Z,$test.PValue) -ForegroundColor Cyan
    $verdict = if ($test.PValue -lt 0.05 -and $test.Diff -gt 0) { "HILFT signifikant (weniger Throttling, p<0.05)" }
               elseif ($test.PValue -lt 0.05 -and $test.Diff -lt 0) { "SCHADET signifikant (mehr Throttling)" }
               else { "kein signifikanter Unterschied (mehr Ops/Runden noetig)" }
    Write-Host ("Urteil: $verdict") -ForegroundColor Green
    [pscustomobject]@{ controlLimit=$ControlLimit; controlOps=$cOps; controlThrottle=$cThr; controlRate=$test.P1
        treatmentOps=$tOps; treatmentThrottle=$tThr; treatmentRate=$test.P2; endFloor=$rf.Floor
        diff=$test.Diff; z=$test.Z; pValue=$test.PValue; verdict=$verdict } |
        ConvertTo-Json -Depth 4 | Set-Content -Path "$OutDir\ab_result.json" -Encoding UTF8
    Write-Host "`nErgebnis: $OutDir\ab_result.json" -ForegroundColor Cyan
}
