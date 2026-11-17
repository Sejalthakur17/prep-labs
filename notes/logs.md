# Logs, text tools and my first script

## Where logs live

A log is a text file where a program records what it did and what went wrong. Most support work starts by reading one.

- `/var/log/syslog`: general system messages. First stop for "something odd happened".
- `/var/log/auth.log`: logins, `sudo`, SSH attempts. For "who logged in or tried to?".
- `/var/log/kern.log`: kernel messages (disks, memory, hardware).
- `/var/log/dpkg.log`: packages installed, upgraded or removed. Answers "what changed on this server?".
- `/var/log/nginx/access.log`: every web request. `error.log`: web server errors.
- `/var/log/cloud-init.log` and `cloud-init-output.log`: what AWS set up on first boot.
- `/var/log/dmesg`: kernel boot messages. Older ones are saved as `dmesg.0`, `dmesg.1.gz` (read with `zcat`).
- `/var/log/wtmp`, `lastlog`: successful logins. `/var/log/btmp`: failed password logins (empty on EC2, password login is off).
- `/var/log/unattended-upgrades/`: automatic security updates.

## Who can read the logs

- `auth.log` is `-rw-r-----`, owner `syslog`, group `adm`. Owner reads and writes, group reads, everyone else has no access.
- My user `ubuntu` is in the `adm` group (`id` shows `4(adm)`), so I can read these logs without `sudo`.
- A user not in `adm` gets `Permission denied`. Files owned by `root` with no group read (and folders like `private/`) need `sudo`.

## Reading one auth.log line

```
2026-11-17T07:03:55.343767+00:00 ip-172-31-13-118 sshd-session[1053]: Accepted publickey for ubuntu from 223.181.19.177 port 28205 ssh2: RSA SHA256:mYDr...
```
- `2026-11-17T07:03:55...+00:00` is the date and time in **UTC**. India is UTC+5:30, so add 5:30 before telling anyone a local time.
- `ip-172-31-13-118` is the server's hostname.
- `sshd-session[1053]` is the program that wrote the line, and its PID.
- `Accepted publickey` means the login succeeded using a key, not a password.
- `for ubuntu from 223.181.19.177 port 28205`: the username, my IP, and a random temporary port my Mac used.
- `RSA SHA256:...` is the fingerprint (a label) of the key. The same fingerprint on every login means the same key.
- A login creates two sessions in the log (`tty` and `manager`). That is normal.

## journalctl (the systemd journal)

- `journalctl -b`: logs since this boot.
- `journalctl -b -p err`: only errors and worse since this boot (`-p` = priority).
- `journalctl --since "1 hour ago"`: only recent logs.
- `journalctl -k`: kernel messages only.
- `journalctl -u ssh`: one service. On Ubuntu SSH is called `ssh`, not `sshd`.
- Press `q` to quit.

`tail -f <file>` follows one known file live. `journalctl -u <service>` shows everything one service logged, filterable by time and priority. I use `tail -f` when I know the file, and `journalctl -u` when I know the service.

## Text tools

- `grep "word" file`: lines containing the word. `-i` ignore case, `-c` count lines, `-v` lines that do NOT match, `-o` print only the matching part, `-E` extended patterns like `A|B`.
- `awk '{print $N}'`: print column N. Lines are split on spaces. `$0` is the whole line.
- `cut -d' ' -fN`: field N with a chosen separator.
- `sed 's/old/new/'`: replace text in the output. It does not change the file.
- `tail -n 20 file`: last 20 lines. `head` shows the first lines.
- `|` (pipe): output of the left command becomes input of the right one.
- `>` writes output to a file (overwrites). `>>` appends. `> /dev/null` throws output away. `>&2` sends a message to the error channel.

Splitting a sample line with awk:
```
Nov 3 10:01:11 web1 sshd[101]: Failed password for root from 203.0.113.5 port 4001 ssh2
$1  $2 $3      $4   $5         $6     $7       $8  $9   $10  $11         $12  $13  $14
```
`$9` is the username and `$11` is the IP. The real auth.log starts with one timestamp field, so its columns are different. Always look at one real line before choosing a column.

## The count-and-rank pattern

```
awk '{print $11}' file | sort | uniq -c | sort -nr
```
- `awk` pulls out the column.
- `sort` puts identical values next to each other. `uniq` only merges **neighbouring** duplicates, so this step is required.
- `uniq -c` collapses duplicates and puts the count in front.
- `sort -nr` sorts as numbers (`-n`), biggest first (`-r`).
- Add `| head -10` for the top 10.

## My script: failed_ssh.sh

Shows the top source IPs of failed SSH logins. Lives in `~/canonical-prep-labs/scripts/`.

- `#!/usr/bin/env bash`: the shebang. Tells Linux which program runs the file.
- `set -euo pipefail`: `-e` exit on any failing command, `-u` unset variable is an error, `-o pipefail` a pipe fails if any part of it fails.
- `LOG="${1:-/var/log/auth.log}"`: use the first argument, or this default if none is given.
- `[[ ! -r "$LOG" ]]`: is the file NOT readable? If so print an error to stderr and `exit 1`.
- `result=$( ... )`: run the pipeline and store its output in a variable.
- `grep -E 'Failed password|Invalid user'`: keep lines with either phrase.
- `grep -oE 'from [0-9]{1,3}(\.[0-9]{1,3}){3}'`: keep only `from <IPv4 address>`.
- `awk '{print $2}'`: keep just the IP.
- `sort | uniq -c | sort -nr | head -10`: count and rank, top 10.
- `|| true`: needed because `grep` returns an error when it finds no match, and `set -e` would kill the script.
- `[[ -z "$result" ]]`: is the result empty? Then print "No failed SSH attempts found".

