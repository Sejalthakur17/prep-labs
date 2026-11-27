# EC2 instance unreachable over SSH: troubleshooting runbook

**Environment:** Ubuntu Server on an AWS EC2 instance (t3.micro), default VPC, public subnet, connecting from a laptop with an OpenSSH client.

**Symptom:** `ssh -i key.pem ubuntu@<public-ip>` fails, hangs, or is refused.

**Audience:** anyone who can reach the AWS console and has never debugged this before.

---

## 1. Read the error first

The error text tells you which layer is broken before you check anything else.

| What you see | What it means | Layer | Where to look first |
|---|---|---|---|
| `Operation timed out` / `Connection timed out` | Packets are being dropped on the way | AWS network | Security group, network ACL, route table, wrong IP |
| `Connection refused` | The packet arrived but nothing is listening on port 22 | Inside the OS | sshd stopped, OS firewall (ufw) |
| `UNPROTECTED PRIVATE KEY FILE`, `bad permissions`, then `Permission denied (publickey)` | Your own SSH client ignored the key file | Your machine | Key file permissions |
| `Permission denied (publickey)` with no warning above it | The server rejected the key or username | Authentication | Key pair, username |

**Rule of thumb:** a timeout means something is dropping packets, "refused" means someone answered and said no, and "permission denied" means you got all the way to the SSH server.

---

## 2. The checklist (work from outside in)

The order is outside in: check the cheapest and most common causes first, then go deeper. Do not change anything until you have looked at the item.

| # | Check | Why it matters | How to check |
|---|---|---|---|
| 1 | Instance state and the two status checks | If AWS says the instance or its host is unhealthy, nothing else matters | Console, EC2, Instances, Status checks column. The system check is AWS's hardware and network. The instance check is your OS. |
| 2 | Public IP or Elastic IP | A normal public IP changes after stop and start, so you may be connecting to the old address | Console, instance details |
| 3 | Security group inbound rule | The most common cause. A security group is a firewall around the instance. | Security tab. Is there a rule for TCP 22 from your current IP? Your IP changes with your network. |
| 4 | Network ACL | A second firewall on the subnet. It is stateless, so it must allow traffic in and out. | VPC, Network ACLs |
| 5 | Route table and internet gateway | Without a route to the internet gateway (`0.0.0.0/0` to `igw-...`), a public subnet isn't public | VPC, Route tables |
| 6 | Key, username, key permissions | Wrong key or user gives `Permission denied (publickey)`. Loose permissions on the key file gives a "bad permissions" warning. | `ubuntu` is the user for Ubuntu images. Run `ls -l key.pem` and look for `-r--------`. |
| 7 | System log or screenshot | Shows boot errors such as a bad fstab, without needing SSH | Actions, Monitor and troubleshoot, Get system log |
| 8 | Inside the OS | Full disk, sshd down, ufw blocking 22 | Only reachable through Instance Connect, SSM, or by stopping the instance and mounting its disk elsewhere |

The steps below explain each check in detail.

### Step 1: Is the instance healthy?

- Console, EC2, Instances. The state must be **Running**.
- The **Status check** column should read `2/2 checks passed` (or `3/3` on newer instances).
  - *System status check* fails: problem on AWS's side (hardware or network). Stop and start the instance to move it to a new host.
  - *Instance status check* fails: problem inside your OS (bad boot, full disk, kernel). Go to step 7.

### Step 2: Is the public IP the one you are using?

- A normal public IPv4 address **changes every time the instance is stopped and started**.
- Compare the **Public IPv4 address** in the console with the address in your command.
- If you need a fixed address, attach an **Elastic IP**. Release it when you are done, because an unattached Elastic IP costs money.

### Step 3: Does the security group allow your current IP on port 22?

The security group is the firewall around the instance. This is the most common cause of a timeout.

1. Console, instance, **Security** tab, open the security group, **Inbound rules**.
2. Look for a rule: type **SSH**, protocol **TCP**, port **22**.
3. Check the **Source** column.

Three things can be wrong here:

| Problem | How it looks | Fix |
|---|---|---|
| The rule was deleted | No port 22 row | Add: SSH, TCP, 22, source **My IP** |
| The rule exists but the source is an old IP | Port 22 row present, source does not match your IP | Edit the rule and set the source to **My IP** |
| The rule exists for the wrong port or protocol | Port is not 22, or protocol is UDP | Correct the port and protocol |

**How to detect the stale-IP case:**

```
curl -4 ifconfig.me
```

This prints your current public IP. If it differs from the Source column (for example, the rule says `203.0.113.10/32` but you are now `203.0.113.77`), that is the cause.

A rule created with **My IP** is a snapshot taken at creation time. Your IP changes when your ISP rotates it, when you switch networks (home, office, phone hotspot), or when you start a VPN. The deleted-rule fault and the stale-IP fault produce the same timeout, so always compare the two addresses.

### Step 4: Does the network ACL allow it?

- A network ACL is a second firewall on the subnet. Unlike a security group, it is **stateless**, so it must allow traffic in **and** out (return traffic uses ephemeral ports 1024 to 65535).
- Console, VPC, Network ACLs, find the one attached to the instance's subnet.
- The default ACL allows everything. If someone customised it, look for a deny rule on port 22 or on the ephemeral range.

