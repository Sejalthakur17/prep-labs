# Day 10: Firewalls (EC2 lab1)

## Core idea
An EC2 server has two firewalls. A connection must pass both.

| Layer | Where it runs | Managed with |
|---|---|---|
| Security group (lab-sg) | Outside the server, in AWS | AWS console |
| ufw | Inside Ubuntu | `sudo ufw ...` |

## DROP vs REJECT

| | What the server does | What the client sees |
|---|---|---|
| DROP | Throws the packet away silently | Waits, then `Operation timed out` |
| REJECT | Answers "no" immediately | Instant `Connection refused` |

**Rule of thumb:**
- Timeout: something dropped it (security group or ufw deny).
- Refused: the host answered no (nothing listening, or ufw reject).

## Safe way to enable a firewall over SSH
1. Get my IP as the server sees it: `echo $SSH_CLIENT` (first value, here 223.181.22.111)
2. Allow it on SSH: `sudo ufw allow from 223.181.22.111 to any port 22 proto tcp`
3. Schedule an escape timer: `echo "ufw --force disable" | sudo at now + 10 minutes`
4. Set defaults and rules:
   ```bash
   sudo ufw default deny incoming
   sudo ufw default allow outgoing
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   sudo ufw enable
   ```
5. Confirm SSH still works (type a command, open a second SSH session).
6. Cancel the timer: `sudo atq`, then `sudo atrm <job-number>`

Needs `atd` running: `systemctl is-active atd` should print `active`.

## Under the hood
ufw is a front end for iptables/nft (on Ubuntu 26.04 iptables is a compatibility layer over nft).
- `sudo iptables -L -n -v | head -40`
- `sudo nft list ruleset | head -60`

Three chains:
- INPUT (policy DROP): traffic coming in; this is the "default deny incoming".
- FORWARD (policy DROP): traffic passing through; not used on a normal server.
- OUTPUT (policy ACCEPT): traffic going out.

Useful rules in the nft output:
- `ct state related,established ... accept` lets replies and existing SSH sessions through.
- `jump ufw-user-input` is where my own rules (80, 443, SSH) live.
- `log prefix "[UFW BLOCK] "` logs blocked packets to `/var/log/ufw.log`.

## The four experiments (server IP 13.203.203.4, port 8080)

| # | Security group | ufw | Result on Mac | Who answered |
|---|---|---|---|---|
| 1 | 8080 open | default deny | `Operation timed out` | ufw dropped it (logged as `[UFW BLOCK] DPT=8080`) |
| 2 | 8080 open | `reject 8080/tcp` | `Connection refused` (instant) | Server said no |
| 3 | 8080 open | `allow 8080/tcp` | `succeeded!` | Both layers allow |
| 4 | 8080 removed | `allow 8080/tcp` | `Operation timed out` | Security group dropped it |

Proof of the layer: experiment 1 left a `[UFW BLOCK]` line in the log. Experiment 4 left no new line, because the packet never reached the server.

## Cheat sheet

### ufw
| Goal | Command |
|---|---|
| Status (short / detailed / numbered) | `sudo ufw status` / `sudo ufw status verbose` / `sudo ufw status numbered` |
| Turn on / off | `sudo ufw enable` / `sudo ufw disable` |
| Default policies | `sudo ufw default deny incoming` and `sudo ufw default allow outgoing` |
| Allow a port | `sudo ufw allow 80/tcp` |
| Allow a port from one IP only | `sudo ufw allow from 1.2.3.4 to any port 22 proto tcp` |
| Reject a port (instant refusal) | `sudo ufw reject 8080/tcp` |
| Deny a port (silent drop) | `sudo ufw deny 8080/tcp` |
| Delete a rule by its text | `sudo ufw delete allow 8080/tcp` |
| Delete a rule by number | `sudo ufw delete 3` (highest number first) |
| Reset everything (careful) | `sudo ufw reset` |

### Escape timer (at)
| Goal | Command |
|---|---|
| Install and start | `sudo apt install -y at` and `sudo systemctl enable --now atd` |
| Schedule a job | `echo "ufw --force disable" \| sudo at now + 10 minutes` |
| List jobs | `sudo atq` |
| Cancel a job | `sudo atrm <job-number>` |

### Testing from the Mac
| Goal | Command |
|---|---|
| Knock on a port | `nc -zv -w 3 <public-ip> 8080` |
| Is the server reachable at all | `ssh -i lab-key.pem ubuntu@<public-ip>` |

### Checking the server
| Goal | Command |
|---|---|
| What is listening | `sudo ss -tlnp` |
| Is port 8080 listening | `sudo ss -tlnp \| grep ':8080'` |
| Start a test web server | `python3 -m http.server 8080 &` (use `sudo` for port 80) |
| Stop a background job | `kill %1` or `sudo pkill -f "http.server 8080"` |
| See blocked packets | `sudo grep "UFW BLOCK" /var/log/ufw.log \| tail -5` |
| Under the hood | `sudo iptables -L -n -v \| head -40` and `sudo nft list ruleset \| head -60` |
| My IP as the server sees it | `echo $SSH_CLIENT` |
| Server time (UTC) | `date` |

### AWS security group (console)
EC2 > Instances > your instance > Security tab > `lab-sg` > Edit inbound rules > Add rule > **Save rules**.
- Source `x.x.x.x/32` means exactly one IP.
- A new rule shows `-` as its ID until it is saved.
- Never delete the SSH (22) rule while connected over SSH.

