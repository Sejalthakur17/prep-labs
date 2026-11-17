# Server running but unreachable: boot stopped in emergency mode after a bad /etc/fstab entry

**Date / environment:** 17 Nov 2026 · AWS EC2 `lab1` (t3.small, ap-south-1b) · Ubuntu 26.04.1 LTS, kernel 7.0.0-1016-aws · 8 GiB gp3 root volume + 2 GiB gp3 data volume · repair instance `rescue` (t3.micro, same AZ)

**Symptom (what the "customer" would report):**
"My instance shows as running in AWS, but I can't SSH in after a reboot." First `Operation timed out`, later `Connection refused`.

**Impact:** `lab1` completely unreachable. In a production setting this would be a full outage of anything hosted on the server.

---

## Timeline (command → what I saw → what I concluded)

| # | What I did | What I saw | What I concluded |
|---|---|---|---|
| 1 | Attached a 2 GiB EBS volume, then `lsblk`, `fdisk`, `mkfs.ext4`, `mount` at `/data` | `df -h /data` showed 2.0G; `blkid` gave UUID `a88ad6d2-acc5-48bc-9bf2-649344512a07` | The disk itself works |
| 2 | Added an fstab line for `/data`, ran `mount -a`, rebooted | After reboot `/data` was **not** mounted; `mount -a` printed nothing | Realised later: the line still had a placeholder instead of my real UUID, so it could never match a disk, and `nofail` hid the error (see Second finding) |
| 3 | Deliberately added `UUID=11111111-2222-3333-4444-555555555555  /broken  ext4  defaults  0  2` (fake UUID, **no `nofail`**) and ran `sudo reboot` | SSH: `Operation timed out` | Server not reachable |
| 4 | Checked the EC2 console | Instance state Running, status checks 3/3 passed, public IP unchanged | Status checks were misleading; they lag behind the real state |
| 5 | Checked the security group | SSH allowed from my IP; EC2 Instance Connect also failed (expected, since the rule only allows my own IP) | Ruled out network rules |
| 6 | `nc -vz -w 5 <ip> 22` | `Connection refused` | Packets reach the host but nothing is listening, so `sshd` is not running |
| 7 | EC2 console screenshot / `aws ec2 get-console-output --instance-id <id> --latest --output text` | `Timed out waiting for device /dev/disk/by-uuid/11111111-…` → `Dependency failed for broken.mount - /broken` → `Dependency failed for local-fs.target` → `Reached target emergency.target - Emergency Mode` | **Root cause found:** the boot stopped in emergency mode over the fake fstab entry |
| 8 | Stopped `lab1`, detached its root volume, attached it to `rescue` as `/dev/sdf` | First I mounted the wrong volume (the 2 GiB data disk): only `lost+found`, and nano said `/mnt/fix/etc` did not exist | Wrong volume. Found the right one via the volume's **Attached resources** panel |
| 9 | Mounted the 6.9G root partition at `/mnt/fix`, `cat /mnt/fix/etc/fstab` | Three default Ubuntu lines + the `/broken` line; **no `/data` line** | Confirms the bad line; no `/data` line was left in the file |
| 10 | Backed up the file, deleted `/broken`, added the correct `/data` line with `nofail`, unmounted, reattached the volume to `lab1` as `/dev/sda1`, reattached the data volume as `/dev/sdf`, started `lab1` | SSH worked on the new public IP (it changes after stop/start) | Fixed |

---

## Root cause
`/etc/fstab` contained an entry for a device that does not exist (fake UUID) and had no `nofail` option. At boot, systemd waited about 90 seconds for the device, treated the failed mount as a required dependency of `local-fs.target`, and dropped into emergency mode. `sshd` never started, so the server was running but unreachable.

## Fix
Mounted the broken root volume on a second instance (`rescue`), removed the bad line, put in the correct `/data` entry with `nofail`, reattached the volume to `lab1` as `/dev/sda1`, and started the instance.

Final fstab:
```
LABEL=cloudimg-rootfs	/	ext4	discard,commit=30,errors=remount-ro	0 1
LABEL=BOOT	/boot	ext4	defaults	0 2
LABEL=UEFI	/boot/efi	vfat	umask=0077	0 1
UUID=a88ad6d2-acc5-48bc-9bf2-649344512a07  /data  ext4  defaults,nofail  0  2
```

## How I verified
- SSH login worked after the instance started.
- `df -h /data` showed `/dev/nvme1n1p1  2.0G … /data`.
- `findmnt --verify` reported 0 parse errors and 0 errors (the 4 warnings were only "Permission denied" because I ran it without `sudo`).
- Final reboot test: **[FILL IN: after `sudo reboot`, did `/data` mount by itself? yes/no]**

## Prevention / what to monitor
- Use `nofail` on any non-root mount so a missing disk cannot block boot.
- Before every reboot after editing fstab: `cat /etc/fstab` (confirm what was saved), `sudo findmnt --verify`, `sudo mount -a`, then `df -h <mountpoint>`.
- Copy the real UUID from `blkid` into the line and re-read the file for leftover placeholder text. `nofail` will hide a wrong UUID, so confirm with `df -h` after `mount -a`.
- Take an AMI or snapshot before risky changes.
- Keep a runbook for "running but unreachable": console screenshot and system log first, then security group, then the rescue-instance method.

## What I learned
1. AWS status checks can show 3/3 passed while the OS is stuck in emergency mode, so the console log is the more reliable evidence. `Operation timed out` and `Connection refused` also mean different things: refused means the packets arrived but no service was listening.
2. Identify EBS volumes by their **Attached resources** panel, not by size alone. I mounted the wrong disk once before getting it right.

---

## Second finding: why `/data` did not mount the first time
My first `/data` entry did not mount after the first reboot, and `mount -a` printed no error. The cause: I had left the placeholder text in the line instead of pasting my real UUID from `blkid`. A UUID that matches no disk, combined with `nofail`, makes `mount -a` fail silently, because `nofail` suppresses errors for missing devices. So nothing mounted and nothing was reported.

By the time of recovery that line was no longer in the file (it was replaced when I edited fstab to add the fake line), so I cannot show the original line. This explanation comes from my own account of what I typed.

Lesson: `nofail` protects the boot but hides mistakes. After `mount -a`, always confirm with `df -h <mountpoint>` or `findmnt`, and never rely on "no output" alone.

---

## Part 2: service and permission faults (to be added on Day 5)
*(nginx syntax error, unreadable web root, port 80 already in use)*
