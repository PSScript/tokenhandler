# Quick-Win (Python) — „Weniger ist mehr": Retry-After ist die Wahrheit, Writes bündeln

## Zwei kleine Ursachen, ein großer Effekt
1. Viele Poller legen einen Exponential-Backoff **zusätzlich** auf das `Retry-After`
   des Servers ⇒ sie warten **länger als nötig** (doppelt).
2. Fertige Items werden **pro Worker einzeln** verschoben ⇒ „last man standing"-
   Gedränge auf dem 4er-Concurrency-Slot (per App × Postfach).

## Änderung A — Retry-After ersetzt Backoff, es addiert sich nicht
Das `Retry-After` ist **verbindlich und abschließend**. Nur wenn es fehlt, greift der
eigene Backoff.

**Vorher**
```python
delay = backoff_delay(attempt)
if retry_after is not None:
    delay = delay + retry_after        # <-- Ueber-Warten: Server-Zeit PLUS Backoff
time.sleep(delay)
```

**Nachher**
```python
delay = retry_after if retry_after is not None else backoff_delay(attempt)
time.sleep(delay)                       # genau so lange wie noetig, keine Sekunde mehr
```

## Änderung B — ein gebundener Write-Durchsatz statt Worker-Fanout
Read bleibt bei `$top=25` (ein Request, 25 Mails). Genau die Asymmetrie
**1 Read : 25 Writes** ist der Grund, warum die Begrenzung auf die **Write-Seite** gehört.

**Vorher:** jeder `ThreadPoolExecutor`-Worker ruft selbst `move()`.

**Nachher**
```python
import json, threading

carrier = json.load(open("calibration.json"))["recommendedCarrierConcurrency"]  # z.B. 3
write_gate = threading.Semaphore(carrier)     # begrenzt GLEICHZEITIGE Writes global

def move_bounded(message_id, target_folder_id):
    with write_gate:                          # nie mehr als `carrier` Moves parallel
        return graph_move(message_id, target_folder_id)
```
Die Worker legen fertige Items in eine `collections.deque`; das `Semaphore` sorgt dafür,
dass nie mehr als `carrier` Moves gleichzeitig laufen — das 4er-Limit wird nicht mehr
**selbst** verletzt.

## Warum „weniger ist mehr"
Durchsatz ist **Goodput(N) = N · (1 − p(N))**. Weil die Grenze ein **Bucket-Overflow**
ist (Kapazität c, der (c+1)-te läuft über), gilt näherungsweise
`Goodput ≈ min(N, c)` und `Fehler ≈ max(0, N − c)`: unterhalb von c gewinnst du linear,
ab c nur noch Fehler + Wartezeit. Das Optimum liegt **genau bei c**, nicht darüber. Der
Kalibrier-Sweep liefert dir c (= `recommendedCarrierConcurrency`) als Zahl.
