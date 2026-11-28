# Incident 10: Capstone 2 - nginx will not start (invalid config line)

**Date:** Sat 28 Nov 2026 (times below are UTC)
**Host:** lab1 (Ubuntu, AWS EC2)
**Type:** Capstone ticket (fault injected by my own script)
**Status:** Resolved and verified

**Blindness note:** This ticket was not fully blind. The injecting script printed `Job for nginx.service failed...` on my terminal, which gave the fault away. I have since silenced the script's output for later tickets. I still followed the full method (reproduce, find the layer, read logs, one change, verify) so the diagnosis, fix, reply and KB article are real practice.

---

## Summary

nginx would not start because line 1 of `/etc/nginx/sites-enabled/default` contained an invalid directive, `this_is_a_typo;`. nginx tests its configuration before starting, the test failed, and no web server was running, so the website was unreachable. I removed that one line, confirmed `nginx -t` passed, started nginx, and verified from the server and from outside. Time from fault (05:44:26) to verified fix (05:50:01) was about 6 minutes.

## Symptom (as a customer would say it)

"Our website is down and will not load."

## Environment

- Ubuntu on EC2 (instance `lab1`), nginx 1.28.3 managed by systemd
- Site config: `/etc/nginx/sites-enabled/default`

## Timeline

| # | Time (UTC) | Command | What I saw | What I concluded |
|---|------------|---------|-----------|------------------|
| 1 | 05:44:26 | `sudo ./breakit.sh 3` | Terminal printed `Job for nginx.service failed...` | The script's own output exposed an nginx start failure (not blind). Fault injected at 05:44:26 |
| 2 | ~05:44:39 | `systemctl status nginx.service` | `failed`; pre-start `nginx -t` exited with status 1; log line `unknown directive "this_is_a_typo" in /etc/nginx/sites-enabled/default:1` | The service never started. The cause is in the config, and the log names the file and line |
| 3 | 05:44-05:48 | `journalctl -xeu nginx.service` | Same `[emerg]` line, start job failed | Confirms the status output; no other error hidden |
| 4 | 05:44-05:48 | `curl -I http://52.66.250.35` (from my Mac) | `curl: (7) Failed to connect ... port 80 after 47 ms` | A fast failure means the connection was refused, so nothing is listening. A timeout would have pointed to the security group |
| 5 | 05:44-05:48 | `systemctl restart` (no unit name), then `systemctl restart nginx.service` without `sudo` | `Too few arguments`, then a password prompt | My typing mistakes; no change was made. On EC2 the `ubuntu` user normally has no password, so the prompt is a dead end. Use `sudo` |
| 6 | 05:44-05:48 | `sudo systemctl restart nginx.service` | Failed again with the same error | Hypothesis "transient failure, a restart will fix it" rejected: the config is still invalid |
| 7 | 05:48:30 | `sudo nginx -t` and `sudo head -5 /etc/nginx/sites-enabled/default` | `unknown directive "this_is_a_typo" ... :1`; line 1 of the file is `this_is_a_typo;` | **Root cause confirmed two ways:** the test output and the file itself |
| 8 | 05:48-05:49 | `sudo sed -i --follow-symlinks '1d' /etc/nginx/sites-enabled/default`, then `head -3`, then `sudo nginx -t` | File now starts with the `##` comment; `syntax is ok`, `test is successful` | One change applied; config proven valid before I started nginx |
| 9 | 05:49:35 | `sudo systemctl start nginx`, `systemctl status nginx --no-pager`, `curl -I localhost` | `active (running)`; `200 OK` | Fixed on the server |
| 10 | 05:50:01 | `curl -I http://52.66.250.35` (from my Mac) | `200 OK` | Fixed from outside too |
| 11 | 05:50:36 | `sudo cat /root/.fault`, `sudo /root/restore.sh`, `curl -I localhost` | Fault record `6 2026-11-28T05:44:26Z`; restore ran cleanly; `200 OK` | My diagnosis matched the injected fault; system back to baseline |

Times come from `Date:` headers and systemd timestamps. Rows with a range were run between the two timestamps around them.

## Time limits

| Phase | Limit | Actual |
|-------|-------|--------|
| Diagnose and fix | 45 min | about 5 min (05:44:26 to 05:49:35), verified from outside at 05:50:01 |
| Customer reply | 20 min | about 10-15 min (reviewing and editing the draft) |
| Internal note / KB | 20 min | about 10-15 min (reviewing and editing the draft) |

## Root cause

An invalid line, `this_is_a_typo;`, was at line 1 of `/etc/nginx/sites-enabled/default`. nginx runs a configuration test (`nginx -t`) before it starts. The test failed, so systemd reported the service as failed and nothing served web traffic. In this exercise my own script added the line. In a real ticket I would ask the customer what they changed just before the outage, because a recent config edit is the most likely cause.

## Why this became an outage

nginx reads its whole configuration at start. One invalid line makes the whole configuration invalid, so nginx refuses to start. A `reload` with a bad config normally keeps the old settings running, but a restart or fresh start does not, which is why the site went down.

## Fix

1. Confirmed the error with `sudo nginx -t` and looked at line 1 of the file (`head -5`)
2. Removed only that line: `sudo sed -i --follow-symlinks '1d' /etc/nginx/sites-enabled/default`
3. Ran `sudo nginx -t` and waited for `syntax is ok` and `test is successful` before starting anything
4. Started nginx: `sudo systemctl start nginx`

## Verification

