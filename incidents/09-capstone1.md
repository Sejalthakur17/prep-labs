# Incident 09: Capstone 1 - Root filesystem full, website still up

**Date:** Fri 27 Nov 2026
**Host:** lab1 (Ubuntu, AWS EC2)
**Type:** Capstone ticket (blind fault, injected by my own script)
**Status:** Resolved and verified

---

## Summary

The root filesystem (`/`) was 100% full (48M free). The cause was a single 3.1G file, `/var/fill`, created at 07:13 UTC. I removed it, and the disk returned to 54% used with 3.1G free. The website kept serving the whole time because nginx was only reading from disk.

## Symptom (as a customer would say it)

"Something on this server seems wrong, but the website itself loads."

Note: my first wording of the ticket was "the website stopped loading". That did not match what I found, so I widened my checks instead of forcing the evidence to fit (see "What I got wrong" below).

## Environment

- Ubuntu on EC2 (instance `lab1`), root disk 6.7G
- nginx 1.28.3, listening on ports 80 and 443

## Timeline

| # | Command | What I saw | What I concluded |
|---|---------|-----------|------------------|
| 1 | `curl -I http://<public-ip>` (from my Mac) | `200 OK` | Site reachable from outside; security group and nginx are fine |
| 2 | `curl -I http://localhost` (on lab1) | `200 OK` | nginx works locally too |
| 3 | `systemctl status nginx` | active (running), enabled | Service is healthy, not stopped or masked |
| 4 | `ss -tlnp \| grep nginx` | No output | Looked like a problem, but it was a permissions artifact (needs `sudo`) |
| 5 | `df -h` | `/` at 100%, 48M free | **First real lead: disk is full** |
| 6 | `df -i` | 18% inodes used | Not inode exhaustion, so real space is being used |
| 7 | `sudo ss -tlnp \| grep nginx` | Listening on 80 and 443 | Confirms step 4 was just a missing `sudo` |
| 8 | `sudo du -xh / --max-depth=1 \| sort -h \| tail` | `/var` is 4.2G of 6.6G | Problem is under `/var` |
| 9 | `sudo find / -xdev -type f -size +500M -exec ls -lh {} \;` | `/var/fill`, 3.1G, root-owned, created 07:13 | Found the culprit |
| 10 | `sudo lsof +L1` | No output | No deleted-but-open files; `rm` will free space immediately |
| 11 | `sudo rm /var/fill` | - | Applied the single fix |
| 12 | `df -h /` | 54% used, 3.1G free | Space recovered |
| 13 | `curl -I http://<public-ip>` (from my Mac) | `200 OK` | Site still fine |
| 14 | `sudo touch /var/testfile && sudo rm /var/testfile` | `writes OK` | Disk accepts writes again |

## Root cause

A 3.1G file (`/var/fill`) filled the root filesystem. In this exercise the fault was injected by my own script. In a real ticket I would ask the customer what changed around 07:13 (the file's creation time is a useful clue).

## Why the website stayed up

Serving an existing static page only needs to read from disk. A full disk breaks things that need to write: logs, `apt` installs, uploads, temp files, and new data. A real customer would likely report "I can't save or upload" or "the server is acting strange", not "the site is down".

## Fix

1. Confirmed the file's size and owner (`ls -lh /var/fill`: root-owned, 3.1G)
2. Checked for deleted-but-open files (`lsof +L1`: none)
3. Removed the file (`sudo rm /var/fill`)

## Verification

- `df -h /`: 54% used, 3.1G available
- `curl -I` from outside: `200 OK`
- Write test (`touch` and `rm` in `/var`): succeeded

## Hypotheses I checked and ruled out

| Hypothesis | How I checked | Result |
|------------|---------------|--------|
| nginx stopped or masked | `systemctl status nginx` | Ruled out |
| nginx on the wrong port | `sudo ss -tlnp` | Ruled out |
| Security group blocking traffic | `curl` from outside | Ruled out |
| Inode exhaustion | `df -i` | Ruled out (18%) |
| Deleted-but-open file | `lsof +L1` | Ruled out |
| Large file using real space | `du`, `find` | **Confirmed** |

## What I got wrong / what I learned

- **The ticket did not match the fault.** I started from "site down", but both `curl` checks returned 200. I did not force a match; I moved on to other layers (disk, names, permissions), which is the right response when a symptom cannot be reproduced.
- **An empty result is not always "nothing there".** `ss -tlnp` without `sudo` printed nothing even though nginx was listening. I re-ran it with `sudo` before drawing a conclusion.
- **Check before deleting.** I confirmed what the file was and that no process held it open before running `rm`. In a real ticket the file might belong to the customer.
- **Tooling note:** on my Mac (zsh), text after `#` on the same line is not ignored in interactive mode, so a trailing comment on a command caused extra `curl` errors. The command itself was fine.

## Prevention (what I would recommend to a customer)

- Disk-usage alerts at about 80%
- Log rotation so logs cannot grow without limit
- Monitor `/var` and other growth areas
- Keep application data on separate volumes from the root filesystem
