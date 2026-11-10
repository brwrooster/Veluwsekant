#!/bin/bash
# =====================================================================
#  P2000 offline-pakket voor de Raspberry Pi            (10 nov 2026)
#
#  Wat doet dit? Valt het internet weg, dan toont het scherm toch het
#  alarm dat de eigen antenne van de Pi hoort. Het alarm komt dan
#  rechtstreeks van de Pi, met de kaart van de SD-kaart (geen route).
#
#  Gebruik:   bash installeer_offline.sh                   installeren
#             bash installeer_offline.sh --terugdraaien    alles weer weghalen
#
#  Veilig: ontvanger.py krijgt eerst een reservekopie (ontvanger.py.voor-offline).
#  Gaat de offline-dienst stuk, dan werkt ontvanger.py precies zoals voorheen.
# =====================================================================
set -u
SUDO="${P2000_SUDO-sudo}"
UNIT_DIR="${P2000_UNIT_DIR:-/etc/systemd/system}"
DIENST_NAAM="p2000-offline"
POORT=8765

stop_hier() { echo; echo "STOP: $*"; exit 1; }
ok()        { echo "  OK      $*"; }
let_op()    { echo "  LET OP  $*"; }

# ---------- niet als root draaien (dan zijn de bestanden straks van root)
if [ "$(id -u)" = 0 ] && [ -z "${P2000_TOESTAAN_ROOT:-}" ]; then
  stop_hier "Draai dit gewoon als jezelf, zonder sudo ervoor:  bash installeer_offline.sh"
fi

# ---------- waar staat ontvanger.py?
MAP=""
for k in "$PWD" "$HOME"; do
  if [ -f "$k/ontvanger.py" ]; then MAP="$k"; break; fi
done
[ -n "$MAP" ] || stop_hier "Ik vind ontvanger.py niet. Ga eerst naar de map waar ontvanger.py staat (meestal: cd ~) en start dit opnieuw."

ontvanger_dienst() {
  if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^p2000-rtl-ontvanger\.service'; then
    echo "p2000-rtl-ontvanger"; return
  fi
  systemctl list-unit-files --type=service 2>/dev/null | awk '$1 ~ /ontvanger/ {sub(/\.service$/, "", $1); print $1; exit}'
}

herstart_ontvanger() {
  local d; d="$(ontvanger_dienst)"
  if [ -n "$d" ]; then
    $SUDO systemctl restart "$d" && ok "ontvanger opnieuw gestart ($d)" || let_op "ontvanger herstarten lukte niet; start de Pi opnieuw op: sudo reboot"
  else
    let_op "ik vind de ontvanger-dienst niet. Start de Pi opnieuw op:  sudo reboot"
  fi
}

# ---------- terugdraaien
if [ "${1:-}" = "--terugdraaien" ]; then
  echo "Offline-pakket weghalen..."
  $SUDO systemctl disable --now "$DIENST_NAAM" 2>/dev/null
  $SUDO rm -f "$UNIT_DIR/$DIENST_NAAM.service"
  $SUDO systemctl daemon-reload 2>/dev/null
  [ -f "$MAP/offline_venster.sh" ] && bash "$MAP/offline_venster.sh" stop 2>/dev/null
  [ -f "$MAP/offline_simuleer.sh" ] && bash "$MAP/offline_simuleer.sh" aan >/dev/null 2>&1
  if [ -f "$MAP/patch_ontvanger.py" ]; then python3 "$MAP/patch_ontvanger.py" --terug "$MAP/ontvanger.py"; fi
  rm -rf "$MAP/offline_data" "$MAP/offline_capcodes.json" "$MAP/offline_instellingen.json" \
         "$MAP/offline_dienst.py" "$MAP/offline_kaart.py" "$MAP/offline_haak.py" "$MAP/patch_ontvanger.py" \
         "$MAP/offline_venster.sh" "$MAP/offline_simuleer.sh" "$MAP/offline_test.sh" "$MAP/__pycache__"
  herstart_ontvanger
  echo "Klaar. Alles staat weer zoals voor het offline-pakket."
  exit 0
fi

echo "== P2000 offline-pakket installeren (map: $MAP) =="
command -v python3 >/dev/null || stop_hier "python3 ontbreekt."
command -v curl >/dev/null    || stop_hier "curl ontbreekt."
if ! command -v chromium >/dev/null && ! command -v chromium-browser >/dev/null; then
  let_op "Chromium niet gevonden; het offline-scherm kan dan niet openen."
fi

# ---------- bestanden neerzetten
cat > "$MAP/offline_dienst.py" <<'P2000_EINDE_OFFLINE_DIENST_PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
P2000 offline-dienst voor de Raspberry Pi  (10 nov 2026)

Wat doet dit?
  Valt het internet weg, dan kan het scherm op de kazerne geen alarmen meer
  van de Worker krijgen. De Pi hoort ze wel nog (RTL-stick). Deze kleine dienst
  zorgt dat het scherm dan toch werkt:

   1. Hij bewaart een eigen kopie van het scherm (index.html) en van de
      instellingen (/api/taken, met de capcodes), zolang er wel internet is.
   2. Hij kijkt elke paar seconden of de Worker bereikbaar is (/api/ping).
   3. Is dat niet zo, dan toont hij het scherm vanaf de Pi zelf, op
      http://127.0.0.1:8765/?offline=1 - met de alarmen van de eigen antenne.
   4. Meldingen die de Pi offline hoorde, worden later alsnog doorgestuurd
      (met de echte tijd), zodat tellers, log en maandrapport kloppen.

  De capcode-filtering blijft bij ontvanger.py: die stuurt alleen meldingen
  voor deze post door. Deze dienst krijgt dus nooit andere meldingen.

Veiligheid:
  - Luistert ALLEEN op 127.0.0.1 (niet bereikbaar van buiten de Pi).
  - Gaat deze dienst stuk, dan merkt ontvanger.py daar niets van (de koppeling
    vangt alle fouten op).
  - Alleen standaardbibliotheek van Python en curl; niets te installeren.

Starten:   python3 offline_dienst.py [pad/naar/offline_instellingen.json]
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HIER = os.path.dirname(os.path.abspath(__file__))

STANDAARD = {
    "basis": "",                 # bv. https://rbdatasolutions.nl/p2000/master (of .../almere)
    "sleutel": "",               # de Pi-sleutel van deze post
    "poort": 8765,
    "map": os.path.join(HIER, "offline_data"),
    "ping_sec": 5,               # hoe vaak kijken of de Worker bereikbaar is
    "uit_na": 3,                 # zo vaak achter elkaar mislukt = offline
    "aan_na": 2,                 # zo vaak achter elkaar gelukt = weer online
    "onbevestigd_sec": 90,       # geen bevestiging van ontvanger.py? dan alsnog nasturen
    "open_min_sec": 90,          # offline-scherm minstens zo lang open na het OPENEN (tegen heen-en-weer springen)
    "min_venster_sec": 360,      # na een ALARM minstens zo lang open (en minstens 'hoe lang een alarm blijft staan' + 1 minuut)
    "volg_holdmin": True,        # en minstens 'hoe lang een alarm blijft staan' + 1 minuut
    "ververs_taken_sec": 60,
    "ververs_scherm_sec": 6 * 3600,
    "nasturen_wacht_sec": 20,    # mislukt het nasturen (bv. ingetrokken sleutel)? zo lang wachten voor een nieuwe poging
    "max_leeftijd_uur": 48,      # ouder dan dit: niet meer nasturen (de Worker weigert ze ook)
    "venster_start": None,       # opdracht (lijst) om het offline-scherm te tonen
    "venster_stop": None,        # opdracht (lijst) om het weer weg te halen
    "venster_opruim": None,      # opdracht (lijst) bij het starten van de dienst: een achtergebleven offline-scherm opruimen
}

KAARTSTUK_PAD = re.compile(r"^/lokaal/kaart/(\d{1,2})/(\d{1,8})/(\d{1,8})\.png$")
ASSET_PAD = re.compile(r"^/((?:image/)?[A-Za-z0-9_.-]+\.(?:png|jpe?g|gif|svg|webp|ico))$", re.I)
CONTENT_TYPES = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                 "svg": "image/svg+xml", "webp": "image/webp", "ico": "image/x-icon"}
ALARM_MAX_LEEFTIJD_MS = 20 * 60 * 1000   # het scherm negeert oudere meldingen bij het openen toch al


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def lees_json(pad, standaard):
    try:
        with open(pad, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return standaard


def schrijf_bestand(pad, inhoud):
    """Veilig wegschrijven: eerst een tijdelijk bestand, dan pas vervangen."""
    tmp = pad + ".tmp"
    mode = "wb" if isinstance(inhoud, bytes) else "w"
    with open(tmp, mode, **({} if mode == "wb" else {"encoding": "utf-8"})) as f:
        f.write(inhoud)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, pad)


def boot_id():
    try:
        with open("/proc/sys/kernel/random/boot_id") as f:
            return f.read().strip()
    except Exception:
        return ""


_klok_cache = [0.0, False]


def klok_gesynchroniseerd():
    """Staat de klok van de Pi gelijk met internet? (Een Pi heeft geen batterijklokje.)
    Het antwoord wordt 30 seconden onthouden, zodat dit niet bij elke melding een opdracht start."""
    nu = time.monotonic()
    if nu - _klok_cache[0] < 30 and _klok_cache[0] > 0:
        return _klok_cache[1]
    try:
        r = subprocess.run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"],
                           capture_output=True, text=True, timeout=2)
        _klok_cache[1] = r.stdout.strip() == "yes"
    except Exception:
        _klok_cache[1] = False
    _klok_cache[0] = nu
    return _klok_cache[1]


def vraag(url, methode="GET", body=None, timeout=5):
    """Een webvraag via curl (zoals de ontvanger zelf). Geeft (statuscode, tekst); statuscode 0 = mislukt."""
    cmd = ["curl", "-sS", "-A", "p2000-offline/1", "--max-time", str(timeout), "-w", "\n%{http_code}", "-X", methode]
    data = None
    if body is not None:
        cmd += ["-H", "content-type: application/json", "--data-binary", "@-"]
        data = json.dumps(body).encode("utf-8")
    cmd.append(url)
    try:
        r = subprocess.run(cmd, input=data, capture_output=True, timeout=timeout + 3)
    except Exception as e:
        return 0, str(e)
    uit = r.stdout.decode("utf-8", "replace")
    tekst, _, code = uit.rpartition("\n")
    try:
        return int(code), tekst
    except ValueError:
        return 0, (r.stderr.decode("utf-8", "replace") or uit)[:200]


