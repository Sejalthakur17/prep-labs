# Day 21: NFS fault drills

Done on 24 Nov 2026. AWS EC2, Ubuntu 26.04, ap-south-1. Everything below is from my own terminal output; unverified points are marked.
Builds on the baseline in [storage-lvm-nfs.md](storage-lvm-nfs.md). Full incident report: [../incidents/07-nfs.md](../incidents/07-nfs.md). KB article: [../kb/nfs-mount-hangs-server-down.md](../kb/nfs-mount-hangs-server-down.md).

## The four layers I was testing

| Layer | Question it answers | Fault |
|---|---|---|
| Permissions | Does the server accept who I am? | A |
| Network | Can packets reach the server? | B |
| File identity | Does the server still know the file the client is holding? | C |
| Availability | Is the server alive, and what does the client do if not? | D |

**Troubleshooting order for any NFS ticket:** network, then service, then permissions, then file state.

## Setup

- `nfs-server` 172.31.2.131 and `nfs-client` 172.31.9.106 (private IPs), both in `nfs-sg`.
- Baseline before breaking anything:
  - `systemctl status nfs-kernel-server`: `active (exited)`. That is the normal healthy state for NFS, not a problem.
  - `exportfs -v`: `/srv/share 172.31.9.106(sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,root_squash,no_all_squash)`.
  - Client mount: `nfs4`, `vers=4.2`, `hard`, `timeo=600`, `retrans=2`, `sec=sys`.
- Four terminals, two per machine. A hung command freezes its terminal, so I investigate from the second one and stay out of `/mnt/nfs` there.
- Habit: write the prediction down before running the command.

## Fault A: permission denied (three forms)

**Break it** (server): `sudo chown root:root /srv/share && sudo chmod 755 /srv/share` → `drwxr-xr-x 2 root root`.

| Test (client) | Result | Why |
|---|---|---|
| `touch /mnt/nfs/a.txt` as `ubuntu` (UID 1000) | Permission denied | Folder owner is 0, mode 755 gives "others" no write |
| `sudo touch /mnt/nfs/a.txt` | Permission denied | root_squash: remote root arrives as `nobody` |
| `id` | `uid=1000(ubuntu) gid=1000(ubuntu) ...` | This is the number the client sends |
| `ls -lnd /mnt/nfs` | `drwxr-xr-x+ 2 0 0 4096 Nov 24 11:56` | `-n` prints raw UIDs, which is how mismatches show up |

**Fix 1** (precise): `sudo chown 1000:1000 /srv/share` → `ubuntu ubuntu`. `touch a.txt` worked; `sudo touch b.txt` was still denied, which is correct (root is still squashed).
**Fix 2** (lab shortcut): `sudo chmod 777 /srv/share`. `touch c.txt` worked. Not a production answer.

**Form 3, file owned by someone else:** on the server `sudo useradd -u 2001 alice`, then `sudo -u alice touch /srv/share/alice.txt` (mode 644). On the client:
- `ls -l` showed `alice.txt` owned by `2001 2001`, bare numbers, because the client has no such user.
- `echo test >> /mnt/nfs/alice.txt` as `ubuntu`: Permission denied.
- Cleanup: `sudo rm /srv/share/alice.txt && sudo userdel alice`, folder back to `drwxrwxrwx`.

**Lessons**
- NFS (`sec=sys`) compares numeric UIDs. The same name on two machines with different UIDs is two different people.
- Root being denied is root_squash. The alternative `no_root_squash` makes client root into server root, so it is a security risk.
- Permissions are checked on every request, so no remount was needed after any fix.
- Every file and the directory showed a `+` (an ACL). I did not run `getfacl`, so I don't know where it comes from.

## Fault B: firewalls (two layers)

**Part 1: security group.** Unmounted first (`sudo umount /mnt/nfs`), then deleted the TCP 2049 rule from `nfs-sg`.

| Step | `nc -zv -w 5 172.31.2.131 2049` | Mount |
|---|---|---|
| Rule removed | `timed out: Operation now in progress` | `timeout 30 sudo mount ...` hung, printed nothing, `mount \| grep nfs` empty |
| Rule restored (TCP 2049, source `nfs-sg`) | `succeeded!` | Mounted, files listed |

