# DNS / HTTP / nginx / firewall cheatsheet (Day 7)

## 1. Troubleshooting order (bottom to top)

A broken lower layer makes everything above it look broken, so go in this order and stop at the first failure.

| # | Command | Question |
|---|---|---|
| 1 | `ip a` | Do I have an IP? |
| 2 | `ip r` | Do I have a default route? |
| 3 | `ping -c 2 8.8.8.8` | Can I reach the internet by IP? (AWS gateway often ignores ping, skip it) |
| 4 | `dig example.com` | Does name resolution work? |
| 5 | `curl -v http://...` | Does the web request work? |
| 6 | `ss -tulpn` | Is anything listening on the port? |
| 7 | `sudo ufw status verbose` | Is the OS firewall blocking? |
| 8 | Logs | What does the service say? |

Outside the instance there is one more layer: the AWS **security group**. Use `tcpdump` to find out which side of the instance boundary the packet reaches.

---

## 2. Timeout vs refused vs error page

| What the client sees | Meaning | Look at |
|---|---|---|
| **Timeout** (slow, nothing back) | Packets dropped silently, or wrong IP/route | Security group, ufw `deny`, routing, DNS server not answering |
| **Connection refused** (instant) | Something answered "no" | Service not running, wrong port, ufw `reject` |
| **HTTP error page** (4xx/5xx) | The connection worked, the web server answered | nginx / app config and logs |

Quick test: `time curl --connect-timeout 5 http://host/`

---

## 3. HTTP status codes

| Code | Name | Plain meaning | First check |
|---|---|---|---|
| 200 | OK | Worked | n/a |
| 301 / 302 | Redirect | Go to another URL | `curl -L`, where does it point? |
| 400 | Bad Request | Malformed request | Client / proxy headers |
| 403 | Forbidden | Found it, will not serve it | File permissions, no index file |
| 404 | Not Found | Nothing at that path/site | Path, `root`, `server_name` (default site?) |
| 500 | Internal Server Error | App crashed | App logs |
| 502 | Bad Gateway | nginx fine, **backend dead or wrong** | Backend running? Right port? |
| 503 | Service Unavailable | Overloaded / maintenance | Load, backend health |
| 504 | Gateway Timeout | Backend too slow | Backend performance, timeouts |

First digit: 2 = success, 3 = redirect, 4 = client's fault, 5 = server's fault.

---

## 4. curl

| Command | Use |
|---|---|
| `curl URL` | Body only |
| `curl -I URL` | Headers only (HEAD) |
| `curl -i URL` | Headers + body |
| `curl -v URL` | Full conversation: `*` connect, `>` sent, `<` received |
| `curl -L URL` | Follow redirects |
| `curl --connect-timeout 5 URL` | Give up connecting after 5 s |
| `curl -4 ifconfig.me` | Show my public IPv4 |
| `curl --resolve a.test:80:127.0.0.1 http://a.test/` | Fake DNS for one request |
| `curl -H "Host: b.test" http://localhost/` | Set the Host header by hand |

Common exit codes: `6` cannot resolve host, `7` failed to connect (refused), `28` timeout, `35` TLS handshake error, `52` empty reply, `56` connection reset while receiving, `60` certificate problem.

---

## 5. nginx

```bash
sudo nginx -t                              # test syntax (does NOT prove the config is right)
sudo nginx -T | grep -n server_name        # print the config nginx actually loaded
sudo systemctl reload nginx                # apply config, no dropped connections
sudo systemctl restart nginx               # stop + start (interrupts users)
sudo systemctl status nginx
sudo tail -n 20 /var/log/nginx/error.log
sudo tail -n 20 /var/log/nginx/access.log
ls -l /etc/nginx/sites-enabled/            # symlinks, check they are not broken
```

After a reload, wait ~2 s before testing. Always test behaviour with `curl`, not only `nginx -t`.

**Virtual host skeleton**
```
server {
    listen 80;
    server_name a.test;
    root /var/www/site-a;
    index index.html;
}
```

**Reverse proxy skeleton**
```
server {
    listen 80;
    server_name app.test;
    location / {
        proxy_pass http://127.0.0.1:8000;
    }
}
```

nginx picks the site by the **Host header**. No match means the default site answers, which is the usual cause of "wrong site shows up".

