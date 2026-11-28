# Incident 11: Extra capstone run - website returns 403 Forbidden (web folder permission)

**Date:** Sat 28 Nov 2026 (times below are UTC)
**Host:** lab1 (Ubuntu, AWS EC2)
**Type:** Capstone-style ticket (blind fault, injected by my own script)
**Status:** Resolved and verified

**Blindness note:** This run was properly blind. The script printed nothing, and I did not read the script or the fault record until after the fix.

---

## Summary

The website returned `403 Forbidden` even though nginx was running. The directory `/var/www/html` had mode `drwx------` (700) and was owned by root, so the nginx worker process, which runs as `www-data`, could not enter it and refused every request. I changed the directory to `755`, and the page came back with `200 OK` on the server. Time from fault (05:54:39 per the fault record) to verified local fix (05:59:44) was about 5 minutes.

## Symptom (as a customer would say it)

Ticket as given to myself: "Customer says the server is not behaving normally."
Reworded from the evidence: "Our website shows 403 Forbidden."

## Environment

- Ubuntu on EC2 (instance `lab1`), nginx 1.28.3
- Static page `/var/www/html/index.nginx-debian.html`; nginx workers run as `www-data` (`user www-data;`)

## Timeline

| # | Time (UTC) | Command | What I saw | What I concluded |
|---|------------|---------|-----------|------------------|
| 1 | 05:54:49 | `curl -I localhost` | `403 Forbidden`, `Server: nginx/1.28.3` | nginx is running and answering, but refusing access. This is an access problem, not a down service |
| 2 | 05:55:14 | `curl -I http://52.66.250.35` (from my Mac) | `403 Forbidden` | Same from outside, so the network path works and nginx is reachable |
| 3 | ~05:55:40 | `systemctl status nginx.service` | `active (running)` since 05:54:39; pre-start config test `status=0/SUCCESS` | The service and its config are healthy |
| 4 | 05:55-05:59 | `journalctl -xeu nginx.service` | Only normal stop and start lines, no errors | nginx's service log does not hold the refusal; the reason must be in nginx's own error log |
| 5 | 05:55-05:59 | `df -h` (after a typo, `df -h/`) | `/` at 54% used, 3.1G free | Full disk ruled out |
| 6 | 05:55-05:59 | `namei -l /var/www/html/index.html` | `drwx------ root root html`, then `index.html - Permission denied` | The path is blocked at the directory `html`: only root can enter it |
| 7 | 05:55-05:59 | `sudo tail -n 5 /var/log/nginx/error.log`; `grep -E '^user' /etc/nginx/nginx.conf` | `"/var/www/html/index.html" is forbidden (13: Permission denied)` for the requests at 05:54:49 and 05:55:14; `user www-data;` | **Confirmed from nginx's side:** the worker runs as `www-data`, not root, so it is refused |
| 8 | 05:59:44 | `sudo chmod 755 /var/www/html`, then `namei -l /var/www/html/index.nginx-debian.html`, then `curl -I localhost` | Directory now `drwxr-xr-x`, file `-rw-r--r--`; `200 OK` | One change applied and verified on the server |

Times come from `Date:` headers and systemd timestamps. Rows with a range were run between the two timestamps around them.

## Time limits

| Phase | Limit | Actual |
|-------|-------|--------|
| Diagnose and fix | 45 min | about 5 min (05:54:49 first symptom to 05:59:44 verified locally) |
| Customer reply | 20 min | about 10-15 min (reviewing and editing the draft) |
| Internal note / KB | 20 min | about 10-15 min (reviewing and editing the draft) |

## Root cause

`/var/www/html` was owned by root with mode `700` (`drwx------`). nginx's worker runs as `www-data`, which is "other" to that directory. To serve a file, a user needs execute (`x`, meaning permission to enter) on every directory in the path and read (`r`) on the file. `www-data` had neither on `html`, so nginx returned `403`. In this exercise my own script changed the mode. In a real ticket I would ask what ran on the server around 05:54 (a deployment, a clean-up, an ownership or permission change).

## Why the symptom looked like "forbidden", not "down"

The network, the security group and the service were all fine: the request reached nginx and nginx answered. That is why the reply was an HTTP status (`403`) and not a connection error. A connection error would mean nothing was listening; a timeout would point to a firewall. The status code tells me which layer to look at.

## Fix

1. Found the blocked directory with `namei -l`
2. Confirmed the reason from nginx's error log and the user nginx runs as
3. Changed only that directory: `sudo chmod 755 /var/www/html`

## Verification

- `namei -l /var/www/html/index.nginx-debian.html`: every directory `drwxr-xr-x`, file `-rw-r--r--`, no `Permission denied`
- `curl -I localhost`: `200 OK` (05:59:44)
- `curl -I http://52.66.250.35` from my Mac (06:10:14, after the fix): `200 OK`
- Fault record `/root/.fault` read after the fix: `7 2026-11-28T05:54:39Z`, matching my diagnosis
- After `sudo /root/restore.sh`, `curl -I localhost` returned `200 OK` (06:10:47): the server is back to its clean baseline

## Hypotheses I checked and ruled out

