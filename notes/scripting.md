# Scripting for support (Day 24)

*Written 26 Nov 2026 for the Nov 24 plan item. Everything marked "observed" comes from my own terminal output on `lab1`. Things I did not run or confirm are listed at the end.*

Goal: turn the manual first-look checks into a script a customer could run, and a small log tool, so a ticket starts with facts instead of guesses.

---

## 1. `scripts/healthcheck.sh`

Built in four layers, running it after each one:

| Layer | Added | Why |
|---|---|---|
| 1 | The eight manual checks (uptime/load, memory, disk, inodes, failed units, top CPU, listening ports, recent errors) inside a `section()` helper | Same commands I ran by hand first, predicted before each run |
| 2 | Header (`hostname`, `date`), swap note, root-aware ports block | Memory with no swap is a finding; `ss -p` shows nothing useful without root |
| 3 | `WARN_DISK` setting, `check_disk()` function, `problems` counter | A threshold I can change from the environment, so I can test it without filling a disk |
| 4 | Failed-unit count, `--help`, final `RESULT` line and exit code | Other tools (cron, CI, monitoring) can read 0 or 1 without parsing text |

After the "stopped is not failed" test (section 4) I added a fifth piece: `EXPECT_PORTS` and `check_port()`.

### Settings

| Variable | Default | Meaning |
|---|---|---|
| `WARN_DISK` | 80 | Root filesystem percent that counts as a problem |
| `EXPECT_PORTS` | `"22"` | Space-separated TCP ports that must be listening |

Exit code: 0 when every check passes, 1 when `problems` is above zero.

### Baseline on `lab1` (observed, 26 Nov 2026, about 40 minutes after boot)

| Check | Result |
|---|---|
| Load average | 0.00 / 0.00 / 0.00 at first; one run showed 1.07 / 0.40 / 0.15, the next 0.22 / 0.29 / 0.13 |
| Memory | 908Mi total, about 580 to 600Mi available, buff/cache between 366Mi and 527Mi |
| Swap | None (`Swap: 0B`) |
| Root disk | 6.7G, 42% used |
| Inodes | 878,080 total, 16% used |
| Failed units | 0 |

The load spike: the 1-minute number was highest and the 15-minute number was near zero, so something short had just started. `packagekitd` (started 07:58) and a `kworker` appear in the next `Top CPU` output. That timing fits, but I did not check the journal for that minute, so it is a guess, not a finding.

### Listening ports, read with `sudo` (observed)

| Port | Owner | Meaning |
|---|---|---|
| 22 (IPv4 and IPv6) | `sshd`, and `systemd` PID 1 | SSH. systemd holds the socket too (socket activation) |
| 80, 443 | `nginx`, three PIDs | One master and workers sharing the listening socket |
| 53 on 127.0.0.53 and 127.0.0.54 | `systemd-resolve` | Local DNS resolver, loopback only |
| UDP 68 on `ens5` | `systemd-network` | DHCP client |
| UDP 323 on 127.0.0.1 and ::1 | `chronyd` | Time sync, loopback only |

Only 22, 80 and 443 listen on non-loopback addresses. Without `sudo` the `Process` column is empty, which is why the script prints a "not root" note.

---

## 2. Tests and results (all observed)

| Test | Result |
|---|---|
| `bash -n healthcheck.sh` | No output, so the syntax is valid |
| `--help` | Usage text listing both settings, `exit=0` |
| Normal run | `RESULT: all checks passed`, `exit=0` |
| `WARN_DISK=10` | `WARNING: root disk at 42% (limit 10%)`, `RESULT: 1 problem(s) found`, `exit=1`, and the script carried on to the next section |
| `systemd-run --unit=failtest2 /bin/false` | `failtest2.service` listed as `loaded failed failed`, `WARNING: 1 failed unit(s)` |
| After `systemctl reset-failed` | `all checks passed`, `exit=0` |
| `nginx` stopped, first version of the script | Nothing under Failed units, `all checks passed`, `exit=0` |
| `nginx` stopped, with `EXPECT_PORTS="22 80 443"` | Port 22 OK, warnings for 80 and 443, `2 problem(s) found`, `exit=1` |
| `nginx` started again | `all checks passed`, `exit=0` |

