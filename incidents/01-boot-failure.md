# Server running but unreachable: boot stopped in emergency mode after a bad /etc/fstab entry

**Environment:** AWS EC2 `lab1` (t3.small, ap-south-1b) · Ubuntu 26.04.1 LTS, kernel 7.0.0-1016-aws · 8 GiB gp3 root volume + 2 GiB gp3 data volume · repair instance `rescue` (t3.micro, same AZ)

**Symptom (what the "customer" would report):**
"My instance shows as running in AWS, but I can't SSH in after a reboot." First `Operation timed out`, later `Connection refused`.

**Impact:** `lab1` completely unreachable. In a production setting this would be a full outage of anything hosted on the server.

---

## Timeline (command → what I saw → what I concluded)

| # | What I did | What I saw | What I concluded |
|---|---|---|---|
| 1 | Attached a 2 GiB EBS volume, then `lsblk`, `fdisk`, `mkfs.ext4`, `mount` at `/data` | `df -h /data` showed 2.0G; `blkid` gave UUID `a88ad6d2-acc5-48bc-9bf2-649344512a07` | The disk itself works |
| 2 | Added an fstab line for `/data`, ran `mount -a`, rebooted | After reboot `/data` was **not** mounted; `mount -a` printed nothing | Realised later: the line still had a placeholder instead of my real UUID, so it could never match a disk, and `nofail` hid the error (see Second finding) |
| 3 | Deliberately added `UUID=11111111-2222-3333-4444-555555555555  /broken  ext4  defaults  0  2` (fake UUID, **no `nofail`**) and ran `sudo reboot` | SSH: `Operation timed out` | Server not reachable |
| 4 | Checked the EC2 console | Instance state Running, status checks 3/3 passed, public IP unchanged | Status checks were misleading; they lag behind the real state |
| 5 | Checked the security group | SSH allowed from my IP; EC2 Instance Connect also failed (expected, since the rule only allows my own IP) | Ruled out network rules |
| 6 | `nc -vz -w 5 <ip> 22` | `Connection refused` | Packets reach the host but nothing is listening, so `sshd` is not running |
| 7 | EC2 console screenshot / `aws ec2 get-console-output --instance-id <id> --latest --output text` | `Timed out waiting for device /dev/disk/by-uuid/11111111-…` → `Dependency failed for broken.mount - /broken` → `Dependency failed for local-fs.target` → `Reached target emergency.target - Emergency Mode` | **Root cause found:** the boot stopped in emergency mode over the fake fstab entry |
| 8 | Stopped `lab1`, detached its root volume, attached it to `rescue` as `/dev/sdf` | First I mounted the wrong volume (the 2 GiB data disk): only `lost+found`, and nano said `/mnt/fix/etc` did not exist | Wrong volume. Found the right one via the volume's **Attached resources** panel |
| 9 | Mounted the 6.9G root partition at `/mnt/fix`, `cat /mnt/fix/etc/fstab` | Three default Ubuntu lines + the `/broken` line; **no `/data` line** | Confirms the bad line; no `/data` line was left in the file |
| 10 | Backed up the file, deleted `/broken`, added the correct `/data` line with `nofail`, unmounted, reattached the volume to `lab1` as `/dev/sda1`, reattached the data volume as `/dev/sdf`, started `lab1` | SSH worked on the new public IP (it changes after stop/start) | Fixed |

---

## Root cause
`/etc/fstab` contained an entry for a device that does not exist (fake UUID) and had no `nofail` option. At boot, systemd waited about 90 seconds for the device, treated the failed mount as a required dependency of `local-fs.target`, and dropped into emergency mode. `sshd` never started, so the server was running but unreachable.

## Fix
Mounted the broken root volume on a second instance (`rescue`), removed the bad line, put in the correct `/data` entry with `nofail`, reattached the volume to `lab1` as `/dev/sda1`, and started the instance.

Final fstab:
```
LABEL=cloudimg-rootfs	/	ext4	discard,commit=30,errors=remount-ro	0 1
LABEL=BOOT	/boot	ext4	defaults	0 2
LABEL=UEFI	/boot/efi	vfat	umask=0077	0 1
UUID=a88ad6d2-acc5-48bc-9bf2-649344512a07  /data  ext4  defaults,nofail  0  2
```

## How I verified
- SSH login worked after the instance started.
- `df -h /data` showed `/dev/nvme1n1p1  2.0G … /data`.
- `findmnt --verify` reported 0 parse errors and 0 errors (the 4 warnings were only "Permission denied" because I ran it without `sudo`).
- Final reboot test: after `sudo reboot` `/data` was mounted by itself i 

