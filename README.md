# prep-labs — Linux & Cloud Support Practice

Hands-on labs where I **reproduce a fault, diagnose it from logs and tools, fix it, and write it up** the way a support engineer would: a root-cause incident report, a plain-language reply to the "customer", and a short knowledge-base article.

I'm building this to practise Linux and cloud support work on Ubuntu: troubleshooting, ownership of a problem from first report to fix, and clear written communication. It is a work in progress, and the table below shows what is done and what is still planned.

*Last updated: 23 Nov 2026 (through Day 16: KVM host built).*

---

## How I troubleshoot

Every lab follows the same order:

**Symptom → reproduce → which layer (hardware / OS / network / service / app) → logs → hypothesis → one change → verify → document**

Each incident report records the commands I ran, what I saw, what I concluded, the root cause, the fix, how I verified it, and what I would tell a customer to monitor.

---

## Environment

- **Cloud lab:** AWS EC2, Ubuntu Server LTS (26.04), region ap-south-1 (Mumbai). I take an AMI before each "break it" lab and restore afterwards.
- **Local lab:** a local VM on my Mac, where a lab needs console access or extra network cards.
- **KVM lab:** a separate EC2 instance (`kvm-host`, `m7i-flex.large`) with nested virtualization enabled, because KVM needs the CPU's virtualization extensions and a normal EC2 instance hides them. I stop it when I'm not using it.
- **Network labs (bridge, bond, MTU):** built with Linux network namespaces and veth pairs on the same EC2 instance, so nothing touches the SSH interface (`ens5`). I record `ip -br addr` before and after each lab to prove the real connection was unchanged.
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
| 3 | TLS faults | Expired certificate, hostname mismatch, incomplete chain, self-signed certificate | ✅ | [incidents/03-tls.md](incidents/03-tls.md) |
| 4 | Resource exhaustion | CPU load, memory/OOM kill, full disk, deleted-but-open files, inode exhaustion | ✅ | [incidents/04-resource-exhaustion.md](incidents/04-resource-exhaustion.md) |
| 5 | Network faults | Bridge missing a port, bond with a dead member, MTU mismatch, firewall dropping ICMP "fragmentation needed", all reproduced in namespaces | ✅ | [incidents/05-bond-bridge-mtu.md](incidents/05-bond-bridge-mtu.md) · [notes/bond-bridge.md](notes/bond-bridge.md) |
| 6 | Virtualization (KVM/libvirt) | Guest will not start, no guest network, full storage pool | 🟡 | `incidents/06-…md` |
| 7 | Storage (LVM and NFS) | Permission denied, firewall on 2049, stale file handle, hung mount | ⬜ | `incidents/07-…md` |

Also done: firewalls on EC2 (security group vs `ufw`, DROP vs REJECT), written up in [notes/firewalls.md](notes/firewalls.md).

### Lab 3 progress: TLS

| Part | Status | What I found |
|---|---|---|
| Expired / wrong name / incomplete chain / self-signed | ✅ reproduced | Read the verify code from `openssl s_client` (10 expired, 62 hostname, 20/21 chain, 18 self-signed). An expired chain printed the error three times because the leaf, intermediate and root were all past expiry. Pointing `ssl_certificate_key` at the certificate instead of the key took nginx down, so I always run `nginx -t` before a reload. |
| Duplicate `server_name` | ✅ found in Gate 2 | `nginx -t` passed but printed `conflicting server name "lab.local"`: an old test site and the new one both claimed it. nginx used the first in alphabetical order and ignored the other. Fixed by removing the old site's symlink, and confirmed the served certificate by comparing SHA-256 fingerprints. |

### Lab 4 progress: resource exhaustion

| Part | Status | What I found |
|---|---|---|
| CPU load | ✅ reproduced | `stress-ng --cpu 2` took load to 1.87 on a 2-CPU instance. Found both workers in `htop` (F6, sort by PERCENT_CPU). `renice +10` only made a difference once another process (`htop`) competed for CPU: the reniced worker dropped to about 92%. Nice values matter under contention only. |
| Memory and OOM kill | ✅ reproduced | `--vm-bytes 90%` is a percentage of *available* memory, and `--vm-bytes 600M` is split across workers, so neither exhausted RAM. A 1500M total did. `stress-ng` reported `passed: 2`, but `dmesg` showed many `Out of memory: Killed process ... (stress-ng-vm)` lines. nginx survived because `stress-ng` sets `oom_score_adj:1000` on its workers. Lesson: check `dmesg`, not the tool's summary. |
| Full disk | ✅ reproduced | A 2 GB file took root from 41% to 72%. `du` without `-a` listed only directories and hid the file, but `/var` (2.6G) was far larger than its subfolders combined (about 550M), which pointed to a file sitting directly in it. `du -xah` and `find -size +500M` named `/var/big`. |
| Deleted but still held open | ✅ reproduced | After `rm`, `df` stayed at 3.2G used while `du` showed only 48K for the folder. `lsof +L1` found the holder (`sleep`, PID 4820, `(deleted)`). Killing it freed the space. Also learned that `/tmp` here is tmpfs (RAM, 455M), and that a `tail -f &` holder can race with `rm` or exit on its own. |
| Inode exhaustion | ✅ reproduced | A loop-mounted filesystem with 2000 inodes failed at file 1989 with "No space left on device" while `df -h` showed 89M free. `df -i` showed 100%. Root baseline for comparison: 16% of 878,080 inodes. |
| KB article 1 | ✅ done | [kb/no-space-left-on-device.md](kb/no-space-left-on-device.md): "No space left on device" while `df -h` shows free space. Covers four causes (inodes exhausted, deleted-but-open files, the wrong filesystem such as RAM-backed `tmpfs`, and a large file filling the disk), the commands that tell them apart, and how to verify the fix. |

