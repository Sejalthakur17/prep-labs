#!/usr/bin/env bash
# verify-kvm-host.sh
# Checks that this machine is ready to run KVM guests through libvirt.
# Usage: ./verify-kvm-host.sh   (run as the normal user, after logging in again
#        so the libvirt group applies)

set -u

pass=0
fail=0

check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: ${description}"
    pass=$((pass + 1))
  else
    echo "FAIL: ${description}"
    fail=$((fail + 1))
  fi
}

check "CPU exposes vmx or svm"              grep -Eq '(vmx|svm)' /proc/cpuinfo
check "/dev/kvm exists"                     test -c /dev/kvm
check "kvm-ok reports acceleration"         bash -c 'kvm-ok | grep -q "can be used"'
check "libvirt group exists"                getent group libvirt
check "current user is in libvirt group"    bash -c 'id -nG | tr " " "\n" | grep -qx libvirt'
check "libvirt daemon answers (virsh)"      virsh -c qemu:///system list --all
check "default libvirt network is active"   bash -c 'virsh -c qemu:///system net-list | grep -q "default.*active"'

echo
echo "Passed: ${pass}  Failed: ${fail}"

[ "${fail}" -eq 0 ]