class Dienst:
    def __init__(self, cfg):
        self.cfg = cfg
        self.map = cfg["map"]
        os.makedirs(os.path.join(self.map, "img"), exist_ok=True)
        self.lock = threading.RLock()
        self.boot = boot_id()
        self.online = True
        self.fout = 0
        self.goed = 0
        self.venster_sinds = None          # time.monotonic() waarop het offline-scherm openging
        self.venster_sinds_ms = None       # idem, als klok-tijd in ms (voor het vergelijken met meldingen)
        self.venster_tot = 0.0             # time.monotonic(): minstens zolang open houden
        self.venster_proc = None
        self.items = lees_json(self.pad("items.json"), [])
        self.teller = int(time.time()) % 100000
        self.laatste_taken = 0.0
        self.laatste_scherm = float("-inf")     # bij elke start van de dienst meteen een verse kopie van het scherm halen
        self.laatste_ping_ok = None
        self.nasturen_na = 0.0             # time.monotonic(): eerder niet opnieuw proberen
        self.kaart = None                  # kaart op de SD-kaart (offline_kaart.py); zonder dat bestand werkt alles als voorheen
        try:
            import offline_kaart
            self.kaart = offline_kaart.Kaart(cfg, self.pad, log, lambda: self.online, self.postplek)
        except Exception as e:
            log("kaart niet beschikbaar:", repr(e))

    def pad(self, naam):
        return os.path.join(self.map, naam)

    def postplek(self):
        """De plek van de post (uit de instellingen van het scherm), of None."""
        try:
            d = json.loads(self.taken_ruw() or "{}")
            if isinstance(d.get("eigenLat"), (int, float)) and isinstance(d.get("eigenLon"), (int, float)):
                return d["eigenLat"], d["eigenLon"]
        except Exception:
            pass
        return None

    # ------------------------------------------------------------------ meldingen
    def opslaan(self):
        try:
            schrijf_bestand(self.pad("items.json"), json.dumps(self.items))
        except Exception as e:
            log("items opslaan mislukt:", e)

    def leeftijd_ms(self, it):
        """Hoe oud is deze melding? De Pi heeft geen batterijklokje, dus bij voorkeur de
        stopwatch van de Pi (monotonic) gebruiken; die loopt door tot de Pi herstart."""
        if it.get("boot") == self.boot and self.boot:
            leeftijd = (time.monotonic() - it["t_mono"]) * 1000
        else:
            # De Pi is sindsdien herstart: de stopwatch is weg, alleen de klok blijft over
            wand = (time.time() - it["t_wall"]) * 1000
            if it.get("klok_ok") and klok_gesynchroniseerd():
                leeftijd = wand
            elif wand > self.cfg["max_leeftijd_uur"] * 3600 * 1000:
                leeftijd = wand       # zeker te oud, ook als de klok onzeker is
            else:
                leeftijd = 0          # onbekend: liever nu meetellen dan kwijtraken
        return max(0, int(leeftijd))

    def nieuwe_melding(self, doel, url, body, eigen):
        with self.lock:
            self.teller += 1
            # Een melding voor een andere post (regiogroep-partner met een andere sleutel)
            # hoort niet op het scherm van deze post; hij wordt wel later nagestuurd.
            sl = (body or {}).get("sleutel") if isinstance(body, dict) else None
            if eigen and sl and sl != self.cfg["sleutel"]:
                eigen = False
            it = {
                "id": "lok-%d-%d" % (int(time.time() * 1000), self.teller),
                "ts_ms": int(time.time() * 1000), "text": str((body or {}).get("text", "")),
                "doel": doel, "eigen": bool(eigen), "url": url, "body": body or {},
                "bezorgd": None, "doorgestuurd": False, "test": False,
                "t_mono": time.monotonic(), "boot": self.boot, "t_wall": time.time(),
                "klok_ok": klok_gesynchroniseerd(),
            }
            self.items.append(it)
            # Alleen als we zeker offline zijn houdt dit alarm het offline-scherm open. Een alarm dat
            # gewoon bij de Worker aankomt, laat het gewone scherm zelf zien; dat telt hier niet mee
            # (anders houdt elke testoproep het offline-scherm eindeloos open).
            if it["eigen"] and not self.online:
                self.venster_tot = max(self.venster_tot, time.monotonic() + self.venster_minimaal())
            self.opslaan()
            return it["id"]

    def lokale_test(self, tekst):
        """Een testmelding vanaf het scherm zelf (offline mag dat ook): alleen tonen, nooit nasturen."""
        with self.lock:
            self.teller += 1
            it = {"id": "lok-%d-%d" % (int(time.time() * 1000), self.teller), "ts_ms": int(time.time() * 1000),
                  "text": str(tekst), "doel": "", "eigen": True, "url": "", "body": {}, "bezorgd": True,
                  "doorgestuurd": True, "test": True, "t_mono": time.monotonic(), "boot": self.boot,
                  "t_wall": time.time(), "klok_ok": False}
            self.items.append(it)
            self.opslaan()
            return it["id"]

    def resultaat(self, mid, bezorgd):
        with self.lock:
            for it in self.items:
                if it["id"] == mid:
                    if it["bezorgd"] is True:
                        return True          # eenmaal bezorgd blijft bezorgd
                    it["bezorgd"] = bool(bezorgd)
                    break
            else:
                return False
            if not bezorgd and it["eigen"] and not it["test"]:
                # Dit alarm kwam NIET bij de Worker aan: het gewone scherm weet er niets van, dus het
                # offline-scherm moet het ook volle tijd tonen. (Een mislukte melding voor een andere
                # post zegt niets over ons eigen scherm en schakelt dus niets om.)
                self.venster_tot = max(self.venster_tot, it["t_mono"] + self.venster_minimaal())
                if self.online:
                    self.markeer_offline("het doorsturen naar de Worker mislukte")
            self.opslaan()
            return True

    def venster_minimaal(self):
        if not self.cfg.get("volg_holdmin", True):
            return self.cfg["min_venster_sec"]
        hold = 5
        try:
            taken = json.loads(self.taken_ruw() or "{}")
            hold = float(taken.get("holdMin") or 5)
        except Exception:
            pass
        return max(self.cfg["min_venster_sec"], hold * 60 + 60)

    def tel_verlopen(self):
        """Geen bevestiging gekregen van ontvanger.py? Dan veiligheidshalve alsnog nasturen
        (de Worker herkent een dubbele melding en telt hem dan niet nog eens)."""
        nu = time.monotonic()
        wijzig = False
        for it in self.items:
            if it["bezorgd"] is None and it.get("boot") == self.boot and nu - it["t_mono"] > self.cfg["onbevestigd_sec"]:
                it["bezorgd"] = False
                wijzig = True
        if wijzig:
            self.opslaan()

    def opruimen(self):
        max_ms = self.cfg["max_leeftijd_uur"] * 3600 * 1000
        nieuw = []
        for it in self.items:
            leeftijd = self.leeftijd_ms(it)
            klaar = it["doorgestuurd"] or it["bezorgd"] is True
            if leeftijd > max_ms or (klaar and leeftijd > 30 * 60 * 1000):
                continue
            nieuw.append(it)
        if len(nieuw) > 500:
            nieuw = nieuw[-500:]
        if len(nieuw) != len(self.items):
            self.items = nieuw
            self.opslaan()

    # ------------------------------------------------------------------ wat het scherm ziet
    def api_pi(self):
        """De laatste melding voor het offline-scherm, in dezelfde vorm als de Worker (/api/pi)."""
        with self.lock:
            nu_ms = time.time() * 1000
            kandidaten = []
            for it in self.items:
                if not it["eigen"] or nu_ms - it["ts_ms"] > ALARM_MAX_LEEFTIJD_MS:
                    continue
                if self.venster_sinds_ms is not None:
                    # Offline-scherm staat open: alles van na het openen, plus wat er vlak voor
                    # het openen (tot een minuut, de ontvanger wacht even op de Worker) nog niet
                    # bevestigd was.
                    if it["ts_ms"] < self.venster_sinds_ms - 60000:
                        continue
                    if it["bezorgd"] is True and not it["test"] and it["ts_ms"] < self.venster_sinds_ms:
                        continue
                else:
                    if it["bezorgd"] is True and not it["test"]:
                        continue
                kandidaten.append(it)
            if not kandidaten:
                return {}
            it = max(kandidaten, key=lambda x: x["ts_ms"])
            return {"id": it["id"], "ts": it["ts_ms"], "text": it["text"], "bron": "p2000",
                    "viaFeed": False, "test": bool(it["test"])}

    def api_log(self):
        with self.lock:
            logs = [{"ts": it["ts_ms"], "text": it["text"], "bron": "p2000", "nagestuurd": it["bezorgd"] is not True}
                    for it in self.items if it["eigen"] and not it["test"]]
        return {"logs": logs[-100:]}

    def taken_ruw(self):
        try:
            with open(self.pad("taken.json"), "r", encoding="utf-8") as f:
                return f.read()
        except Exception:
            return ""

    def scherm_ruw(self):
        try:
            with open(self.pad("index.html"), "rb") as f:
                return f.read()
        except Exception:
            return None

    def status(self):
        with self.lock:
            wacht = [i for i in self.items if i["bezorgd"] is False and not i["doorgestuurd"] and not i["test"]]
            return {"online": self.online, "venster_open": self.venster_sinds is not None,
                    "te_versturen": len(wacht), "items": len(self.items),
                    "scherm_in_geheugen": self.scherm_ruw() is not None,
                    "taken_in_geheugen": bool(self.taken_ruw()), "laatste_ping_ok": self.laatste_ping_ok,
                    "kaart": self.kaart.status() if self.kaart else None}

    # ------------------------------------------------------------------ verbinding bewaken
    def ping(self):
        status, tekst = vraag(self.cfg["basis"].rstrip("/") + "/api/ping", timeout=3)
        ok = status == 200 and '"ok":true' in tekst.replace(" ", "")
        if ok:
            self.laatste_ping_ok = time.time()
        return ok

    def markeer_offline(self, reden):
        if self.online:
            log("OFFLINE:", reden)
        self.online = False
        self.goed = 0
        self.fout = max(self.fout, self.cfg["uit_na"])
        self.venster_beheer()

    def venster_beheer(self):
        nu = time.monotonic()
        moet = (not self.online) or nu < self.venster_tot
        if moet and self.venster_sinds is None:
            self.venster_sinds = nu
            self.venster_sinds_ms = int(time.time() * 1000)
            tot = nu + self.cfg["open_min_sec"]
            # Een alarm dat net voor het openen binnenkwam (de ontvanger wacht even op de Worker)
            # moet ook gewoon zijn volle tijd op het scherm blijven staan.
            for it in self.items:
                if it["eigen"] and not it["test"] and it["bezorgd"] is not True and it.get("boot") == self.boot:
                    tot = max(tot, it["t_mono"] + self.venster_minimaal())
            self.venster_tot = max(self.venster_tot, tot)
            log("offline-scherm tonen")
            self.voer_uit(self.cfg.get("venster_start"), houd=True)
        elif not moet and self.venster_sinds is not None:
            log("offline-scherm weghalen")
            self.venster_sinds = None
            self.venster_sinds_ms = None
            self.voer_uit(self.cfg.get("venster_stop"))
            if self.venster_proc is not None:
                try:
                    self.venster_proc.terminate()
                except Exception:
                    pass
                self.venster_proc = None

    def voer_uit(self, cmd, houd=False):
        if not cmd:
            return
        try:
            p = subprocess.Popen(cmd, start_new_session=True)
            if houd:
                self.venster_proc = p
            else:
                p.wait(timeout=20)
        except Exception as e:
            log("opdracht mislukt:", cmd, e)

    def ronde(self):
        ok = self.ping()
        with self.lock:
            if ok:
                self.goed += 1
                self.fout = 0
            else:
                self.fout += 1
                self.goed = 0
            if self.online and self.fout >= self.cfg["uit_na"]:
                self.online = False
                log("OFFLINE: Worker niet bereikbaar")
            elif not self.online and self.goed >= self.cfg["aan_na"]:
                self.online = True
                log("weer ONLINE")
            self.tel_verlopen()
            self.venster_beheer()
        if self.online:
            self.ververs_caches()
            self.stuur_spool()
        with self.lock:
            self.opruimen()

    # ------------------------------------------------------------------ kopieën bewaren
    def haal(self, pad_op_worker):
        sep = "&" if "?" in pad_op_worker else "?"
        url = self.cfg["basis"].rstrip("/") + pad_op_worker + sep + "sleutel=" + self.cfg["sleutel"]
        return vraag(url, timeout=8)

    def ververs_caches(self):
        nu = time.monotonic()
        if self.scherm_ruw() is None or nu - self.laatste_scherm > self.cfg["ververs_scherm_sec"]:
            self.laatste_scherm = nu
            status, tekst = self.haal("/api/pi-scherm")
            if status == 200 and "</html>" in tekst.lower():
                schrijf_bestand(self.pad("index.html"), tekst.encode("utf-8"))
                log("kopie van het scherm bewaard (%d tekens)" % len(tekst))
                for m in set(re.findall(r"""["'(]\s*/?(image/[A-Za-z0-9_.-]+\.(?:png|jpe?g|gif|svg|webp|ico))""", tekst, re.I)):
                    self.haal_plaatje(m)
            else:
                log("kopie van het scherm ophalen mislukt:", status)
        if not self.taken_ruw() or nu - self.laatste_taken > self.cfg["ververs_taken_sec"]:
            self.laatste_taken = nu
            status, tekst = self.haal("/api/taken")
            try:
                ok = status == 200 and isinstance(json.loads(tekst), dict)
            except Exception:
                ok = False
            if ok:
                schrijf_bestand(self.pad("taken.json"), tekst)
            else:
                log("instellingen ophalen mislukt:", status)

    def haal_plaatje(self, rel):
        """rel = bv. 'image/ploeg-a.png'"""
        naam = rel.replace("/", "_")
        url = self.cfg["basis"].rstrip("/") + "/api/pi-scherm?bestand=/" + rel + "&sleutel=" + self.cfg["sleutel"]
        cmd = ["curl", "-sS", "-A", "p2000-offline/1", "--max-time", "8", "-o", self.pad("img/" + naam + ".tmp"),
               "-w", "%{http_code}", url]
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=12)
            if r.stdout.decode().strip() == "200":
                with open(self.pad("img/" + naam + ".tmp"), "rb") as f:
                    kop = f.read(300).lower()
                # Een foutpagina (html) is geen plaatje: nooit als plaatje bewaren
                if not rel.lower().endswith(".svg") and (kop.lstrip().startswith(b"<!doctype") or b"<html" in kop):
                    raise ValueError("geen plaatje")
                os.replace(self.pad("img/" + naam + ".tmp"), self.pad("img/" + naam))
                return True
        except Exception:
            pass
        try:
            os.remove(self.pad("img/" + naam + ".tmp"))
        except Exception:
            pass
        return False

    def plaatje(self, rel):
        naam = rel.replace("/", "_")
        pad = self.pad("img/" + naam)
        if not os.path.exists(pad) and self.online:
            self.haal_plaatje(rel)
        try:
            with open(pad, "rb") as f:
                return f.read()
        except Exception:
            return None

    # ------------------------------------------------------------------ later doorsturen
    def stuur_spool(self):
        if time.monotonic() < self.nasturen_na:
            return
        with self.lock:
            wacht = [i for i in self.items if i["bezorgd"] is False and not i["doorgestuurd"] and not i["test"]]
        wacht.sort(key=lambda i: -self.leeftijd_ms(i))      # oudste eerst
        for it in wacht:
            leeftijd = self.leeftijd_ms(it)
            if leeftijd > self.cfg["max_leeftijd_uur"] * 3600 * 1000:
                with self.lock:
                    it["doorgestuurd"] = True
                log("te oud om na te sturen, overgeslagen:", it["text"][:50])
                continue
            body = dict(it["body"])
            body["nalevering"] = True
            body["leeftijdMs"] = leeftijd
            status, tekst = vraag(it["url"], "POST", body, timeout=8)
            if status == 200 and '"ok":true' in tekst.replace(" ", ""):
                with self.lock:
                    it["doorgestuurd"] = True
                    self.opslaan()
                log("nagestuurd (%d s oud): %s" % (leeftijd // 1000, it["text"][:50]))
            else:
                log("nasturen mislukt (%s), over %d s opnieuw: %s" % (status, self.cfg["nasturen_wacht_sec"], tekst[:80]))
                self.nasturen_na = time.monotonic() + self.cfg["nasturen_wacht_sec"]
                break

    def lus(self):
        # Na een herstart van deze dienst kan er nog een offline-scherm van de vorige keer staan
        # (de dienst laat het scherm bewust draaien als hij zelf herstart). Eerst opruimen.
        self.voer_uit(self.cfg.get("venster_opruim"))
        try:
            if self.kaart:
                self.kaart.start()
        except Exception as e:
            log("kaart starten mislukt:", repr(e))
        while True:
            try:
                self.ronde()
            except Exception as e:
                log("fout in ronde:", repr(e))
            time.sleep(self.cfg["ping_sec"])


class Verzoek(BaseHTTPRequestHandler):
    server_version = "p2000-offline"
    D = None

    def log_message(self, *a):
        pass

    def stuur(self, code, data, soort="application/json; charset=utf-8", cache=False):
        if isinstance(data, (dict, list)):
            data = json.dumps(data)
        if isinstance(data, str):
            data = data.encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", soort)
        self.send_header("content-length", str(len(data)))
        self.send_header("cache-control", "public, max-age=3600" if cache else "no-store")
        self.end_headers()
        self.wfile.write(data)

    def lees_body(self):
        try:
            n = int(self.headers.get("content-length") or 0)
            return json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
        except Exception:
            return {}

    def do_GET(self):
        D = self.D
        pad = self.path.split("?")[0]
        if pad in ("/", "/index.html"):
            html = D.scherm_ruw()
            if html is None:
                return self.stuur(503, "Nog geen kopie van het scherm op de Pi. Zodra er internet is wordt die opgehaald.",
                                  "text/plain; charset=utf-8")
            if D.kaart:
                try:
                    html = D.kaart.herschrijf(html)       # Leaflet vanaf de SD-kaart i.p.v. van internet
                except Exception:
                    pass
            return self.stuur(200, html, "text/html; charset=utf-8")
        m = KAARTSTUK_PAD.match(pad)
        if m:
            data = D.kaart.tegel(int(m.group(1)), int(m.group(2)), int(m.group(3))) if D.kaart else None
            if data is None:
                return self.stuur(404, "", "text/plain")
            return self.stuur(200, data, "image/png", cache=True)
        if pad.startswith("/lokaal/lib/"):
            r = D.kaart.lib_bestand(pad[len("/lokaal/lib/"):]) if D.kaart else None
            if r is None:
                return self.stuur(404, "", "text/plain")
            return self.stuur(200, r[0], r[1], cache=True)
        if pad == "/lokaal/geocode":
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("q", [""])[0]
            gevonden = None
            try:
                gevonden = D.kaart.zoek(q) if D.kaart else None
            except Exception as e:
                log("geocode fout:", repr(e))
            if not gevonden:
                return self.stuur(200, {"ok": False})
            gevonden["ok"] = True
            return self.stuur(200, gevonden)
        m = ASSET_PAD.match(pad)
        if m:
            data = D.plaatje(m.group(1))
            if data is None:
                return self.stuur(404, "", "text/plain")
            return self.stuur(200, data, CONTENT_TYPES.get(pad.rsplit(".", 1)[-1].lower(), "application/octet-stream"))
        if pad == "/api/pi":
            return self.stuur(200, D.api_pi())
        if pad == "/api/taken":
            return self.stuur(200, D.taken_ruw() or "{}")
        if pad == "/api/log":
            return self.stuur(200, D.api_log())
        if pad == "/api/ontvanger":
            return self.stuur(200, {"heeftPi": False})
        if pad == "/api/stroom":
            return self.stuur(404, "", "text/plain")      # geen websocket: het scherm vraagt dan zelf elke seconde
        if pad == "/lokaal/status":
            return self.stuur(200, D.status())
        if pad.startswith("/api/"):
            return self.stuur(200, {})
        return self.stuur(404, "", "text/plain")

    def do_POST(self):
        D = self.D
        pad = self.path.split("?")[0]
        body = self.lees_body()
        if pad == "/lokaal/melding":
            mid = D.nieuwe_melding(str(body.get("doel", "")), str(body.get("url", "")), body.get("body") or {}, bool(body.get("eigen")))
            return self.stuur(200, {"ok": True, "id": mid})
        if pad == "/lokaal/resultaat":
            return self.stuur(200, {"ok": D.resultaat(str(body.get("id", "")), bool(body.get("bezorgd")))})
        if pad == "/api/pi":                       # testknop op het offline-scherm
            tekst = str(body.get("text", "")).strip()
            if tekst:
                D.lokale_test(tekst)
            return self.stuur(200, {"ok": True, "lokaal": True})
        if pad.startswith("/api/"):
            return self.stuur(200, {"ok": True})
        return self.stuur(404, "", "text/plain")


def laad_config(argv):
    cfg = dict(STANDAARD)
    pad = argv[1] if len(argv) > 1 else os.path.join(HIER, "offline_instellingen.json")
    cfg.update(lees_json(pad, {}))
    return cfg


def main():
    cfg = laad_config(sys.argv)
    if not cfg["basis"] or not cfg["sleutel"]:
        sys.exit("offline_instellingen.json mist 'basis' en/of 'sleutel'.")
    D = Dienst(cfg)
    Verzoek.D = D
    threading.Thread(target=D.lus, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", int(cfg["poort"])), Verzoek)
    log("offline-dienst luistert op 127.0.0.1:%s, basis %s" % (cfg["poort"], cfg["basis"]))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
P2000_EINDE_OFFLINE_DIENST_PY
cat > "$MAP/offline_kaart.py" <<'P2000_EINDE_OFFLINE_KAART_PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Kaart voor de offline-dienst  (10 nov 2026)

Wat doet dit?
  Zolang er internet is, bewaart de Pi op zijn SD-kaart:
    1. de kaartstukjes (PDOK, dezelfde als het gewone scherm) rond de post,
    2. een lijst van alle straten in de omgeving met hun plek (PDOK Locatieserver),
    3. de kaartbibliotheek (Leaflet) van het scherm.
  Valt het internet weg, dan kan het offline-scherm daarmee toch een kaart tonen:
  de dienst zoekt de straat uit de melding op in die lijst en geeft de kaartstukjes
  vanaf de SD-kaart. Zonder route en rijtijd; de ster staat op het midden van de straat.

Veilig:
  - Alles hier vangt fouten zelf op; een fout in dit bestand raakt het alarm niet.
  - Downloaden gaat rustig (een paar kaartstukjes per seconde) en alleen als er internet is.
  - Er wordt nooit een foute plek getoond: straat EN plaats moeten in de melding staan.
"""
import json
import math
import os
import re
import shutil
import threading
import time
import unicodedata
import urllib.parse
import urllib.request

LEAFLET_CDN = "https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/"     # zoals in index.html
LIB_VERPLICHT = ["leaflet.min.js", "leaflet.min.css"]
LIB_OPTIONEEL = ["images/layers.png", "images/layers-2x.png", "images/marker-icon.png",
                 "images/marker-icon-2x.png", "images/marker-shadow.png"]
STANDAARD_MIDDEN = (52.356938, 5.247188)

STANDAARD = {
    "kaart": True,
    "tegel_url": "https://service.pdok.nl/brt/achtergrondkaart/wmts/v2_0/standaard/EPSG:3857/{z}/{x}/{y}.png",
    "pdok_basis": "https://api.pdok.nl/bzk/locatieserver/search/v3_1/",
    "leaflet_basis": LEAFLET_CDN,
    # [zoom, straal in km] : hoe ver rond de post per zoomniveau
    "kaart_zoom_straal_km": [[10, 40], [11, 40], [12, 40], [13, 35], [14, 25], [15, 18], [16, 10]],
    "kaart_midden": None,            # [lat, lon]; leeg = de plek van de post uit de instellingen van het scherm
    "kaart_pauze_sec": 0.25,         # rust tussen twee kaartstukjes
    "kaart_max_tegels": 9000,
    "kaart_max_mb": 400,
    "kaart_ververs_dagen": 60,       # na zoveel dagen alle kaartstukjes opnieuw ophalen
    "kaart_ronde_sec": 600,          # zo vaak kijken of er iets te doen is
    "kaart_start_wacht_sec": 20,
    "straten_ververs_dagen": 30,
    "gemeenten": ["Almere", "Zeewolde", "Lelystad", "Dronten", "Noordoostpolder", "Urk", "Gooise Meren",
                  "Huizen", "Blaricum", "Laren", "Amsterdam", "Harderwijk"],
}

KLOK_REDELIJK = 1.7e9       # een Pi zonder internet kan een verkeerde klok hebben; die tellen we niet mee


# ---------------------------------------------------------------------- hulpfuncties
def norm(s):
    """Kleine letters, zonder accenten of leestekens, losse woorden met een spatie ertussen."""
    s = unicodedata.normalize("NFKD", str(s or "").lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return s.strip()


def tegel_van(lat, lon, z):
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    lr = math.radians(lat)
    y = (1.0 - math.log(math.tan(lr) + 1.0 / math.cos(lr)) / math.pi) / 2.0 * n
    return x, y


def tegels_rond(lat, lon, zoom_straal):
    """Alle (z, x, y) rond lat/lon, per zoomniveau binnen de straal in km; eerst de grote
    overzichten, en per niveau eerst wat het dichtst bij de post ligt."""
    uit = []
    for z, km in zoom_straal:
        z = int(z)
        n = 2 ** z
        dlat = float(km) / 111.32
        dlon = float(km) / (111.32 * max(0.1, math.cos(math.radians(lat))))
        cx, cy = tegel_van(lat, lon, z)
        x0, y1 = tegel_van(lat - dlat, lon - dlon, z)
        x1, y0 = tegel_van(lat + dlat, lon + dlon, z)
        lijst = []
        for x in range(max(0, int(math.floor(x0))), min(n - 1, int(math.floor(x1))) + 1):
            for y in range(max(0, int(math.floor(y0))), min(n - 1, int(math.floor(y1))) + 1):
                lijst.append(((x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2, z, x, y))
        lijst.sort()
        uit.extend((z, x, y) for _, z, x, y in lijst)
    return uit


def haal_bytes(url, timeout=12):
    """(statuscode, bytes); statuscode 0 = mislukt."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "p2000-offline/1"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b""
    except Exception:
        return 0, b""


def schrijf(pad, data):
    os.makedirs(os.path.dirname(pad), exist_ok=True)
    tmp = pad + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, pad)


def lees_json(pad, standaard):
    try:
        with open(pad, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return standaard


POINT = re.compile(r"POINT\(\s*(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*\)")


class Kaart:
    def __init__(self, cfg, pad_van, log, is_online, midden_van):
        self.c = dict(STANDAARD)
        self.c.update({k: v for k, v in cfg.items() if k in STANDAARD})
        self.pad_van = pad_van            # functie: relatief pad -> volledig pad in de data-map
        self.log = log
        self.is_online = is_online
        self.midden_van = midden_van      # functie: geeft (lat, lon) of None
        self.map = pad_van("kaart")
        self.index = {}                   # genormaliseerde straatnaam -> lijst (naam, woonplaats, gemeente, lat, lon)
        self.n_straten = 0
        self.stand = {"tegels_klaar": 0, "tegels_totaal": 0, "bezig": False, "mb": 0.0, "fout": "",
                      "straten_fout": "", "lib_fout": "", "tegels_op_schijf": 0}
        self._bytes = 0
        self._draad = None
        self._stop = False
        self._laad_straten()
        self._mb_tellen()                 # wat er al op de SD-kaart staat (ook als de Pi nu offline is)

    # ------------------------------------------------------------------ starten
    def start(self):
        if not self.c.get("kaart") or self._draad is not None:
            return
        self._draad = threading.Thread(target=self._lus, daemon=True)
        self._draad.start()

    def stop(self):
        self._stop = True

    def _lus(self):
        time.sleep(self.c["kaart_start_wacht_sec"])
        while not self._stop:
            try:
                if self.is_online():
                    self.ronde()
            except Exception as e:
                self.stand["fout"] = repr(e)[:120]
                self.log("kaart: fout:", repr(e))
            time.sleep(self.c["kaart_ronde_sec"])

    def ronde(self):
        self.ververs_lib()
        if self._stop or not self.is_online():
            return
        self.ververs_straten()
        if self._stop or not self.is_online():
            return
        self.ververs_tegels()

    # ------------------------------------------------------------------ Leaflet
    def lib_pad(self, naam):
        return os.path.join(self.map, "lib", naam)

    def lib_klaar(self):
        return all(os.path.exists(self.lib_pad(n)) for n in LIB_VERPLICHT)

    def ververs_lib(self):
        if self.lib_klaar():
            return
        for naam in LIB_VERPLICHT + LIB_OPTIONEEL:
            if os.path.exists(self.lib_pad(naam)):
                continue
            status, data = haal_bytes(self.c["leaflet_basis"].rstrip("/") + "/" + naam)
            ok = status == 200 and len(data) > 100
            if ok and naam.endswith(".js"):
                ok = b"Leaflet" in data[:2000] or b"leaflet" in data[:2000]
            if ok and naam.endswith(".css"):
                ok = b".leaflet-" in data
            if ok and naam.endswith(".png"):
                ok = data[:4] == b"\x89PNG"
            if ok:
                schrijf(self.lib_pad(naam), data)
            elif naam in LIB_VERPLICHT:
                self.stand["lib_fout"] = "kon %s niet ophalen (%s)" % (naam, status)
                self.log("kaart: Leaflet ophalen mislukt:", naam, status)
                return
        self.stand["lib_fout"] = ""
        self.log("kaart: Leaflet bewaard op de SD-kaart")

    def lib_bestand(self, naam):
        """Voor de webserver: (bytes, content-type) of None. Alleen bekende namen."""
        if naam not in LIB_VERPLICHT + LIB_OPTIONEEL:
            return None
        try:
            with open(self.lib_pad(naam), "rb") as f:
                data = f.read()
        except Exception:
            return None
        soort = {"js": "application/javascript", "css": "text/css", "png": "image/png"}[naam.rsplit(".", 1)[-1]]
        return data, soort

    def herschrijf(self, html):
        """Het offline-scherm gebruikt de eigen kopie van Leaflet i.p.v. de internetversie."""
        if not html or not self.lib_klaar():
            return html
        try:
            for naam in LIB_VERPLICHT:
                html = html.replace((LEAFLET_CDN + naam).encode(), ("/lokaal/lib/" + naam).encode())
        except Exception:
            pass
        return html

    # ------------------------------------------------------------------ straten
    def _straten_pad(self):
        return os.path.join(self.map, "straten.json")

    def _laad_straten(self):
        d = lees_json(self._straten_pad(), {})
        self._zet_index(d.get("straten") or [])

    def _zet_index(self, lijst):
        index = {}
        for r in lijst:
            try:
                naam, wp, gem, lat, lon = r
                index.setdefault(norm(naam), []).append((naam, wp, gem, float(lat), float(lon)))
            except Exception:
                continue
        self.index = index
        self.n_straten = sum(len(v) for v in index.values())

    def _straten_oud(self):
        d = lees_json(self._straten_pad(), {})
        if not d.get("straten"):
            return True
        if time.time() < KLOK_REDELIJK:
            return False
        gemaakt = d.get("gemaakt") or 0
        return (time.time() - gemaakt) > self.c["straten_ververs_dagen"] * 86400 or \
            sorted(d.get("gemeenten") or []) != sorted(self.c["gemeenten"])

    def _straten_van_gemeente(self, gem):
        basis = self.c["pdok_basis"].rstrip("/") + "/free"
        fl = "straatnaam,woonplaatsnaam,gemeentenaam,centroide_ll"
        pogingen = [
            ("*:*", ["type:weg", 'gemeentenaam:"%s"' % gem]),
            ('gemeentenaam:"%s"' % gem, ["type:weg"]),
            ('type:weg AND gemeentenaam:"%s"' % gem, []),
        ]
        laatste_fout = "geen antwoord"
        for q, fqs in pogingen:
            uit = []
            start = 0
            totaal = None
            while True:
                par = [("q", q), ("fl", fl), ("rows", "100"), ("start", str(start))] + [("fq", f) for f in fqs]
                status, data = haal_bytes(basis + "?" + urllib.parse.urlencode(par), timeout=20)
                if status != 200:
                    laatste_fout = "HTTP %s" % status
                    break
                try:
                    antw = json.loads(data.decode("utf-8", "replace")).get("response") or {}
                except Exception:
                    laatste_fout = "antwoord onleesbaar"
                    break
                docs = antw.get("docs") or []
                totaal = antw.get("numFound", 0) if totaal is None else totaal
                for d in docs:
                    m = POINT.search(str(d.get("centroide_ll") or ""))
                    naam = d.get("straatnaam")
                    if not (m and naam):
                        continue
                    uit.append([naam, d.get("woonplaatsnaam") or "", d.get("gemeentenaam") or gem,
                                round(float(m.group(2)), 5), round(float(m.group(1)), 5)])
                start += len(docs)
                if not docs or start >= (totaal or 0) or start >= 20000 or self._stop:
                    break
                time.sleep(0.15)
            if uit:
                return uit, ""
            if totaal == 0:
                laatste_fout = "geen straten gevonden"
        return [], laatste_fout

    def ververs_straten(self):
        if not self._straten_oud():
            return
        alles = []
        gelukt = []
        fouten = []
        for gem in self.c["gemeenten"]:
            if self._stop or not self.is_online():
                return
            lijst, fout = self._straten_van_gemeente(gem)
            if lijst:
                alles.extend(lijst)
                gelukt.append(gem)
                self.log("kaart: %d straten van %s" % (len(lijst), gem))
            else:
                fouten.append("%s: %s" % (gem, fout))
            time.sleep(0.3)
        if not alles:
            self.stand["straten_fout"] = "; ".join(fouten)[:200] or "niets opgehaald"
            self.log("kaart: straten ophalen mislukt:", self.stand["straten_fout"])
            return
        uniek = {}
        for r in alles:
            uniek[(norm(r[0]), norm(r[1]), norm(r[2]))] = r
        lijst = list(uniek.values())
        schrijf(self._straten_pad(), json.dumps({"gemaakt": time.time(), "gemeenten": gelukt, "straten": lijst},
                                                ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        self._zet_index(lijst)
        self.stand["straten_fout"] = ("sommige gemeenten mislukt: " + "; ".join(fouten))[:200] if fouten else ""
        self.log("kaart: %d straten bewaard" % self.n_straten)

    # ------------------------------------------------------------------ opzoeken
    def zoek(self, tekst):
        """Zoekt in de hele meldingstekst een straat uit de lijst, gevolgd door de plaats.
        Geeft {lat, lon, naam, plaats} of None. Straat EN plaats moeten kloppen."""
        t = " " + norm(tekst) + " "
        if len(t) < 5 or not self.index:
            return None
        beste = None
        for sleutel, kand in self.index.items():
            if not sleutel:
                continue
            zoek = " " + sleutel + " "
            p0 = t.find(zoek)
            if p0 < 0:
                continue
            einde = p0 + len(zoek) - 1                  # positie van de spatie na de straat
            ruim = []
            while p0 >= 0:
                ruim.append(p0 + len(zoek) - 1)
                p0 = t.find(zoek, p0 + 1)
            for naam, wp, gem, lat, lon in kand:
                for plaats in {norm(wp), norm(gem)}:
                    if not plaats:
                        continue
                    pz = " " + plaats + " "
                    for einde in ruim:
                        q = t.find(pz, einde)
                        if q < 0:
                            continue
                        gat = len(t[einde:q].split())    # woorden tussen straat en plaats (huisnummer e.d.)
                        if gat > 4:
                            continue
                        # een woonplaats die in de melding staat telt zwaarder dan alleen de gemeente
                        score = (len(sleutel), 1 if plaats == norm(wp) else 0, -gat)
                        if beste is None or score > beste[0]:
                            beste = (score, [(naam, wp or gem, lat, lon)])
                        elif score == beste[0]:
                            beste[1].append((naam, wp or gem, lat, lon))
        if beste is None:
            return None
        kand = beste[1]
        # Zelfde straatnaam op meer plekken die ver uit elkaar liggen (en de melding zegt niet welke)?
        # Dan liever niets tonen dan een verkeerde plek.
        for k in kand[1:]:
            if self._afstand_km(kand[0][2], kand[0][3], k[2], k[3]) > 1.5:
                return None
        naam, plaats, lat, lon = kand[0]
        return {"lat": lat, "lon": lon, "naam": naam, "plaats": plaats, "zoom": self.zoom_voor(lat, lon)}

    @staticmethod
    def _afstand_km(lat1, lon1, lat2, lon2):
        p = math.pi / 180.0
        a = (math.sin((lat2 - lat1) * p / 2) ** 2
             + math.cos(lat1 * p) * math.cos(lat2 * p) * math.sin((lon2 - lon1) * p / 2) ** 2)
        return 12742.0 * math.asin(math.sqrt(a))

    def zoom_voor(self, lat, lon):
        """Hoogste zoomniveau (hooguit 15) waarvoor de kaartstukjes rond deze plek zijn opgeslagen."""
        try:
            mlat, mlon = self._midden()
            d = self._afstand_km(mlat, mlon, lat, lon)
            beste = None
            for z, km in self.c.get("kaart_zoom_straal_km") or STANDAARD["kaart_zoom_straal_km"]:
                if d <= float(km) and (beste is None or int(z) > beste):
                    beste = int(z)
            return min(15, beste) if beste else 12
        except Exception:
            return 12

    # ------------------------------------------------------------------ kaartstukjes
    def tegel_pad(self, z, x, y):
        return os.path.join(self.map, "t", str(z), str(x), "%s.png" % y)

    def tegel(self, z, x, y):
        try:
            with open(self.tegel_pad(z, x, y), "rb") as f:
                return f.read()
        except Exception:
            return None

    def _staat_pad(self):
        return os.path.join(self.map, "stand.json")

    def _midden(self):
        m = self.c.get("kaart_midden")
        if isinstance(m, (list, tuple)) and len(m) == 2:
            try:
                return float(m[0]), float(m[1])
            except Exception:
                pass
        try:
            r = self.midden_van()
            if r:
                return float(r[0]), float(r[1])
        except Exception:
            pass
        return STANDAARD_MIDDEN

    def _mb_tellen(self):
        totaal = 0
        aantal = 0
        for pad, _, files in os.walk(os.path.join(self.map, "t")):
            for f in files:
                try:
                    totaal += os.path.getsize(os.path.join(pad, f))
                    aantal += 1
                except OSError:
                    pass
        self._bytes = totaal
        self.stand["mb"] = round(totaal / 1048576.0, 1)
        self.stand["tegels_op_schijf"] = aantal

    def _vrije_ruimte(self):
        pad = self.map
        while pad and not os.path.isdir(pad):
            ouder = os.path.dirname(pad)
            if ouder == pad:
                break
            pad = ouder
        try:
            return shutil.disk_usage(pad or ".").free
        except Exception:
            return None

    def ververs_tegels(self):
        lat, lon = self._midden()
        lijst = tegels_rond(lat, lon, self.c["kaart_zoom_straal_km"])[: int(self.c["kaart_max_tegels"])]
        stand = lees_json(self._staat_pad(), {})
        opnieuw = False
        if time.time() > KLOK_REDELIJK:
            laatste = stand.get("laatste_ronde") or 0
            opnieuw = laatste > 0 and (time.time() - laatste) > self.c["kaart_ververs_dagen"] * 86400
        self.stand["tegels_totaal"] = len(lijst)
        te_doen = [t for t in lijst if opnieuw or not os.path.exists(self.tegel_pad(*t))]
        self.stand["tegels_klaar"] = len(lijst) - len([t for t in lijst if not os.path.exists(self.tegel_pad(*t))])
        self._mb_tellen()
        if not te_doen:
            return
        vrij = self._vrije_ruimte()
        if vrij is not None and vrij < 300 * 1048576:
            self.stand["fout"] = "te weinig ruimte op de SD-kaart (nog %d MB vrij)" % (vrij // 1048576)
            self.log("kaart:", self.stand["fout"])
            return
        self.stand["bezig"] = True
        self.log("kaart: %d kaartstukjes te halen (van %d)" % (len(te_doen), len(lijst)))
        mislukt_achter_elkaar = 0
        gehaald = 0
        try:
            for z, x, y in te_doen:
                if self._stop or not self.is_online():
                    return
                if self._bytes > self.c["kaart_max_mb"] * 1048576:
                    self.stand["fout"] = "SD-kaart-limiet bereikt (%s MB)" % self.c["kaart_max_mb"]
                    self.log("kaart:", self.stand["fout"])
                    return
                url = self.c["tegel_url"].replace("{z}", str(z)).replace("{x}", str(x)).replace("{y}", str(y))
                status, data = haal_bytes(url)
                if status == 200 and data[:4] == b"\x89PNG":
                    schrijf(self.tegel_pad(z, x, y), data)
                    self._bytes += len(data)
                    gehaald += 1
                    mislukt_achter_elkaar = 0
                    if not opnieuw:
                        self.stand["tegels_klaar"] += 1
                else:
                    mislukt_achter_elkaar += 1
                    if status in (429, 503):
                        time.sleep(60)
                    if mislukt_achter_elkaar >= 10:
                        self.stand["fout"] = "kaartserver geeft geen kaartstukjes (laatste antwoord %s)" % status
                        self.log("kaart:", self.stand["fout"], "- ik probeer het later opnieuw")
                        return
                time.sleep(self.c["kaart_pauze_sec"])
            self.stand["fout"] = ""
            self.stand["mb"] = round(self._bytes / 1048576.0, 1)
            if time.time() > KLOK_REDELIJK:
                schrijf(self._staat_pad(), json.dumps({"laatste_ronde": time.time()}).encode())
            self.log("kaart: klaar, %d kaartstukjes opgehaald (%.0f MB op de SD-kaart)" % (gehaald, self._bytes / 1048576.0))
        finally:
            self.stand["bezig"] = False
            self.stand["mb"] = round(self._bytes / 1048576.0, 1)

    # ------------------------------------------------------------------ status
    def status(self):
        s = dict(self.stand)
        s.update({"aan": bool(self.c.get("kaart")), "lib": self.lib_klaar(), "straten": self.n_straten})
        return s
P2000_EINDE_OFFLINE_KAART_PY
cat > "$MAP/offline_haak.py" <<'P2000_EINDE_OFFLINE_HAAK_PY'
# -*- coding: utf-8 -*-
"""
Koppeling tussen ontvanger.py en de offline-dienst (10 nov 2026).

ontvanger.py roept deze functies aan. Ze GOOIEN NOOIT een fout en wachten nooit
langer dan een halve seconde: staat de offline-dienst uit of is hij kapot, dan
gebeurt er hier gewoon niets en werkt ontvanger.py precies zoals voorheen.

  lokaal_melding(doel_naam, url, body, eigen)
      VOOR het versturen naar de Worker aanroepen. Geeft een id terug (of None).
      Het offline-scherm kan de melding dan meteen tonen, ook als het versturen
      naar de Worker straks mislukt of lang duurt.
        url   = het adres waar ontvanger.py naartoe post (.../api/pi)
        body  = het woordenboek (dict) dat verstuurd wordt, mét sleutel
        eigen = True als dit de eigen post is (alleen dan toont het scherm 'm)

  lokaal_resultaat(id, bezorgd)
      NA het versturen: True als de Worker de melding aannam, anders False.
      Bij False wordt de melding bewaard en later alsnog doorgestuurd.

  bezorgd_uit_curl(returncode, uitvoer)
      Maakt van het resultaat van curl een True/False voor lokaal_resultaat.
      True = de Worker heeft geantwoord (JSON). curl zonder -f geeft ook returncode 0
      bij een foutpagina van Cloudflare; dat telt hier dus NIET als bezorgd.

  bewaar_capcodes(pad, doel_naam, lijst) / laad_capcodes(pad, doel_naam)
      Bewaart de capcode-lijst van een doel op schijf, zodat ontvanger.py na een
      herstart zonder internet toch weet waarop hij moet filteren.
"""
import json
import os
import urllib.request

LOKAAL = os.environ.get("P2000_OFFLINE_URL", "http://127.0.0.1:8765")


def _post(pad, data, timeout=0.5):
    try:
        req = urllib.request.Request(LOKAAL + pad, data=json.dumps(data).encode("utf-8"),
                                     headers={"content-type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception:
        return None


def lokaal_melding(doel_naam, url, body, eigen):
    try:
        if isinstance(body, (str, bytes)):
            body = json.loads(body)
        r = _post("/lokaal/melding", {"doel": doel_naam, "url": url, "body": body, "eigen": bool(eigen)})
        return r.get("id") if r else None
    except Exception:
        return None


def bezorgd_uit_curl(returncode, uitvoer):
    """True als curl gelukt is EN de Worker met JSON antwoordde (ook een JSON-foutmelding
    zoals 'ongeldige sleutel' telt: de Worker leeft dan, nasturen heeft geen zin)."""
    try:
        if returncode != 0:
            return False
        return isinstance(json.loads(uitvoer), dict)
    except Exception:
        return False


def lokaal_resultaat(mid, bezorgd):
    try:
        if mid:
            _post("/lokaal/resultaat", {"id": mid, "bezorgd": bool(bezorgd)})
    except Exception:
        pass


def bewaar_capcodes(pad, doel_naam, lijst):
    """Alleen schrijven als er iets veranderd is; altijd via een tijdelijk bestand."""
    try:
        try:
            with open(pad, "r", encoding="utf-8") as f:
                alles = json.load(f)
            if not isinstance(alles, dict):
                alles = {}
        except Exception:
            alles = {}
        nieuw = sorted(str(c) for c in lijst)
        if alles.get(doel_naam) == nieuw:
            return
        alles[doel_naam] = nieuw
        tmp = pad + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(alles, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, pad)
    except Exception:
        pass


def laad_capcodes(pad, doel_naam):
    try:
        with open(pad, "r", encoding="utf-8") as f:
            alles = json.load(f)
        lijst = alles.get(doel_naam)
        return list(lijst) if isinstance(lijst, list) and lijst else None
    except Exception:
        return None
P2000_EINDE_OFFLINE_HAAK_PY
cat > "$MAP/patch_ontvanger.py" <<'P2000_EINDE_PATCH_ONTVANGER_PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Past ontvanger.py aan voor de offline-dienst  (10 nov 2026)

Wat verandert er in ontvanger.py? Alleen kleine regels die de offline-dienst
inlichten. Er wordt niets weggehaald of herschreven:

  1. bovenaan:        de koppeling laden (en als die ontbreekt: niets doen)
  2. na de capcodes:  bewaarde capcode-lijsten uit de vorige keer inladen
  3. post_melding():  VOOR het versturen de melding aan de dienst geven,
                      NA het versturen doorgeven of het gelukt is
  4. capcode-ververs: elke nieuwe capcode-lijst ook op schijf bewaren

Veilig:
  - Alles-of-niets: ontbreekt er iets, dan wordt er NIETS aangepast.
  - Eerst een reservekopie:  ontvanger.py.voor-offline
  - De nieuwe versie wordt eerst gecontroleerd (compileren) voor hij erin komt.
  - Twee keer draaien kan geen kwaad (de tweede keer meldt 'al aangepast').

Gebruik:  python3 patch_ontvanger.py [pad/naar/ontvanger.py]
          python3 patch_ontvanger.py --terug [pad/naar/ontvanger.py]   (reservekopie terugzetten)
"""
import ast
import os
import re
import shutil
import sys

MARKER = "# --- offline-koppeling (10 nov 2026)"
BEKENDE_VERSIES = {"d97779cee60973a5e9a945962f6e51e1"}   # ontvanger.py van de demo-Pi, 10 nov 2026


def md5(pad):
    import hashlib
    with open(pad, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


class Anker(Exception):
    pass


def kop_tekst(nl):
    return nl.join([
        MARKER + ": alles hieronder vangt fouten op; zonder offline_haak.py werkt ontvanger.py als voorheen",
        "try:",
        "    import offline_haak",
        "except Exception:",
        "    import types as _types",
        "    _niets = lambda *a, **k: None",
        "    offline_haak = _types.SimpleNamespace(lokaal_melding=_niets, lokaal_resultaat=_niets,",
        "                                          bewaar_capcodes=_niets, laad_capcodes=_niets,",
        "                                          bezorgd_uit_curl=lambda *a, **k: False)",
        'OFFLINE_CAPCODE_PAD = os.path.join(SCRIPT_DIR, "offline_capcodes.json")',
        "",
    ])


def laad_tekst(nl):
    return nl.join([
        MARKER + ": bewaarde capcode-lijsten inladen (voor een herstart zonder internet)",
        "for _d in DOELEN:",
        '    _bew = offline_haak.laad_capcodes(OFFLINE_CAPCODE_PAD, _d["naam"])',
        "    if _bew:",
        '        actieve_capcodes_per_doel[_d["naam"]] = set(_bew)',
        '        print(f"[offline] capcodes van {_d[\'naam\']} uit bewaarde kopie geladen: {sorted(_bew)}", flush=True)',
        "",
    ])


def vind_aanpassingen(bron):
    """Geeft een lijst (regelnummer_na_welke_regel, tekst_zonder_inspringing, soort) terug,
    of gooit Anker met een duidelijke uitleg."""
    boom = ast.parse(bron)
    regels = bron.splitlines()
    nl = "\r\n" if "\r\n" in bron else "\n"
    uit = []

    def naam_van(n):
        return n.id if isinstance(n, ast.Name) else None

    def module_toewijzing(naam):
        for n in boom.body:
            if isinstance(n, ast.Assign) and any(naam_van(t) == naam for t in n.targets):
                return n
        raise Anker("de regel '%s = ...' staat niet op het hoofdniveau" % naam)

    def functie(naam):
        for n in boom.body:
            if isinstance(n, ast.FunctionDef) and n.name == naam:
                return n
        raise Anker("de functie '%s' is niet gevonden" % naam)

    def inspring(regelnr):
        m = re.match(r"[ \t]*", regels[regelnr - 1])
        return m.group(0)

    # 1. koppeling laden, direct na CONFIG_PAD = ...
    n = module_toewijzing("CONFIG_PAD")
    uit.append((n.end_lineno, kop_tekst(nl), ""))

    # 2. bewaarde capcodes inladen, direct na actieve_capcodes_per_doel = ...
    n = module_toewijzing("actieve_capcodes_per_doel")
    uit.append((n.end_lineno, laad_tekst(nl), ""))

    # 3. post_melding
    f = functie("post_melding")
    args = [a.arg for a in f.args.args]
    if args[:2] != ["doel_naam", "tekst"]:
        raise Anker("post_melding heeft andere parameters dan verwacht: %s" % args)
    payload = None
    for n in f.body:
        if isinstance(n, ast.Assign) and any(naam_van(t) == "payload" for t in n.targets):
            payload = n
    if payload is None:
        raise Anker("in post_melding staat 'payload = ...' niet direct in de functie")
    url_toegewezen = any(isinstance(n, ast.Assign) and any(naam_van(t) == "url" for t in n.targets) for n in f.body)
    if not url_toegewezen:
        raise Anker("in post_melding staat 'url = ...' niet direct in de functie")
    proef = None
    for n in f.body:
        if isinstance(n, ast.Try) and n.lineno > payload.end_lineno:
            proef = n
            break
    if proef is None:
        raise Anker("na 'payload = ...' komt in post_melding geen try-blok")
    run = None
    for n in proef.body:
        if (isinstance(n, ast.Assign) and any(naam_van(t) == "resultaat" for t in n.targets)
                and isinstance(n.value, ast.Call) and isinstance(n.value.func, ast.Attribute)
                and n.value.func.attr == "run"):
            run = n
            break
    if run is None:
        raise Anker("in het try-blok van post_melding staat 'resultaat = subprocess.run(...)' niet")
    if not proef.handlers:
        raise Anker("het try-blok van post_melding heeft geen except")
    handler = proef.handlers[0]
    uit.append((payload.end_lineno,
                '_off_id = offline_haak.lokaal_melding(doel_naam, url, payload, any(_d["naam"] == doel_naam for _d in DOELEN))',
                inspring(payload.lineno)))
    uit.append((run.end_lineno,
                "offline_haak.lokaal_resultaat(_off_id, offline_haak.bezorgd_uit_curl(resultaat.returncode, resultaat.stdout))",
                inspring(run.lineno)))
    eerste = handler.body[0]
    uit.append((eerste.lineno - 1, "offline_haak.lokaal_resultaat(_off_id, False)", inspring(eerste.lineno)))

    # 4. capcodes bewaren in ververs_capcodes_voor_doel
    f = functie("ververs_capcodes_voor_doel")
    gevonden = None
    for n in ast.walk(f):
        if (isinstance(n, ast.Expr) and isinstance(n.value, ast.Call) and naam_van(n.value.func) == "schrijf_status"
                and len(n.value.args) >= 2 and naam_van(n.value.args[0]) == "naam" and naam_van(n.value.args[1]) == "nieuwe_set"):
            gevonden = n
            break
    if gevonden is None:
        raise Anker("in ververs_capcodes_voor_doel staat 'schrijf_status(naam, nieuwe_set)' niet")
    uit.append((gevonden.end_lineno, "offline_haak.bewaar_capcodes(OFFLINE_CAPCODE_PAD, naam, nieuwe_set)",
                inspring(gevonden.lineno)))
    return uit, nl


def pas_toe(bron):
    if MARKER in bron:
        return None
    uit, nl = vind_aanpassingen(bron)
    regels = bron.splitlines(keepends=True)
    # van onder naar boven invoegen, zodat de regelnummers kloppen
    for na_regel, tekst, inspr in sorted(uit, key=lambda x: -x[0]):
        blok = "".join(inspr + r + nl if r else "" for r in tekst.split(nl))
        if not blok.endswith(nl):
            blok += nl
        # zorg dat de regel waarna we invoegen op een regeleinde eindigt
        if na_regel >= 1 and not regels[na_regel - 1].endswith(("\n", "\r")):
            regels[na_regel - 1] += nl
        regels.insert(na_regel, blok)
    nieuw = "".join(regels)
    compile(nieuw, "ontvanger.py", "exec")           # moet nog steeds geldig Python zijn
    return nieuw


def main():
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    terug = "--terug" in sys.argv
    pad = os.path.abspath(argv[0] if argv else "ontvanger.py")
    reserve = pad + ".voor-offline"
    if terug:
        if not os.path.exists(reserve):
            sys.exit("Geen reservekopie gevonden (%s). Niets teruggezet." % reserve)
        shutil.copy2(reserve, pad)
        print("ontvanger.py teruggezet naar de versie van voor de offline-aanpassing.")
        return
    if not os.path.exists(pad):
        sys.exit("ontvanger.py niet gevonden op %s" % pad)
    with open(pad, "r", encoding="utf-8", newline="") as f:
        bron = f.read()
    versie = md5(pad)
    if MARKER in bron:
        print("ontvanger.py is al aangepast. Niets gedaan.")
        return
    if versie not in BEKENDE_VERSIES:
        print("Let op: dit is een andere versie van ontvanger.py dan waarop ik getest heb (%s)." % versie)
        print("        Ik controleer nu of de plekken er toch zijn.")
    try:
        nieuw = pas_toe(bron)
    except Anker as e:
        sys.exit("NIETS AANGEPAST. Ik kon een plek niet vinden: %s.\nStuur me deze regel, dan pas ik het aan." % e)
    except SyntaxError as e:
        sys.exit("NIETS AANGEPAST. De aangepaste versie klopte niet (%s). Stuur me deze regel." % e)
    if not os.path.exists(reserve):
        shutil.copy2(pad, reserve)
    tmp = pad + ".nieuw"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(nieuw)
    shutil.copymode(pad, tmp)
    os.replace(tmp, pad)
    print("ontvanger.py aangepast (reservekopie: %s)." % os.path.basename(reserve))


if __name__ == "__main__":
    main()
P2000_EINDE_PATCH_ONTVANGER_PY
cat > "$MAP/offline_venster.sh" <<'P2000_EINDE_OFFLINE_VENSTER_SH'
#!/bin/bash
# Het offline-scherm tonen of weghalen.
#   bash offline_venster.sh start     -> het offline-scherm tonen
#   bash offline_venster.sh stop      -> het offline-scherm weghalen; het gewone scherm is dan weer te zien
#   bash offline_venster.sh opruimen  -> bij het starten van de offline-dienst: een achtergebleven offline-scherm opruimen
# De offline-dienst roept dit zelf aan; je hoeft er niets mee.
#
# Twee manieren (staat in offline_instellingen.json, 'venster_modus'):
#   tweede  = er opent een TWEEDE Chromium bovenop het gewone scherm (Pi's met genoeg geheugen, en de demo).
#   vervang = het gewone scherm wordt gesloten en het offline-scherm komt in de plaats; daarna komt
#             het gewone scherm weer terug. Er draait dan steeds maar EEN browser (Pi 3 met 1 GB).
DIR="$(cd "$(dirname "$0")" && pwd)"
INST="${P2000_OFFLINE_INSTELLINGEN:-$DIR/offline_instellingen.json}"
PROFIEL="${P2000_OFFLINE_PROFIEL:-/tmp/p2000-offline-profiel}"
MARKER="${P2000_OFFLINE_MARKER:-/tmp/p2000-offline-gestopt}"
URL="http://127.0.0.1:${P2000_OFFLINE_POORT:-8765}/?offline=1"

lees() {
  python3 - "$INST" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2]) or "")
except Exception:
    print("")
PY
}
MODUS="$(lees venster_modus)"
HOOFD_START="$(lees hoofd_start)"
HOOFD_PATROON="$(lees hoofd_patroon)"
# Is de vervang-modus niet helemaal ingesteld? Dan veilig terugvallen op het tweede venster.
if [ "$MODUS" = "vervang" ] && { [ -z "$HOOFD_START" ] || [ -z "$HOOFD_PATROON" ]; }; then MODUS="tweede"; fi

zet_wayland() {
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    for s in "$XDG_RUNTIME_DIR"/wayland-*; do
      case "$s" in *.lock) continue ;; esac
      if [ -S "$s" ]; then export WAYLAND_DISPLAY="$(basename "$s")"; break; fi
    done
  fi
  export DISPLAY="${DISPLAY:-:0}"
}

hoofd_draait() { pgrep -f -- "$HOOFD_PATROON" >/dev/null 2>&1; }

stop_hoofd() {
  hoofd_draait || return 0
  pkill -TERM -f -- "$HOOFD_PATROON" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    hoofd_draait || return 0
    sleep 0.5
  done
  pkill -KILL -f -- "$HOOFD_PATROON" 2>/dev/null
  sleep 0.5
}

start_hoofd() {
  hoofd_draait && return 0
  zet_wayland
  # eigen sessie, zodat het gewone scherm blijft draaien ook als deze dienst herstart
  setsid bash -c "exec $HOOFD_START" </dev/null >/dev/null 2>&1 &
}

offline_chromium() {
  CHR="$(command -v chromium || command -v chromium-browser)"
  [ -n "$CHR" ] || { echo "Chromium niet gevonden"; return 1; }
  OFFLINE_CMD=("$CHR" --user-data-dir="$PROFIEL" --kiosk --noerrdialogs --disable-infobars --no-first-run
    --no-default-browser-check --disable-session-crashed-bubble --password-store=basic
    --disable-background-networking --disable-sync
    --autoplay-policy=no-user-gesture-required "$URL")
}

ruim_profiel_op() {
  pkill -f -- "--user-data-dir=$PROFIEL" 2>/dev/null
  sleep 0.5
  rm -rf "$PROFIEL" 2>/dev/null
}

case "${1:-}" in
  start)
    rm -f "$MARKER" 2>/dev/null
    pkill -f -- "--user-data-dir=$PROFIEL" 2>/dev/null
    sleep 0.3
    rm -rf "$PROFIEL" 2>/dev/null
    zet_wayland
    offline_chromium || exit 1
    if [ "$MODUS" != "vervang" ]; then
      exec "${OFFLINE_CMD[@]}" >/dev/null 2>&1
    fi
    # vervang-modus: eerst het gewone scherm sluiten, dan het offline-scherm tonen
    stop_hoofd
    "${OFFLINE_CMD[@]}" >/dev/null 2>&1 &
    CP=$!
    trap 'kill "$CP" 2>/dev/null; exit 0' TERM INT HUP
    wait "$CP"
    # Het offline-scherm is gestopt. Door 'stop' (dan staat de markering er en zet 'stop' het gewone scherm terug)
    # of onverwacht (gecrasht of niet gestart)? Dan zetten wij het gewone scherm zelf terug, zodat het scherm nooit leeg blijft.
    if [ ! -e "$MARKER" ]; then start_hoofd; fi
    exit 0
    ;;
  stop)
    : > "$MARKER" 2>/dev/null
    ruim_profiel_op
    if [ "$MODUS" = "vervang" ]; then start_hoofd; fi
    exit 0
    ;;
  opruimen)
    # De dienst is (opnieuw) gestart. Een offline-scherm van de vorige keer opruimen.
    # Eerst de markering zetten: een achtergebleven start-script zet dan het gewone scherm NIET zelf terug
    # (dat doen wij hieronder), anders kunnen er twee komen.
    : > "$MARKER" 2>/dev/null
    ruim_profiel_op
    if [ "$MODUS" = "vervang" ]; then
      # Het gewone scherm terugzetten als het weg is. Niet vlak na het opstarten van de Pi: dan start
      # het gewone scherm zelf (autostart) en zouden er twee komen.
      UP="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"
      if [ "${UP:-0}" -gt "${P2000_OFFLINE_MIN_UPTIME:-180}" ]; then start_hoofd; fi
    fi
    exit 0
    ;;
  *)
    echo "gebruik: bash offline_venster.sh start|stop|opruimen"
    exit 1
    ;;
esac
P2000_EINDE_OFFLINE_VENSTER_SH
cat > "$MAP/offline_simuleer.sh" <<'P2000_EINDE_OFFLINE_SIMULEER_SH'
#!/bin/bash
# Doet alsof de Worker niet bereikbaar is, zonder de Pi van het internet te halen.
# Je terminal via Pi Connect blijft gewoon werken.
#   bash offline_simuleer.sh uit [minuten]   -> internet 'weg' (zet zichzelf na 10 minuten terug)
#   bash offline_simuleer.sh aan             -> internet 'terug'
DIR="$(cd "$(dirname "$0")" && pwd)"
HOST="$(python3 - "$DIR/offline_instellingen.json" <<'PY'
import json, sys, urllib.parse
print(urllib.parse.urlparse(json.load(open(sys.argv[1]))["basis"]).hostname or "")
PY
)"
[ -n "$HOST" ] || { echo "Kan de naam van de Worker niet vinden in offline_instellingen.json"; exit 1; }
SUDO="${P2000_SUDO-sudo}"
HOSTS="${P2000_HOSTS:-/etc/hosts}"
case "${1:-}" in
  uit)
    MIN="${2:-10}"
    grep -q "# p2000-offline-test" "$HOSTS" || echo "127.0.0.1 $HOST # p2000-offline-test" | $SUDO tee -a "$HOSTS" >/dev/null
    $SUDO systemctl stop p2000-offline-test-terug.timer 2>/dev/null
    $SUDO systemd-run --quiet --on-active="${MIN}m" --unit=p2000-offline-test-terug /bin/sed -i '/# p2000-offline-test/d' "$HOSTS" 2>/dev/null
    echo "De Worker ($HOST) is nu 'onbereikbaar' voor deze Pi."
    echo "Na ongeveer 15 seconden schakelt het scherm over naar offline."
    echo "Het zet zichzelf over $MIN minuten weer terug. Eerder terug:  bash offline_simuleer.sh aan"
    ;;
  aan)
    $SUDO sed -i '/# p2000-offline-test/d' "$HOSTS"
    $SUDO systemctl stop p2000-offline-test-terug.timer 2>/dev/null
    echo "De Worker is weer bereikbaar. Binnen ongeveer 10 seconden is de Pi weer online."
    echo "Het offline-scherm blijft nog even staan (ongeveer 1,5 minuut; na een alarm langer) en gaat dan vanzelf weg."
    ;;
  *)
    echo "gebruik:  bash offline_simuleer.sh uit   of   bash offline_simuleer.sh aan"
    exit 1
    ;;
esac
P2000_EINDE_OFFLINE_SIMULEER_SH
cat > "$MAP/offline_test.sh" <<'P2000_EINDE_OFFLINE_TEST_SH'
#!/bin/bash
# Stuurt een nep-melding naar de offline-dienst, net zoals ontvanger.py dat doet.
#   bash offline_test.sh          -> alleen tonen op het offline-scherm. Wordt NIET doorgestuurd.
#   bash offline_test.sh kaart    -> zoals de eerste, maar met een ECHTE straat uit de straatlijst van deze Pi,
#                                    zodat je de kaart op de straat ziet (de straat staat in de uitvoer).
#   bash offline_test.sh echt     -> telt echt mee en wordt later doorgestuurd naar de Worker.
#                                    Alleen gebruiken op de demo-post!
# Het offline-scherm is alleen open als er geen internet is (zie offline_simuleer.sh).
DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$DIR/offline_instellingen.json" "${1:-}" <<'PY'
import json, os, sys, urllib.request
from collections import Counter
cfg = json.load(open(sys.argv[1]))
echt = sys.argv[2] == "echt"
tekst = "P 2 BDH-03 TESTMELDING offline Teststraat 1 Almere 254133"
if sys.argv[2] == "kaart":
    try:
        lijst = json.load(open(os.path.join(cfg["map"], "kaart", "straten.json"), encoding="utf-8"))["straten"]
        telling = Counter(r[0].lower() for r in lijst)
        r = next(r for r in lijst if telling[r[0].lower()] == 1)
        tekst = "P 2 BDH-03 TESTMELDING offline %s 1 %s 254133" % (r[0], r[2] or r[1])
        print("Teststraat uit de straatlijst:", r[0], "in", r[2] or r[1])
    except Exception as e:
        print("Er is nog geen straatlijst op deze Pi (", repr(e)[:60], "). Kijk met:  curl -s http://127.0.0.1:%s/lokaal/status" % cfg.get("poort", 8765))
        sys.exit(1)
poort = cfg.get("poort", 8765)
def post(pad, data):
    r = urllib.request.Request("http://127.0.0.1:%s%s" % (poort, pad), data=json.dumps(data).encode(),
                               headers={"content-type": "application/json"}, method="POST")
    return json.loads(urllib.request.urlopen(r, timeout=3).read())
try:
    if echt:
        print(post("/lokaal/melding", {"doel": "offline-test", "url": cfg["basis"].rstrip("/") + "/api/pi",
                                      "body": {"sleutel": cfg["sleutel"], "text": tekst, "herkomstPost": "offline-test"}, "eigen": True}))
        print("Verstuurd als echte melding. Zonder bevestiging wordt hij na 90 seconden (of zodra er weer internet is) doorgestuurd.")
    else:
        print(post("/api/pi", {"text": tekst, "test": True}))
        print("Verstuurd als lokale test (wordt niet doorgestuurd).")
    s = json.loads(urllib.request.urlopen("http://127.0.0.1:%s/lokaal/status" % poort, timeout=3).read())
    print("Stand:", s)
except Exception as e:
    print("Mislukt:", e)
    print("Draait de offline-dienst?  sudo systemctl status p2000-offline")
PY
P2000_EINDE_OFFLINE_TEST_SH
chmod +x "$MAP/offline_venster.sh" "$MAP/offline_simuleer.sh" "$MAP/offline_test.sh"
ok "bestanden neergezet"

# ---------- instellingen van deze Pi (uit instellingen.json)
DOEL="${DOEL:-}" python3 - "$MAP" <<'PY' || stop_hier "Ik kon de instellingen niet maken. Staat er een worker_url en sleutel in instellingen.json?"
import ast, json, os, re, sys
m = sys.argv[1]
src = open(os.path.join(m, "ontvanger.py"), encoding="utf-8").read()
std = {}
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "STANDAARD_CONFIG" for t in n.targets):
        try:
            std = ast.literal_eval(n.value)
        except Exception:
            std = {}
cfg = dict(std)
try:
    cfg.update(json.load(open(os.path.join(m, "instellingen.json"), encoding="utf-8")))
except Exception:
    pass
doelen = cfg.get("doelen") if isinstance(cfg.get("doelen"), list) and cfg.get("doelen") else \
    [{"naam": "standaard", "worker_url": cfg.get("worker_url", ""), "sleutel": cfg.get("sleutel", "")}]
keuze = os.environ.get("DOEL", "")
gekozen = next((d for d in doelen if keuze and d.get("naam") == keuze), doelen[0])
if not gekozen.get("worker_url") or not gekozen.get("sleutel"):
    sys.exit(1)
basis = re.sub(r"/api/pi/?$", "", gekozen["worker_url"].rstrip("/"))
uit = {"basis": basis, "sleutel": gekozen["sleutel"], "poort": 8765, "map": os.path.join(m, "offline_data"),
       "venster_start": ["/bin/bash", os.path.join(m, "offline_venster.sh"), "start"],
       "venster_stop": ["/bin/bash", os.path.join(m, "offline_venster.sh"), "stop"],
       "venster_opruim": ["/bin/bash", os.path.join(m, "offline_venster.sh"), "opruimen"]}

# ---- hoe komt het offline-scherm op het scherm?
#   tweede  = een tweede Chromium bovenop het gewone scherm (genoeg geheugen, of geen kiosk)
#   vervang = het gewone scherm sluit tijdelijk en komt daarna weer terug (weinig geheugen, bv. Pi 3 met 1 GB)
import subprocess
wens = os.environ.get("MODUS", "").strip().lower()
if wens not in ("", "tweede", "vervang"):
    print("  LET OP  MODUS=%s ken ik niet (kies tweede of vervang); ik kies zelf." % wens)
    wens = ""
ram_mb = 0
try:
    ram_mb = int(re.search(r"MemTotal:\s+(\d+)", open(os.environ.get("P2000_MEMINFO", "/proc/meminfo")).read()).group(1)) // 1024
except Exception:
    pass
start = patroon = ""
auto = os.path.expanduser("~/.config/labwc/autostart")
try:
    tekst = open(auto, encoding="utf-8").read().replace("\\\n", " ")
    for regel in tekst.splitlines():
        r = regel.strip()
        if not r or r.startswith("#") or "chromium" not in r or "--kiosk" not in r:
            continue
        if r.endswith("&"):
            r = r[:-1].rstrip()
        if any(t in r for t in (";", "&", "|", "(", ")", "`", "$(")):
            print("  LET OP  de Chromium-regel in de autostart is te ingewikkeld voor mij (%s)" % r[:60])
            continue
        url = next((t for t in r.split() if re.match(r"^(https?|file)://", t)), "")
        if not url:
            continue
        start = r
        patroon = "chromium.*" + re.sub(r"([.?+*\[\](){}|^$\\])", r"\\\1", url)
        break
except Exception:
    pass
modus = wens or ("vervang" if (start and 0 < ram_mb < 1500) else "tweede")
if modus == "vervang" and not start:
    print("  LET OP  geen kiosk-regel gevonden in %s; ik gebruik een tweede venster." % auto)
    modus = "tweede"
if modus == "vervang":
    gevonden = subprocess.run(["pgrep", "-f", "--", patroon], capture_output=True).returncode == 0
    if not gevonden:
        print("  LET OP  ik zie het gewone scherm nu niet draaien met die regel (staat het scherm aan?).")
        if not wens:
            print("          Daarom kies ik het tweede venster. Start het scherm en draai dit nog eens, of kies zelf: MODUS=vervang bash installeer_offline.sh")
            modus = "tweede"
uit["venster_modus"] = modus
if modus == "vervang":
    uit["hoofd_start"] = start
    uit["hoofd_patroon"] = patroon
pad = os.path.join(m, "offline_instellingen.json")

# ---- kaart op de SD-kaart (offline kaart). Instellingen per Pi: bij opnieuw installeren blijven ze staan.
try:
    oud = json.load(open(pad, encoding="utf-8"))
    for k, v in oud.items():
        if k.startswith("kaart") or k.startswith("straten") or k in ("gemeenten", "tegel_url", "pdok_basis", "leaflet_basis"):
            uit[k] = v
except Exception:
    pass
gem = os.environ.get("GEMEENTEN", "").strip()
if gem:
    uit["gemeenten"] = [g.strip() for g in gem.split(",") if g.strip()]
kaartkeuze = os.environ.get("KAART", "").strip().lower()
if kaartkeuze in ("uit", "nee", "0"):
    uit["kaart"] = False
elif kaartkeuze in ("aan", "ja", "1"):
    uit["kaart"] = True
with open(pad, "w", encoding="utf-8") as f:
    json.dump(uit, f, indent=2)
os.chmod(pad, 0o600)
print("  OK      scherm van deze Pi: '%s' op %s" % (gekozen.get("naam", "?"), basis))
if modus == "vervang":
    print("  OK      offline-scherm: het gewone scherm gaat tijdelijk dicht en komt daarna vanzelf terug (geheugen: %d MB)" % ram_mb)
else:
    print("  OK      offline-scherm: opent als tweede venster bovenop het gewone scherm (geheugen: %d MB)" % ram_mb)
if uit.get("kaart") is False:
    print("  OK      kaart offline: UIT (KAART=aan bash installeer_offline.sh zet hem weer aan)")
else:
    print("  OK      kaart offline: AAN, gemeenten voor de straatlijst: %s" % ", ".join(uit.get("gemeenten") or ["(standaard: regio Almere)"]))
if len(doelen) > 1:
    print("  LET OP  deze Pi heeft %d doelen (%s). Hoort het scherm bij een andere?  Draai dan:  DOEL=naam bash installeer_offline.sh"
          % (len(doelen), ", ".join(str(d.get("naam")) for d in doelen)))
PY

# ---------- ontvanger.py aanpassen (met reservekopie)
python3 "$MAP/patch_ontvanger.py" "$MAP/ontvanger.py" || stop_hier "ontvanger.py is NIET aangepast. Er is niets stuk. Stuur me de melding hierboven."
ok "ontvanger.py klaar voor offline"

# ---------- de offline-dienst als systeemdienst
TMP_UNIT="$(mktemp)"
cat > "$TMP_UNIT" <<UNIT
[Unit]
Description=P2000 offline-dienst (alarm tonen zonder internet)
After=network.target

[Service]
User=$(id -un)
WorkingDirectory=$MAP
ExecStart=$(command -v python3) $MAP/offline_dienst.py $MAP/offline_instellingen.json
Restart=always
RestartSec=3
# Bij een herstart van deze dienst blijft het scherm gewoon staan (het gewone scherm wordt door deze dienst gestart)
KillMode=process

[Install]
WantedBy=multi-user.target
UNIT
$SUDO cp "$TMP_UNIT" "$UNIT_DIR/$DIENST_NAAM.service" && rm -f "$TMP_UNIT" || stop_hier "Kon de dienst niet neerzetten."
$SUDO systemctl daemon-reload
$SUDO systemctl enable "$DIENST_NAAM" >/dev/null 2>&1
$SUDO systemctl restart "$DIENST_NAAM" && ok "offline-dienst gestart" || stop_hier "De offline-dienst startte niet. Kijk met:  sudo journalctl -u $DIENST_NAAM -n 30"

# ---------- wachten tot de dienst zijn kopie van het scherm heeft
echo "  ...     even wachten op de kopie van het scherm (max. 45 seconden)"
KLAAR=0
for i in $(seq 1 45); do
  S="$(curl -s --max-time 2 "http://127.0.0.1:$POORT/lokaal/status" 2>/dev/null | tr -d ' ')"
  case "$S" in *'"scherm_in_geheugen":true'*'"taken_in_geheugen":true'*) KLAAR=1; break ;; esac
  sleep 1
done
if [ "$KLAAR" = 1 ]; then
  ok "kopie van het scherm en de instellingen staan op de Pi"
else
  let_op "de kopie is er nog niet. Kijk met:  sudo journalctl -u $DIENST_NAAM -n 30"
fi

# ---------- de kaart wordt op de achtergrond opgehaald
case "$(curl -s --max-time 2 "http://127.0.0.1:$POORT/lokaal/status" 2>/dev/null | tr -d ' ')" in
  *'"kaart":{'*'"aan":true'*)
    ok "offline kaart: wordt de eerste 30-60 minuten op de achtergrond op de SD-kaart gezet (de Pi moet online zijn)"
    echo "          voortgang:  curl -s http://127.0.0.1:$POORT/lokaal/status" ;;
esac

# ---------- ontvanger opnieuw starten (pas nu de dienst draait)
herstart_ontvanger

echo
echo "== Klaar =="
echo "Test in drie stappen (je terminal blijft gewoon werken):"
echo "  1.  bash $MAP/offline_simuleer.sh uit      (doet alsof er geen internet is)"
echo "  2.  wacht 20 seconden, dan:  bash $MAP/offline_test.sh      (testalarm op het offline-scherm)"
echo "      en met kaart op een echte straat:  bash $MAP/offline_test.sh kaart   (kan pas als de straatlijst klaar is)"
echo "  3.  bash $MAP/offline_simuleer.sh aan      (internet weer 'terug')"
echo "Alles weer weghalen:  bash installeer_offline.sh --terugdraaien"
