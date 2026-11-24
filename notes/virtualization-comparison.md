# LXD vs Docker vs KVM

*24 Nov 2026 · host: `kvm-host` (AWS EC2 `m7i-flex.large`, nested virtualization, Ubuntu 26.04.1, kernel `7.0.0-1018-aws`)*

Related: [kvm-first-guest.md](kvm-first-guest.md) (how the KVM guest was built) and [incidents/06-kvm.md](../incidents/06-kvm.md) (four KVM faults).

Docker is not installed yet, so the Docker column is marked "not tested" wherever I have no measurement. Fill it in during Week 4.

## Comparison

| | LXD system container | Docker container | KVM virtual machine |
|---|---|---|---|
| Kernel | Same as the host: `uname -r` printed `7.0.0-1018-aws` on both | Not tested | Its own: guest `6.8.0-147-generic`, host `7.0.0-1018-aws` |
| Userland | Own: container Ubuntu 24.04.5 on a 26.04.1 host | Not tested | Own: full Ubuntu 24.04.5 guest |
| Isolation (what I saw) | Process namespace: one `sleep` was PID 6588 on the host and PID 658 inside the container | Not tested | Separate kernel on virtualized hardware (nested here) |
| Startup | 12.2 s until the container had an IPv4 address (one run, `dir` storage pool) | Not measured | 20.6 s cold and 17.1 s warm until SSH answered |
| Memory limit | `lxc config set c1 limits.memory 256MiB`, then `free -m` inside showed 256 total | Not tested | Fixed at `virt-install` time (`--memory 1024`) |
| Snapshot | `lxc snapshot` is filesystem only (`STATEFUL: NO`). I deleted a file, `lxc restore`, and the file was back | Not tested | Internal snapshot of a running guest also stored RAM state: 561 MiB inside the qcow2 |
| Typical use | A whole-OS-like "lightweight VM" | Package and run one application | Full OS, own kernel, strongest isolation |

## How I measured

- **KVM boot:** `time ( virsh start vm1 && until ssh ... true; do sleep 1; done )`. Stops when SSH answers. The first run was right after the instance restarted (cold), the second after a clean shutdown (warm).
- **LXD launch:** `time ( lxc launch ubuntu:24.04 c1 && until [ -n "$(lxc list c1 -c 4 --format csv)" ]; do sleep 0.2; done )`, run after the image was already downloaded. Stops when the container has an IPv4 address, the closest equivalent to "SSH answers".
- **Not comparable:** an earlier LXD run that stopped as soon as `lxc exec c1 -- true` succeeded took 9.9 s. At that point the container had no IP address yet, so I do not use it in the table.

## Limits of these numbers

- One LXD run and two KVM runs. Timings vary, so treat them as rough.
- The LXD storage pool uses the `dir` driver (`lxc storage list`). I have not tested another driver, so I cannot say how much faster LXD would be on ZFS or btrfs.
- KVM here runs on nested virtualization inside EC2, which is slower than on bare metal.
- The break in the LXD snapshot test was shown only by an empty `ls /root`, not by an explicit "No such file" error.

## My conclusion

LXD started faster than KVM here (12.2 s to an IP address against 17.1 to 20.6 s until SSH answered) most likely because a container shares the host's kernel, so there is no kernel to boot and no virtual hardware to set up. The gap was only moderate, probably because my LXD storage pool uses the `dir` driver and because KVM here runs on nested virtualization, but I did not test either explanation. The snapshots also stored different things: the LXD snapshot was filesystem only (`STATEFUL: NO`), while the KVM snapshot of a running guest also stored its RAM state (561 MiB). I would pick LXD for quick, disposable test environments that behave like a full OS and can share the host's kernel, and KVM when I need a separate kernel, a different OS, or the strongest isolation between workloads.