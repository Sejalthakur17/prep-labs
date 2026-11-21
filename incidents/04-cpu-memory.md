# Day 13: CPU and memory

**Date:** 21 Nov 2026
**Lab machine:** lab1 (Ubuntu, 2 vCPU, 908Mi RAM, no swap, nginx running)

---

## Baseline (idle machine)

| Metric | Value |
|---|---|
| Load average | ~0.05 (after boot settled) |
| Available memory | 590Mi of 908Mi |
| Swap | 0B |
| CPU idle (`vmstat`) | 98 to 100% |
| `r`, `si`/`so`, `wa` | all 0 |

Note: `free` was 279Mi but `available` was 590Mi. Linux uses spare RAM as cache, so read **available**, not free.

---

## Incident 1: High CPU

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

---

## Incident 2: OOM kill

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

---

## How to read an OOM line

| Field | Meaning |
|---|---|
| Process name and PID | The victim the kernel chose |
| `anon-rss` | Real RAM in use (the number that matters) |
| `total-vm` | Virtual memory reserved, not all in use |
| `oom_score_adj` | Kill priority (-1000 to 1000, higher is killed first) |
| `global_oom` / `CONSTRAINT_NONE` | Whole machine out of memory |
| `invoked oom-killer` | The process that triggered it by asking for memory |

---

## Customer follow-up questions (after an OOM kill)

1. What was running on the instance at the time?
2. How much RAM does the instance have?
3. What changed recently (deploy, traffic, config)?
4. Is it repeating, or a one-off?
5. Do they have monitoring that shows memory over time?

---

## Quick triage cheat sheet

| Customer says | Check | Command |
|---|---|---|
| "Server is slow" | Load vs CPU count | `uptime`, `nproc` |
| "Which process?" | Sort by CPU | `htop` (F6, PERCENT_CPU) |
| "Out of memory?" | Available, not free | `free -h` |
| "App just died" | Kernel log | `sudo dmesg -T \| grep -i oom` |
| "Is it swapping?" | si/so columns | `vmstat 1` |

