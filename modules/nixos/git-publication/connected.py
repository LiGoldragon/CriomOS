"""Turn new Connected records from the configured overlay unit into wake markers."""

import json
from pathlib import Path
import re
import sys
from time import monotonic

from delivery import wake


def follow(journal, unit, pattern, starting_at, notify_ready, mark):
    journal.this_boot()
    journal.add_match(_SYSTEMD_UNIT=unit)
    journal.seek_monotonic(starting_at)
    notify_ready()
    while True:
        for record in journal:
            message = record.get("MESSAGE")
            if isinstance(message, str) and pattern.search(message):
                mark()
        journal.wait()


if __name__ == "__main__":
    from systemd import daemon, journal

    configuration = json.loads(Path(sys.argv[1]).read_bytes())
    with journal.Reader(flags=journal.LOCAL_ONLY) as entries:
        follow(
            entries, configuration["unit"], re.compile(configuration["messagePattern"]), monotonic(),
            lambda: daemon.notify("READY=1"), lambda: wake(configuration),
        )
