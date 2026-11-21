# Incident 04: Resource exhaustion (CPU, memory, disk, deleted files, inodes)

**Date:** 21 Nov 2026
**Lab machine:** Ubuntu on EC2 (`lab1`): 2 vCPU, 908Mi RAM, no swap, nginx running, 6.7G root volume (`/dev/root`)

Five faults, one theme: a resource ran out. The same symptom ("slow", "app died", "No space left on device") had several different causes, and the first tool I reached for did not always tell them apart.

| # | Fault | Symptom | Key command | Root cause |
|---|---|---|---|---|
| 1 | High CPU | Load 1.87 on 2 CPUs | `htop` (F6, PERCENT_CPU) | CPU-bound process |
| 2 | OOM kill | Workers killed, tool said "passed" | `dmesg -T \| grep -i oom` | Memory demand above 908Mi, no swap |
| 3 | Full disk | Root at 72%, 1.9G free | `du -xah`, `find -size +500M` | One 2 GB file in `/var` |
| 4 | Deleted but open | `df` unchanged after `rm` | `lsof +L1` | Process holding a deleted file |
| 5 | Inodes exhausted | "No space left" with 89M free | `df -i` | Filesystem created with 2000 inodes |

---

## Baseline

| Metric | Value |
|---|---|
| Load average | ~0.05 (after boot settled) |
| Available memory | 590Mi of 908Mi |
| Swap | 0B |
| CPU idle (`vmstat`) | 98 to 100% |
| `r`, `si`/`so`, `wa` | all 0 |
| `df -h /` | 6.7G size, 2.7G used, 3.9G available (41%) |
| `df -i /` | 878,080 inodes, 136,089 used (16%) |
| `/tmp` | **tmpfs**, 455M, RAM-backed (not the root disk) |
| `/var/tmp` | on `/dev/root` (the real disk) |

Note: `free` was 279Mi but `available` was 590Mi. Linux uses spare RAM as cache, so read **available**, not free.

---

## Part 1: CPU and memory

### Incident 1: High CPU

- **Symptom:** Load average rose from ~0.05 to 1.87 on a 2-CPU instance. Both CPU bars at 100%.
- **Commands run:**
  - `stress-ng --cpu 2 --timeout 180s &` to create the load
  - `uptime` to watch load rise
  - `htop` (F6, sort by PERCENT_CPU) to find the process
  - `pgrep -a stress` to get PIDs
  - `sudo renice +10 -p 1458` to lower priority
  - `kill 1456` to stop it
- **What I saw:**
  - Two `stress-ng-cpu` workers at the top of htop (PIDs 1458, 1459).
  - Load average 1.87, 1.04, 0.48. The 1-min value is higher than the 15-min value, so the load is recent.
  - After renice, PID 1458 showed NI 10, PRI 30 and ~92% CPU. PID 1459 showed NI 0 and 100%.
  - Before htop competed for CPU, both workers showed ~100%.
- **Cause:** CPU-bound process.
- **Fix / action:** Lowered priority with renice, then stopped the process with `kill` (signal 15). It exited cleanly.
- **Lesson:** Nice values only matter under contention. With 2 CPUs and 2 workers, both got a full CPU until another process (htop) wanted time. Renice tames a heavy job without killing it.

### Incident 2: OOM kill

- **Symptom:** Memory pressure with no swap. `stress-ng` reported `passed: 2` and `failed: 0`, but the kernel was killing its workers.
- **Commands run:**
  - `free -h` before and after
  - `stress-ng --vm 2 --vm-bytes 90% --timeout 60s` (no OOM)
  - `stress-ng --vm 2 --vm-bytes 600M --timeout 60s` (no OOM)
  - `stress-ng --vm 2 --vm-bytes 1500M --timeout 60s` (OOM kills)
  - `sudo dmesg -T | grep -i -E "out of memory|oom|killed process"`
  - `journalctl -k | grep -i "out of memory" | head -5`
  - `systemctl is-active nginx`
- **What I saw:**
  - Key line: `Out of memory: Killed process 2411 (stress-ng-vm) total-vm:847736kB, anon-rss:478696kB ... oom_score_adj:1000`
  - Many kills between 10:26 and 10:28, because stress-ng kept restarting workers and the kernel kept killing them.
  - `global_oom` with `CONSTRAINT_NONE`: the whole machine ran out, not a container limit.
  - After recovery: `available` 629Mi, no stress processes, nginx still `active`.
- **Cause:** Memory exhaustion. The workers asked for far more than the 908Mi available, with no swap.
- **Fix / action:** Killed workers recovered on their own. No reboot was needed.
- **Lessons:**
  1. `--vm-bytes 90%` means 90% of *free* memory at that moment, not total RAM.
  2. `--vm-bytes` is split across workers, so 600M with 2 workers is 300MB each. Always read stress-ng's "using X per stressor" line to check the real size.
  3. A tool's summary can say "passed" while the kernel killed processes. **Check dmesg, not the program's report.**
  4. The victim isn't always the cause. stress-ng sets `oom_score_adj:1000`, so its workers were picked first and nginx survived. Normally the kernel picks by memory use and score.
  5. Read `anon-rss` to see real RAM used by the killed process.

