# Ubuntu lifecycle and security updates (Day 23)

Done on `lab1`, Ubuntu 26.04.1 LTS (resolute), 26 Nov 2026.

## 1. Concepts in my own words
- **LTS:** Long Term Support release, one every 2 years (April of even years), meant for servers and production.
- **Support length:** 5 years of standard security maintenance. On my 26.04 machine `pro security-status` says Main/Restricted is patched until **2031**.
- **Ubuntu Pro (ESM):** extends security coverage to **2036** for Main/Restricted (`esm-infra`) and for Universe/Multiverse (`esm-apps`). Free for personal use on up to 5 machines. My machine is **not attached**.

### Glossary
| Term | Meaning |
|---|---|
| Interim release | About 9 months of support, not for production |
| USN | Ubuntu Security Notice, the announcement of a security fix |
| CVE | Public ID for a vulnerability |
| SRU | Stable Release Update: a non-security bug fix, tested in `-proposed` first, so slower |
| HWE | Newer kernels backported to an LTS |
| Launchpad | Where Ubuntu bugs are tracked (`LP: #...`) |
| Pocket | A channel in the archive: `resolute`, `resolute-security`, `resolute-updates`, `resolute-backports` |

## 2. Commands run on the VM
| Command | What it showed |
|---|---|
| `lsb_release -a` | Ubuntu 26.04.1 LTS, codename resolute |
| `pro security-status` | 715 packages: 708 Main/Restricted, 7 Universe/Multiverse. Not attached to Pro. (`ubuntu-security-status` is now an alias that redirects here.) |
| `pro status` | esm-apps, esm-infra, livepatch, landscape available but not enabled |
| `sudo apt update` | Refreshed the package lists (they were 4 days old). 30 packages upgradable afterwards |
| `apt list --upgradable` | The pocket after the slash shows the kind of update (see section 3) |
| `apt changelog <pkg> \| sed -n '1,/^ -- /p'` | Newest changelog entry only: pocket, CVEs, patches |
| `apt policy <pkg>` | Installed vs Candidate, and which pockets offer each version |
| `apt rdepends --installed libpcap0.8t64` | Only `tcpdump` depends on it here |

## 3. Security update vs SRU
Read the pocket in `apt list --upgradable` or on the first line of the changelog.

| Pocket shown | Kind | Examples from my VM |
|---|---|---|
| `resolute-updates,resolute-security` | Includes a security fix | libexpat1, libpcap0.8t64, krb5 libs, tzdata, linux-aws |
| `resolute-updates` only | Regular fix or backport (SRU) | vim, fwupd, snapd, libsqlite3-0 |

- `vim 2:9.1.2141-1ubuntu4.10` is labelled `resolute` with an `LP:` bug, so it is a regular fix. The entry below it (`4.9`) was `resolute-security`, so one package can get both kinds.
- `fwupd 2.1.6-3ubuntu4~26.04.1` says "Backport to resolute" with several `LP:` bugs: a classic SRU.
- Security fixes are published to both `-security` and `-updates`, so machines with only one enabled still get them.

## 4. Security update trace A: libpcap, USN-9203-1 (25 Nov 2026)
- **Package:** libpcap (binary package here: `libpcap0.8t64`). Only `tcpdump` depends on it on my VM.
- **CVEs (7):**
  - CVE-2025-11961: bad MAC address validation in `pcap_ether_aton()`, out-of-bounds read/write. **Affects only 22.04 and 24.04, not 26.04.**
  - CVE-2026-18238: rpcap client trusts messages from a remote server (info leak, crash).
  - CVE-2026-18313: rpcapd does not free memory for client filter programs (memory-exhaustion DoS).
  - CVE-2026-31911: BPF interpreter mishandles invalid instructions (crash).
  - CVE-2026-31912: BPF interpreter missing bounds check (out-of-bounds read).
  - CVE-2026-6244: BPF interpreter missing division-by-zero check (crash).
  - CVE-2026-6554: BPF interpreter does not limit backward jumps (hang, remote DoS).