- `systemctl status nginx --no-pager`: `active (running)`
- `curl -I localhost` on the server: `200 OK`
- `curl -I http://52.66.250.35` from outside: `200 OK`
- Fault record `/root/.fault` read after the fix: `6`, matching my diagnosis

## Hypotheses I checked and ruled out

| Hypothesis | How I checked | Result |
|------------|---------------|--------|
| Temporary failure that a restart fixes | `sudo systemctl restart nginx.service` | Ruled out: failed with the same error |
| Security group or network blocking traffic | `curl` from outside failed in 47 ms (refused, not a timeout) | Ruled out as the cause: nothing was listening |
| Service masked or disabled | `systemctl status`: `Loaded ... enabled` | Ruled out |
| Invalid configuration | `nginx -t`, log line and `head` of the file | **Confirmed** |

## What I got wrong / what I learned

- **The ticket was not blind.** My script printed an nginx error, which told me the layer before I started. I fixed the script so it prints nothing.
- **I typed `systemctl restart` with no unit, then without `sudo`.** On EC2, use `sudo systemctl ...`; the password prompt cannot be answered.
- **Restarting did not help.** When the log already names the file and line, fix the cause; do not retry the same action.
- **Test before you start.** `nginx -t` should pass before any start, restart or reload.
- **`sed -i` and symlinks.** `sites-enabled/default` is a symlink. Plain `sed -i` would replace it with a regular file, so I used `--follow-symlinks`.
- **Pager tip.** `journalctl -xeu` opens a pager; use `--no-pager -n 30` to print and return to the prompt.

## Prevention (what I would recommend to a customer)

- Always run `sudo nginx -t && sudo systemctl reload nginx` instead of a bare restart
- Keep a backup before editing config: `sudo cp file file.bak`
- Keep config files in version control so a bad change is easy to find and undo
- Add an external check that alerts when the site stops returning `200`

---

# Customer reply: Capstone 2

**Ticket:** Our website is down and will not load
**Related incident:** `incidents/10-capstone2.md`

**Subject: Resolved: your website is back online**

Hi,

Thanks for reporting this. Your website was down because the web server software could not start. One of its settings files contained a line it did not recognise, and the server refuses to start when its settings contain an error.

I removed that line, checked that the settings were valid, and started the server again. Your website now loads normally, both from the server itself and from the internet.

I cannot tell how the line got there. If you or your team edited the website's settings shortly before about 05:44 UTC today, that is the likely source. Let me know and I can help make sure it does not happen again.

To avoid a repeat, run the web server's built-in settings check before restarting it, and keep a backup copy of the file before editing it.

Please reply if you notice anything else.

Kind regards,
Sejal

---

# KB article: nginx fails to start with "unknown directive"

## Title

nginx fails to start: `unknown directive` in a configuration file

## Environment

- Ubuntu Server (tested on 24.04 LTS), AWS EC2
- nginx 1.28.x managed by systemd

## Symptom

- The website is unreachable.
- `curl` from another machine fails immediately with "Couldn't connect" (connection refused), not after a long wait.
- `systemctl status nginx` shows `failed`.
- `systemctl restart nginx` fails with `Job for nginx.service failed because the control process exited with error code`.

## Cause

nginx checks its configuration before it starts. A directive that is misspelled or does not exist (for example a typo) makes that check fail, so nginx does not start. The error message names the file and the line.

## Solution

1. Look at the service state and the error.

```bash
systemctl status nginx --no-pager
```

2. Run the configuration test. It prints the file and line number of the problem.

```bash
sudo nginx -t
```

Example output: `unknown directive "this_is_a_typo" in /etc/nginx/sites-enabled/default:1`

3. Look at the lines around the one it names.

```bash
sudo sed -n '1,10p' /etc/nginx/sites-enabled/default
```

4. Make a backup, then fix or remove only that line.

```bash
sudo cp /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/default.bak
sudo nano /etc/nginx/sites-enabled/default
```

5. Test again. Repeat until you see `syntax is ok` and `test is successful`. Do not start nginx before this passes.

```bash
sudo nginx -t
```

6. Start nginx.

```bash
sudo systemctl start nginx
```

## Verification

1. Confirm the service is running:

```bash
systemctl status nginx --no-pager
```

Expected: `active (running)`.

2. Confirm it answers locally:

```bash
curl -I localhost
```

Expected: `HTTP/1.1 200 OK`.

3. From another machine, run `curl -I http://<server-ip>` and expect `200 OK`.

## Notes

- A fast "connection refused" means nothing is listening. A long wait followed by a timeout usually points to a firewall or security group instead.
- `/etc/nginx/sites-enabled/` often contains symlinks. If you edit with `sed -i`, add `--follow-symlinks`, otherwise `sed` replaces the symlink with a regular file.
- `journalctl -xeu nginx.service --no-pager -n 30` shows the same error if `nginx -t` is not available.
- Restarting again without fixing the file will not help.
- Do not keep backups inside /etc/nginx/sites-enabled/. nginx loads every file in that folder (include /etc/nginx/sites-enabled/*;), so a leftover default.bak becomes a second configuration and can cause conflicts such as duplicate default_server errors. If you already left one there, move it out with sudo mv /etc/nginx/sites-enabled/default.bak ~/, then run sudo nginx -t.

## Prevention

- Run `sudo nginx -t && sudo systemctl reload nginx` for every change.
- Keep a backup before editing config, stored outside the nginx include folders: `sudo cp /etc/nginx/sites-enabled/default ~/default.bak`
- Keep configuration in version control.
- Monitor the website from outside and alert on failures.