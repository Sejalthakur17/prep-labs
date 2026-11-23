# qemu-kvm has no installation candidate on Ubuntu 26.04

## Environment

- Ubuntu 26.04.1 LTS (resolute), amd64, running on AWS EC2 with nested virtualization
- Installing a KVM/libvirt stack with `apt`

## Symptom

Running the usual install command fails:

```
$ sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils cloud-image-utils
Package qemu-kvm is a virtual package provided by:
  qemu-system-x86-hwe 1:10.2.1+ds-1ubuntu4.4 (= 1:10.2.1+ds-1ubuntu4.4)
  qemu-system-x86 1:10.2.1+ds-1ubuntu3.3 (= 1:10.2.1+ds-1ubuntu3.3)
You should explicitly select one to install.

Error: Package 'qemu-kvm' has no installation candidate
```

Adding the user to the libvirt group then fails as well:

```
$ sudo usermod -aG libvirt $USER
usermod: group 'libvirt' does not exist
```

## Cause

`qemu-kvm` is a virtual package on this release. It is only a name that points
to real packages, and two packages provide it (`qemu-system-x86` and
`qemu-system-x86-hwe`). With `-y`, apt cannot choose between them, so it aborts
the whole transaction and installs nothing.

The `usermod` error is a side effect. The `libvirt` group is created while the
libvirt packages are installed. Because the install was cancelled, the group
never existed.

## Solution

1. Install the real package instead of the virtual one:

   ```
   sudo apt install -y qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst bridge-utils cloud-image-utils
   ```

   Use `qemu-system-x86`, the standard x86 package. The `-hwe` variant belongs
   to the hardware-enablement kernel stream and is not needed here.

2. Confirm the group now exists, then add your user:

   ```
   getent group libvirt
   sudo usermod -aG libvirt $USER
   ```

3. Log out and back in so the new group applies to your session.

## Verification

```
virsh list --all          # empty table with headers, no error
ls -l /dev/kvm            # character device, group kvm
systemctl is-active libvirtd
virsh net-list --all      # default network: active, autostart yes
```

The install now completes, `getent group libvirt` shows your user, and
`virsh list --all` runs without a permissions error.
