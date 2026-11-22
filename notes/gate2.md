# Gate 2 checkpoint (22 Nov 2026)

A cold test of four tasks on `lab1`, with no notes open. Each part was timed. A part counts as a clean pass only if I needed no hints, and the table says where I did.

| Task | Result | Time | What tripped me up |
|---|---|---|---|
| a. HTTPS nginx from scratch | Pass (one hint) | 10 min (target 15) | `nginx -t` passed but printed a duplicate `server_name` warning that I did not notice until it was pointed out |
| b. Bridge and bond, then a failover test | Pass | 20 min (target 25) | none; the bond design differed from my notes (see below) |
| c. Explain the MTU failure aloud | Done, explanation needs fixes | 2 min (target 2) | said bits instead of bytes; mixed up what is fragmented and what the ICMP message is |
| d. Fix a full disk | Pass | 8 min (target 15) | ran `lsof` on a made-up filename before using the real one (harmless) |

---

## Task a: HTTPS nginx from scratch

**Task**
Serve `https://lab.local` from nginx with a certificate I create myself, and prove it works with a real client.

**What I did**
1. Created `/etc/ssl/lab/` and one `openssl req -x509 -newkey rsa:2048 -nodes` command that made the key and certificate together, with `-addext "subjectAltName=DNS:lab.local"`.
2. `chmod 600` on the key, then checked the name with `openssl x509 -noout -ext subjectAltName` (it showed `DNS:lab.local`).
3. Wrote a server block (`listen 443 ssl`, `server_name`, the two `ssl_certificate` lines, a `root`), linked it into `sites-enabled`, ran `nginx -t`, then reloaded.

**Evidence**
- `curl --cacert /etc/ssl/lab/cert.pem --resolve lab.local:443:127.0.0.1 https://lab.local` returned my page.
- The same `curl` without `--cacert` failed with error 60 and exit code 60 (`self-signed certificate (18)`). That is the correct result, because curl does not trust a certificate I made myself.

**The problem I missed**
`nginx -t` printed `conflicting server name "lab.local" on 0.0.0.0:443, ignored` and still said the test was successful. `nginx -T | grep` showed two enabled blocks claiming `lab.local`: the new one (`cert.pem`) and my Day 9 test site (`fullchain.pem`). nginx loads `sites-enabled` alphabetically and uses the first, so the new block answered and the old one was ignored.

**Fix**
Removed only the old symlink (`sudo rm /etc/nginx/sites-enabled/tls-lab`), kept the file in `sites-available`, then ran `nginx -t && systemctl reload nginx`. The warning was gone.

**Verification**
- `nginx -t` printed no `[warn]` line.
- The SHA-256 fingerprint of the certificate nginx served matched the fingerprint of `/etc/ssl/lab/cert.pem`.
- `curl --cacert ...` still returned my page, and `http://localhost` returned 200, so my other sites still answered.

**Lessons**
- `nginx -t` can pass and still warn about something wrong. Read all of its output, not just the last line.
- Test with a real client and a CA file, never only with `curl -k`.
- Prove which certificate is being served by comparing fingerprints.

---

## Task b: bridge and bond cold, with a failover test

**What I built (from a paper drawing)**
- Namespaces `ns1` and `ns2`, each with a veth cable to `br0` (10.10.0.1/24 and 10.10.0.2/24).
- Namespace `nsb` with `bond0` (`active-backup`, `miimon 10`) made of `b1` and `b2`, at 10.20.0.2/24. Both cables plug into the same `br0`, and `10.20.0.1/24` sits on `br0` in the main namespace.

**Evidence**
- `ns1` pinged `10.10.0.2`: 3 sent, 3 received, 0% loss. `bridge link` listed all four ports with `master br0`.
- `/proc/net/bonding/bond0` showed `fault-tolerance (active-backup)`, active slave `b1`, both members `MII Status: up`.
- `nsb` pinged `10.20.0.1`: 3 of 3 received.

**Failover test**
Ran a 30-packet ping in the background (`-i 0.5`), and about 2 seconds in took down the active member's bridge-side end (`ip link set b1-br down`).
- Result: `30 packets transmitted, 30 received, 0% packet loss`.
- The active slave changed from `b1` to `b2`.

**Cleanup**
Deleted the namespaces and `br0`. `ip netns list` printed nothing, and `ens5` still showed `172.31.10.100/20` (I had saved `ip -br addr show ens5` to `/tmp/ens5.before` and compared with `diff`).