Exit codes: `0` means success, anything else means failure. Check the last one with `echo $?`.

Why I match "Invalid user" as well as "Failed password": EC2 only allows key logins, so there are no password failures. A wrong username logs `Invalid user <name> from <IP>`.

Test results:
- On my `/tmp/sample.log`: `3 203.0.113.5` and `1 192.0.2.99`, as predicted.
- On a missing file: error message and `exit code: 1`.
- On the real `auth.log`: "No failed SSH attempts found". That is the correct result, because my security group only lets my own IP in and every login was `Accepted publickey`.

## What I found in my real logs

- Every SSH login was `Accepted publickey`. No failures, because the security group blocks strangers.
- My public IP changed between Nov 3 (`223.181.19.57`) and Nov 16 (`223.181.19.177`). Home internet providers rotate IPs. If the rule had been a single old `/32`, SSH would have timed out. This is a classic "I could SSH yesterday" ticket.
- The same key fingerprint appeared on every login. An unknown fingerprint would be a red flag.
- `btmp` is 0 bytes because password login is off.
- The kernel is `7.0.0-1016-aws`, so this is a newer Ubuntu release than I assumed. Check with `lsb_release -a` and record the real version.
- `last` is not installed on this release. Newer Ubuntu uses `wtmpdb` (`sudo apt install wtmpdb`, then `wtmpdb last`). Or use `grep "Accepted publickey" /var/log/auth.log | tail`.

## What I got wrong and how I fixed it

1. **`chmod: cannot access 'failed_ssh.sh': No such file or directory`**
   - Symptom: `chmod` and `./failed_ssh.sh` both failed.
   - Diagnosis: the prompt showed `~`, and `ls` printed nothing. I was in my home folder and the repo folder had never been created on this instance.
   - Fix: `mkdir -p ~/canonical-prep-labs/scripts`, `cd` into it, create the script with `nano`, then `chmod +x`.
   - Lesson: the shell looks for `./name` in the **current folder only**. Run `pwd` and `ls` first.

2. **Script not executable yet**
   - `ls -l` showed `-rw-rw-r--`, no `x`. `chmod +x` adds the execute bit, and the file then shows `-rwxrwxr-x`.

## Troubleshooting method for log problems

1. Find out which service or file is involved (`systemctl status`, `ls /var/log`).
2. Read the newest lines: `tail -n 20 <file>` or `journalctl -u <name> -n 20`.
3. Narrow by time and severity: `--since "30 minutes ago" -p err`.
4. Filter with `grep`, pick the column with `awk`, count with `sort | uniq -c | sort -nr`.
5. Convert timestamps to the customer's time zone before reporting when it happened.
6. Change one thing, then check the log again to confirm.

## Cheat sheet

Reading logs
- `ls -lh /var/log` lists logs with sizes
- `tail -n 20 <file>` last 20 lines, `tail -f <file>` follow live
- `zcat <file>.gz | head` read a compressed log
- `journalctl -u <name> --since "30 minutes ago" -p err`
- `journalctl -b -p err` errors since boot
- `id` shows my groups (is `adm` listed?)

Filtering
- `grep -i "text" file`, `grep -c`, `grep -v`, `grep -oE 'pattern'`
- `awk '{print $N}'` one column
- `cut -d' ' -fN`, `sed 's/old/new/'`
- `... | sort | uniq -c | sort -nr | head`

Scripts
- `chmod +x script.sh` then `./script.sh <args>`
- `$1` first argument, `$?` last exit code
- `exit 1` fail, `exit 0` success
- `[[ -r file ]]` readable, `[[ -z "$var" ]]` empty
- `set -euo pipefail` at the top of every script

Making nginx write logs
- `curl -s localhost > /dev/null` a normal request (access.log)
- `curl -s localhost/missing > /dev/null` a 404 (access.log and error.log)
- `sudo nginx -t` tests the config

nginx log timestamps
- `access.log`: `17/Nov/2026:07:45:10 +0000`
- `error.log`: `2026/11/17 07:45:10`
- Errors from the last 30 minutes (file version):
  `awk -v t="$(date -d '30 minutes ago' '+%Y/%m/%d %H:%M:%S')" '$1" "$2 >= t' /var/log/nginx/error.log`
- Errors from the journal: `sudo journalctl -u nginx --since "30 minutes ago" -p err`

## Common errors

Reading logs
- `Permission denied` on a log: I'm not in the `adm` group, or the file is root-only. Use `sudo`, and check `id`.
- `auth.log` or `syslog` missing: rsyslog isn't installed. `sudo apt install -y rsyslog`, or use `journalctl`.
- `last: command not found`: newer Ubuntu uses `wtmpdb`.
- Empty `access.log`: nobody has visited the web server yet. Send a request with `curl`.

Scripts
- `No such file or directory` when running `./script.sh`: wrong folder or the file doesn't exist. `pwd`, `ls`.
- `Permission denied` when running it: missing execute bit. `chmod +x`.
- `bad interpreter` or `^M` in the error: Windows line endings. `sed -i 's/\r$//' script.sh`.
- Script silently exits with no output: `set -e` stopped it when `grep` found nothing. Add `|| true` where "no match" is acceptable.
- Wrong or empty column from `awk`: the log format differs from what I assumed. Look at one real line and count the fields.
- Counts look doubled: one failed attempt can write two log lines.

SSH access
- `Operation timed out`: the security group doesn't allow my current IP (it may have changed), or the instance isn't running. Check `curl -4 ifconfig.me` and the inbound rule.
- `Permission denied (publickey)`: wrong user or key. Use `ubuntu@<ip>` and the correct `.pem`.
- Time looks wrong in a log: logs are in UTC. Add 5:30 for India.
