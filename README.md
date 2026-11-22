# Rundenwettkampf Auswertung

Aktuelle Version: **v1.0**, Ordner [`rwk-auswertung-v1.0`](rwk-auswertung-v1.0).

**Herunterladen:** Immer den **kompletten Ordner** `rwk-auswertung-v1.0` herunterladen, nicht nur einzelne Dateien: oben auf **Code › Download ZIP** klicken, die ZIP-Datei entpacken und den Ordner `rwk-auswertung-v1.0` an einen festen Platz auf dem PC kopieren (zum Beispiel `C:\rwk-auswertung-v1.0`). Darin **Starten.cmd** doppelklicken.


<p>Spielt einen Rundenwettkampf nach dem Schießen auf dem Fernseher ab: Schuss für Schuss, mit Übersicht und Endergebnis.
Die Daten kommen direkt aus der DISAG-Datenbank (OpticScore).</p>

<div class="note warn"><b>⚠ Kein offizielles DISAG-Programm.</b> Ein privates Projekt, das in keiner Verbindung zu DISAG
steht. Die Nutzung erfolgt auf eigene Gefahr: Der Ersteller übernimmt keinen Support und keine Gewährleistung, auch nicht
für Probleme, die durch das Programm entstehen können (zum Beispiel an OpticScore oder der Schießanlage).
Lizenz: MIT, siehe Datei LICENSE.</div>

<h2>1. Einrichtung (einmalig)</h2>
<p><b class="ui">Starten.cmd</b> doppelklicken, in der Steuerung <b class="ui">⚙ Einstellungen</b> öffnen, am Ende
<b class="ui">Speichern</b>.</p>
<ul>
<li><b>Branding:</b> Vereinsname, Logo, Farben eintragen oder <b class="ui">Branding laden …</b></li>
<li><b>1. DISAG-Datenbank (nötig):</b> meist <b>C:\Disag\Daten\dboss.mdb</b>, sonst <b class="ui">Datei wählen …</b>
<b>Für die Auswertung reicht das.</b></li>
<li><b>2. JSON Live (freiwillig):</b> OpticScore meldet damit jeden Schuss sofort weiter. Das Wartebild zeigt dann
an jedem Stand den Schützen und wie viele Schuss er hat, ab seinem ersten Schuss. Zuerst im OpticScore-Server unter
<b>Extras › Optionen › JSON Live</b> einschalten. Dann hier Haken setzen und die Quelle wählen:
<b>UDP-Port</b> (Standard 30169, kennt nur Schüsse seit Programmstart) oder <b>Logdatei</b>
(meist OUT-JSONInterface.log, kennt alle Schüsse von heute).</li>
<li><b>3. Zuweisung sofort anzeigen (freiwillig):</b> Der Schütze erscheint schon beim Zuweisen in OpticScore, nicht
erst beim ersten Schuss. Dafür schreibt OpticScore pro Stand ein Protokoll (Range1.log, Range2.log …) in den Ordner
<b>RangesLog</b>, normalerweise <b>C:\Disag\Daten\RangesLog</b> (neben der dboss.mdb).
<b class="ui">Stand-Protokoll einschalten</b> klicken, <b>OpticScore neu starten</b>, Haken setzen.
<span class="warn-text">Achtung: Das stellt das Log-Level von OpticScore auf INFO, OpticScore schreibt dann deutlich
mehr Logs. Bei Nichtgebrauch wieder ausschalten.</span></li>
</ul>

<h2>2. Starten</h2>
<ol>
<li><b class="ui">Starten.cmd</b> doppelklicken. Die Steuerung öffnet sich im Browser, unten rechts erscheint das Vereinslogo.</li>
<li><b class="ui">📺 Anzeige öffnen</b> klicken, der Fernseher zeigt das Wartebild.</li>
</ol>

<h2>3. Wettkampf abspielen</h2>
<ol>
<li>Nach dem Schießen <b class="ui">⟳ Wettkampf-Daten neu einlesen</b> klicken.</li>
<li>Wettkampf anklicken. Steht „⚠ Fehlende Schüsse“ auf der Karte, erst in OpticScore prüfen.</li>
<li><b class="ui">▶ Auswertung starten</b> klicken.</li>
</ol>
<table>
<tr><th>Taste</th><th>Was passiert</th></tr>
<tr><td><kbd>Leertaste</kbd></td><td>Start und Pause</td></tr>
<tr><td><kbd>←</kbd> <kbd>→</kbd></td><td>Schritt zurück oder weiter</td></tr>
<tr><td><kbd>↑</kbd> <kbd>↓</kbd></td><td>vorheriger oder nächster Schütze</td></tr>
<tr><td><kbd>Pos1</kbd></td><td>von vorn</td></tr>
</table>
<p>Zurück zur Liste mit <b class="ui">☰ Auswahl</b>.</p>

<h2>4. Beenden</h2>
<p>Rechtsklick auf das Vereinslogo unten rechts › <b class="ui">Beenden</b>.</p>

<h2>5. Wenn etwas nicht klappt</h2>
<table>
<tr><th>Problem</th><th>Lösung</th></tr>
<tr><td>Fernseher zeigt nichts</td><td><b class="ui">📺 Anzeige öffnen</b> klicken.</td></tr>
<tr><td>Steuerung weg oder „Keine Verbindung“</td><td>Doppelklick auf das Vereinslogo unten rechts, sonst <b class="ui">Starten.cmd</b> neu.</td></tr>
<tr><td>Wettkampf fehlt</td><td>Er braucht Schüsse in OpticScore. Dann <b class="ui">⟳ Wettkampf-Daten neu einlesen</b>.</td></tr>
<tr><td>Datenbank-Fehler</td><td>In ⚙ Einstellungen die DISAG-Datenbank prüfen.</td></tr>
<tr><td>JSON Live ohne Daten</td><td>In OpticScore JSON Live eingeschaltet? Port oder Logdatei richtig?</td></tr>
<tr><td>„Stand-Protokoll: OpticScore neu starten“</td><td>OpticScore beenden und neu starten.</td></tr>
<tr><td>Programm hängt</td><td>Task-Manager (<kbd>Strg</kbd>+<kbd>Umschalt</kbd>+<kbd>Esc</kbd>), „Windows PowerShell“ beenden, <b class="ui">Starten.cmd</b> neu.</td></tr>
</table>


