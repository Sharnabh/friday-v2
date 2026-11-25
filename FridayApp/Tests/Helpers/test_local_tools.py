import datetime
import importlib.util
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from uuid import uuid4

ROOT=Path(__file__).resolve().parents[2]/"Sources/FridayCore/Resources"
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/(name+".py"))
    value=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

class LocalTools(unittest.TestCase):
    def test_workflow_restart_and_retry(self):
        worker=module("briefing")
        with tempfile.TemporaryDirectory() as path:
            worker.ROOT=Path(path)
            db=sqlite3.connect(worker.ROOT/"history.sqlite")
            db.execute("CREATE TABLE runs(id TEXT PRIMARY KEY,step TEXT,attempts INTEGER,retry REAL,error TEXT)")
            now=datetime.datetime(2026,11,25,10)
            def fail():
                raise RuntimeError("calendar offline")
            worker.run(db,9,"",now,fail)
            self.assertEqual(db.execute("select step from runs").fetchone()[0],"read calendar")
            worker.run(db,9,"",now+datetime.timedelta(hours=1),lambda:[])
            worker.run(db,9,"",now+datetime.timedelta(hours=2),fail)
            self.assertEqual(db.execute("select step,attempts from runs").fetchone(),("complete",2))
            self.assertEqual(len(list(worker.ROOT.glob("*.txt"))),1)
            db.close()
    def test_backup_roundtrip(self):
        backup=module("archive");backup.DOMAIN="test.friday."+uuid4().hex
        try:
            with tempfile.TemporaryDirectory() as path:
                backup.DB=Path(path)/"db";folder=Path(path)/"backup"
                with sqlite3.connect(backup.DB) as db:
                    db.execute("create table memories(scope,body,source,revision)")
                    db.execute("insert into memories values('shared','fixture','test',1)")
                subprocess.run(["defaults","write",backup.DOMAIN,"bot","alpha"],check=True)
                backup.save(folder)
                with sqlite3.connect(backup.DB) as db:db.execute("delete from memories")
                subprocess.run(["defaults","write",backup.DOMAIN,"bot","beta"],check=True)
                backup.restore(folder)
                self.assertEqual(subprocess.check_output(["defaults","read",backup.DOMAIN,"bot"],text=True).strip(),"alpha")
                with sqlite3.connect(backup.DB) as db:self.assertEqual(db.execute("select body from memories").fetchone()[0],"fixture")
        finally:subprocess.run(["defaults","delete",backup.DOMAIN],capture_output=True)