### Lab 5 progress: network faults

| Part | Status | What I found |
|---|---|---|
| Bridge: missing port | ✅ reproduced | Interface stayed `UP` with the right IP, but ping got 100% loss. The only clue was the missing port in `bridge link`. Fixed with `ip link set <port> master br0`. |
| Bond: active-backup failover | ✅ reproduced | Failover worked in both directions and `Link Failure Count` increased. A continuous ping across the failover lost 0 packets (30 of 30 received, and 189 of 189 in a longer run). The bond did not switch back because no `primary` was set. A read right after the link went down showed stale state because of `miimon` polling. |
| MTU mismatch | ✅ reproduced | Lowering one veth to MTU 1400 made small pings work while large don't-fragment pings got 100% loss with no error message. Found the path MTU by lowering the ping size until it passed (1372 + 28 bytes of headers = 1400). |
| Firewall drops ICMP type 3 code 4 | ✅ reproduced | Same "small works, big hangs" symptom, but `tcpdump` showed the router's `need to frag (mtu 1400)` message arriving while the firewall's DROP counter rose (6 packets, 3456 bytes). Removing the rule restored Path MTU Discovery. Never block all ICMP. |
| Incident write-up | ✅ done | One report covering the four faults and how each looked different. |

### Lab 6 progress: virtualization (KVM/libvirt)

| Part | Status | What I found |
|---|---|---|
| KVM host on EC2 | ✅ built | A normal EC2 instance is already a VM and hides the CPU's virtualization extensions, so I launched `kvm-host` (`m7i-flex.large`, 2 vCPU) with nested virtualization enabled. `egrep -c '(vmx\|svm)' /proc/cpuinfo` printed 4 on 2 vCPUs because Intel lists both a `flags` and a `vmx flags` line per CPU. `grep -c '^flags.*vmx'` gave 2, equal to `nproc`, and `kvm-ok` confirmed acceleration. |
| Install the stack | ✅ fixed | `qemu-kvm` is a virtual package on 26.04, so apt aborted the whole install, and `usermod` then failed because the `libvirt` group did not exist yet. Installing `qemu-system-x86` fixed both. Write-up: [kb/qemu-kvm-no-installation-candidate-ubuntu-26-04.md](kb/qemu-kvm-no-installation-candidate-ubuntu-26-04.md). |
| Verify | ✅ passed | `virsh list --all` ran cleanly, `/dev/kvm` exists (group `kvm`), `libvirtd` is active, and the `default` network is active with autostart. The checks are scripted in [scripts/verify-kvm-host.sh](scripts/verify-kvm-host.sh). |
| First guest VM | ⬜ next | Ubuntu cloud image, qcow2 overlay disk, cloud-init seed, `virt-install --import`. |

---

## Scripts

| Script | What it does |
|---|---|
| `scripts/failed_ssh.sh` | Reads an SSH auth log and lists the IP addresses with the most failed password attempts. Tested on a sample log file. |
| `scripts/hello.sh` and `scripts/hello.service` | A small demo service I use to practise systemd faults. |
| `scripts/verify-kvm-host.sh` | Checks that a host can run KVM guests: CPU flag, `/dev/kvm`, `kvm-ok`, `libvirt` group membership, `virsh`, and the `default` network. Prints PASS or FAIL for each check. |

---

## Notes and cheat sheets

- [Processes, packages and systemd](notes/systemd.md)
- [Packet capture with `tcpdump`](notes/tcpdump.md)
- [TCP basics](notes/tcp.md)
- [TLS basics](notes/tls.md)
- [Firewalls on EC2: security groups and `ufw`](notes/firewalls.md)
- [Linux bridge and bond with network namespaces](notes/bond-bridge.md) (commands, lab log, troubleshooting table, interview Q&A)
- [KVM, QEMU and libvirt: concepts and the nested-virtualization host](notes/kvm-host.md)
- [Gate 1 checkpoint results](notes/gate1.md)
- [Gate 2 checkpoint results](notes/gate2.md)

---

## Contact

- GitHub: [Sejalthakur17](https://github.com/Sejalthakur17)
- LinkedIn: [sejalthakurr](https://www.linkedin.com/in/sejalthakurr/)