## Prevention / what to monitor
- Use `nofail` on any non-root mount so a missing disk cannot block boot.
- Before every reboot after editing fstab: `cat /etc/fstab` (confirm what was saved), `sudo findmnt --verify`, `sudo mount -a`, then `df -h <mountpoint>`.
- Copy the real UUID from `blkid` into the line and re-read the file for leftover placeholder text. `nofail` will hide a wrong UUID, so confirm with `df -h` after `mount -a`.
- Take an AMI or snapshot before risky changes.
- Keep a runbook for "running but unreachable": console screenshot and system log first, then security group, then the rescue-instance method.

## What I learned
1. AWS status checks can show 3/3 passed while the OS is stuck in emergency mode, so the console log is the more reliable evidence. `Operation timed out` and `Connection refused` also mean different things: refused means the packets arrived but no service was listening.
2. Identify EBS volumes by their **Attached resources** panel, not by size alone. I mounted the wrong disk once before getting it right.

---

## Second finding: why `/data` did not mount the first time
My first `/data` entry did not mount after the first reboot, and `mount -a` printed no error. The cause: I had left the placeholder text in the line instead of pasting my real UUID from `blkid`. A UUID that matches no disk, combined with `nofail`, makes `mount -a` fail silently, because `nofail` suppresses errors for missing devices. So nothing mounted and nothing was reported. But after I added UUID the /data was mount and was working perfectly fine. 

After the recovery that line was no longer in the file (it was replaced when I edited fstab to add the fake line), so I cannot show the original line. This explanation comes from my own account of what I typed.

Lesson: `nofail` protects the boot but hides mistakes. After `mount -a`, always confirm with `df -h <mountpoint>` or `findmnt`, and never rely on "no output" alone.

---

## Part 2: service and permission faults 
# Lab 1 (part 2): nginx service and permission faults

**Environment:** AWS EC2 instance `ip-172-31-10-100`, launched from my `clean-baseline` AMI. nginx 1.28.3 (Ubuntu), managed by systemd. Python 3.14.4 was used to create fault C.
**Date:** Nov 17, 2026 (all times UTC).
**Test setup:** `/var/www/html/index.html` contains `hello from lab1` (16 bytes). Config backup saved as `~/default.bak`.
**Method:** I broke one thing at a time, wrote down a prediction first, diagnosed with logs and commands, fixed it, and verified with `curl -I localhost` before moving on.

## Summary

| Fault | Visible symptom | Key command that revealed the cause | Root cause | Impact |
|---|---|---|---|---|
| A: syntax error | nginx fails to start | `sudo nginx -t` | Missing `;` on a `listen` directive in `sites-enabled/default` | About 5 min (17:05:37 to 17:10:30) |
| B: unreadable content | `403 Forbidden`, service shows running | `namei -l /var/www/html/index.html` | Web root folder set to `700`; variant: `index.html` set to `600` | About 2 min each (17:11:52 to 17:13:57; 17:15:29 to 17:17:26) |
| C: port in use | nginx fails to start | `sudo ss -tulpn \| grep :80` | `python3` (PID 1739) was listening on port 80 | About 7 min (17:23:09 to 17:30:33) |

---

## Fault A: nginx fails to start after a config syntax error

**Symptom (what the "customer" would report):**
"I changed a setting and restarted nginx, and now my website is down."

**Impact:**
The website was unavailable from 17:05:37 (nginx stopped by the restart) until 17:10:30 (nginx running again), about 5 minutes. The restart is what caused the outage: a restart stops nginx first, so the old working copy was gone when the new config failed its test.

**Timeline (command → what I saw → what I concluded):**
1. `sudo systemctl restart nginx` → `Job for nginx.service failed because the control process exited with error code.` → the restart failed.
2. `systemctl status nginx` → `Active: failed (Result: exit-code)`, and `ExecStartPre=/usr/sbin/nginx -t ... (code=exited, status=1/FAILURE)` → systemd runs a config test before every start, and that test failed, so nginx never started.
3. `sudo nginx -t` → `[emerg] invalid parameter "listen" in /etc/nginx/sites-enabled/default:23` and `configuration file /etc/nginx/nginx.conf test failed` → exact file and line of the problem.
4. `journalctl -u nginx -n 20` → the same `[emerg]` line at 17:05:37, followed by `Failed to start nginx.service` → logs confirm the cause.
5. Opened the file with `sudo nano /etc/nginx/sites-enabled/default` and looked at line 23 and the line above it → the `listen` directive on the previous line was missing its closing `;`, so nginx read the next `listen` as an extra parameter. nginx reported line 23 because that is where it noticed the problem, one line after the real typo.
6. Restored the `;` → `sudo nginx -t` printed `syntax is ok` and `test is successful`.
7. `sudo systemctl start nginx` then `curl -I localhost` → `HTTP/1.1 200 OK` at 17:10:30.

