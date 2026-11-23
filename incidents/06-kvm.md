# Incident 06: KVM guest failures (libvirt and QEMU on Ubuntu)

**Date:** 23 Nov 2026
**Goal:** break a working KVM guest four ways, diagnose each from its first error message, fix it, and verify.

How the guest was built (cloud image, qcow2 overlay, cloud-init seed, libvirt NAT network) is in [notes/kvm-first-guest.md](../notes/kvm-first-guest.md).

## Environment

- **Host:** `kvm-host`, AWS EC2 `m7i-flex.large`, nested virtualization enabled, Ubuntu Server 26.04, region ap-south-1.
- **Guest:** `vm1`, built from the Ubuntu 24.04 (noble) cloud image with a cloud-init seed (`seed.img`).
- **Guest disk:** `/var/lib/libvirt/images/vm1.qcow2` (qcow2, thin-provisioned).
- **Guest network:** libvirt `default` NAT network on bridge `virbr0` (192.168.122.0/24). The guest is only reachable from `kvm-host`, so I SSH to `kvm-host` first.
- **Recovery point:** snapshot `clean` (taken 07:42 before any fault).

## Baseline (recorded before breaking anything)

```
virsh list --all          -> vm1 running
virsh net-list --all      -> default active, autostart yes
virsh domifaddr vm1       -> 192.168.122.212/24
ssh ubuntu@192.168.122.212 "hostname"   -> ubuntu
```

Original file state, saved to `~/incidents/original-state.txt`:

```
-rw-r--r-- 1 libvirt-qemu kvm  621284352 Oct 17 13:17 noble-server-cloudimg-amd64.img
-rw-r--r-- 1 libvirt-qemu kvm     374784 Nov 23 07:37 seed.img
-rw-r--r-- 1 root         root 654180352 Nov 23 07:47 vm1.qcow2
```

Note: while the guest is shut off, `vm1.qcow2` is `root:root` mode 644. Later, while the guest was running, it showed `libvirt-qemu kvm` with a `+` (ACL). I believe libvirt relabels the disk when it starts a guest, but I did not confirm that.

## Order of checks for any "VM will not start" ticket

1. The exact error printed by `virsh start`.
2. `/var/log/libvirt/qemu/<vm>.log` (use `sudo tail -3`, because the last 20 lines are mostly the QEMU command line).
3. `sudo journalctl -u libvirtd --since "5 minutes ago" --no-pager | tail`.
4. Then the layer checks: `virsh domblklist`, `ls -l` on the disk path, `virsh net-list --all`, `df -h`.

---

## Fault A: missing disk file

**Symptom (customer words):** "My virtual machine will not start."

**Reproduce:**
```
sudo mv /var/lib/libvirt/images/vm1.qcow2 /var/lib/libvirt/images/vm1.bak
virsh start vm1
```

**First clue:** the `virsh start` error itself.
```
error: Cannot access storage file '/var/lib/libvirt/images/vm1.qcow2' (as uid:64055, gid:991): No such file or directory
```

**Diagnosis:** `virsh domblklist vm1` still pointed at `vm1.qcow2`, but `ls -l` showed only `vm1.bak`. The config and the disk no longer matched.

**Root cause:** the disk file was moved while the guest was still defined with the old path.

**Fix:** `sudo mv vm1.bak vm1.qcow2`, then `virsh start vm1`.

**Verify:** `virsh list` showed `running`, and `ssh ubuntu@192.168.122.212 "hostname"` returned `ubuntu`.

**What I learned:** the error already contained the answer (the exact path). The `uid:64055, gid:991` part shows libvirt checks access as the unprivileged QEMU user (`libvirt-qemu`, group `kvm`), not as root.

**What a customer should monitor:** do not move or rename disk files while a guest is defined. Use `virsh domblklist <vm>` to see which files a guest depends on.

---

## Fault B1: permission denied on the disk

**Symptom:** "The VM fails to start after we changed file permissions."

**Reproduce:**
```
sudo chmod 000 /var/lib/libvirt/images/vm1.qcow2
virsh start vm1
```

**First clue:** the `virsh start` error already carried QEMU's message.
```
error: internal error: process exited while connecting to monitor: ... qemu-system-x86_64: -blockdev {... "filename":"/var/lib/libvirt/images/vm1.qcow2" ...}: Could not open '/var/lib/libvirt/images/vm1.qcow2': Permission denied
```

**Diagnosis:** the same line appeared at the bottom of `/var/log/libvirt/qemu/vm1.log` and in the `libvirtd` journal. `ls -l` showed `----------  root root`. `aa-status` showed AppArmor loaded (187 profiles, 109 in enforce mode) with nothing pointing at this disk.

**Root cause:** mode 000 on the disk, so the unprivileged QEMU process could not open it.

**Fix:** restore the mode I recorded at the start (not a guess):
```
sudo chown root:root /var/lib/libvirt/images/vm1.qcow2
sudo chmod 644 /var/lib/libvirt/images/vm1.qcow2
```

**Verify:** guest started, `running`, SSH returned `ubuntu`.