### Stopped is not failed

A service stopped on purpose is `inactive`, not `failed`, so `systemctl --failed` showed nothing while the website was down. The script said everything was fine. The fix is to check what the customer cares about: are the expected ports listening. In a ticket, "no failed units" does not mean "everything is running."

---

## 3. Concepts I practised

| Idea | What I now understand |
|---|---|
| `set -e` | Stops the script when a command fails |
| `set -u` | Stops on an unset variable, so a typo is an error instead of an empty string |
| `set -o pipefail` | A pipe counts as failed if any command in it fails, not just the last |
| `\|\| true` | Lets one harmless failure pass without ending the script |
| `cmd \|\| problems=$((problems + 1))` | If the check fails, add one to the counter. Because of the `\|\|`, `set -e` does not kill the script |
| `&&` vs `\|\|` vs `\|` | `&&` runs the next command on success, `\|\|` on failure, `\|` feeds output into the next command |
| `${VAR:-default}` | Use the environment value, or the default if unset. Also safe under `set -u` |
| `${1:-}` | First argument or empty, so `$1` does not crash under `set -u` |
| `local` | Keeps a variable inside its function |
| `$(cmd)` | Substitutes a command's output. Quote it: `"$(cmd)"` |
| `return 1` in a function | Signals failure to the caller. The last command's status is the default |
| `echo $?` | Exit code of the previous command |
| `${PIPESTATUS[0]}` | Exit code of the first command in a pipe. `$?` after `\| tail` shows `tail`'s code, which is nearly always 0 |
| `grep -q pattern <<< "$out"` | Here-string. I stored `ss` output first and searched the variable |
| `sed -n '/start/,/end/p'` | Prints only the lines between two patterns, useful to look at one section |
| Functions before use | Bash reads top to bottom, so a function must be defined before the line that calls it |

Why `check_port` stores the output first: with `ss -tln | grep -q`, `grep -q` can exit at the first match and `ss` may be cut off mid-write, which `pipefail` reports as a failed pipe. I did not reproduce this problem myself. I wrote the safer version from what I read, so treat the explanation as understood, not demonstrated.

---

## 4. Investigation: errors that turned out to be old history

Same order I use for every ticket.

| Step | What I did |
|---|---|
| Symptom | `journalctl -p err -n 20` listed `networkctl: Interface "br0" not found`, and also `v1-br`, `v2-br`, `b2-br`, all dated 22 Nov |
| Hypothesis | Leftovers from the earlier bridge work in Lab 5, not a current fault |
| Test 1 | `journalctl -b -p err` (this boot only) showed one line, the `piix4_smbus` message |
| Test 2 | `grep -rn "br0\|v1-br\|v2-br" /etc/netplan /etc/systemd /etc/network` printed nothing |
| Test 3 | `systemctl list-units --all \| grep -i -E "br0\|bridge"` printed nothing |
| Wider check | `sudo grep -rIl "br0\|v1-br\|v2-br" /etc` printed nothing, and `ip -br link` showed only `lo` and `ens5` |
| Conclusion | The errors were from 22 Nov and nothing in `/etc` or on the live system still refers to those bridges. No action needed |

What I did not find: which unit or script called `networkctl` on 22 Nov. "Left over from the bridge work" fits the dates, but I did not trace it.

The lesson: `journalctl -p err -n 20` spans several boots, so old errors can look current. Add `-b` before investigating.

The other two journal errors are known background noise on this VM: `piix4_smbus ... SMBus base address uninitialized` (a hardware probe message) and `sshd-session: mm_reap: child terminated by signal 15` (an SSH helper stopped at logout).

---

## 5. `scripts/log_summary.py`

Counts lines per severity (ERROR, WARN, INFO, OTHER) in a file given on the command line.

| Behaviour | Exit code |
|---|---|
| Success | 0 |
| Wrong number of arguments (prints usage) | 1 |
| File not found | 2 |
| Permission denied | 3 |
| Path is a directory | 4 |

