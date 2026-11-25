"""Consistent SQLite snapshots for the user-selected FRIDAY backup folder."""
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile

DOMAIN = "local.friday.assistant"
DB = Path.home() / "Library/Application Support/Friday/Memory.sqlite"


def copy_database(src, dst):
    with sqlite3.connect(src.as_uri()+"?mode=ro",uri=True) as reader, sqlite3.connect(dst) as writer:
        if reader.execute("pragma quick_check").fetchone() != ("ok",):
            raise ValueError("Memory database did not pass validation")
        reader.backup(writer)


def save(folder):
    folder.mkdir(mode=0o700,exist_ok=False)
    domains = subprocess.check_output(["defaults", "domains"], text=True).strip().split(", ")
    settings = folder / "settings.plist"
    if DOMAIN in domains:
        subprocess.run(["defaults", "export", DOMAIN, str(settings)], check=True)
    else:
        settings.write_bytes(plistlib.dumps({}))
    has_memory = DB.exists()
    if has_memory:
        copy_database(DB,folder/"Memory.sqlite")
    (folder/"manifest.json").write_text(json.dumps({"version":1,"memory":has_memory}))


def apply_memory(folder, present):
    if present:
        copy_database(folder / "Memory.sqlite", DB)
    elif DB.exists():
        # Replace all pages transactionally, including on an open WAL database.
        with sqlite3.connect(":memory:") as empty, sqlite3.connect(DB) as writer:
            empty.backup(writer)


def restore(folder):
    manifest=json.loads((folder/"manifest.json").read_text())
    if manifest.get("version")!=1 or not isinstance(plistlib.loads((folder/"settings.plist").read_bytes()),dict):
        raise ValueError("Unsupported backup")
    if manifest["memory"]:
        with sqlite3.connect((folder/"Memory.sqlite").as_uri()+"?mode=ro",uri=True) as db:
            db.execute("SELECT scope,body,source,revision FROM memories LIMIT 1").fetchone()
    DB.parent.mkdir(parents=True,exist_ok=True)
    recovery=Path(tempfile.mkdtemp(prefix="Restore-",dir=DB.parent))/"before"
    save(recovery)
    try:
        apply_memory(folder, manifest["memory"])
        subprocess.run(["defaults","import",DOMAIN,str(folder/"settings.plist")],check=True)
    except Exception:
        apply_memory(recovery, (recovery/"Memory.sqlite").exists())
        subprocess.run(["defaults","import",DOMAIN,str(recovery/"settings.plist")],check=True)
        raise
    print("Restored. Reopen FRIDAY. Recovery copy: "+str(recovery))


if __name__=="__main__":
    os.umask(0o077)
    action, path=sys.argv[1:]
    {"save":save,"restore":restore}[action](Path(path).resolve())
