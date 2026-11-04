"""Read one Peras log window, retaining nanoseconds and source locations."""
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import json
import re


def timestamp_ns(value):
    match = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)", value)
    if not match:
        raise ValueError(f"expected a timestamp with an explicit timezone: {value!r}")
    seconds = int(datetime.fromisoformat(match[1] + match[3].replace("Z", "+00:00")).timestamp())
    return seconds * 1_000_000_000 + int((match[2] or "").ljust(9, "0"))


@dataclass
class Record:
    path: Path
    line: int
    at_ns: int
    event: dict

    @property
    def location(self):
        return f"{self.path}:{self.line}"


class Logs:
    def __init__(self, root, since=None, until=None):
        self.records = []
        self.issues = []
        self.nodes = {}
        lower = timestamp_ns(since) if since else None
        upper = timestamp_ns(until) if until else None
        if lower is not None and upper is not None and lower >= upper:
            raise ValueError("--since must be earlier than --until")
        seen_files = set()
        starts = {}
        for path in sorted(Path(root).glob("logs/*_*/node-*.json")):
            stat = path.stat()
            identity = (stat.st_dev, stat.st_ino)
            if identity in seen_files:
                continue
            seen_files.add(identity)
            with path.open(encoding="utf-8") as stream:
                for line_number, line in enumerate(stream, 1):
                    if not line.strip():
                        continue
                    try:
                        event = json.loads(line)
                        at_ns = timestamp_ns(event["at"])
                        if not isinstance(event["ns"], str) or not isinstance(event.get("data", {}), dict):
                            raise ValueError("invalid namespace or data")
                    except (ValueError, KeyError, TypeError) as error:
                        self.issues.append({"location": f"{path}:{line_number}", "error": str(error)})
                        continue
                    if event["ns"] == "Startup.DiffusionInit.CreatedLocalSocket":
                        match = re.search(r"(?:^|/)node(\d+)/", event.get("data", {}).get("path", ""))
                        if match:
                            node = int(match[1])
                            previous = self.nodes.setdefault(path.parent, node)
                            if previous != node:
                                raise ValueError(f"{path.parent} contains different node identities")
                    if (lower is not None and at_ns < lower) or (upper is not None and at_ns >= upper):
                        continue
                    if event["ns"] == "Startup.DiffusionInit.CreatedLocalSocket":
                        starts.setdefault(path.parent, set()).add(at_ns)
                    self.records.append(Record(path, line_number, at_ns, event))
        repeated = [str(path) for path, times in starts.items() if len(times) > 1]
        if repeated:
            raise ValueError("multiple starts in the selected logs; select one run using --since/--until: " + ", ".join(repeated))
        self.records.sort(key=lambda record: (record.at_ns, str(record.path), record.line))
        active = {record.path.parent for record in self.records}
        self.nodes = {path: node for path, node in self.nodes.items() if path in active}