**Access log line:** `client - - [time] "METHOD /path HTTP/1.1" status bytes "referrer" "user-agent"`. The default format has no Host, so a 200 does not prove the right site answered. `error.log` shows `server:` and `upstream:`.

---

## 6. DNS (systemd-resolved)

```bash
resolvectl status                          # which DNS server per interface
dig example.com                            # uses the configured resolver (via 127.0.0.53)
dig @8.8.8.8 example.com                   # bypass it, ask Google directly
dig +short example.com
sudo resolvectl dns ens5 192.0.2.1         # (lab) break DNS, not persistent
sudo resolvectl revert ens5                # undo, back to DHCP-provided DNS
resolvectl flush-caches
```

Plain `dig` fails but `dig @8.8.8.8` works: the **configured resolver** is the problem. Do not hand-edit `/etc/resolv.conf` (managed link). A timeout of 15 s is 3 tries x 5 s.

| `dig` status | Meaning |
|---|---|
| `NOERROR` with answers | Fine |
| `NOERROR`, 0 answers | Name exists, no record of that type |
| `NXDOMAIN` | Name does not exist (typo, wrong zone) |
| `SERVFAIL` | Resolver could not get a valid answer (broken upstream, DNSSEC) |
| `REFUSED` | Server will not answer you |
| `communications error ... timed out` | Nobody answered (dead resolver, firewall) |

---

## 7. Firewall

```bash
sudo ufw status verbose
sudo ufw allow 22/tcp          # ALWAYS before enabling
sudo ufw enable
sudo ufw allow 80/tcp
sudo ufw deny 80/tcp           # silent drop -> client times out
sudo ufw reject 80/tcp         # active refusal -> client sees "connection refused" instantly
sudo ufw delete deny 80/tcp
sudo ufw disable
```

- `deny` = DROP (timeout). `reject` = RESET (refused).
- Default is `deny (incoming)`: deleting a deny rule does **not** open the port. Add an `allow`.
- ufw does not filter loopback, so `curl localhost` works while the outside is blocked.
- Two firewalls on EC2: **security group** (outside the instance) and **ufw** (inside). Both look like a timeout.

---

## 8. tcpdump

```bash
sudo tcpdump -nn -i ens5 port 80
```

| Flag | Meaning |
|---|---|
| `[S]` | SYN, "can I connect?" |
| `[S.]` | SYN-ACK, "yes" |
| `[.]` | ACK |
| `[P.]` | Data (request or response) |
| `[F.]` | FIN, closing politely |
| `[R.]` | RST, refusing / aborting |

| What the capture shows | Meaning |
|---|---|
| Nothing at all | Packets never arrived: security group / network |
| Repeated `[S]`, no `[S.]` | Arrived, dropped inside: ufw deny, service not accepting |
| `[S]` then `[R.]` | Actively refused: ufw reject, nothing listening |
| Full `S, S., ., P.` exchange | Network is fine, look at the application |

Repeated SYNs with growing gaps (35 ms, 70, 140, ...) are TCP exponential backoff, which is why a dropped connection "hangs".

---

## 9. Common errors: what they mean and what to do

### nginx

| Error / symptom | Meaning | First check / fix |
|---|---|---|
| `[warn] conflicting server name "x" on 0.0.0.0:80, ignored` | Two `server` blocks claim the same name; the second is ignored | `grep -n server_name /etc/nginx/sites-enabled/*`, fix the duplicate |
| `[emerg] directive "root" is not terminated by ";"` | Missing semicolon | Go to the file and line number in the message |
| `[emerg] unexpected "}"` | Missing `;` or `{` earlier | Check the line above the one reported |
| `[emerg] unknown directive "..."` | Typo in a directive name | Fix spelling |
| `[emerg] open() "/etc/nginx/sites-enabled/x" failed (2: No such file or directory)` | Broken symlink | Recreate with `ln -s` using the absolute path |
| `[emerg] bind() to 0.0.0.0:80 failed (98: Address already in use)` | Another program owns port 80 | `sudo ss -tulpn \| grep :80` |
| `connect() failed (111: Connection refused) while connecting to upstream` (**502**) | Backend not listening on that address | Compare `upstream:` in the log with `ss -tulpn` |
| `upstream timed out (110: Connection timed out)` (**504**) | Backend too slow or unreachable | Backend load, `proxy_read_timeout` |
| `no live upstreams` (**502**) | All servers in an upstream group are marked down | Check each backend |
| `open() ".../file" failed (13: Permission denied)` (**403**) | nginx user cannot read the file/dir | `ls -ld` each folder in the path, `chmod`/`chown` |
| `directory index of ".../" is forbidden` (**403**) | No index file and autoindex off | Add `index.html` or fix `index` |
| `open() ".../file" failed (2: No such file or directory)` (**404**) | Wrong path or `root` | `ls` the path, check `root` |
| `nginx -t` OK but behaviour wrong | Syntax is valid, meaning is not | `curl`, `nginx -T`, compare ports/names |
| Change has no effect | Not saved, not reloaded, not enabled, or reload race | `grep` the file, reload, `sleep 2`, `ls -l sites-enabled` |