**What I learned:** the lab guide suggested restoring `libvirt-qemu:kvm` with mode 600, but the file's original state was `root:root` 644. Recording `ls -l` first meant I restored the real original rather than someone else's assumption.

**What a customer should monitor:** file ownership and mode of everything under `/var/lib/libvirt/images/`, especially after backups, restores or manual copies.

---

## Fault B2: disk in the wrong location

**Symptom:** "We moved the disk to another folder and updated the path, and now the VM will not start."

**Reproduce:**
```
sudo cp /var/lib/libvirt/images/vm1.qcow2 ~/vm1.qcow2
virsh edit vm1            # changed the main disk <source file=...> to /home/ubuntu/vm1.qcow2
virsh domblklist vm1      # vda -> /home/ubuntu/vm1.qcow2
virsh start vm1
```

**First clue:**
```
error: Cannot access storage file '/home/ubuntu/vm1.qcow2' (as uid:64055, gid:991): Permission denied
```

**Diagnosis:**
- `ls -ld /home/ubuntu` showed `drwxr-x--- ubuntu ubuntu` (mode 750). `libvirt-qemu` is "other" for that directory, so it cannot enter it.
- `sudo dmesg | grep -i apparmor | tail -5` showed only `apparmor="STATUS"` profile_replace lines and no `apparmor="DENIED"` line.
- `/var/log/libvirt/qemu/vm1.log` ended with `shutting down, reason=failed` and no QEMU error. The `libvirtd` journal had the same "Cannot access storage file" line. So libvirt refused before QEMU even launched.

**Root cause:** the disk was in a home directory the QEMU user cannot reach. The evidence points to directory permissions rather than AppArmor. I did not prove it by changing the directory mode. A follow-up test is `chmod o+x /home/ubuntu` to see whether the start then fails with a real AppArmor denial.

**Fix:** put the original path back. `virsh edit` rejected my edit twice:
```
error: XML document failed to validate against schema: ... Extra element devices in interleave
```
Failed edits are not saved, so the guest kept pointing at the wrong path. I switched to a scripted edit:
```
virsh dumpxml vm1 > ~/vm1.xml
sed -i "s#/home/ubuntu/vm1.qcow2#/var/lib/libvirt/images/vm1.qcow2#" ~/vm1.xml
grep "source file" ~/vm1.xml
virsh define ~/vm1.xml
```

**Verify:** `virsh domblklist vm1` showed the original path, the guest started, SSH returned `ubuntu`. Then I removed the copy and the XML file and confirmed with `ls ~/vm1.*`.

**What I learned:** two different "Permission denied" errors exist. B1 was QEMU failing to open a file. B2 was libvirt's own access check failing first, and its message includes the uid and gid it checked as. `dumpxml`, `sed`, `define` is a safer way to change a guest's XML than an interactive edit when you cannot see the mistake.

**What a customer should monitor:** keep disks in libvirt storage pools, not in home directories.

---

## Fault C: guest network down

**Symptom:** "The VM is running but we cannot connect to it."

**Reproduce:**
```
virsh net-destroy default
virsh net-list --all
ip a show virbr0
virsh domifaddr vm1
ssh -o ConnectTimeout=5 ubuntu@192.168.122.212
```

**First clue:**
- `virsh list` still showed `vm1 running`, so the guest itself was fine.
- `virsh net-list --all` showed `default  inactive`.
- `ip a show virbr0` printed `Device "virbr0" does not exist.`
- SSH printed `Connection timed out`.

**Diagnosis:** `virsh domifaddr vm1` still listed `192.168.122.212` even though the network was gone. That output is stale and cannot be trusted as proof that the guest is reachable.

**Root cause:** the libvirt `default` network (and its bridge `virbr0`) was stopped, so the guest's virtual NIC had nothing to connect to.

**Fix attempts, in order:**
1. `virsh net-start default`: `virbr0` came back with IP 192.168.122.1, but its state was `NO-CARRIER ... state DOWN`.
2. `virsh reboot vm1`: SSH still failed, now with `No route to host`.
3. `virsh destroy vm1` then `virsh start vm1`: `virbr0` showed `UP,LOWER_UP`, and SSH returned `ubuntu`.

**Why:** my understanding is that the running guest's virtual NIC stayed attached to the old, deleted bridge. A reboot happens inside the same QEMU process and does not re-attach it. A full stop and start does. I did not inspect the tap device to confirm this.

**Variant (guest stopped first):**
```
virsh destroy vm1
virsh net-destroy default
virsh start vm1
error: Failed to start domain 'vm1'
error: Requested operation is not valid: network 'default' is not active
```
Same cause, different symptom: here the guest cannot even start. Fix: `virsh net-start default`, then `virsh start vm1`. SSH worked.

**What a customer should monitor:** `virsh net-list --all` should show `default` as `active`. After restarting a libvirt network, restart the guests that use it.

---

## Fault D: host disk full

**Symptom:** "The VM froze, and we cannot take a snapshot."