**Part 2: ufw on the server.** `sudo ufw allow OpenSSH` first, then `sudo ufw enable` (it warned about disrupting SSH; I answered `y`). `ufw status` showed only `OpenSSH ALLOW`.

| Step | `nc` | Mount |
|---|---|---|
| ufw on, no 2049 rule (security group fine) | `timed out` | Hung until Ctrl+C |
| Allowed 2049 from the client IP | `succeeded!` | Mounted |

The fix command was `sudo ufw allow from 172.31.9.106 to any port 2049`. *I did not paste `ufw status` after this, so confirm the rule is listed before committing.*

**Lessons**
- A **timeout** means packets are dropped: check the security group, then `ufw`. The symptom is identical for both layers.
- "Connection refused" would mean the host answered with nothing listening (service stopped). I did not reproduce that case.
- Always allow SSH before enabling ufw.

## Fault C: stale file handle

**Break it:** client in `/mnt/nfs` (shell `cd`'d in), a second client terminal running `tail -f /mnt/nfs/hello`. On the server:
```bash
sudo rm -rf /srv/share && sudo mkdir /srv/share && sudo chmod 777 /srv/share && sudo exportfs -ra
```
(I had copied the folder to `/tmp/share-backup` first.)

| Check (client) | Result |
|---|---|
| `ls` and `ls /mnt/nfs` | `ls: unknown io error: '.', 'Os { code: 116, kind: StaleNetworkFileHandle, message: "Stale file handle" }'` |
| `mount \| grep nfs` | Still listed normally |
| `sudo dmesg \| tail -5` | Nothing about it, only boot-time lines |

The wording is different from classic `ls`, but it is errno 116, the same error.

**Fix:** leave the mount, `sudo umount /mnt/nfs`, mount again. `umount` first said `device is busy`; `fuser -vm /mnt/nfs` named my `tail` (PID 1472). The folder was empty after remounting because `rm -rf` deleted the files; I restored them with `sudo cp -a /tmp/share-backup/. /srv/share/`.

**Lessons**
- The mount looks healthy while the thing the client was holding is gone, and the kernel log can stay clean.
- The new server-side object has the same name but is a different object. Recreating an export, restoring a backup or a failover can all cause this.
- **My mistake:** I ran `mount` again while the stale mount was still busy, which stacked a new mount on top. `ls` showed an empty folder (the new share). `sudo umount -l /mnt/nfs` then removed the top one. Later `findmnt /mnt/nfs` showed a single mount. I never checked what was underneath. Rule: run `mount | grep nfs` before every mount and unmount until it is empty.

## Fault D: hard mount, server stopped

**Break it:** stopped `nfs-server` from the console (a stop keeps the private IP).

| Observation | Evidence |
|---|---|
| `ls /mnt/nfs` froze | Terminal stuck |
| Process state | `1653 D+ ls --color=auto /mnt/nfs` (D = uninterruptible sleep; `+` = foreground) |
| Mount table | `mount \| grep nfs` still showed a normal mount |
| Ctrl+C | Freed the terminal, so the single `ls` was cancelled. The mount stayed, and the next access hung again |
| Kernel message | Nothing at first. After a second `ls` and a wait: `[ 1503.926869] nfs: server 172.31.2.131 not responding, timed out` |
| Server started again | `mount \| grep nfs` and `ls /mnt/nfs` worked with no remount. `dmesg` showed no "OK" line |

**Run 2: forced recovery** (server stopped again, `ls` frozen as PID 1822):
1. `sudo umount -f /mnt/nfs`: `umount.nfs4: /mnt/nfs: device is busy`, mount still listed.
2. `ps -eo pid,stat,cmd | awk '$2 ~ /D/'` found PID 1822. `sudo kill -9 1822` said `No such process`: my Ctrl+C had already ended it.
3. `sudo umount -f /mnt/nfs` then succeeded silently, and `mount | grep nfs` was empty. `-l` was not needed.
4. Server started, `mount | grep nfs` empty, then one `sudo mount ...`, one mount line, files listed.

**Lessons**
- `hard` means the mount retries forever. I expected a process in `D` state to be unkillable, but Ctrl+C worked in my test. The mount's behaviour is `hard`, not the single command.
- Use `ps` to find the holder. `fuser` and `lsof` can touch the mount and hang the terminal.
- `umount -f` does not beat a busy mount. Release the holder, then force. `umount -l` is the last resort.
- The kernel log line only appears when a request is in flight. After I cancelled my first `ls`, nothing was waiting, so nothing was logged (my reasoning, not verified).
- My expectation was `not responding, still trying`. The line on this kernel was `not responding, timed out`. I record the line as printed.

## Escalation order for a hung mount

1. Restore the server (the safe fix; the client resumes by itself).
2. Release whatever holds the mount (Ctrl+C or `kill`).
3. `sudo umount -f <mountpoint>`.
4. `sudo umount -l <mountpoint>` as a last resort.

**Risk to state to a customer:** forcing the mount away can lose writes the client has not flushed to the server. I did not test this (no write was in flight), so it is the documented behaviour, not something I measured.

## Cheat table

| Symptom | First command | Likely cause |
|---|---|---|
| Mount hangs or times out | `nc -zv -w 5 <server> 2049` | Security group or `ufw` dropping packets |
| `Connection refused` on 2049 | `systemctl status nfs-kernel-server` (server) | Service stopped (not reproduced) |
| Write fails, root also denied | `ls -lnd <dir>`; `exportfs -v` | Owner or mode, plus `root_squash` |
| Owners show as numbers | `ls -ln` on both machines | UID mismatch |
| `Stale file handle` | `mount \| grep nfs` (still looks fine) | Server-side object recreated |
| Commands freeze after an outage | `ps -eo pid,stat,cmd \| awk '$2 ~ /D/'` | `hard` mount with the server down |

## Mistakes I made (and what they taught me)

1. Typed `<server-private-ip>` literally. Bash read `<server-private-ip>` as input redirection from a file of that name, so `mount` never ran. The next write failed with Permission denied because `/mnt/nfs` was only an empty root-owned local directory. Placeholders always need replacing, brackets included.
2. Ran client commands on the server: `echo test >> /mnt/nfs/alice.txt` gave `No such file or directory`, and `mount | grep nfs` showed only `nfsd on /proc/fs/nfsd`. Check the hostname in the prompt first.
3. Pasted prompt text into the shell (`command not found`, `syntax error`). Copy only the commands.
4. Ran `dmesg` without sudo: `read kernel buffer failed: Operation not permitted`.
5. Stacked a mount on a busy stale one (see Fault C).

## Not verified

- Where the `+` ACL on files and the directory comes from (no `getfacl`).
- The `Connection refused` case.
- What the frozen `ls` did in the first terminal when the server came back (not captured). The mount worked again without a remount.
- That `umount -f` loses data (nothing was being written).
- What was under the stacked mount.

## Interview Q&A

- **Root gets "permission denied" writing to an NFS share. Why?** `root_squash` maps remote root to `nobody`. Fix the owner or mode for the real user. `no_root_squash` works but makes client root into server root.
- **A mount hangs. What is the first thing you run?** `nc -zv -w 5 <server> 2049`. A timeout means dropped packets (security group, then `ufw`). A refusal means nothing is listening.
- **What is a stale file handle?** The client holds a reference to a server-side object that was deleted or recreated. The mount looks fine. Leave the mount, unmount, mount again.
- **Why does a command freeze when the NFS server dies?** The mount is `hard`, so it retries forever to protect data. Restore the server first. If that is impossible, release the holder, `umount -f`, then `umount -l`, and warn about unflushed writes.
- **`umount -f` says busy. Now what?** Find the holder with `ps`, release it, force again.
- **Hard vs soft?** Hard waits forever and is safe for data. Soft returns errors after timeouts but can lose or corrupt writes (standard NFS behaviour; I did not test soft).