### curl

| Error | Meaning | Look at |
|---|---|---|
| `(6) Could not resolve host` | DNS failed | `dig`, `resolvectl status`, typo in name |
| `(7) Failed to connect ... Connection refused` | Nothing listening / reject | `ss -tulpn`, service status, ufw |
| `(28) Connection timed out` | Dropped packets | Security group, ufw deny, routing |
| `(52) Empty reply from server` | Server closed without answering | App crash, wrong protocol (http vs https) |
| `(60) SSL certificate problem` | TLS certificate not trusted / expired / wrong name | Certificate details (Lab 3) |

### DNS

| Error | Meaning | Look at |
|---|---|---|
| `communications error to 127.0.0.53#53: timed out` | The local stub got no answer from the configured DNS server | `resolvectl status`, then `dig @8.8.8.8` to compare |
| `NXDOMAIN` | Name does not exist | Spelling, record exists in the zone? |
| `SERVFAIL` | Resolver failed to get an answer | Try another resolver, check the domain's nameservers |

### SSH / EC2

| Error | Meaning | Look at |
|---|---|---|
| `Connection timed out` | Packets dropped | Security group source = your **current** IP (`curl -4 ifconfig.me`), instance running? |
| `Connection refused` | Reached the host, sshd not listening | `systemctl status ssh` via console, ufw |
| `Permission denied (publickey)` | Wrong user or wrong key | User (`ubuntu` on Ubuntu AMIs), correct `.pem`, `ssh -i key.pem -v` |
| `UNPROTECTED PRIVATE KEY FILE!` | Key file permissions too open | `chmod 400 key.pem` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | New server at a known IP | `ssh-keygen -R <ip>` (only if you expect the change) |
| `Connection to x closed by remote host` | Reboot, idle timeout, or network drop | `uptime -s`, `journalctl --list-boots`; use `-o ServerAliveInterval=30` |
| Locked out after `ufw enable` | SSH was not allowed first | Console / user-data fix, or launch from the AMI |

### Python test server

| Error | Meaning | Fix |
|---|---|---|
| `OSError: [Errno 98] Address already in use` | Port already taken | `ss -tulpn \| grep :8000`, `kill %1` or pick another port |
| `curl: (7)` right after starting it in the background | Not started yet | `sleep 1` before testing |

---

## 10. Things that do not survive a reboot

| Survives | Does not survive |
|---|---|
| Files in `/etc` (nginx configs), enabled services (`systemctl enable`), installed packages | `resolvectl dns ...` changes, background jobs (`&`), most of `/tmp`, manual `ip` changes |

A temporary fix that "worked" can vanish after a reboot. Make the fix permanent in config, or say it is temporary.

---

## 11. EC2 / AMI reminders

- **Create image** reboots the instance by default; tick **No reboot** to avoid it (copy may be less consistent).
- A new instance from an AMI has the same software but a **new public IP**.
- Stop an instance (not Terminate) to keep the disk; the public IP changes on the next start unless you use an Elastic IP.
- Security group source `My IP` goes stale when your IP changes. Check with `curl -4 ifconfig.me`.
- Keep notes in GitHub, not only on the instance.

---

## 12. Customer reply template

1. What I found (plain language)
2. Root cause
3. What I changed
4. How you can verify (one command or one click)
5. What to send me if it still fails