### Step 5: Does the subnet have a route to the internet?

- Console, VPC, Route tables, find the table attached to the instance's subnet.
- A public subnet needs a route `0.0.0.0/0` pointing to an **Internet Gateway** (`igw-...`).
- If the route is missing or marked **blackhole**, the instance cannot be reached from the internet even when everything else is correct.
- Also confirm the instance actually has a public IPv4 address (step 2).

### Step 6: Key, username and key permissions

- **Username:** `ubuntu` for Ubuntu images (`ec2-user` for Amazon Linux). A wrong username gives `Permission denied (publickey)`.
- **Key pair:** the instance details show the key pair name. Make sure you are using the matching `.pem` file.
- **Key permissions:** the key must not be readable by other users.

```
ls -l key.pem          # should show -r--------
chmod 400 key.pem
```

Reproduced error with `chmod 644`:

```
WARNING: UNPROTECTED PRIVATE KEY FILE!
Permissions 0644 for 'key.pem' are too open.
This private key will be ignored.
Load key "key.pem": bad permissions
ubuntu@<ip>: Permission denied (publickey).
```

The last line looks like the server rejected the key, but the lines above show the client never sent it. Always read the whole output, or run `ssh -v` for details.

### Step 7: Look at the instance without logging in

- Console, select the instance, **Actions, Monitor and troubleshoot, Get system log** (and **Get instance screenshot**).
- Look for boot errors: `emergency mode`, a failed mount (bad `/etc/fstab`), kernel panic, `No space left on device`.

### Step 8: Inside the OS (only if you can get in)

| Cause | Check |
|---|---|
| Disk full | `df -h`, `df -i` |
| sshd not running | `systemctl status ssh`, `journalctl -u ssh` |
| OS firewall blocking | `sudo ufw status`, `sudo ss -tulpn \| grep :22` |
| Bad sshd config | `sudo sshd -t` |

If you cannot log in over SSH, see the recovery options below.

---

## 3. Recovery when SSH is not available

| Situation | Option | Notes |
|---|---|---|
| Port 22 closed in the security group | Fix the rule in the console | The console edit is AWS-side and needs no SSH. **Connect (EC2 Instance Connect) will not help**, because it also uses SSH to the instance. |
| Your key or client is the problem | **Connect** button, EC2 Instance Connect | Works only if port 22 is open to AWS's Instance Connect range and the OS supports it. |
| Instance has the SSM agent and an IAM role | **Session Manager** (Systems Manager) | Needs no inbound port at all. Must be set up in advance. |
| OS is broken (bad fstab, full disk, sshd broken) | Stop the instance, detach the root volume, attach it to a helper instance, fix the files, reattach as the original root device, start | Always note the device name and take a snapshot first. |

---

## 4. Worked example (lab reproduction)

**Setup:** instance `lab1`, Ubuntu, security group with SSH, HTTP and HTTPS allowed from my IP only.

**Fault A: stale source IP**

1. SSH from the laptop: `Operation timed out`.
2. Instance state: Running, all status checks passed. So AWS and the OS are healthy.
3. Public IP in the console matches the one I used. So not a changed instance address.
4. Security group: port 22 rule present, but the source was the old IP.
5. `curl -4 ifconfig.me` printed a different address. The ISP had assigned a new public IP overnight.
6. Edited the three inbound rules (22, 80, 443) to **My IP**. SSH worked immediately.

**Fault B: deleted SSH rule**

1. Deleted the port 22 rule on purpose.
2. SSH: `Operation timed out`, identical to Fault A.
3. Following the checklist, steps 1, 2 and 4 to 6 were fine and step 3 showed no port 22 rule.
4. Re-added SSH, TCP, 22, source **My IP**. SSH worked again.

**Fault C: key permissions**

1. `chmod 644 key.pem`, then SSH: `bad permissions` and `Permission denied (publickey)`.
2. `chmod 400 key.pem`. SSH worked.

**Takeaway:** faults A and B look the same from the outside. The difference is only found by comparing the real IP with the rule's source.

---

## 5. Verify the fix

```
ssh -i key.pem ubuntu@<public-ip>
```

You should get a shell prompt. Also confirm from the console that status checks still pass.

---

## 6. Prevention

- Check your IP (`curl -4 ifconfig.me`) before blaming AWS.
- Use an Elastic IP if the address must stay fixed, and release it afterwards.
- Do not open port 22 to `0.0.0.0/0` as a shortcut. Use **My IP** or a known range.
- Set up Session Manager so you have a way in that does not depend on port 22.
- Keep key files at `chmod 400` and store them in `~/.ssh/`.
- Take a snapshot or AMI before changing anything risky.

---

## 7. Quick reference

```
# From your laptop
curl -4 ifconfig.me                      # my current public IP
ssh -v -i key.pem ubuntu@<ip>            # verbose, shows which step fails
nc -zv -w 3 <ip> 22                      # is port 22 reachable at all?
chmod 400 key.pem                        # fix key permissions

# On the instance
df -h; df -i                             # disk and inode use
systemctl status ssh                     # is sshd running?
sudo ss -tulpn | grep :22                # is anything listening on 22?
sudo ufw status                          # OS firewall
journalctl -u ssh -n 50                  # sshd logs
```