- **Risk on my VM:** low. Most issues need an attacker who controls a filter program or a remote capture server. Patch anyway.
- **Before:** `1.10.6-1ubuntu1.1`. **After:** `1.10.6-1ubuntu1.2` (offered by `resolute-security`).

## 5. Security update trace B: expat 2.7.4-1ubuntu0.3 (resolute-security)
- Changelog dated 24 Nov 2026. Fixes **10 CVEs**: 93990 and 134703 (UTF-16 surrogate handling), 102633 and 118370 (integer overflows), 77214 and 124317 (out-of-bounds reads), 115506 and 113351 (memory-use DoS), 117610 (NULL pointer dereference), 128241 (xmlwf symlink following).
- expat is a shared XML parser library, so many programs are exposed to crafted XML files. Programs that already loaded the old library must be restarted.
- **Backporting:** Ubuntu keeps upstream 2.7.4 and adds its own patches (`ubuntu0.3`). Never judge exposure by the upstream version number: read the changelog or the CVE page.
- `-pre-N` patches are preparatory refactors, not separate vulnerabilities.
- **Before:** `2.7.4-1ubuntu0.2`. **After:** `2.7.4-1ubuntu0.3`.

## 6. After the upgrade
`needrestart` restarted `polkit.service` and **deferred** `dbus.service`, `networkd-dispatcher.service` and `unattended-upgrades.service`. Restarting `dbus` can disrupt the system, so it was left for me. Fix: restart the other two and reboot when convenient.
```
sudo systemctl restart networkd-dispatcher.service unattended-upgrades.service
ls /var/run/reboot-required     # exists only if a reboot is pending
```
Kernel check: `Running kernel seems to be up-to-date.`

## 7. Customer reply template
> Hello, security fixes for supported LTS releases are published as USNs. For libpcap the notice is USN-9203-1 (https://ubuntu.com/security/notices/USN-9203-1). On Ubuntu 26.04 the fixed package is `libpcap0.8t64 1.10.6-1ubuntu1.2`. Please run `sudo apt update && sudo apt upgrade`, then restart services that use the library. Confirm with `apt policy libpcap0.8t64` that Installed matches the fixed version. One of the issues, CVE-2025-11961, only affects 22.04 and 24.04, so it does not apply to your release.

If the release is out of standard support: Ubuntu Pro (ESM) is how security fixes continue to arrive.

## 8. Ubuntu 24.04 vs 26.04
| | 24.04 LTS (noble) | 26.04 LTS (resolute) |
|---|---|---|
| Standard security support | until 2029 | until **2031** (seen on my VM) |
| With Ubuntu Pro (ESM) | until 2034 | until **2036** (seen on my VM) |
| Kernel | 6.8 series | **7.0** series (`linux-aws 7.0.0-...`) |
| OpenSSL | 3.0.x | **3.5.5** (seen in the openssl changelog) |
| glibc | 2.39 | **2.43** (seen in `libc-bin 2.43-...`) |
| Security status command | `ubuntu-security-status` | `pro security-status` (old name redirects) |
| Package indexes | `amd64` | also `amd64v3` indexes (seen in `apt update`) |
| Upgrade path | `do-release-upgrade` to 26.04 once the first point release is out | n/a |

Check any row on a machine with: `uname -r`, `openssl version`, `ldd --version | head -1`, `apt policy <pkg>`, `lsb_release -a`.

## 9. Commands to remember
`lsb_release -a` · `pro security-status` · `pro status` · `apt list --upgradable` · `apt policy <pkg>` · `apt changelog <pkg> | sed -n '1,/^ -- /p'` · `sudo apt install --only-upgrade <pkg>` · `apt rdepends --installed <pkg>` · `ls /var/run/reboot-required`