Notes on the code: `sys.argv` for the argument, `try/except` per error type, a `for ... else` so unmatched lines go to OTHER, `open(path, errors="replace")` so odd bytes do not crash it, and `sorted(..., reverse=True)` for the table.

### Results (observed)

| Test | Result |
|---|---|
| No argument | Usage message, `exit=1` |
| `/nope/missing.log` | `Error: file not found`, `exit=2` |
| `/etc` | `Error: /etc is a directory, not a file`, `exit=4` |
| `/tmp/test.log` (5 lines I wrote) | ERROR 2, WARN 1, INFO 1, OTHER 1, `exit=0` |
| `journalctl -b --no-pager > /tmp/journal.log` | 1371 lines: OTHER 1276, INFO 70, ERROR 22, WARN 3 |

Not tested: the permission-denied path (exit 3).

### Text matching vs priority filtering

`journalctl -b -p err` showed one line this boot, but the script counted 22 lines containing "error". They answer different questions:

| Method | Good for | Problem |
|---|---|---|
| Text match (my script, `grep -i`) | Works on any log file | Overcounts. Matches the word anywhere, even in messages that are not failures |
| Priority filter (`journalctl -p err`) | Structured, no noise | Can miss errors from programs that write the word ERROR but do not set a priority |

Sorting the first 10 matching lines (`grep -i "error" /tmp/journal.log | head -10`):

| Line | Verdict |
|---|---|
| `RAS: Correctable Errors collector initialized` | Noise, a feature name |
| `regulatory.db failed with error -2` | Missing optional firmware file, harmless on a VM |
| `apport-autoreport` path and timer (2 lines) | Noise, a unit description containing "error reports" |
| `amazon-ssm-agent`: seelog config file and `/etc/amazon/ssm` watcher | Optional config missing, harmless |
| `amazon-ssm-agent`: `no EC2 IMDS role found ... StatusCode: 404` and `AccessDeniedException` | A real finding, see below |

The SSM agent ERROR lines are in the journal but `-p err` did not list them. The likely reason is that the agent does not set the journal priority, but I did not verify that.

### Real finding: the SSM agent cannot authenticate

The agent is running, but its logs say no IAM role was found on the instance (HTTP 404 from the metadata service) and Systems Manager access was denied. That points to **no IAM instance profile attached to this instance**, so the Systems Manager route listed in the EC2 recovery checklist would not work here yet.

Not confirmed yet. The test is the metadata check: request a token, then `curl` the `iam/info` path. A 404 means no role, a 200 means a role is attached. The usual fix is an IAM role with the managed policy `AmazonSSMManagedInstanceCore`, attached through Actions, Security, Modify IAM role.

Caution for the public repo: the journal lines contain my AWS account ID. Replace it with `<ACCOUNT_ID>` before pasting log output into any note.

---

## 6. Mistakes and fixes

| Mistake | What happened | Fix / lesson |
|---|---|---|
| New Memory block pasted lower in the file | Output order was Uptime, Disk, ..., Memory, Ports | Bash runs top to bottom, so line order is output order. Moved it under Uptime |
| Ran `python3 log_summary.py` from the repo root | `can't open file ... [Errno 2]` and `exit=2`, the same code my script uses for "file not found" | Run `python3 scripts/log_summary.py`. Read the message, not only the exit code |
| `scripts/` folder did not exist in the repo | `touch` said no such file or directory | `mkdir scripts` first |
| `healthcheck.sh` was created in `~`, not in the repo | The script was outside git | Moved it into `scripts/` |
| `tail -12` hid the Failed units section | The warning was above the visible part | `sed -n '/=== Failed units/,/=== Top CPU/p'` to view one section |

---

## 7. Not done / not verified

- Break-it tests: the typo line (`uptimee`, expect exit 127) and the unset variable (`echo "$NOPE"`).
- `log_summary.py` permission-denied path.
- The `head -6` plus `pipefail` quirk. I added `|| true` as a precaution and did not see it fail without it.
- Which unit called `networkctl` on 22 Nov.
- IAM instance profile check on `lab1`.
- Which process caused the one-minute load spike.
- Stricter whole-word matching in `log_summary.py` (`re.search(r"\bERROR\b", line)`), a stretch idea.

