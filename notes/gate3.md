# Gate 3: timed review (LVM, NFS fault, KVM guest)

Done on 25 Nov 2026 (plan Day 22). Targets: build and extend an LV in 10 min, fix one NFS fault in 10 min, create a KVM guest with cloud-init in 20 min. Cold, with little help from notes.

## Results

| Drill | Target | My time | Where I lost time |
|---|---|---|---|
| NFS fault A: permission denied | 10 min | 5 min | ran `chown` on the client instead of the server |
| NFS fault B: firewall on 2049 | 10 min | 5 min | first `nc` test ran on the server, so it always passed |
| NFS fault C: stale file handle | 10 min | 5 min | ran `ls /mnt/nfs` and `nc` on the server |
| NFS fault D: hard-mount hang | 10 min | 5 min | `dmesg` needed `sudo` |
| LVM build and extend | 10 min | 7 min | `mkdir /lvm` failed, so the `&&` skipped the mount |
| KVM guest from scratch | 20 min | 15 min | reused the name `vm1` on the first try, which was still running |

Gate 3 passes when the KVM guest is finished in 20 minutes: passed.

## Rules I now follow

- Read the exact error first. It usually names the cause.
- Test connectivity from the **client**. A machine testing its own IP always passes.
- Give every guest, disk and seed a new name. A running guest locks its disk.
- Check what exists (`sudo ls`) before downloading or generating anything.
- Never chain a step that must run after `mkdir` with `&&`. Use `mkdir -p`, then `mount` on its own line.
- After every build, prove it: `df -h /lvm`, `ls -ln /mnt/nfs`, a banner with no `Last login`.

## 1. LVM build and extend

```
lsblk                                    # read the device names first (mine: nvme1n1, nvme2n1)
sudo pvcreate /dev/nvme1n1 /dev/nvme2n1
sudo vgcreate vg0 /dev/nvme1n1           # one disk on purpose
sudo lvcreate -L 1G -n data vg0
sudo mkfs.ext4 /dev/vg0/data
sudo mkdir -p /lvm
sudo mount /dev/vg0/data /lvm
df -h /lvm                               # Filesystem column must say /dev/mapper/vg0-data
echo "before resize" | sudo tee /lvm/test.txt
sudo vgextend vg0 /dev/nvme2n1
sudo lvextend -r -L +1G /dev/vg0/data    # grows the LV and the filesystem
df -h /lvm; cat /lvm/test.txt
sudo pvs; sudo vgs; sudo lvs
```

What I saw:

- `mkdir /lvm` failed with `File exists`, so `mkdir && mount` never mounted. `df -h /lvm` showed `/dev/root`, and the test file was written to the root disk. I removed it, mounted, and repeated.
- `lvextend -r` on the unmounted volume ran `e2fsck` first, then `resize2fs` (1.00 to 2.00 GiB). On the mounted volume it printed `on-line resizing required` and grew 2.00 to 3.00 GiB with the file intact.
- `pvs`, `vgs`, `lvs` without `sudo` print `Running as a non-root user` and no tables.
- Final state: `nvme1n1` PFree 0, `nvme2n1` PFree 1016m, VG 3.99g, LV 3.00g.
- If `df` shows the old size after `lvextend`, the `-r` flag was missing: run `sudo resize2fs /dev/vg0/data`.

## 2. NFS faults

Setup: server `172.31.11.113`, client `172.31.10.139` (private IPs; instances run Ubuntu 26.04). Export: `/srv/share 172.31.10.139(rw,sync,no_subtree_check)`. Mount: `sudo mount -t nfs 172.31.11.113:/srv/share /mnt/nfs`.

Diagnosis order, always: reachable (client: `nc -zv -w 3 <server> 2049`) -> exporting (`showmount -e <server>`, `sudo exportfs -v` on the server) -> permissions and UIDs (`ls -ln`, `ls -lnd`, `id`) -> logs (`mount | grep nfs`, `sudo dmesg | tail`).

| Fault | Break | Symptom | First clue | Fix |
|---|---|---|---|---|
| A: permission denied | server: `chown root:root /srv/share; chmod 755 /srv/share` | `touch: Permission denied` as UID 1000 | `ls -lnd /mnt/nfs` shows owner `0 0` | on the **server**: `chown 1000:1000 /srv/share` |
| B: firewall | remove TCP 2049 rule from `nfs-sg` | mount hangs; `nc` times out | client `nc` timed out while server `showmount` still listed the export | re-add 2049 with source `nfs-sg` |
| C: stale handle | delete and recreate `/srv/share` while the client is inside it | `ls` fails with errno 116 `Stale file handle` | `nc` and `showmount` are fine, the error text is the clue | `cd ~`, `umount`, mount again (directory is empty) |
| D: hard-mount hang | stop `nfs-server` in the console | `ls /mnt/nfs` hangs | `nc` times out; `sudo dmesg` shows the server not responding | second terminal: `umount -f`, then `umount -l` if busy; start the server and remount |

What I saw:

- Fault A: `sudo touch` also fails on a 755 root-owned directory. `root_squash` maps remote root to `nobody` (65534). A file created with `sudo` on the client showed owner 65534 on the server.
- Fault A: `sudo chown 1000:1000 /srv/share` on the client printed `cannot dereference '/srv/share'`, because that path only exists on the server.
- Fault B: a timeout means packets are being dropped. Refused would mean nothing is listening (not reproduced here).
- Fault C: this `ls` on Ubuntu 26.04 printed `Os { code: 116, kind: StaleNetworkFileHandle, message: "Stale file handle" }` instead of the classic wording. Same error.
- Fault D: `Ctrl+C` freed the shell. `sudo umount -f /mnt/nfs` printed nothing, which is success; `mount | grep nfs` printed nothing afterwards. After the server restarted, the mount worked again and the file was still there.
- `showmount -e localhost` on the client prints `RPC: Program not registered` because the client runs no NFS server. Ask the server instead: `showmount -e <server-ip>`.
- `dmesg` without `sudo` fails with `Operation not permitted`.

## 3. KVM guest from scratch

Uses the base image already on the host (`sudo ls /var/lib/libvirt/images/`), and new names every time.

```
sudo qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/noble-server-cloudimg-amd64.img \
  /var/lib/libvirt/images/gate3.qcow2 20G

cat > ~/gate3-user-data <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_ed25519.pub)
EOF
cat ~/gate3-user-data                    # key line present, first line exactly #cloud-config

cloud-localds ~/gate3-seed.img ~/gate3-user-data
sudo cp ~/gate3-seed.img /var/lib/libvirt/images/

sudo virt-install --name gate3 --memory 1024 --vcpus 1 \
  --disk /var/lib/libvirt/images/gate3.qcow2 \
  --disk /var/lib/libvirt/images/gate3-seed.img,device=cdrom \
  --os-variant ubuntu24.04 --import --network network=default --noautoconsole

virsh domifaddr gate3                    # empty for 30-60 s after boot, retry
ssh ubuntu@<ip>
```

Pass checks: SSH login with no password, a banner with no `Last login` line, an IP different from the other guests. Mine was `192.168.122.97` against `vm1` at `192.168.122.212`.

Retry cleanly: `virsh destroy gate3` then `virsh undefine gate3 --remove-all-storage` (removes the overlay and seed, not the base image).

What went wrong on the first try:

- `qemu-img create ... vm1.qcow2` failed with `Failed to get "write" lock`, and `virt-install --name vm1` failed with `Disk ... is already in use by other guests ['vm1']`. `vm1` was running. Fix: new names (`gate3`, `gate3.qcow2`, `gate3-seed.img`).
- `ls /var/lib/libvirt/images/` gave `Permission denied`. Use `sudo ls`.
- I downloaded the base image again with `sudo wget` although it was already there, which created a duplicate `.img.1`. I removed it.
- I ran `ssh-keygen` although `~/.ssh/id_ed25519` existed. It asked to overwrite and I did not. Check `ls ~/.ssh/id_ed25519.pub` first.
- `virt-install` warns `Requested memory 1024 MiB is less than the recommended 3072 MiB`. Harmless for a cloud-image guest.
- `cloud-init status`, `hostname` and `ip a` need to run **inside** the guest. I first ran them on the host.

## Symptom to first command

| Symptom | First command |
|---|---|
| `df` shows `/dev/root` for an LV mount point | `findmnt /lvm`, then `sudo mount /dev/vg0/data /lvm` |
| `df` shows the old size after `lvextend` | `sudo resize2fs /dev/vg0/data` |
| LVM command prints `Running as a non-root user` | rerun with `sudo` |
| NFS write fails as a normal user | `ls -lnd` and `id` (numeric UIDs) |
| NFS mount hangs, then times out | client: `nc -zv -w 3 <server> 2049`, then security group and `ufw` |
| NFS `Stale file handle` | `umount`, mount again |
| NFS commands freeze | second terminal: `sudo dmesg \| tail`, `nc`, then `umount -f` |
| `virt-install`: `already in use by other guests` | `virsh list --all`, use a new name |
| `qemu-img`: `Failed to get "write" lock` | the disk belongs to a running guest, use a new overlay |
| guest has no IP yet | wait 30-60 s, retry `virsh domifaddr`, then `virsh net-dhcp-leases default` |
| SSH to the guest asks for a password or refuses the key | `cat` the `user-data` and check the key line, rebuild with a fresh overlay and seed |

## Interview questions I can now answer

- **What is the difference between a timeout and a refused connection?** A timeout means packets are being dropped (security group, firewall). Refused means the host answered and nothing is listening.
- **Why does a root write to an NFS share fail?** `root_squash` maps remote root to `nobody`, and NFS compares numeric UIDs, not names.
- **Why can an NFS command hang forever?** A `hard` mount retries on purpose so a write is never silently lost. The cost is a frozen command.
- **What does `lvextend -r` do?** It grows the LV and then the filesystem, and it works online for ext4.
- **How does cloud-init configure a guest with no password?** It reads a seed disk at first boot, creates the user, and installs the SSH key.

## Not verified

- I did not test growing an LV without `-r`.
- I did not reproduce NFS "connection refused".
- I did not run `getfacl` on the `+` files over NFS.
