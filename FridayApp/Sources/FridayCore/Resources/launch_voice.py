import json
import os
import sys
from pathlib import Path

home = Path.home() / ".hermes"
for facts in sorted((home / "installs").glob("*/facts.json"), key=lambda p: p.stat().st_mtime, reverse=True):
    environment = json.loads(facts.read_text()).get("packages", {}).get("venv", {}).get("environment")
    if environment and (Path(environment) / "bin/python").exists():
        python = str(Path(environment) / "bin/python")
        os.environ["PYTHONPATH"] = str(home / "hermes-agent")
        args = sys.argv[1:]
        script = "screen_summary.py" if args[:1] == ["--screen-summary"] else "voice.py"
        if script == "screen_summary.py":
            args = args[1:]
        os.execv(python, [python, "-u", str(Path(__file__).with_name(script)), *args])
sys.exit("Hermes voice environment missing")