### How to read an OOM line

| Field | Meaning |
|---|---|
| Process name and PID | The victim the kernel chose |
| `anon-rss` | Real RAM in use (the number that matters) |
| `total-vm` | Virtual memory reserved, not all in use |
| `oom_score_adj` | Kill priority (-1000 to 1000, higher is killed first) |
| `global_oom` / `CONSTRAINT_NONE` | Whole machine out of memory |
| `invoked oom-killer` | The process that triggered it by asking for memory |

### Customer follow-up questions (after an OOM kill)

1. What was running on the instance at the time?
2. How much RAM does the instance have?
3. What changed recently (deploy, traffic, config)?
4. Is it repeating, or a one-off?
5. Do they have monitoring that shows memory over time?

---

## Part 2: Disk, deleted files and inodes

The same error, **"No space left on device"**, came from three different causes. `df -h` alone could not tell them apart.

### Incident 3: Full disk

- **Symptom:** root filesystem jumped from 41% to 72% used and only 1.9G stayed free.
- **Commands run:**
  - `df -h /` before and after
  - `AVAIL=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')`, then `sudo fallocate -l $((AVAIL-2))G /var/big` to leave about 2G free
  - `sudo du -xh / --max-depth=2 2>/dev/null | sort -h | tail -10`
  - `sudo du -xah / --max-depth=2 2>/dev/null | sort -h | tail -10`
  - `sudo find / -xdev -type f -size +500M -exec ls -lh {} +`
  - `sudo rm /var/big`
- **What I saw:**
  - 2.7G used (41%) before. 4.7G used (72%) with 1.9G free after `fallocate`.
  - `du` without `-a` showed `/var` at 2.6G but **did not list `/var/big`**. `du` lists only directories unless you add `-a`.
  - The gap gave it away: `/var`'s subfolders (`lib` 355M, `cache` 157M, `log` 42M) added up to about 550M, but `/var` was 2.6G. A big file had to sit directly in `/var`.
  - `du -xah` showed `2.1G /var/big`. `find -size +500M` showed `-rw-r--r-- 1 root root 2.0G /var/big`.
  - The 2.1G from `du` and 2.0G from `ls` differ only by rounding and block size.
- **Cause:** one large file, `/var/big`.
- **Fix:** `sudo rm /var/big`. `df` returned to 2.7G (41%).
- **Lessons:**
  1. `df` tells you *whether* you are full. `du` tells you *what* is using the space.
  2. `du` without `-a` can hide a single big file inside a folder total. Compare a folder to the sum of its children, or use `du -xah` or `find -size`.
  3. `-x` keeps `du` and `find` on one filesystem, so `/proc` and other mounts do not distort the numbers.

### Incident 4: Deleted but still open

- **Symptom:** a file was deleted, but `df` still showed the space as used.
- **Commands run:**
  - `dd if=/dev/zero of=/var/tmp/held bs=1M count=500`
  - `sleep 3600 < /var/tmp/held &` (a holder that keeps the file open)
  - `sudo lsof /var/tmp/held` to confirm the file was open **before** deleting
  - `rm /var/tmp/held`
  - `df -h /var/tmp`, `sudo du -xah /var/tmp --max-depth=1`, `sudo lsof +L1`
  - `kill %1`
- **What I saw:**
  - After `rm`, `df` still showed **3.2G used (49%)**, but `du` showed `/var/tmp` as only **48K**. The two disagreed by about 500M.
  - `lsof +L1` showed `sleep`, PID 4820, holding `/var/tmp/held (deleted)`, with `NLINK 0`.
  - After `kill`, `df` returned to 2.7G (41%). The first `df` ran in the same instant as the `kill`, so it still showed 3.2G. A second `df` a moment later showed the space freed.
- **Cause:** a running process kept the deleted file open, so its data stayed on disk. The name was gone, but the space was not released.
- **Fix:** stopped the holding process. In production, restart or signal the owning service. To free space without a restart, truncate through the file descriptor: `: > /proc/<PID>/fd/<FD>`.
- **What went wrong on the way (kept on purpose):**
  1. `/tmp` is **tmpfs** (RAM, 455M) on this instance. `dd` of 500M failed at about 364M. I moved the test to `/var/tmp`, which is on the real disk. Always run `df -h <path>` on the exact path involved.
  2. `tail -f file &` followed straight away by `rm` **raced**: `tail` had not opened the file yet, so nothing held it and the space freed immediately.
  3. With `tail -f` and a short delay, `tail` opened the file but **exited on its own** after the delete ("no files remaining"). Space is freed the moment the last holder exits.
  4. `sleep 3600 < file` held the file reliably. I added `lsof <file>` before the `rm` to confirm it was open.
