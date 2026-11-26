"""Consistent SQLite snapshots for the user-selected FRIDAY backup folder."""
import json
import os
import shutil
import filecmp
from uuid import UUID
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile

DOMAIN = "local.friday.assistant"
IMAGES = Path.home() / "Library/Application Support/FRIDAY/generated-images"
DB = Path.home() / "Library/Application Support/Friday/Memory.sqlite"


def copy_database(src, dst):
    with sqlite3.connect(src.as_uri()+"?mode=ro",uri=True) as reader, sqlite3.connect(dst) as writer:
        if reader.execute("pragma quick_check").fetchone() != ("ok",):
            raise ValueError("Memory database did not pass validation")
        reader.backup(writer)


def copy_images(source, destination, added):
    if source.is_symlink() or destination.is_symlink():
        raise ValueError("Unexpected image directory link")
    if not source.exists():
        return
    for image in source.iterdir():
        if image.suffix.lower() not in {".png", ".jpg", ".jpeg", ".webp", ".gif"}:
            continue
        try:
            UUID(image.stem)
        except ValueError:
            continue
        if image.is_symlink() or not image.is_file():
            raise ValueError("Invalid image attachment")
        destination.mkdir(mode=0o700, parents=True, exist_ok=True)
        target = destination / image.name
        if target.is_symlink():
            raise ValueError("Invalid destination attachment")
        if target.exists():
            if not filecmp.cmp(image, target, shallow=False):
                raise ValueError("Conflicting image attachment")
            continue
        with target.open("xb") as out:
            added.append(target)
            with image.open("rb") as inp:
                shutil.copyfileobj(inp, out)


def save(folder):
    folder.mkdir(mode=0o700,exist_ok=False)
    domains = subprocess.check_output(["defaults", "domains"], text=True).strip().split(", ")
    settings = folder / "settings.plist"
    if DOMAIN in domains:
        values = plistlib.loads(subprocess.check_output(["defaults", "export", DOMAIN, "-"]))
        values.pop("friday.openrouterApiKey", None)
        settings.write_bytes(plistlib.dumps(values))
    else:
        settings.write_bytes(plistlib.dumps({}))
    has_memory = DB.exists()
    if has_memory:
        copy_database(DB,folder/"Memory.sqlite")
    copy_images(IMAGES, folder / "generated-images", [])
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
    added = []
    try:
        copy_images(folder / "generated-images", IMAGES, added)
        apply_memory(folder, manifest["memory"])
        values = plistlib.loads((folder / "settings.plist").read_bytes())
        values.pop("friday.openrouterApiKey", None)
        subprocess.run(["defaults", "import", DOMAIN, "-"], input=plistlib.dumps(values), check=True)
    except Exception:
        for path in added:
            path.unlink(missing_ok=True)
        apply_memory(recovery, (recovery/"Memory.sqlite").exists())
        subprocess.run(["defaults","import",DOMAIN,str(recovery/"settings.plist")],check=True)
        raise
    print("Restored. Reopen FRIDAY. Recovery copy: "+str(recovery))


if __name__=="__main__":
    os.umask(0o077)
    action, path=sys.argv[1:]
    {"save":save,"restore":restore}[action](Path(path).resolve())