| Hypothesis | How I checked | Result |
|------------|---------------|--------|
| nginx stopped or crashed | `systemctl status`: `active (running)` | Ruled out |
| Bad nginx configuration | Service started; pre-start `nginx -t` exited 0 | Ruled out |
| Network or security group | The `403` came from nginx itself, from the server and from my Mac | Ruled out |
| Full disk | `df -h`: 54% used, 3.1G free | Ruled out |
| The index file's own permission | After the fix the file is still `-rw-r--r--` and I never changed it | Ruled out: the file was fine |
| Directory permission blocks `www-data` | `namei -l`, nginx error log, `user www-data;` | **Confirmed** |

## What I got wrong / what I learned

- **I first blamed the file.** I wrote that `index.html` lacked permission to "execute or write". That was wrong. `namei` showed the block at the directory `html`, and the file's `Permission denied` was only a consequence. A web server needs `x` on each directory and `r` on the file; it does not need write access.
- **The file name.** The log names `index.html` because nginx tries that name first; the page that actually exists is `index.nginx-debian.html`.
- **Which log to read.** `journalctl -u nginx` showed nothing useful. The refusal is recorded in `/var/log/nginx/error.log`.
- **`namei -l <path>`** is the fastest way to see where a path stops being accessible.
- **Typo:** `df -h/` needs a space (`df -h /`).
- **Do not "fix" with 777.** One targeted change (`755`) was enough.

## Prevention (what I would recommend to a customer)

- After any deployment or ownership change, check the web path with `namei -l`
- Use directories `755` and files `644`, owned by the deploy user; avoid `chmod -R 777`
- Add an external check that expects `200` so a `403` raises an alert, not just a total outage

---

# Customer reply: Extra capstone run (403 Forbidden)

**Ticket:** Our website shows 403 Forbidden
**Related incident:** `incidents/11-capstone-perms.md`

**Subject: Resolved: your website was showing "403 Forbidden"**

Hi,

Thanks for reporting this. Your website was showing a "403 Forbidden" message because of a permission setting on the folder that holds your web pages. The web server was running, but the setting only allowed the main administrator account to open that folder, so the web server was turned away.

I changed the folder's permission so the web server can read it again. Your page now loads normally, both from the server itself and from the internet.

I cannot tell how the setting changed. If anyone ran a clean-up, a deployment or a permission change on the server around 05:54 UTC today, that is the likely source. Let me know and I can help make sure it does not happen again.

To avoid a repeat, check that the web server can read your website's folder after any update, and consider an automatic check that alerts you if the site stops loading normally.

Please reply if you notice anything else.

Kind regards,
Sejal

---

# KB article: nginx returns 403 Forbidden because of directory permissions

## Title

nginx returns `403 Forbidden` with `(13: Permission denied)` in the error log

## Environment

- Ubuntu Server (tested on 24.04 LTS), AWS EC2
- nginx 1.28.x serving a static site from `/var/www/html`
- nginx worker processes run as `www-data`

## Symptom

- `curl -I` or a browser shows `HTTP/1.1 403 Forbidden`, both on the server and from other machines.
- `systemctl status nginx` shows `active (running)`.
- `/var/log/nginx/error.log` contains a line like:
  `"/var/www/html/index.html" is forbidden (13: Permission denied)`

## Cause

The nginx worker runs as the user named in the `user` directive (here `www-data`). To serve a file, that user needs **execute** on every directory in the path (permission to enter it) and **read** on the file. If any directory blocks "other" users, for example `drwx------ root root`, nginx cannot reach the file and returns 403. Write permission is not needed.

Not every 403 is this problem. Check the message in the error log first:

1. `(13: Permission denied)`: this article.
2. `directory index of "..." is forbidden`: there is no index file in that folder and directory listing is off.
3. `access forbidden by rule`: a `deny` rule in the nginx configuration.

## Solution

1. Confirm the symptom and that nginx is running.

```bash
curl -I localhost
systemctl status nginx --no-pager
```

2. Read the error log. The message tells you which cause applies.

```bash
sudo tail -n 20 /var/log/nginx/error.log
```

3. Find out which user nginx runs as.

```bash
grep -E '^user' /etc/nginx/nginx.conf
```

4. Check every directory in the path to the file.

```bash
namei -l /var/www/html/index.nginx-debian.html
```

Look for the first line where the owner, group and permission bits would stop that user, such as `drwx------ root root html`.

5. Change only what blocks access. For a web directory:

```bash
sudo chmod 755 /var/www/html
```

Directories are normally `755` and files `644`. Do not use `777`.

## Verification

1. `namei -l /var/www/html/index.nginx-debian.html` shows no `Permission denied`.
2. `curl -I localhost` returns `HTTP/1.1 200 OK`.
3. From another machine, `curl -I http://<server-ip>` returns `200 OK`.

## Notes

- The refusal appears in `/var/log/nginx/error.log`, not in `journalctl -u nginx`.
- A `403` means the request reached nginx. A "connection refused" means nothing is listening, and a long wait ending in a timeout usually means a firewall or security group.
- The file name in the error log may be the first name nginx tries (`index.html`), not the one that exists on disk. `namei -l` on the real file shows the same blocked directory.

## Prevention

- Check the web path with `namei -l` after any deployment, ownership change or permission change.
- Keep directories `755` and files `644`, owned by the deploy user.
- Add an external uptime check that expects `200`, so a `403` raises an alert.