# KVM first guest: cloud image, cloud-init, libvirt network, snapshots

*Day 17 · 23 Nov 2026 · host: `kvm-host` (EC2 `m7i-flex.large`, Ubuntu 26.04, nested virtualization) · guest: Ubuntu 24.04.5 (noble cloud image)*

Follows [kvm-host.md](kvm-host.md), which covers the host build. This note covers building a guest, how it gets its network and SSH key, and what went wrong on the way.

---

## What I built

```
kvm-host (EC2, Ubuntu 26.04, nested virtualization)
 |
 |-- /var/lib/libvirt/images/
 |     noble-server-cloudimg-amd64.img   base image: template, 593 MiB, virtual size 3.5 GiB
 |     vm1.qcow2                         overlay: 20 GiB virtual, backing file = the base image
 |     seed.img                          cloud-init seed (label "cidata"), attached as a CD-ROM
 |
 `-- virbr0  192.168.122.1/24   libvirt "default" network: NAT + DHCP (dnsmasq)
       `-- vnetN -- vm1  192.168.122.x   private address, reachable only from kvm-host
```

The guest (Ubuntu 24.04) is a different release from the host (Ubuntu 26.04). That is fine: the guest brings its own kernel.

## How the pieces fit: the boot sequence

1. `virt-install --import` writes the guest definition to `/etc/libvirt/qemu/vm1.xml` and starts a QEMU process that uses KVM.
2. The guest boots from `vm1.qcow2`. Reads fall through to the base image for blocks the overlay has not changed. Writes go to the overlay only (copy-on-write), so the base image stays clean.
3. cloud-init inside the guest finds the disk labelled `cidata`, reads `user-data`, creates the `ubuntu` user and installs my public key.
4. The guest asks for an address. dnsmasq on `virbr0` answers from the range 192.168.122.2 to .254.
5. The root filesystem grows to fill the 20 GiB disk (`df -h /` showed 19G, 1.7G used).

| Piece | What it is | Why it is there |
|---|---|---|
| Cloud image | Small pre-installed Ubuntu disk | No installer, boots in seconds |
| qcow2 overlay | File that stores only changes from a base image | Many VMs from one clean template |
| `user-data` | cloud-init config (first-boot recipe) | Creates the user and installs the SSH key |
| `seed.img` | Tiny disk labelled `cidata` holding `user-data` | How cloud-init finds the recipe |
| `virt-install` | Defines and starts a guest in libvirt | One command, no GUI |
| `virbr0` / `default` network | libvirt NAT bridge with built-in DHCP | Private IP for guests, internet via the host |

---

## Commands I ran

```bash
# 1. Base image
cd /var/lib/libvirt/images
sudo wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qemu-img info noble-server-cloudimg-amd64.img

# 2. Key and cloud-init (the heredoc inserts the real public key, no copy and paste)
ssh-keygen -t ed25519
cat > ~/user-data <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_ed25519.pub)
EOF
cat ~/user-data                         # always check the key line before building the seed
cloud-localds ~/seed.img ~/user-data
sudo cp ~/seed.img /var/lib/libvirt/images/seed.img

# 3. Overlay disk and guest
sudo qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/noble-server-cloudimg-amd64.img \
  /var/lib/libvirt/images/vm1.qcow2 20G
sudo virt-install --name vm1 --memory 1024 --vcpus 1 \
  --disk /var/lib/libvirt/images/vm1.qcow2 \
  --disk /var/lib/libvirt/images/seed.img,device=cdrom \
  --os-variant ubuntu24.04 --import \
  --network network=default --noautoconsole

# 4. Explore
virsh list
virsh dominfo vm1
virsh domifaddr vm1                     # wait up to a minute for an address
ssh ubuntu@<guest-ip>                   # from kvm-host
virsh console vm1                       # exit with Ctrl+]
virsh net-list --all
virsh net-dumpxml default | head -20
virsh pool-list --all
sudo qemu-img info -U /var/lib/libvirt/images/vm1.qcow2   # -U because the guest is running

# 5. Snapshot, break, revert
virsh snapshot-create-as vm1 clean
ssh ubuntu@<guest-ip> "sudo rm -rf /etc/hostname"
virsh snapshot-list vm1
virsh snapshot-revert vm1 clean
```

## What I measured

| Check | Result |
|---|---|
| Base image | qcow2, 593 MiB on disk, 3.5 GiB virtual size |
| Overlay after first boot | 55.7 MiB on disk, 20 GiB virtual size, backing file = the base image |
| Guest root filesystem | 19G total, 1.7G used (grown from the 3.5 GiB image) |
| `cloud-init status` | `done` |
| Guest address | 192.168.122.x from DHCP (first guest .67, rebuilt guest .212) |
| `default` network | active, autostart yes, `<forward mode='nat'/>`, bridge `virbr0`, gateway 192.168.122.1, DHCP .2 to .254 |
| Storage pool | `images`, active, autostart yes |
| Memory | 1024 MiB works; `virt-install` warns that 3072 MiB is recommended for Ubuntu 24.04 |
| Guest hostname | `ubuntu` (the cloud image default) |

---

## Problems I hit

### 1. Pasted the YAML at the shell prompt

**Symptom:** `Command 'users:' not found`, `-bash: syntax error near unexpected token '('`, `shell:: command not found`.
**Cause:** The shell prompt is not an editor. Each YAML line ran as a command.
**Fix:** Write the file with `nano ~/user-data` or a heredoc (`cat > ~/user-data <<EOF`).