- **Lessons:**
  1. A file's space is freed only when nothing has it open.
  2. A big gap between `df` and `du` points to deleted-but-open files. Confirm with `lsof +L1`.
  3. `kill` only sends a signal. The space returns once the process has actually exited.

### Incident 5: Inode exhaustion

- **Symptom:** `touch` failed with "No space left on device" while `df -h` showed 89M free.
- **Commands run:**
  - `truncate -s 100M ~/small.img`
  - `mkfs.ext4 -F -N 2000 ~/small.img`
  - `sudo mount -o loop ~/small.img /mnt/small`
  - `df -h /mnt/small` and `df -i /mnt/small`
  - `sudo bash -c 'for i in $(seq 1 3000); do touch /mnt/small/f$i || break; done'`
  - `sudo find /mnt/small -xdev -type f | wc -l`
  - `sudo find / -xdev -type f | cut -d/ -f2-3 | sort | uniq -c | sort -n | tail`
- **What I saw:**
  - `mkfs` created 25,600 4k blocks and **2000 inodes**.
  - Start: `df -h` showed 96M size, 152K used, 89M available (1%). `df -i` showed 2000 inodes, 12 used, 1988 free.
  - The loop failed at `f1989`: `touch: cannot touch '/mnt/small/f1989': No space left on device`.
  - End: `df -h` showed 188K used and 89M available (1%). `df -i` showed 2000 used, **0 free, 100%**.
  - A further `touch` failed with the same error. `ls | wc -l` gave 1989 (1988 files plus `lost+found`).
  - `find ... -type f | wc -l` gave 1988, which matches 2000 inodes minus the 12 used internally.
  - Per-directory counts on root: `usr/src` 54,136, `usr/lib` 28,783, `usr/share` 24,485. Nothing abnormal.
  - Root baseline: `df -i /` showed 878,080 inodes, 136,089 used (16%).
- **Cause:** the filesystem was created with only 2000 inodes (`mkfs.ext4 -N 2000`), and 1988 empty files used them all. Free blocks were irrelevant.
- **Fix:** delete files, or recreate the filesystem with more inodes (`mkfs.ext4 -N` or a smaller `-i` bytes-per-inode ratio). Cleanup: `sudo umount /mnt/small && rm ~/small.img`.
- **Real-world sources:** mail queues, session files, cache folders with millions of tiny files.
- **Lessons:**
  1. An inode is one file entry. ext4 fixes the number when the filesystem is created.
  2. Empty files cost almost no space (188K for about 2000 files), so `df -h` looks healthy while `df -i` is at 100%.
  3. The per-directory `find | cut | uniq -c` count shows which folder holds the files.

### Diagnosis routine for "No space left on device"

| Step | Command | What it tells you |
|---|---|---|
| 1 | `df -h <path>` | Which filesystem the path is really on (could be tmpfs) and whether blocks are full |
| 2 | `df -i <path>` | `IUse%` at 100% means inodes exhausted |
| 3 | Compare `du -sh` with `df -h` | A big gap means deleted-but-open files, so run `sudo lsof +L1` |
| 4 | `sudo du -xah / --max-depth=2 \| sort -h \| tail` or `find -size +500M` | Otherwise, find the large file or folder |

---

## Customer reply (draft)

> Thanks for the details. "No space left on device" can come from three different causes, so I checked each one. On your instance the space is used by <what you found>. I freed it by <what you did>, and writes now succeed.
>
> To stop this recurring, I recommend setting an alert at about 80% for disk usage, inode usage and memory, rotating or capping logs, and restarting services that hold deleted files open after any large cleanup. Let me know if it comes back and I will look again.

## What to monitor

- CPU load against CPU count, and memory `available` over time.
- Disk usage and inode usage on every mount, with an alert at about 80%.
- Log growth and rotation (`/var/log`).
- After deleting large files, check that `df` actually dropped.

---

## Quick triage cheat sheet

| Customer says | Check | Command |
|---|---|---|
| "Server is slow" | Load vs CPU count | `uptime`, `nproc` |
| "Which process?" | Sort by CPU | `htop` (F6, PERCENT_CPU) |
| "Out of memory?" | Available, not free | `free -h` |
| "App just died" | Kernel log | `sudo dmesg -T \| grep -i oom` |
| "Is it swapping?" | si/so columns | `vmstat 1` |
| "Disk is full" | Space on the exact path | `df -h <path>` |
| "Disk full but df shows free space" | Inodes | `df -i <path>` |
| "I deleted a file but nothing freed" | Deleted files still open | `sudo lsof +L1` |
| "What is using the space?" | Biggest files and folders | `sudo du -xah / --max-depth=2 \| sort -h \| tail` |
| "Which folder has all the tiny files?" | Files per directory | `sudo find / -xdev -type f \| cut -d/ -f2-3 \| sort \| uniq -c \| sort -n \| tail` |