### Reading a result
| Mac sees | Meaning | Check first |
|---|---|---|
| `succeeded!` | Both layers allow it and something is listening | Nothing to fix |
| `Operation timed out` | Dropped silently | Security group, then ufw (`UFW BLOCK` in the log means ufw) |
| `Connection refused` | Host answered no | Is the service running? Any ufw reject rule? |

## Common errors

| Error or symptom | Cause | Fix |
|---|---|---|
| `nc: getaddrinfo: nodename nor servname provided, or not known` | Typed the placeholder `YOUR_PUBLIC_IP` literally | Use the real public IPv4, e.g. `13.203.203.4` |
| `-bash: new-ip: No such file or directory` | Typed `<new-ip>` with the angle brackets; bash reads `<` as "read from a file" | Replace the whole placeholder, brackets included, with the real value |
| `Operation timed out` on a port | Something dropped it silently | Check the security group, then ufw. A fresh `[UFW BLOCK]` line in the log means ufw did it |
| `Connection refused` on a port | Nothing listening, or a ufw reject rule | `sudo ss -tlnp \| grep ':<port>'` and `sudo ufw status numbered` |
| `nc` to port 80 times out even though rules are right | Security group rule source does not match the Mac's current IP, or the rule was never saved | Compare `223.181.22.111/32` against the Mac's real public IP; check the rule has an ID, not `-` |
| `nc` works to the public IP but not `172.31.x.x` | `172.31.10.100` is the private IP and only works inside the VPC | Always use the public IPv4 from the Mac |
| `at: command not found` | `at` not installed | `sudo apt install -y at` |
| Escape timer never fires | `atd` is not running | `sudo systemctl enable --now atd`, then `systemctl is-active atd` |
| `ufw` suddenly turns itself off mid-lab | The `at` timer fired because it was not cancelled | `sudo atrm <job>` right after confirming SSH works, then `sudo ufw enable` |
| `at` job time looks wrong | Server clock is UTC | Compare against `date` on the server |
| `ssh: connect to host ... Operation timed out` | Security group or ufw blocks port 22, or my home IP changed | Use EC2 Instance Connect from the console, run `echo $SSH_CLIENT`, update the ufw rule and the security group source |
| `Permission denied (publickey)` | Wrong key file, wrong user, or key not in the current folder | Use `-i lab-key.pem` and user `ubuntu`, run from the folder holding the key |
| `WARNING: UNPROTECTED PRIVATE KEY FILE!` | Key file permissions too open | `chmod 400 lab-key.pem` |
| `OSError: [Errno 98] Address already in use` | Another process already uses that port | `sudo ss -tlnp \| grep ':8080'`, then kill that PID or the old job |
| `PermissionError: [Errno 13]` starting the web server | Ports below 1024 need root | `sudo python3 -m http.server 80 &` |
| `kill: %1: no such job` | The job is not in this shell | `sudo pkill -f "http.server 8080"` |
| `ERROR: Could not delete non-existent rule` | The rule text does not match exactly | Run `sudo ufw status numbered` and delete by number |
| Deleted the wrong rule after deleting two | Rule numbers shift after each delete | Delete the highest number first, re-check with `status numbered` |
| Leftover `22/tcp ALLOW IN Anywhere` rules | An earlier `ufw allow ssh` or `allow 22` | Delete them by number, but only after confirming a second SSH session works |
| A ufw allow rule seems ignored | An earlier rule matches first (first match wins) | `sudo ufw status numbered` and check the order |
| `Chain INPUT (policy DROP)` but ports still open | A ufw allow rule exists for that port | `sudo ufw status verbose` |
| Lab results look wrong after a break | Leftover rules or listeners from an earlier run | Clean up: `sudo ufw status numbered`, `sudo ss -tlnp`, and check the security group |

## Things I learned the hard way
- `<angle-brackets>` in a command are placeholders. Replace the whole thing, brackets included.
- Use the public IPv4 (13.203.203.4) from the Mac, not the private one (172.31.10.100).
- `nc` to a port only succeeds if something is listening there, so start a listener first.
- The server clock is UTC, so `at` job times look different from my local time.
- Delete ufw rules by number from the highest down, because numbers shift.
- ufw rules are read top to bottom and the first match wins (`sudo ufw status numbered`).
- If my home IP changes, the SSH rule stops matching. Backup: EC2 Instance Connect in the AWS console.
- Always cancel the `at` timer after confirming SSH works, or it will turn ufw off mid-lab.
- Save the security group rules. An unsaved rule shows `-` as its ID and does nothing.

## Final state after cleanup
```
[ 1] 80/tcp         ALLOW IN    Anywhere
[ 2] 22/tcp         ALLOW IN    223.181.22.111
[ 3] 443/tcp        ALLOW IN    Anywhere
[ 4] 80/tcp (v6)    ALLOW IN    Anywhere (v6)
[ 5] 443/tcp (v6)   ALLOW IN    Anywhere (v6)
```
Security group: HTTP 80, SSH 22, HTTPS 443, all from 223.181.22.111/32. The 8080 rule is removed.

## Checkpoint
**Q: How does DROP look different from REJECT to a client?**
A: DROP makes the client wait and then time out. REJECT gives an instant "Connection refused."

## Support tip
- "It hangs" means a firewall or security group is dropping traffic, so check both layers.
- "Connection refused" means the host answered no, so check whether the service is running and whether a reject rule exists.
