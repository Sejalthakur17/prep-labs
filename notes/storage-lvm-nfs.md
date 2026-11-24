# Day 20: LVM and NFS baseline

Done on 24 Nov 2026. AWS EC2, Ubuntu 26.04, ap-south-1. Everything below is from my own terminal output; unverified points are marked.
The NFS fault drills (permission denied, firewall, stale handle, hung mount) are Day 21 and are not covered here.

## Part 1: LVM

| Layer | Meaning | Commands |
|---|---|---|
| PV (physical volume) | A disk prepared for LVM | `pvcreate` |
| VG (volume group) | A pool made from one or more PVs | `vgcreate`, `vgextend` |
| LV (logical volume) | A slice of the pool that gets a filesystem | `lvcreate`, `lvextend` |

**What I did**
1. Created two 2 GiB gp3 EBS volumes in the same AZ as `lab1` and attached them as `/dev/sdg` and `/dev/sdh`.
2. They appeared as `nvme1n1` and `nvme2n1`, not the names in the lab guide (`nvme2n1`, `nvme3n1`). I read `lsblk` instead of copying names.
3. Matched disks to console volumes with `lsblk -o NAME,SIZE,SERIAL` (serial = volume ID without the hyphen), so I knew which disk was which before wiping anything.
4. `nvme1n1` had an unmounted ext4 partition. I mounted it read-only, saw only an empty `lost+found` dated Nov 17, then ran `wipefs -a` on the partition and then the disk. Why it had a filesystem: not confirmed (my guess is a volume created from an older snapshot).
5. Built and grew it:
```bash
sudo pvcreate /dev/nvme1n1 /dev/nvme2n1
sudo vgcreate vg0 /dev/nvme1n1            # one disk on purpose
sudo lvcreate -L 1G -n data vg0
sudo mkfs.ext4 /dev/vg0/data
sudo mkdir /lvm && sudo mount /dev/vg0/data /lvm
echo "before resize" | sudo tee /lvm/test.txt
sudo vgextend vg0 /dev/nvme2n1
sudo lvextend -r -L +1G /dev/vg0/data     # grows LV and filesystem while mounted
```

**Measurements**
| Step | `df -h /lvm` |
|---|---|
| After `mkfs.ext4` on a 1 GiB LV | 974M total, 284K used |
| After `lvextend -r -L +1G` | 2.0G total, 1.9G available |

- `/lvm/test.txt` still read `before resize` afterwards.
- `pvs`/`vgs`/`lvs` after: `vg0` 3.99g total, 1.99g free, `data` 2.00g. `nvme1n1` had 0 free and `nvme2n1` 1.99g free, so the LV used the whole first disk plus a sliver of the second while the filesystem still sees one disk.
- `-r` makes `lvextend` also run `resize2fs`. Without it the LV grows but `df` stays old; the fix is `resize2fs /dev/vg0/data`. I did not test the no-`-r` case.
- The mount was not persistent (no `/etc/fstab` entry).

**Lessons:** don't copy device names from a guide; match serials to the console first. `wipefs` destroys data, so I checked the disk was empty before running it.

## Part 2: NFS baseline

**Setup**
- Security group `nfs-sg`: TCP 2049, TCP 111 and UDP 111 with the source set to `nfs-sg` itself; SSH from my IP only (/32).
- Two t3.micro Ubuntu 26.04 instances (`nfs-server`, `nfs-client`), same subnet, both in `nfs-sg`. NFS uses **private** IPs.
- Server: `nfs-kernel-server`, `/srv/share` (mode 777 for the baseline), `/etc/exports`:
```
/srv/share <client-private-ip>(rw,sync,no_subtree_check)
```
then `sudo exportfs -ra` and `showmount -e localhost` (listed the export for the client IP).
- Client: `nfs-common`, then `sudo mount -t nfs <server-private-ip>:/srv/share /mnt/nfs`.

**What the mount line showed** (`mount | grep nfs`): `nfs4`, `vers=4.2`, `hard`, `proto=tcp`, `timeo=600`, `retrans=2`, `sec=sys`.
- `hard`: the client retries forever if the server is gone (protects data, makes commands hang).
- `sec=sys`: the server trusts numeric UIDs from the client.
- `nc -zv -w 5 <server> 2049` succeeded, so 2049 was open through the security group.

**Results**
- Files written on either side appeared on the other. `ls -ln` showed `1000 1000` on both machines, so no UID mismatch.
- **root_squash:** `sudo touch /mnt/nfs/rootfile` on the client created a file owned by `65534` (`nobody`), not 0; the server showed the same owner. It only worked because the directory was mode 777.
- The client's `ls -l` showed a `+` after the permissions (an ACL is present); the server's did not. I did not inspect the ACL, so I don't know why.

**Problem: `showmount -e` hung from the client** while the mount worked and `nc` to 2049 succeeded.
- Likely cause (not verified): `showmount` asks the server's `mountd` service on a port my security group doesn't allow. NFSv4 needs only 2049. `rpcinfo -p <server>` would confirm.
- Lesson: a hang or timeout means something is dropping packets; "connection refused" would mean the port is reachable with nothing listening.
- Also: `systemctl status nfs-server` logged `exportfs: can't open /etc/exports for reading` because the service started before I edited the file. After `exportfs -ra` the export list was correct.

**Storage cheat line:** EBS = block (a raw disk for one instance), S3 = object (API, not mounted), EFS = shared NFS-style file storage.

**Cleanup:** deleted the two 2 GiB LVM volumes after the lab. The NFS pair is kept for the Day 21 fault drills.
