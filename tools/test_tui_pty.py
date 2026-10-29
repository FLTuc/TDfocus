#!/usr/bin/env python3
"""Test de bout en bout de TDfocus (terminal) dans un vrai pseudo-terminal.

Lance src/TDfocus.Terminal.ps1 avec pwsh dans un PTY, envoie des touches et lit l'écran
grâce à un petit émulateur (positionnement du curseur, effacements). Les données, le
dossier personnel et les réglages sont isolés dans un dossier temporaire.

Usage : python3 tools/test_tui_pty.py [--pwsh pwsh] [--keep]
"""
import argparse
import datetime
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "src", "TDfocus.Terminal.ps1")
COLS, ROWS = 100, 34


class Screen:
    """Émulateur minimal : suffisant pour la sortie de TDfocus."""

    CSI = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])")
    OSC = re.compile(r"\x1b\][^\x07]*\x07")

    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.clear()
        self.row = self.col = 0
        self.pending = ""

    def clear(self):
        self.grid = [[" "] * self.cols for _ in range(self.rows)]

    def feed(self, data):
        text = self.pending + data
        self.pending = ""
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "\x1b":
                osc = self.OSC.match(text, i)
                if osc:
                    i = osc.end()
                    continue
                csi = self.CSI.match(text, i)
                if csi:
                    self.apply(csi.group(1), csi.group(2))
                    i = csi.end()
                    continue
                if len(text) - i < 32:  # séquence coupée : on attend la suite
                    self.pending = text[i:]
                    return
                i += 1
                continue
            if ch == "\r":
                self.col = 0
            elif ch == "\n":
                self.row = min(self.rows - 1, self.row + 1)
            elif ch >= " ":
                if self.col < self.cols and self.row < self.rows:
                    self.grid[self.row][self.col] = ch
                self.col += 1
            i += 1

    def apply(self, params, cmd):
        if cmd == "H":
            parts = [p for p in params.split(";") if p]
            self.row = max(0, int(parts[0]) - 1) if parts else 0
            self.col = max(0, int(parts[1]) - 1) if len(parts) > 1 else 0
        elif cmd == "K":
            if self.row < self.rows:
                for c in range(self.col, self.cols):
                    self.grid[self.row][c] = " "
        elif cmd == "J" and params == "2":
            self.clear()
        elif cmd in "hl" and params == "?1049":
            self.clear()

    def text(self):
        return "\n".join("".join(r).rstrip() for r in self.grid)


