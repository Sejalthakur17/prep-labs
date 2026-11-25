# prep-labs — Linux & Cloud Support Practice

Hands-on labs where I **reproduce a fault, diagnose it from logs and tools, fix it, and write it up** the way a support engineer would: a root-cause incident report, a plain-language reply to the "customer", and a short knowledge-base article.

I'm building this to practise Linux and cloud support work on Ubuntu: troubleshooting, ownership of a problem from first report to fix, and clear written communication. It is a work in progress, and the table below shows what is done and what is still planned.

*Last updated: 25 Nov 2026 (through Day 22: Gate 3 review done, with LV, NFS faults and a fresh KVM guest under time).*

---

## How I troubleshoot

Every lab follows the same order:

**Symptom → reproduce → which layer (hardware / OS / network / service / app) → logs → hypothesis → one change → verify → document**

Each incident report records the commands I ran, what I saw, what I concluded, the root cause, the fix, how I verified it, and what I would tell a customer to monitor.

---

## Environment

- **Cloud lab:** AWS EC2, Ubuntu Server LTS (26.04), region ap-south-1 (Mumbai). I take an AMI before each "break it" lab and restore afterwards.
- **Local lab:** a local VM on my Mac, where a lab needs console access or extra network cards.
- **KVM lab:** a separate EC2 instance (`kvm-host`, `m7i-flex.large`) with nested virtualization enabled, because KVM needs the CPU's virtualization extensions and a normal EC2 instance hides them. Guests are built from the Ubuntu 24.04 cloud image and sit on libvirt's NAT network (`virbr0`, 192.168.122.0/24), so I reach them from `kvm-host`, not from my Mac. I stop `kvm-host` when I'm not using it.
- **Network labs (bridge, bond, MTU):** built with Linux network namespaces and veth pairs on the same EC2 instance, so nothing touches the SSH interface (`ens5`). I record `ip -br addr` before and after each lab to prove the real connection was unchanged.
- **Storage labs (LVM, NFS):** LVM on two extra 2 GiB EBS volumes attached to `lab1` (matched to the console by volume serial before any wipe). NFS on two t3.micro instances (`nfs-server`, `nfs-client`) in a security group that allows 2049 and 111 only from its own members; NFS traffic uses private IPs. I deleted the LVM volumes after the lab. I delete the NFS pair after its labs and rebuild it (about 10 minutes) when a lab needs it.
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
| 6 | Virtualization (KVM/libvirt) | Guest will not start (missing disk, permission denied, disk in an unreachable path), guest running but no network, full host disk pausing the guest, LXD container compared with a KVM guest | ✅ | [incidents/06-kvm.md](incidents/06-kvm.md) · [notes/kvm-first-guest.md](notes/kvm-first-guest.md) · [notes/virtualization-comparison.md](notes/virtualization-comparison.md) |
| 7 | Storage (LVM and NFS) | LVM grown online; NFS baseline built; permission denied (root_squash and UID mismatch), firewall on 2049 (security group and `ufw`), stale file handle, hung hard mount | ✅ | [incidents/07-nfs.md](incidents/07-nfs.md) · [notes/storage-lvm-nfs.md](notes/storage-lvm-nfs.md) · [notes/nfs-faults.md](notes/nfs-faults.md) · [kb/nfs-mount-hangs-server-down.md](kb/nfs-mount-hangs-server-down.md) |

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
| First guest VM | ✅ built | Built `vm1` from the Ubuntu 24.04 cloud image on the 26.04 host: a qcow2 overlay on the 593 MiB base image, a cloud-init seed (`user-data` → `seed.img`) and `virt-install --import`. The first guest rejected my SSH key (`Permission denied (publickey)`): `user-data` still held the template's placeholder key, so cloud-init installed a key that matched nothing. Rebuilt it with `$(cat ~/.ssh/id_ed25519.pub)` and a fresh overlay, because cloud-init applies the user and key only on first boot. `cloud-init status` then reported `done` and the root filesystem grew to 19G. Notes: [notes/kvm-first-guest.md](notes/kvm-first-guest.md). |
| Guest network and storage | ✅ explored | `vm1` got an address from libvirt's DHCP on `virbr0` (NAT, gateway 192.168.122.1, range .2 to .254) and is reachable only from `kvm-host`. The overlay was 55.7 MiB on disk after first boot against a 20 GiB virtual size, with the base image as its backing file. `qemu-img info` on a running guest fails with "Failed to get shared write lock"; `-U` reads it safely. |
| Snapshot and revert | ✅ done | Took a snapshot of the running guest, ran `rm` on `/etc/hostname`, then reverted. libvirt restarted the guest in a new QEMU process (domain ID 2 → 3), SSH said "No route to host" for about 15 seconds, then worked and the file was back. Next time I will show the file missing before the revert. Later `qemu-img info -U` listed the snapshot `clean` at 561 MiB: the guest's RAM state, stored inside the qcow2, which explains the overlay growing from 55.7 MiB to about 624 MiB. |
| Fault A: missing disk | ✅ reproduced | After moving `vm1.qcow2` away, `virsh start` printed the exact missing path in its first error line, and `virsh domblklist` showed the config still pointed at it. The error also showed `uid:64055, gid:991`, the unprivileged user libvirt checks access as. |
| Fault B: permissions and wrong path | ✅ reproduced | With mode 000 on the disk, `virsh start` printed QEMU's `Could not open ... Permission denied`, repeated in the QEMU log and the `libvirtd` journal. I restored the owner and mode I had recorded first (`root:root` 644), not the ones the lab guide suggested. With the disk copied into `/home/ubuntu`, libvirt refused before QEMU launched. There was no AppArmor `DENIED` line in `dmesg` and the home directory was mode 750, so the evidence points to directory permissions rather than AppArmor. `virsh edit` rejected my fix twice on schema validation, so I used `virsh dumpxml`, `sed` and `virsh define`. |
| Fault C: no guest network | ✅ reproduced | After `virsh net-destroy default` the guest stayed `running`, `virbr0` disappeared and SSH timed out, yet `virsh domifaddr` still listed the old IP (stale). `virsh net-start default` brought the bridge back as `NO-CARRIER`, and `virsh reboot` was not enough (`No route to host`). Only `virsh destroy` then `virsh start` restored SSH. `virsh domifaddr` showed the same device (`vnet6`) after the reboot and a new one (`vnet7`) only after the full restart, which fits the NIC staying attached to the deleted bridge (not confirmed). With the guest stopped first, `virsh start` failed with `network 'default' is not active`. |
| Fault D: full host disk | ✅ reproduced | Filling the host to 99% made `virsh snapshot-create-as` fail with `Error while writing VM state: Input/output error`. A write inside the guest then left it `paused (I/O error)` at 100%. Deleting the filler was not enough: the guest stayed paused until `virsh resume`. After I freed space and resumed, the thin-provisioned `vm1.qcow2` grew to about 3 GB, most likely because the `dd` I interrupted with Ctrl+C kept running inside the guest (not verified). My first `du` on a glob failed because the shell expanded it without root. |
| Incident write-up | ✅ done | [incidents/06-kvm.md](incidents/06-kvm.md): all four faults with the first clue for each, where my results differed from the lab guide, a symptom-to-first-command table, my mistakes, and interview questions. |
| Customer replies | ✅ done | Plain-language replies for two faults (host disk full, guest network down) in [incidents/06-kvm.md](incidents/06-kvm.md), each with what I confirmed, what I don't know yet, what I did, and when I will update the customer. The network reply says plainly that a forced restart can lose unsaved in-memory work. |
| LXD vs KVM | ✅ done | LXD 6.10.1 gave an Ubuntu 24.04 container an IP address in 12.2 s (`dir` storage pool, one run), against 20.6 s cold and 17.1 s warm for the KVM guest to answer SSH. The container reported the host's kernel (`7.0.0-1018-aws`) while the guest runs `6.8.0-147-generic`. One `sleep` was PID 6588 on the host and 658 inside the container. `limits.memory 256MiB` showed as 256 in `free -m`. The LXD snapshot was filesystem only (`STATEFUL: NO`), and restoring it brought a deleted file back. Details and limits: [notes/virtualization-comparison.md](notes/virtualization-comparison.md). |

