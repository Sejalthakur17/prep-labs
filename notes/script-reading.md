# Reading someone else's script: `/etc/cron.daily/logrotate`

*Day 24, Part 3. I printed it with `cat /etc/cron.daily/logrotate` on `lab1` and explained each line. Anything I did not run is marked.*

Why this matters: in support I will get scripts I did not write (cron jobs, vendor tools, customer scripts). The skill is to read them in three passes: purpose first, then inputs and outputs, then line by line.

## The script (14 lines of logic)

```sh
#!/bin/sh

# skip in favour of systemd timer
if [ -d /run/systemd/system ]; then
    exit 0
fi

# this cronjob persists removals (but not purges)
if [ ! -x /usr/sbin/logrotate ]; then
    exit 0
fi

/usr/sbin/logrotate /etc/logrotate.conf
EXITVALUE=$?
if [ $EXITVALUE != 0 ]; then
    /usr/bin/logger -t logrotate "ALERT exited abnormally with [$EXITVALUE]"
fi
exit $EXITVALUE
```

## Pass 1: purpose

It runs `logrotate` once a day from cron, so old log files get compressed and deleted instead of filling the disk. If `logrotate` fails, it writes an alert to the system log.

## Pass 2: inputs and outputs

| | What |
|---|---|
| Input | The config file `/etc/logrotate.conf` (and what it includes) |
| Checks | Whether the machine uses systemd, and whether `/usr/sbin/logrotate` is executable |
| Output | Rotated log files, an `ALERT` line in the journal on failure, and the same exit code as `logrotate` |

## Pass 3: line by line

| Line | What it does |
|---|---|
| `#!/bin/sh` | Runs under the basic POSIX shell, not bash, so no bash-only features such as `[[ ]]` or arrays |
| `# skip in favour of systemd timer` | Comment: on systemd machines a timer does this job instead |
| `if [ -d /run/systemd/system ]; then` | True if the directory `/run/systemd/system` exists. That directory only exists when the machine booted with systemd |
| `exit 0` | Stop now and report success. The cron job does nothing on a systemd machine |
| `fi` | Ends the `if` block |
| `# this cronjob persists removals (but not purges)` | Comment about package behaviour: the cron file stays after the package is removed, so the script has to cope with `logrotate` being missing |
| `if [ ! -x /usr/sbin/logrotate ]; then` | True if `/usr/sbin/logrotate` is **not** executable (`!` negates, `-x` tests the execute bit) |
| `exit 0` | Package removed: quietly do nothing |
| `/usr/sbin/logrotate /etc/logrotate.conf` | Run the real tool with the main config |
| `EXITVALUE=$?` | Save the exit code of the command just run. It must come on the very next line, because every later command overwrites `$?` |
| `if [ $EXITVALUE != 0 ]; then` | Compare as **strings** with `!=`. A numeric test would be `-ne`. It works here because the codes are plain numbers |
| `/usr/bin/logger -t logrotate "ALERT exited abnormally with [$EXITVALUE]"` | Writes a line to the system log, tagged `logrotate`, including the exit code |
| `fi` | Ends the block |
| `exit $EXITVALUE` | Pass logrotate's exit code to whatever ran the script, so cron sees success or failure |

## What this means on my machine

The very first check (`/run/systemd/system` exists) should be true on `lab1`, because it runs systemd, so this cron script would exit immediately and do nothing. The real work would be done by a systemd timer. I have **not verified** that. To check:

```bash
ls -d /run/systemd/system
systemctl list-timers --all | grep -i logrotate
systemctl status logrotate.service --no-pager
```

## Three sentences for the notes

**Purpose:** it is a safety-net cron job that rotates logs through `logrotate` on machines that do not use systemd, and does nothing on machines that do.
**What could make it fail:** a syntax error in `/etc/logrotate.conf` or the files it includes, a permission or ownership problem on a log directory, a full disk, or a damaged `logrotate` state file. On a systemd machine the real risk moves to the timer unit, not this script.
**What I would check first:** `journalctl -t logrotate` for the `ALERT` line and the exit code, then `systemctl status logrotate.service`, then a dry run with `sudo logrotate -d /etc/logrotate.conf`, which prints what it would do without changing anything.

These three commands come from reading the script and general knowledge. I have not run them on `lab1`.

## Things this script taught me

- Scripts often start with guard clauses that exit early. Find them first, because they tell you when the script does nothing.
- Capture `$?` immediately, or the value is lost.
- A script should pass on the exit code of the tool it wraps, so the caller can tell what happened. My own `healthcheck.sh` does the same with its `RESULT` line.
- `logger` is how a script writes to the journal. `journalctl -t <tag>` reads those lines back.