### 2. `Permission denied (publickey)` on the first guest

**Symptom:** The guest booted and got an address, but `ssh ubuntu@192.168.122.67` was refused.
**Diagnosis:** `cat ~/user-data` showed the template line unchanged: `ssh-ed25519 AAAA...your-full-key... user@host`. cloud-init had installed a key that matches no private key I own.
**What did not matter:** I ran `chmod 400` on `~/.ssh/id_ed25519.pub`. File permissions on a *public* key do not affect login. SSH checks the *private* key, `~/.ssh/id_ed25519`, which must not be readable by group or others (mode 600 or 400). My other `chmod` attempts failed only because I was in `/var/lib/libvirt/images`, not `~/.ssh`, so the files were not found.
**Fix:** Regenerate `user-data` with `$(cat ~/.ssh/id_ed25519.pub)`, confirm with `cat`, rebuild `seed.img`, and create the guest again from a fresh overlay.
**Why a rebuild:** cloud-init applies the user and SSH key once, on first boot. Changing the seed afterwards does not fix a guest that has already booted.

### 3. Rebuilding the guest cleanly

```bash
virsh destroy vm1
virsh undefine vm1 --remove-all-storage
```

This removed `vm1.qcow2` **and** `seed.img`, because both were attached to the guest. The base image survived because it is only a backing file, not an attached disk. If I had attached the base image directly, `--remove-all-storage` would have deleted it. Always check with `virsh domblklist vm1` first.

The next `ls /var/lib/libvirt/images` failed with `Permission denied`: the folder is not readable by my user. Use `sudo ls -lh`.

### 4. `qemu-img info` on a running guest

**Symptom:** `Failed to get shared "write" lock. Is another process using the image?`
**Cause:** QEMU holds a lock on the disk while the guest runs.
**Fix:** `sudo qemu-img info -U <file>` (`-U` is `--force-share`). It is safe for reading. Never write to a disk a running guest is using.

### 5. New guest, new host key

Each new guest has its own SSH host key, and addresses can be reused. If a new guest gets an old guest's address, SSH shows `REMOTE HOST IDENTIFICATION HAS CHANGED`. Clear the old entry with `ssh-keygen -R <ip>`.

---

## Snapshot behaviour I observed

- `virsh snapshot-create-as vm1 clean` on a running guest created a snapshot whose State column says `running`. libvirt stores it inside `vm1.qcow2` (an internal snapshot).
- After `virsh snapshot-revert vm1 clean`, the domain ID changed from 2 to 3 and the network device from `vnet1` to `vnet2`, so libvirt restored the guest into a new QEMU process.
- The first SSH after the revert failed with `No route to host`. About 15 seconds later `ping` showed 0% loss, SSH worked, and `cat /etc/hostname` printed `ubuntu`.
- I did not confirm why the route was missing for a few seconds. A likely cause is the guest's network device being recreated. Next time I will check `ip neigh` on the host while it happens.
- **Gap in my test:** I ran the `rm` but did not show the file missing before the revert. Next time: `ssh ... "cat /etc/hostname"` between the `rm` and the revert, so the output proves the break and the repair.

---

## Where things live

| What | Path |
|---|---|
| Guest definitions | `/etc/libvirt/qemu/vm1.xml` |
| Guest logs | `/var/log/libvirt/qemu/vm1.log` |
| Disks, base image, seed | `/var/lib/libvirt/images/` |
| Default network definition | `virsh net-dumpxml default` |

---

## Interview Q&A

**How did the guest get its IP address?**
The guest sent a DHCP request on its virtual NIC. libvirt runs dnsmasq on `virbr0`, which answered with an address from 192.168.122.2 to .254 and the gateway 192.168.122.1.

**How did the guest get my SSH key without a password?**
cloud-init read `user-data` from the `cidata` disk (`seed.img`) on first boot and wrote the key to `/home/ubuntu/.ssh/authorized_keys`.

**Why use an overlay instead of copying the image?**
It is created instantly and stores only changes (55.7 MiB after first boot). The base stays clean, so many guests can share one template. The cost: the overlay depends on the base, so deleting or moving the base breaks every overlay.

**Why can't I SSH to the guest from outside the host?**
Its address is private and NATed behind `virbr0`. Only the host can reach it. To get in from elsewhere, jump through the host or use a bridged network.

**`Permission denied (publickey)` on a new cloud-init guest. What do you check?**
First what key cloud-init was actually given (`cat user-data`, then confirm the seed was rebuilt and the guest created after that). Then whether the private key is mode 600 and the right user and address are used. Last, `virsh console` or the guest's `/var/log/cloud-init.log` if I can get in another way.

**What does a snapshot protect you from, and what does it not?**
It rolls the guest back to a known state quickly. It is not a backup: an internal snapshot lives inside the same disk file, so losing that file loses both.

## Next time (not tried yet)

- Reach the guest from my Mac in one command: `ssh -J ubuntu@<kvm-host-ip> ubuntu@<guest-ip>`. This needs my Mac's public key as a second line under `ssh_authorized_keys` in `user-data`.
- Before stopping `kvm-host`, shut the guest down cleanly: `virsh shutdown vm1`. The guest definition persists, but autostart is disabled, so start it again with `virsh start vm1`.
- Day 18 (Lab 6) uses `vm1` for the fault exercises: guest will not start, no guest network, full storage pool.