**Root cause:**
A missing semicolon at the end of a `listen` directive in `/etc/nginx/sites-enabled/default` made the configuration invalid. nginx tests its config before starting and refuses to start with an invalid one.

**Fix:**
Put the semicolon back, confirmed with `sudo nginx -t`, then started the service.

**How I verified:**
`nginx -t` reported success and `curl -I localhost` returned `HTTP/1.1 200 OK` with `Content-Length: 16` (my test page).

**Prevention / what to monitor:**
- Always run `sudo nginx -t` before every reload or restart.
- Use `reload` after a passing test. A reload with a bad config keeps the old working config running, so the site stays up. A restart does not.
- Keep a backup of the working config (I used `~/default.bak`) or keep `/etc/nginx` in version control.
- Alert when `nginx.service` enters the `failed` state.

**What I learned:**
- `nginx -t` gives the exact file and line, so I read that first instead of guessing.
- The reported line can be one line after the real typo, so I check the line above too.
- `restart` takes the site down if the new config is bad; testing first avoids that.

---

## Fault B: 403 Forbidden because nginx cannot read the content

### Round 1: web root folder set to `700`

**Symptom (what the "customer" would report):**
"The server is up but my site shows 403 Forbidden."

**Impact:**
All requests returned an error page from about 17:11:52 (permission change) until 17:13:57 (first 200 after the fix), about 2 minutes. nginx stayed `active (running)` the whole time, so a monitor that only checks "is the service up?" would not have noticed.

**Timeline (command → what I saw → what I concluded):**
1. `sudo chmod 700 /var/www/html` (the fault I introduced), then `sudo systemctl reload nginx`.
2. `systemctl status nginx` → `Active: active (running)`, reload succeeded → the service is healthy, so the problem is not a crash.
3. `curl -I localhost` → `HTTP/1.1 403 Forbidden` → nginx is answering but refusing to serve the page.
4. `sudo tail -n 5 /var/log/nginx/error.log` → `"/var/www/html/index.html" is forbidden (13: Permission denied)` → the operating system denied access (error 13).
5. `ps aux | grep nginx` → master process (PID 1415) runs as `root`; workers (PIDs 1438, 1439) run as `www-data` → `www-data` is the user that needs access.
6. `namei -l /var/www/html/index.html` → `drwx------ root root html`, then `index.html - Permission denied` → the folder allows only root, so `www-data` cannot enter it.

**Root cause:**
`/var/www/html` was set to `700` (owner only). The nginx workers run as `www-data`, which is neither the owner nor in the group. A folder without the execute (`x`) permission cannot be entered, so nothing inside it can be read.

**Fix:**
`sudo chmod 755 /var/www/html`

**How I verified:**
`curl -I localhost` → `HTTP/1.1 200 OK` at 17:13:57. `namei -l` showed `drwxr-xr-x root root html` and `-rw-r--r-- root root index.html`.

### Round 2 (variant): `index.html` set to `600`

**Impact:**
403 errors from about 17:15:29 until 17:17:26, about 2 minutes.

**Timeline (command → what I saw → what I concluded):**
1. `sudo chmod 600 /var/www/html/index.html`, then `sudo systemctl reload nginx`.
2. `curl -I localhost` → `HTTP/1.1 403 Forbidden` (17:15:34) → same symptom as round 1.
3. `sudo tail -n 5 /var/log/nginx/error.log` → `open() "/var/www/html/index.html" failed (13: Permission denied)` → the wording differs from round 1 (`open() ... failed` instead of `is forbidden`), which hints that the failure is now opening the file itself.
4. `namei -l /var/www/html/index.html` → every folder `drwxr-xr-x`, but the file is `-rw------- root root index.html` → this time the file is the blocker, not the folder.
5. I re-ran `sudo chmod 755 /var/www/html` → `curl -I localhost` still returned `403 Forbidden` at 17:16:51 → the folder was already `755`, so that command changed nothing. A fix has to match the cause.
6. `sudo chmod 644 /var/www/html/index.html`, then `sudo systemctl reload nginx` → `HTTP/1.1 200 OK` at 17:17:26.

**Root cause:**
The file `index.html` was set to `600` (owner read/write only), so the `www-data` worker could not read it even though the folder was fine.

**Fix:**
`sudo chmod 644 /var/www/html/index.html`

**How I verified:**
`curl -I localhost` → `HTTP/1.1 200 OK`; `namei -l` showed `-rw-r--r-- root root index.html`.

**Prevention / what to monitor (both rounds):**
- Keep web roots readable by the web server user: folders `755`, files `644`.
- After any deployment or permission change, run `namei -l <file>` and a `curl -I` test.
- Monitor HTTP status codes (a rise in 403s), not only whether the service is running.