**Reproduce:** baseline `df -h` showed `/dev/root` 28G, 4.0G used, 24G available (15%). I filled all but 300 MB:
```
avail=$(sudo df --output=avail -BM /var/lib/libvirt/images | tail -1 | tr -dc 0-9)    # 24536 (MB)
sudo fallocate -l $((avail-300))M /var/lib/libvirt/images/filler
sudo df -h /var/lib/libvirt/images        # 28G used, 300M avail, 99%
virsh snapshot-create-as vm1 s2
ssh ubuntu@192.168.122.212 "dd if=/dev/zero of=~/big bs=1M count=2000"    # interrupted with Ctrl+C
```

**First clue:**
```
error: operation failed: snapshot-save job failed: Error while writing VM state: Input/output error
```
Then `virsh domstate --reason vm1` printed `paused (I/O error)`, and `df -h` showed `0` available at 100%.

**Diagnosis:** `df -h` on the host showed 100%. My `du -sh /var/lib/libvirt/images/*` failed with "No such file or directory" because the shell expanded the `*` without root, so it could not list the directory. Running `du` under `sudo` as a whole (for example `sudo du -sh /var/lib/libvirt/images`) is the correct form.

**Root cause:** the host filesystem was full. `vm1.qcow2` is thin-provisioned, so the guest thinks it has 19G, but the file only grows when data is written. When the host had no space, the write failed and libvirt paused the guest to protect its data. The image grew from about 650 MB to 3.07 GB (`vm1.qcow2` showed `3067019264`) during the `dd`.

**Fix:**
```
sudo rm /var/lib/libvirt/images/filler
virsh domstate --reason vm1     # still: paused (I/O error)
virsh resume vm1
ssh ubuntu@192.168.122.212 "rm -f ~/big; hostname; df -h /"
```

**Verify:** host `df -h` back to 16% used, `virsh domstate vm1` showed `running`, and the guest's own `df -h /` showed 2.9G used of 19G.

**What I learned:** freeing space does not automatically unpause the guest. It stayed `paused (I/O error)` until I ran `virsh resume`. Also, `rm` inside the guest does not shrink the qcow2 file on the host. Not tested: whether `fstrim` inside the guest reclaims space (the QEMU command line shows `discard=unmap`).

**What a customer should monitor:** free space on the filesystem holding the images, with an alert well before 100%. Thin-provisioned disks can fill a host without any warning from inside the guest.

---

## Where my results differed from the lab guide

| Step | Guide expected | What I actually saw |
|---|---|---|
| B1 restore | `chown libvirt-qemu:kvm`, `chmod 600` | original was `root:root` 644, so I restored that |
| B2 cause | AppArmor denial in `dmesg` | no `DENIED` line; home directory mode 750 and a libvirt pre-check failure |
| B2 undo | `virsh edit` | edit was rejected by schema validation; used `dumpxml`, `sed`, `define` |
| C fix | `virsh net-start default`, maybe reboot | reboot was not enough, needed `virsh destroy` then `start` |
| D result | no-space error | snapshot failed with I/O error and the guest paused; needed `virsh resume` |

## Troubleshooting table

| Symptom | First command | What it shows | Fix |
|---|---|---|---|
| `virsh start` says cannot access storage file, No such file | `virsh domblklist <vm>` then `ls -l` the path | path in config does not exist | restore the file or fix the path |
| `Could not open ... Permission denied` | `ls -l <disk>`, `ls -ld <parent dir>` | wrong mode, owner or unreachable directory | restore recorded mode and owner, keep disks in `/var/lib/libvirt/images/` |
| Guest running but no SSH | `virsh net-list --all`, `ip a show virbr0` | `default` inactive or bridge missing | `virsh net-start default`, then stop and start the guest |
| `network 'default' is not active` on start | `virsh net-list --all` | network stopped | `virsh net-start default` |
| Guest frozen or snapshot fails with I/O error | `virsh domstate --reason <vm>`, `df -h` | `paused (I/O error)`, disk 100% | free space, then `virsh resume` |

## Mistakes I made (and what I changed)

- Pasted the `mv` command twice, so the second one failed with "cannot stat". Fix: run each step once and read the output before the next.
- Put a cleanup `rm` in the same pasted block as the experiment, so it ran before I had looked at the result. Fix: clean up in a separate step.
- Ran `du` on a glob without root. Fix: put `sudo` in front of the whole command.
- Edited XML interactively and broke the schema. Fix: scripted edit with `virsh define`.

## Interview questions this lab prepares me for

1. **A VM will not start. Where do you look?** The `virsh start` error, then the QEMU log, then the `libvirtd` journal, then the disk path, permissions, network and free space.
2. **Why can root move a file that the VM cannot read?** QEMU runs as the unprivileged `libvirt-qemu` user, so it needs read and write access in its own right.
3. **Why does a full host break a guest with free space?** The qcow2 disk is thin-provisioned, so the guest's free space is not backed by host space.
4. **The guest is running but unreachable. What now?** Check the libvirt network and bridge, then restart the guest if its NIC was attached to the old bridge.
