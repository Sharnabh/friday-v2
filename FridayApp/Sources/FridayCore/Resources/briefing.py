"""User-configured daily or file-triggered Calendar briefings, run by launchd."""
from datetime import datetime, timedelta
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys

ROOT = Path.home() / "Library/Application Support/Friday/Workflows"
AGENT = Path.home() / "Library/LaunchAgents/local.friday.briefing.plist"
LABEL = "local.friday.briefing"
def read_calendar(day):
    executable = Path(__file__).resolve().parents[1] / "MacOS/Friday"
    result = subprocess.run([str(executable), "--calendar-day", day], capture_output=True,
                            text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Could not read Calendar")
    return json.loads(result.stdout)


def configure(hour, watch):
    ROOT.mkdir(parents=True, exist_ok=True)
    AGENT.parent.mkdir(parents=True, exist_ok=True)
    if watch and not Path(watch).is_file():
        raise ValueError("Choose an existing file")
    config = {"Label": LABEL, "ProgramArguments": [sys.executable, str(Path(__file__).resolve()), "run", str(hour), watch],
              "StartCalendarInterval": {"Hour": hour, "Minute": 0}, "RunAtLoad": True, "StartInterval": 900}
    if watch:
        config["WatchPaths"] = [watch]
    domain = "gui/" + str(os.getuid())
    subprocess.run(["launchctl", "bootout", domain + "/" + LABEL], capture_output=True)
    tmp = AGENT.with_suffix(".tmp")
    tmp.write_bytes(plistlib.dumps(config))
    tmp.replace(AGENT)
    subprocess.run(["launchctl", "bootstrap", domain, str(AGENT)], check=True)


def run(db, hour, watch, now=None, collect=None):
    now = now or datetime.now()
    db.execute("CREATE TABLE IF NOT EXISTS checkpoints(id TEXT PRIMARY KEY, events TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS steps(id TEXT, attempt INTEGER, step TEXT, status TEXT, at TEXT)")
    keys = []
    if now.hour >= hour:
        keys.append("daily-" + now.date().isoformat())
    if watch and Path(watch).exists():
        stat = Path(watch).stat()
        version = hashlib.sha256((watch+str(stat.st_mtime_ns)+str(stat.st_size)).encode()).hexdigest()[:20]
        keys.append("file-" + version)
    # Retry unfinished runs even if the Mac was asleep across midnight.
    keys.extend(row[0] for row in db.execute("SELECT id FROM runs WHERE step!='complete' AND retry<=?",(now.timestamp(),)))
    for key in dict.fromkeys(keys):
        db.execute("BEGIN IMMEDIATE")
        try:
            row = db.execute("SELECT step,attempts,retry FROM runs WHERE id=?", (key,)).fetchone()
            if row and (row[0] == "complete" or row[2] > now.timestamp()):
                db.rollback()
                continue
            attempt = (row[1] if row else 0) + 1
            step = "read calendar"
            try:
                day = key.removeprefix("daily-") if key.startswith("daily-") else now.date().isoformat()
                checkpoint = db.execute("SELECT events FROM checkpoints WHERE id=?", (key,)).fetchone()
                if checkpoint:
                    data = json.loads(checkpoint[0])
                else:
                    data = collect() if collect else read_calendar(day)
                    db.execute("INSERT INTO checkpoints VALUES(?,?)", (key, json.dumps(data)))
                    db.execute("INSERT INTO steps VALUES(?,?,?,?,?)", (key, attempt, step, "complete", now.isoformat()))
                step = "write briefing"
                lines = ["Calendar briefing · " + day, ""]
                for when, title in data:
                    local = datetime.fromisoformat(when.replace("Z", "+00:00")).astimezone()
                    lines.append(local.strftime("%H:%M") + "  " + title)
                if not data:
                    lines.append("No events returned for today.")
                tmp = ROOT / (key + ".tmp")
                tmp.write_text("\n".join(lines))
                tmp.replace(ROOT / (key + ".txt"))
                db.execute("INSERT INTO steps VALUES(?,?,?,?,?)", (key, attempt, step, "complete", now.isoformat()))
                db.execute("DELETE FROM checkpoints WHERE id=?", (key,))
                db.execute("INSERT OR REPLACE INTO runs VALUES(?, 'complete', ?, 0, '')",(key,attempt))
            except Exception as exc:
                db.execute("INSERT INTO steps VALUES(?,?,?,?,?)", (key, attempt, step, "failed", now.isoformat()))
                retry = now + timedelta(minutes=min(240,15 * 2**min(attempt-1,4)))
                db.execute("INSERT OR REPLACE INTO runs VALUES(?,?,?,?,?)",(key,step,attempt,retry.timestamp(),str(exc)))
            db.commit()
        except BaseException:
            db.rollback()
            raise


def main():
    os.umask(0o077)
    action = sys.argv[1]
    if action == "history":
        if (ROOT/"runs.sqlite").exists():
            with sqlite3.connect(ROOT/"runs.sqlite") as db:
                for key,step,attempts,error in db.execute("SELECT id,step,attempts,error FROM runs ORDER BY rowid DESC LIMIT 15"):
                    print(f"{key} · {step} · {attempts} attempt(s) {error}")
                    if db.execute("SELECT 1 FROM sqlite_master WHERE name='steps'").fetchone():
                        for at, name, status in db.execute("SELECT at,step,status FROM steps WHERE id=? ORDER BY rowid", (key,)):
                            print(f"  {at[:16]}  {name} · {status}")
        return
    if action == "pause":
        subprocess.run(["launchctl","bootout","gui/"+str(os.getuid())+"/"+LABEL],capture_output=True)
        AGENT.unlink(missing_ok=True)
        return
    hour = int(sys.argv[2])
    if not 0 <= hour < 24:
        raise ValueError("Hour must be 0–23")
    if action == "configure":
        configure(hour,sys.argv[3])
    elif action == "run":
        ROOT.mkdir(parents=True,exist_ok=True)
        with sqlite3.connect(ROOT/"runs.sqlite",timeout=120) as db:
            db.execute("CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY,step TEXT,attempts INTEGER,retry REAL,error TEXT)")
            run(db,hour,sys.argv[3])


if __name__ == "__main__":
    main()