---

## 8. Interview questions with my answers

Each answer is about 30 seconds out loud. Cut the lab example first if it runs long.

### 1. What does `set -euo pipefail` do, and when would `|| true` be needed with it?

It is three safety switches. `-e` stops the script when a command fails. `-u` stops on an unset variable, so a typo is an error instead of silently becoming an empty string. `-o pipefail` makes a pipeline count as failed if any command in it fails, not just the last one.

`|| true` is for a command that is allowed to fail. Without it, `set -e` ends the script at that line. In my healthcheck, `systemctl --failed ... || true` keeps the script going so it can still count the failed units and report a result.

### 2. `systemctl --failed` shows nothing but the customer's site is down. What next?

Stopped is not failed. A service stopped on purpose, or never started, is `inactive`, and `--failed` only lists units that crashed or exited with an error. So I check:

1. `systemctl status <service>` for its real state.
2. `sudo ss -tulpn` to see whether anything listens on the expected port, and which process owns it.
3. The logs, scoped to this boot: `journalctl -u <service> -b`.
4. If the box looks healthy, the layers outside it, such as the security group and `ufw`.

Lab example: with nginx stopped, my first healthcheck said `all checks passed` while the site was down. I fixed it by adding a check that the expected ports are listening.

### 3. How do you read load average?

Three numbers: the average number of runnable processes over the last 1, 5 and 15 minutes. I compare them with the CPU count from `nproc`, because a load of 1.0 is a fully busy single CPU but only half of a two-CPU machine. I also read them as a trend: a high 1-minute number with a low 15-minute number means something just started, and all three high means sustained load. On Linux, load also counts processes waiting on disk, so high load with low CPU can point at I/O.

Lab example: `lab1` showed 1.07, 0.40, 0.15, a short burst that was fading, and the next reading was 0.22, 0.29, 0.13.

### 4. `df -h` shows free space but writes fail. What do you check?

1. **Inodes exhausted:** `df -i`. The disk can have free space but no file entries left. In my lab, a filesystem with 2000 inodes failed at file 1989 with `No space left on device` while `df -h` showed 89M free.
2. **Deleted but still held open:** `df` stays high while `du` is low. `lsof +L1` shows the process holding the file, and stopping it frees the space.
3. **Wrong filesystem:** the path may sit on a small separate or RAM-backed filesystem such as `tmpfs`. `df -h <path>` checks the filesystem for that exact path.

If none fit, I check quotas and read-only mounts.

### 5. Why use different exit codes in a script?

So the caller can tell which failure happened without parsing text. Zero means success and anything else means failure. In `log_summary.py` I return 1 for wrong usage, 2 for file not found, 3 for permission denied and 4 for a directory. A cron job or monitoring tool can then react differently to each.

Two things I learned: Python's own `can't open file` error also exits with 2, the same code my script uses for "file not found", so I read the message as well as the code. And behind a pipe, `$?` shows the last command's code, so I use `${PIPESTATUS[0]}` to see the script's own.

### 6. How do you tell a real error from noise in a journal?

I do not trust a count until I have read the lines behind it. First I scope the logs to this boot with `journalctl -b`, because old errors from earlier boots look current. Then I use two views. A priority filter (`-p err`) is clean but can miss programs that write the word ERROR without setting a priority. A text match catches those but also catches noise, such as a feature called "Correctable Errors collector".

Lab example: `-p err` showed one line this boot while a text search found 22. Most were noise, but the SSM agent lines looked real: they said no IAM role was found on the instance. I also checked the old `br0 not found` errors against the config and the live interfaces before calling them leftovers.

Be careful with two points in this answer. The reason `-p err` missed the SSM lines (the agent probably does not set a priority) is my guess, and the missing IAM role is the likely explanation but I have not run the metadata check. Say "my guess is" until I have.