### Lab 7 progress: storage (LVM and NFS)

| Part | Status | What I found |
|---|---|---|
| LVM: build and grow online | ✅ done | Two 2 GiB gp3 volumes appeared as `nvme1n1` and `nvme2n1`, not the names in the lab guide, so I matched `lsblk -o NAME,SIZE,SERIAL` to the console volume IDs before touching anything. One disk carried an old empty ext4 partition (only `lost+found`, checked read-only); I cleared it with `wipefs`. Built `vg0` from one disk, a 1 GiB LV (`df` showed 974M), then `vgextend` and `lvextend -r -L +1G` while mounted: `df` showed 2.0G and the test file survived. The LV used the whole first disk plus a sliver of the second. I did not test growing without `-r`. Notes: [notes/storage-lvm-nfs.md](notes/storage-lvm-nfs.md). |
| NFS baseline | ✅ done | Server exported `/srv/share` to the client's private IP. The mount came up as `nfs4`, `vers=4.2`, `hard`, `sec=sys`. Files written on either side showed on the other with UID 1000 on both machines. As root on the client, `touch` created a file owned by 65534 (`nobody`): root_squash. The client's `ls -l` showed a `+` (ACL) the server did not; on Day 21 every file and the directory showed it, and I still did not run `getfacl`. |
| `showmount` hang | ✅ found | `showmount -e` from the client hung while the mount worked and `nc` to port 2049 succeeded. Likely cause: `showmount` talks to `mountd` on a port my security group does not allow (not verified; `rpcinfo -p` would confirm). NFSv4 itself needs only 2049. |
| Fault (a): permission denied | ✅ reproduced | With the server directory `root:root` 755, a write as `ubuntu` (UID 1000) failed, and so did `sudo`, because root_squash turns remote root into `nobody`. `ls -lnd` showed owner `0 0`. `chown 1000:1000` fixed it for `ubuntu` while `sudo touch` still failed (correct); `chmod 777` also worked but is lab-only. A file created by a server-only user with UID 2001 showed as a bare `2001` on the client, and `ubuntu` could not append to it (mode 644). No remount was needed after any fix. |
| Fault (b): firewall on 2049 | ✅ reproduced | With the security group rule removed, `nc -zv -w 5` printed `timed out: Operation now in progress` and the mount hung; restoring the rule gave `succeeded!`. Enabling `ufw` on the server (SSH allowed first) gave the identical symptom while the security group was fine, so there were two firewall layers; allowing 2049 from the client IP fixed it. I did not reproduce "connection refused", and I did not paste `ufw status` after the fix. |
| Fault (c): stale file handle | ✅ reproduced | Deleting and recreating `/srv/share` while a client sat inside it made `ls` fail with errno 116 (`Stale file handle`) while `mount \| grep nfs` still looked healthy and `dmesg` showed nothing. `umount` first said `device is busy` (`fuser -vm` named my `tail`). I then mounted over the busy mount by mistake, which stacked a second mount on top; `umount -l` removed the top one and `findmnt` later showed a single mount. I never checked what was underneath. |
| Fault (d): hung hard mount | ✅ reproduced | After stopping the server, `ls` froze in state `D` (`1653 D+`). Ctrl+C freed the command, so it was killable, but the mount stayed and the next access hung again. `dmesg` printed `not responding, timed out` (not "still trying") only after a second `ls` and a wait; no recovery line appeared after the server returned, and the mount worked again with no remount. `umount -f` said `device is busy` until I released the frozen `ls`, then succeeded; `umount -l` was not needed. I did not test data loss, and I did not capture what the frozen `ls` did when the server returned. |
| Incident write-up and customer replies | ✅ done | [incidents/07-nfs.md](incidents/07-nfs.md): four faults, the first command for each symptom, where my results differed from my expectations, my mistakes, and two customer replies (frozen folder, mount timeout), each with what I confirmed, what I don't know yet, what I did, and when I will update. |
| KB article 2 | ✅ done | [kb/nfs-mount-hangs-server-down.md](kb/nfs-mount-hangs-server-down.md): NFS mount hangs when the server stops or reboots. Symptoms, cause, diagnosis commands, an escalation order (restore the server, release the holder, `umount -f`, `umount -l`), the data-loss warning, and how to verify. |

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
- [KVM first guest: cloud image, cloud-init, libvirt network, snapshots](notes/kvm-first-guest.md) (commands, measurements, problems and fixes, interview Q&A)
- [KVM guest failures: four faults, troubleshooting table and mistakes](incidents/06-kvm.md)
- [LXD vs Docker vs KVM: measured comparison](notes/virtualization-comparison.md)
- [Storage: LVM and NFS baseline](notes/storage-lvm-nfs.md) (commands, measurements, the `showmount` hang, root_squash)
- [NFS fault drills: permissions, firewall, stale handle, hung mount](notes/nfs-faults.md) (commands, measurements, escalation order, mistakes, interview Q&A)
- [NFS failures: four faults, symptom-to-command table and customer replies](incidents/07-nfs.md)
- [Gate 1 checkpoint results](notes/gate1.md)
- [Gate 2 checkpoint results](notes/gate2.md)
- [Gate 3 checkpoint results: LVM, NFS faults and a fresh KVM guest under time](notes/gate3.md)

---

## Contact

- GitHub: [Sejalthakur17](https://github.com/Sejalthakur17)
- LinkedIn: [sejalthakurr](https://www.linkedin.com/in/sejalthakurr/)
