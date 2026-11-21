"""The journal follower starts at the tail and marks only new matched entries."""

import json
from pathlib import Path
import re
import sys

sys.path.insert(0, sys.argv[1])
from connected import follow


class EndOfFixture(Exception):
    pass


class JournalFixture:
    def __init__(self, entries, history, actions):
        self.batches = iter(entries)
        self.history = history
        self.actions = actions

    def this_boot(self):
        self.actions.append("boot")

    def add_match(self, **matches):
        self.actions.append(matches)

    def seek_tail(self):
        self.actions.append("tail")

    def get_previous(self):
        self.actions.append("positioned")
        return {"MESSAGE": self.history}

    def __iter__(self):
        return next(self.batches)

    def wait(self):
        self.actions.append("wait")
        if self.actions.count("wait") == 2:
            raise EndOfFixture


default, custom = (json.loads(Path(name).read_bytes()) for name in sys.argv[2:])
for config, selected, not_selected in (
    (default, "2026/11/21 09:00:00 Connected outbound: fixture", "Connected"),
    (custom, "Fixture peer up: fixture", "2026/11/21 09:00:00 Connected inbound: fixture"),
):
    actions = []
    entries = JournalFixture(
        [
            iter([{"MESSAGE": not_selected}, {"MESSAGE": b"invalid UTF-8\xff"}, {}]),
            iter([{"MESSAGE": selected.replace("Connected", "Disconnected")
                   if config is default else "Fixture peer down: fixture"},
                  {"MESSAGE": selected}, {"MESSAGE": selected}]),
        ],
        selected,
        actions,
    )
    try:
        follow(entries, config["unit"], re.compile(config["messagePattern"]),
               lambda: actions.append("ready"), lambda: actions.append("wake"))
    except EndOfFixture:
        pass
    assert actions == [
        "boot", {"_SYSTEMD_UNIT": config["unit"]}, "tail", "positioned", "ready",
        "wait", "wake", "wake", "wait",
    ], actions
print("Connected contract: current boot and configured unit; tail is quiet; each new matching record marks once.")
