# prep-labs — Linux & Cloud Support Practice

Hands-on labs where I **reproduce a fault, diagnose it from logs and tools, fix it, and write it up** the way a support engineer would: a root-cause incident report, a plain-language reply to the "customer", and a short knowledge-base article.

I'm building this to practise Linux and cloud support work on Ubuntu: troubleshooting, ownership of a problem from first report to fix, and clear written communication. It is a work in progress, and the table below shows what is done and what is still planned.

---

## How I troubleshoot

Every lab follows the same order:

**Symptom → reproduce → which layer (hardware / OS / network / service / app) → logs → hypothesis → one change → verify → document**

Each incident report records the commands I ran, what I saw, what I concluded, the root cause, the fix, how I verified it, and what I would tell a customer to monitor.

---

## Environment

- **Cloud lab:** AWS EC2, Ubuntu Server LTS (26.04), region ap-south-1 (Mumbai). I take an AMI before each "break it" lab and restore afterwards.
- **Local lab:** a local VM on my Mac, where a lab needs console access or extra network cards.
- **Client:** macOS terminal over SSH; Wireshark for reading packet captures.
- All faults are created on throwaway lab machines. No real customer data is used.

---

## Repo layout

```
prep-labs/
  README.md
  notes/        # my study notes and cheat sheets
  incidents/    # one write-up per lab: symptom, diagnosis, root cause, fix
  kb/           # public-style knowledge base articles
  scripts/      # bash and Python helpers
```

---

## Labs

Status key: ✅ done and written up · 🟡 in progress · ⬜ planned

| # | Lab | What I reproduce and diagnose | Status | Write-up |
|---|---|---|---|---|
| 1 | Boot, service and permission faults | Broken `/etc/fstab` entry (emergency mode), failed nginx service, unreadable web root, port already in use | ✅ | [incidents/01-boot-failure.md](incidents/01-boot-failure.md) |
| 2 | DNS and HTTP failures | Bad resolver, firewall blocking port 80, reverse proxy pointing at the wrong port | ✅ | [incidents/02-dns-http.md](incidents/02-dns-http.md) |
| 3 | TLS faults | Expired certificate, hostname mismatch, incomplete chain | ⬜ | `incidents/03-…md` |
| 4 | Resource exhaustion | CPU load, memory and OOM kill, full disk, inode exhaustion | ⬜ | `incidents/04-…md` |
| 5 | Network faults | MTU mismatch, bonding failover, bridge misconfiguration | ⬜ | `incidents/05-…md` |
| 6 | Virtualization (KVM/libvirt) | Guest will not start, no guest network, full storage pool | ⬜ | `incidents/06-…md` |
| 7 | Storage (LVM and NFS) | Permission denied, firewall on 2049, stale file handle, hung mount | ⬜ | `incidents/07-…md` |

Labs 3 to 7 are next.

---

## Scripts

| Script | What it does |
|---|---|
| `scripts/failed_ssh.sh` | Reads an SSH auth log and lists the IP addresses with the most failed password attempts. Tested on a sample log file. |
| `scripts/hello.sh` and `scripts/hello.service` | A small demo service I use to practise systemd faults. |

---

## Community support practice

I answered an Ask Ubuntu question after reproducing the problem on a lab machine first:

- [Is there any way to get status code (XXX) of Nginx except setting up stub_status page?](https://askubuntu.com/questions/1552888/is-there-any-way-to-get-status-code-xxx-of-nginx-except-setting-up-stub-status/1570987#1570987)
  Covers checking for a 200 with `curl`, what `000`, `404` and exit codes `22` and `7` mean, and a `/healthz` endpoint.

---

## Notes and cheat sheets

- [Processes, packages and systemd](notes/systemd.md)
- [Packet capture with `tcpdump`](notes/tcpdump.md)
- [TCP basics](notes/tcp.md)
- [TLS basics](notes/tls.md)
- [Gate 1 checkpoint results](notes/gate1.md)
---

## Contact

- GitHub: [Sejalthakur17](https://github.com/Sejalthakur17)
- LinkedIn: [sejalthakurr](https://www.linkedin.com/in/sejalthakurr/)