**Differences from my Day 11 notes**
- The Day 11 design used a separate namespace (`nsc`) with its own bridge on the far side. Here both cables went to the same `br0`.
- I used `miimon 10`, not 100.
- I took down the bridge-side end of the cable rather than the bond member itself. That still triggers failover, because a veth pair loses carrier on both ends.
- The members were already down when joined (new veth ends start down), so the rule "members must be down before joining" was **not** tested in this run.

---

## Task c: explain the MTU failure aloud

I recorded a 2-minute explanation. Corrections to make before I say it again:

| What I said | What is correct |
|---|---|
| The limit is 1500 bits | 1500 **bytes** (and 1472 is also bytes) |
| Large packets are divided into fragments, and the ICMP message comes when there are not enough fragments | Large packets with the Don't Fragment (DF) bit set are **dropped** by the link with the smaller MTU, and that router sends back ICMP "fragmentation needed" (type 3, code 4) with the smaller size |
| `ping -m do -s` sets the size of fragments | `ping -M do` (capital M) sets DF so nothing may be fragmented; `-s` sets the payload size. 1472 + 28 bytes of IP and ICMP headers = 1500 |
| The fix is sending 1472 at a time | Lower `-s` until the ping passes, then add 28 to get the path MTU. Fix by allowing ICMP type 3 code 4 through firewalls, setting matching MTUs on both ends, or clamping the TCP MSS |

**Version to practise**
MTU is the largest packet a link can carry in one go, normally 1500 bytes. If a packet is bigger than the next link allows and the DF bit is set, the router drops it and sends back an ICMP "fragmentation needed" message with the smaller size. If a firewall blocks that message, the sender never learns, so large packets vanish silently while small ones work. That is why pages load but downloads hang. I test it with `ping -M do -s 1472`, then lower `-s` until it passes; that size plus 28 is the path MTU. The fix is to allow ICMP type 3 code 4, set matching MTUs, or clamp the TCP MSS.

---

## Task d: fix a full disk

**Planted fault:** a hidden 3 GB file (`fallocate -l 3G /var/lib/.x$RANDOM`), name not noted.

**Diagnosis**
1. `df -h /` showed 85% used (5.6G used, 1.1G free), up from 40%.
2. `df -i /` showed 16% of inodes used, so it was not an inode problem.
3. `du -xh / --max-depth=1` pointed to `/var` (3.5G), then `/var/lib` (3.4G). Its listed subfolders added up to only about 0.4G, so a file had to sit directly in `/var/lib`.
4. `find / -xdev -type f -size +500M -exec ls -lh {} +` named `/var/lib/.x25525` (3.0G).
5. `lsof +L1` printed nothing, so no deleted-but-open file was involved.

**Fix and verification**
`sudo rm /var/lib/.x25525`. `df -h /` went back to 40% (2.6G used) and `df -i` stayed at 16%.

**Extra test: deleted but still open**
Created a 2 GB file, held it open with `sleep 1000 < file &`, then deleted it.
- `df` showed 4.6G used (70%) while `du -xsh /` showed 2.6G, a 2 GB gap.
- `lsof +L1` showed `sleep`, PID 2327, `/var/lib/.ghost (deleted)`, `NLINK 0`.
- After `kill %1`, `df` returned to 40%.

**Lesson**
`df` says whether the disk is full, `du` and `find` say what is using it, and a gap between `df` and `du` points to deleted-but-open files.

---

## Hints I needed

- **Task a:** the conflicting `server_name` warning was pointed out to me. I then ran `ls -l /etc/nginx/sites-enabled/` and `nginx -T | grep` myself to find the second block.
- **Task c:** the corrections above came from a review after I explained it.

## Attempts

| Date | Task | Fault or setup | Notes or AI used? | Time | Result |
|---|---|---|---|---|---|
| 22 Nov | a. HTTPS nginx | build from scratch | no notes; a hint on the duplicate `server_name` | 10 min | pass (one hint) |
| 22 Nov | b. Bridge and bond | rebuild from my drawing | no notes, no hints | 20 min | pass |
| 22 Nov | c. MTU aloud | explanation | explanation reviewed afterwards | 2 min | done, to redo |
| 22 Nov | d. Full disk | hidden 3 GB file | no notes, no hints | 8 min | pass |

## What I'm practising next

- Reading all of `nginx -t`'s output, including warnings, before reloading.
- Testing the "members down before joining the bond" rule on purpose, and recording the exact result.
- Re-recording the MTU explanation with bytes, the DF bit and ICMP type 3 code 4.
- Repeating the bond build with the separate-namespace design from my Day 11 notes.