**What I learned:**
- `active (running)` does not mean the site works; I always test with `curl`.
- The same 403 can have different causes (folder or file). `namei -l` shows which one, and the `error.log` wording gives a hint.
- When a fix does not work, I stop repeating it and re-read the evidence. In round 2 the second `chmod 755` did nothing because the folder was never the problem.

**Customer reply (Fault B):**

```
Hi Sam,

Thanks for the details. Here is what I found.

1. Your website was showing a "403 Forbidden" error even though the web server program was running.
2. The web server runs as a restricted user for security. A recent permissions change on the website folder stopped that user from opening it.
3. I changed the folder permissions so the web server can read your site's files again. The exact command was: sudo chmod 755 /var/www/html
4. To confirm it is fixed, open your site in a browser, or run: curl -I http://your-site and look for "200 OK".
5. Please avoid setting website folders to 700 (owner only). If you deploy new files, check that the folder stays at 755 and the files at 644.

If anything still looks wrong, please send the output of: ls -ld /var/www/html
```

---

## Fault C: nginx fails to start because port 80 is already in use

**Symptom (what the "customer" would report):**
"I tried to start nginx and it fails. Something else seems to be using the web port."

**Impact:**
nginx was stopped at 17:23:09 and could not be started until 17:30:33, about 7 minutes. In that time a different program answered on port 80: `curl -I localhost` returned `HTTP/1.0 200 OK` with `Server: SimpleHTTP/0.6 Python/3.14.4` and a 598-byte directory listing instead of my site. A "200 OK" alone would have looked healthy, so the `Server:` header is what exposed the wrong program.

**Timeline (command → what I saw → what I concluded):**
1. `sudo systemctl stop nginx` (17:23:09), then `sudo python3 -m http.server 80` in a second terminal → Python started serving on `0.0.0.0` port 80.
2. `curl -I localhost` → `HTTP/1.0 200 OK`, `Server: SimpleHTTP/0.6 Python/3.14.4` → port 80 is answered by Python, not nginx.
3. `sudo systemctl start nginx` (17:28:57) → `Job for nginx.service failed because the control process exited with error code.`
4. `systemctl status nginx` → `Active: failed (Result: exit-code)`; `ExecStartPre ... nginx -t ... status=0/SUCCESS` but `ExecStart ... status=1/FAILURE` → unlike fault A, the config test passed, and nginx failed when it actually started.
5. `journalctl -u nginx -n 20` → `bind() to 0.0.0.0:80 failed (98: Address already in use)` repeated five times, then `still could not bind()` at 17:28:59 → nginx retried a few times and gave up; another process holds port 80.
6. `sudo ss -tulpn | grep :80` → `tcp LISTEN 0 5 0.0.0.0:80 ... users:(("python3",pid=1739,fd=3))` → the process occupying the port is `python3`, PID 1739.

**Root cause:**
A Python test web server (`python3 -m http.server 80`, PID 1739) was already listening on port 80. Only one program can listen on a given address and port, so nginx's attempt to bind failed.

**Fix:**
Stopped the Python server with Ctrl+C (`Keyboard interrupt received, exiting.`). `sudo ss -tulpn | grep :80` then showed nothing, and I started nginx again with `sudo systemctl start nginx`.

**How I verified:**
`curl -I localhost` → `HTTP/1.1 200 OK` with `Server: nginx/1.28.3 (Ubuntu)` at 17:30:33 and again at 17:31:10. `sudo ss -tulpn | grep :80` showed nginx (PIDs 1809, 1810, 1811) listening on `0.0.0.0:80` and `[::]:80`.

**Prevention / what to monitor:**
- Before starting a service, check that its port is free: `sudo ss -tulpn | grep :<port>`.
- Do not leave test servers running on production ports.
- Identify the process with `ss` before killing anything, since it could be something important.
- Alert on a service failing to start, and check the `Server:` header or page content in health checks, not just the status code.

**What I learned:**
- `Address already in use` (error 98) means another process has the port, and `ss -tulpn` tells me which one and its PID.
- A `200 OK` is not proof that the right program answered; the `Server:` header showed it was Python.
- `ExecStartPre` passing but `ExecStart` failing points to a runtime problem (like a busy port) rather than a config error.

---

## Check: the command that revealed each cause

- **Fault A (syntax error):** `sudo nginx -t`
- **Fault B (permissions):** `namei -l /var/www/html/index.html` (with `error.log` as supporting evidence)
- **Fault C (port in use):** `sudo ss -tulpn | grep :80`

**General method:** symptom → reproduce → decide which layer (OS, service, app) → read logs → form a hypothesis → make one change → verify → document.
