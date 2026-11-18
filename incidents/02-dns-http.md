# Incident 02: DNS, firewall and reverse-proxy faults on an EC2 web server

**Date / environment:** 2026-11-18 · EC2 instance `lab1` (ap-south-1) · Ubuntu 26.04.1 LTS · nginx 1.28.3 · systemd-resolved · ufw · tested from a Mac with `ssh` and `curl`

**Summary:** Four faults on one web server, all of which looked like "the website is down" to a user:

| # | Fault | User sees | Type |
|---|---|---|---|
| A | Dead DNS resolver | Names do not resolve, `dig` hangs 15 s | Injected |
| B1 | No inbound rule for port 80 in the AWS security group | Site times out from outside | **Unplanned, real** |
| B2 | ufw `deny` / `reject` on port 80 | Timeout / instant "connection refused" | Injected |
| C | Wrong `proxy_pass` port | 502 Bad Gateway | Injected |

**Layer order used for every fault (bottom to top):**
`ip a` → `ip r` → `ping 8.8.8.8` → `dig` → `curl -v` → `ss -tulpn` → `ufw status` → logs

---

## Fault A: dead DNS resolver

**Symptom (what the customer would report):** "My server cannot reach any website by name, but it was fine yesterday."

**Impact:** Everything that uses a hostname fails: `apt`, `curl`, application calls to APIs.

**Timeline**

| Command | What I saw | What I concluded |
|---|---|---|
| `resolvectl status` (baseline) | DNS server `172.31.0.2` on `ens5` | Normal state recorded |
| `sudo resolvectl dns ens5 192.0.2.1` | (fault injected) | n/a |
| `time dig example.com` | 3x `communications error to 127.0.0.53#53: timed out`, `real 0m15.028s` | Local stub is not getting an answer; 3 tries x 5 s |
| `ping -c 2 8.8.8.8` | 0% loss | Layers 1-3 fine, internet reachable by IP |
| `dig @8.8.8.8 example.com` | Answer in 8 ms | DNS itself works, so my **configured resolver** is the problem |
| `resolvectl status` | DNS server `192.0.2.1` | Root cause confirmed |

**Root cause:** The interface was pointed at a DNS server that never replies.

**Fix:** `sudo resolvectl revert ens5` then `resolvectl flush-caches`.

**How I verified:** `dig +short example.com` returned two addresses instantly; `resolvectl status` showed `172.31.0.2` again.

**Prevention / what to monitor:** Alert on DNS lookup time. Do not hand-edit `/etc/resolv.conf` (it is managed by systemd-resolved). Remember that `resolvectl dns` changes are **not persistent**: a reboot clears them.

---

## Fault B1: security group had no rule for port 80 (unplanned)

**Symptom:** `curl http://<public-ip>/` from my Mac timed out after 5 s.

**Impact:** The site was unreachable from outside while the service itself was healthy.

**Timeline**

| Command | What I saw | What I concluded |
|---|---|---|
| `curl -v --connect-timeout 5 http://<ip>/` from the **instance itself** | Timeout | Invalid test: an instance often cannot reach its own public IP. Test from outside, use `localhost` inside |
| Same curl from the Mac | Timeout | Real failure |
| `sudo ufw status` | `inactive` | The OS firewall is not the cause |
| `sudo tcpdump -nn -i ens5 port 80` during the Mac curl | **No packets at all** | Traffic never reached the instance, so the block is outside it |
| Console: security group inbound rules | No HTTP / port 80 rule | Root cause |
| After adding HTTP from My IP | `200 OK`; tcpdump showed the full handshake | Fixed |

**Root cause:** The security group only allowed SSH. There was no inbound rule for TCP port 80.

**Fix:** Added an inbound rule: HTTP (80), source = my IP only.

**How I verified:** `curl` from the Mac returned `hello from lab1`; tcpdump showed SYN, SYN-ACK, ACK, then the GET and the 200 response.

**Prevention:** When a new service needs to be reachable, open its port in the security group at the same time. Use `tcpdump` on the instance to tell "never arrived" (security group / network) from "arrived but unanswered" (OS firewall / service).

---

## Fault B2: ufw deny and reject on port 80

**Symptom:** Site times out from outside, but `curl localhost` on the server works.

**Timeline**

| Step | Mac curl result | tcpdump on lab1 | Meaning |
|---|---|---|---|
| `ufw deny 80/tcp` | Timeout | SYN repeated 12 times from the same source port, no reply; retries back off exponentially (~35 ms, then doubling) | Packet **arrives** and is silently dropped |
| `ufw delete deny` + `ufw reject 80/tcp` | `Connection refused` in **51 ms** | Reset sent back | lab1 actively refuses |
| `ufw delete reject` only | Timeout again | n/a | Default policy is `deny (incoming)`; deleting a deny rule does not allow anything |
| `ufw allow 80/tcp` | `200 OK` | Full handshake | Fixed |