class Tui:
    def __init__(self, pwsh, env):
        self.screen = Screen(COLS, ROWS)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe(pwsh, [pwsh, "-NoLogo", "-NoProfile", "-File", SCRIPT], env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.exit_code = None

    def pump(self, timeout=0.1):
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return
        try:
            data = os.read(self.fd, 65536)
        except OSError:
            return
        self.screen.feed(data.decode("utf-8", errors="replace"))

    def wait_for(self, needle, timeout=25):
        end = time.time() + timeout
        while time.time() < end:
            self.pump()
            if needle in self.screen.text():
                return
            if self.exited():
                break
        raise AssertionError("Texte attendu absent : %r\n--- écran ---\n%s" % (needle, self.screen.text()))

    def send(self, keys, pause=0.25):
        os.write(self.fd, keys.encode("utf-8"))
        end = time.time() + pause
        while time.time() < end:
            self.pump(0.05)

    def type_line(self, text):
        self.send(text, pause=0.3)
        self.send("\r", pause=0.5)

    def exited(self):
        if self.exit_code is not None:
            return True
        pid, status = os.waitpid(self.pid, os.WNOHANG)
        if pid == 0:
            return False
        self.exit_code = os.waitstatus_to_exitcode(status)
        return True

    def wait_exit(self, timeout=15):
        end = time.time() + timeout
        while time.time() < end:
            self.pump()
            if self.exited():
                return self.exit_code
        os.kill(self.pid, signal.SIGKILL)
        raise AssertionError("TDfocus ne s'est pas fermé.\n" + self.screen.text())


def make_env(base):
    env = {k: v for k, v in os.environ.items() if not k.startswith("XDG_")}
    env.update({
        "HOME": os.path.join(base, "home"),
        "TDFOCUS_DATA": os.path.join(base, "data"),
        "TERM": "xterm-256color",
        "NO_COLOR": "",
        "LANG": "fr_FR.UTF-8",
    })
    env.pop("NO_COLOR")
    os.makedirs(env["HOME"], exist_ok=True)
    os.makedirs(env["TDFOCUS_DATA"], exist_ok=True)
    return env


def read_json(env, name):
    with open(os.path.join(env["TDFOCUS_DATA"], name), encoding="utf-8-sig") as f:
        return json.load(f)


def step(title):
    print("  - " + title, flush=True)


def scenario_main(pwsh, base):
    print("Scénario : journée type", flush=True)
    env = make_env(os.path.join(base, "main"))
    tui = Tui(pwsh, env)
    tui.wait_for("Qu'est-ce qui compte maintenant")
    step("ajout d'une tâche avec sa durée")
    tui.send("a")
    tui.wait_for("Nouvelle tâche")
    tui.type_line("Écrire le rapport 30")
    tui.wait_for("Ajoutée : « Écrire le rapport » (30 min)")
    step("sous-étapes")
    tui.send("p")
    tui.wait_for("Sous-étapes")
    tui.type_line("Plan ; Brouillon ; Relecture")
    tui.wait_for("ÉTAPE 1/3  Plan")
    step("démarrage, étape faite")
    tui.send(" ")
    tui.wait_for("En cours")
    tui.send("s")
    tui.wait_for("ÉTAPE 2/3  Brouillon")
    tui.wait_for("Étape faite : « Plan »")
    step("compteur de pause")
    tui.send(" ")
    tui.wait_for("En pause depuis")
    step("deuxième tâche, temps ajouté")
    tui.send("a")
    tui.type_line("Emails 10")
    tui.wait_for("Emails")
    tui.send("]")
    tui.wait_for("prévu 35 min")
    step("validation puis annulation")
    tui.send("\r")
    tui.wait_for("« Écrire le rapport » terminée. Bravo !")
    tui.send("z")
    tui.wait_for("Validation annulée.")
    step("note rapide et bloc-notes")
    tui.send("n")
    tui.type_line("Appeler le garage")
    tui.wait_for("Noté. Retour à ta tâche !")
    tui.send("N")
    tui.wait_for("Appeler le garage")
    tui.send("q")
    step("réglages, aide, routines, statistiques")
    tui.send("o")
    tui.wait_for("Point de contrôle au carillon")
    tui.send("q")
    tui.send("?")
    tui.wait_for("étape faite / revenir")
    tui.send("q")
    tui.send("r")
    tui.wait_for("Routine du matin")
    tui.send("q")
    tui.send("t")
    tui.wait_for("7 DERNIERS JOURS")
    tui.send("q")
    tui.wait_for("ÉTAPE 2/3  Brouillon")
    step("fermeture (q)")
    tui.send("q")
    code = tui.wait_exit()
    assert code == 0, "code de sortie %s" % code

    state = read_json(env, "state.json")
    titles = [t["title"] for t in state["tasks"]]
    assert titles == ["Écrire le rapport", "Emails"], titles
    steps = state["tasks"][0]["steps"]
    assert [s["done"] for s in steps] == [True, False, False], steps
    assert state["tasks"][0]["plannedMs"] == 35 * 60000
    notes = read_json(env, "notes.json")["items"]
    assert notes[0]["text"] == "Appeler le garage"
    autostart = os.path.join(env["HOME"], ".config", "autostart", "tdfocus.desktop")
    assert os.path.exists(autostart), "fichier de démarrage automatique absent"
    with open(autostart, encoding="utf-8") as f:
        desktop = f.read()
    assert "TDfocus.Terminal.ps1" in desktop and "-Startup" in desktop, desktop
    step("état, notes et démarrage automatique enregistrés")


def scenario_review(pwsh, base):
    print("Scénario : revue du matin", flush=True)
    env = make_env(os.path.join(base, "review"))
    yesterday = (datetime.date.today() - datetime.timedelta(days=1)).strftime("%Y-%m-%d")
    now = int(time.time() * 1000) - 86400000

    def task(title):
        return {"id": uuid.uuid4().hex, "title": title, "plannedMs": 900000, "estimateMs": 900000,
                "elapsedMs": 0, "createdAt": now, "steps": []}

    state = {"version": 1, "tasks": [task("Ranger le bureau"), task("Payer la facture")], "done": [],
             "parked": [], "review": [], "planEndMs": None, "lastSeenMs": now, "dayKey": yesterday}
    with open(os.path.join(env["TDFOCUS_DATA"], "state.json"), "w", encoding="utf-8") as f:
        json.dump(state, f)
    tui = Tui(pwsh, env)
    tui.wait_for("Nouvelle journée ! Voici ce qui reste d'hier.")
    tui.wait_for("Ranger le bureau")
    step("reporter la première à demain")
    tui.send("d")
    tui.wait_for("« Ranger le bureau » reportée à demain.")
    step("garder la seconde")
    tui.send("g")
    tui.wait_for("Revue terminée. Belle journée !")
    tui.wait_for("1 tâche(s) reportée(s) à demain")
    tui.wait_for("Payer la facture")
    step("fermeture (Ctrl+C)")
    tui.send("\x03")
    code = tui.wait_exit()
    assert code == 0, "code de sortie %s" % code
    saved = read_json(env, "state.json")
    assert [t["title"] for t in saved["tasks"]] == ["Payer la facture"]
    assert [t["title"] for t in saved["parked"]] == ["Ranger le bureau"]
    assert saved["review"] == []


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pwsh", default=shutil.which("pwsh") or "pwsh")
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    base = tempfile.mkdtemp(prefix="tdfocus-pty-")
    try:
        scenario_main(args.pwsh, base)
        scenario_review(args.pwsh, base)
        print("OK : TDfocus (terminal) fonctionne dans un vrai terminal.")
    finally:
        if args.keep:
            print("Données conservées dans " + base)
        else:
            shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