**Server-side evidence for the deny case:** `systemctl status nginx` active, `ss -tulpn | grep :80` showed nginx on `0.0.0.0:80` and `[::]:80`, `curl -I http://localhost` returned 200 (ufw does not filter loopback). So the service is healthy and the block is the firewall.

**Root cause:** ufw rule on port 80.

**Fix:** `sudo ufw allow 80/tcp` (and `ufw disable` at the end of the lab).

**Prevention:** Always `ufw allow 22/tcp` **before** `ufw enable`. Test firewall changes from outside the host, not from localhost.

---

## Fault C: wrong proxy_pass port

**Symptom:** `curl -i http://app.test/` returns `502 Bad Gateway`.

**Timeline**

| Command | What I saw | What I concluded |
|---|---|---|
| `nginx -t` after the edit | `syntax is ok` | Syntax check cannot catch a wrong port |
| `curl -i` | `HTTP/1.1 502 Bad Gateway`, `Server: nginx` | nginx is alive; the problem is behind it |
| `tail /var/log/nginx/error.log` | `connect() failed (111: Connection refused) while connecting to upstream ... upstream: "http://127.0.0.1:8001/"` | nginx is trying port **8001** |
| `ss -tulpn \| grep 800` | Only `127.0.0.1:8000` (python3) listening | Backend is on 8000 |
| `nginx -T \| grep proxy_pass` | `proxy_pass http://127.0.0.1:8001;` | Loaded config confirms the mismatch |

**Root cause:** `proxy_pass` pointed at 8001; the backend listens on 8000.

**Fix:** Set `proxy_pass http://127.0.0.1:8000;`, `nginx -t`, `systemctl reload nginx`, wait 2 s.

**How I verified:** `curl` returned `backend says hi`.

**Same 502, two causes (both seen today):**

| | Backend stopped | Wrong port |
|---|---|---|
| Port in the error log | 8000 | 8001 |
| `ss` on 8000 | Nothing listening | Listening |
| Fix | Start the backend | Correct `proxy_pass` |

Restarting nginx fixes neither.

**Prevention:** After any config edit, test the behaviour with `curl`, not just `nginx -t`. Compare the port in the log with `ss`.

---

## Other issues met during the day

- **`conflicting server name "a.test" ... ignored`:** I copied `site-a` to `site-b` and left `server_name a.test`. `nginx -t` passed, but `b.test` served the default site. Fixed by setting `server_name b.test;`. A syntax check can pass while the config is wrong.
- **`OSError: [Errno 98] Address already in use`:** I started a second backend while the first held port 8000. One program per port.
- **Reload race:** `curl` straight after `systemctl reload` sometimes hit old workers. Add `sleep 2`.
- **Reboot mid-lab:** SSH dropped. `journalctl --list-boots` showed boot -1 ending 07:45:09 and the next starting 07:45:36 (a ~27 s gap, so a reboot, not a stop/start; public IP unchanged). Suspected cause: creating an AMI reboots the instance by default. Not yet confirmed against the AMI creation time. Effects: the DNS override, the background backend and `/tmp` content were lost. nginx and its `/etc` config survived.

---

## Customer replies

**For Fault B1 (security group):**

> Hi Sam,
> Thanks for the details. Here is what I found.
> 1. Your website is running correctly on the server, but visitors could not reach it.
> 2. The cloud firewall (security group) only allowed remote login (SSH) and had no rule for web traffic on port 80.
> 3. I added a rule that allows HTTP on port 80.
> 4. To confirm, open the site in your browser or run `curl -I http://your-server-ip/`. You should see `200 OK`.
> 5. If you want the site open to everyone, change the rule's source from your own IP to `0.0.0.0/0`. Only do this if the site is meant to be public.
> If anything still looks wrong, please send the output of that curl command.

**For Fault A (DNS):**

> Hi Sam,
> Thanks for the report. Here is what I found.
> 1. Your server could reach the internet, but it could not translate website names into addresses.
> 2. It was configured to ask a DNS server that does not respond.
> 3. I switched it back to the correct DNS server (`resolvectl revert`).
> 4. To confirm, run `dig example.com`. It should return an address within a second.
> 5. If this setting was changed on purpose, check who edited the network configuration, since a reboot may undo temporary changes.
> If it still fails, please send the output of `resolvectl status`.

---

## What I learned

1. A timeout means packets are being dropped somewhere; "connection refused" means something answered "no". `tcpdump` on the server shows which side of the instance boundary the packet reaches.
2. `nginx -t` only checks syntax. The same 502 can have different causes, so compare what the log says nginx tried with what `ss` shows is listening.


