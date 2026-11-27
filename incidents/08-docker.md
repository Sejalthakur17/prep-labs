# Incident 08: Docker container faults

**Date:** 27 Nov 2026
**Environment:** EC2 `t3.micro` (about 900 MiB RAM), Ubuntu 26.04.1 LTS, kernel `7.0.0-1018-aws`, Docker 29.1.3 (`docker.io` package). Images: `ubuntu:24.04`, `ubuntu:26.04`, `nginx`.
**Method:** for every drill I wrote down a prediction first, ran the command, then compared. Where the result differed from my prediction, I say so.

## Summary

| # | Fault | What I saw | First command that revealed the cause | Cause |
|---|---|---|---|---|
| 1 | Container "exits at once" | Status `Created`, empty logs, exit code 127 | The error printed by `docker run` | Command not found inside the image |
| 2 | Container looks stuck | `Up 4 minutes`, 1.9 MiB memory, 0.5% CPU, never killed | `docker stats --no-stream` | Process idle, not looping or leaking |
| 3 | Container killed, exit 137 | `OOMKilled=true`, exit code 137 | `docker inspect --format '{{.State.OOMKilled}} {{.State.ExitCode}}'` | Hit its 64 MiB memory limit |
| 4 | Web server not reachable | `curl localhost:80` answered from the wrong server, then a port conflict | `sudo ss -tulpn \| grep :80` | Port not published, and the host's own nginx held port 80 |
| 5 | Bind mount write fails | `Permission denied` | `ls -ld` on the host and inside the container | Container user UID 1000 vs a root-owned host folder |

---

## Fault 1: Container exits immediately (exit code 127)

**Symptom:** `docker run --name t1 ubuntu:24.04 nonexistent-cmd` printed an error and returned to the prompt. `docker ps` showed nothing.

**Investigation:**

```
docker ps                  # empty
docker ps -a               # t1 listed, STATUS = Created
docker logs t1             # empty
docker inspect t1 --format '{{.State.ExitCode}}'    # 127
```

The only evidence was the error on the `docker run` line itself:

```
OCI runtime create failed: runc create failed: unable to start container process:
error during container init: exec: "nonexistent-cmd": executable file not found in $PATH
```

**Cause:** the command does not exist in the image, so the process never started.

**What differed from my prediction:** I expected `Exited`. The status was `Created`, which means Docker built the container but the process never ran. An `Exited (N)` status means the process ran and then stopped.

| Status | Meaning | Where to look |
|---|---|---|
| `Created` | The process never started | The error from `docker run` (bad command, bad mount, networking) |
| `Exited (N)` | The process ran, then stopped | `docker logs` and the exit code |

**Side issue:** re-running with the same `--name t1` failed with `The container name "/t1" is already in use`. Names stay reserved until the container is removed.

**Fix:** use a valid command. Remove the old container with `docker rm t1` (or use `docker run --rm` for throwaway containers).

**Verify:** `docker run --rm ubuntu:24.04 echo ok` prints `ok` and leaves nothing behind in `docker ps -a`.

---

## Fault 2: Container looks stuck but is idle

**Symptom:** `docker run --memory 64m --name t2 ubuntu:26.04 bash -c 'tail /dev/zero'` never returned. I expected it to be OOM-killed within seconds.

**Investigation (from a second terminal):**

```
docker ps
docker stats --no-stream t2
```

```
STATUS         Up 4 minutes
CPU %          0.54%
MEM USAGE      1.879MiB / 64MiB
PIDS           1
```

**Finding:** the container was running but using almost no memory and almost no CPU. It was waiting, not leaking. `docker stats` is the quickest way to tell a busy container from an idle one.

**What differed from my prediction:** on `ubuntu:24.04` (GNU `tail`) this command is expected to fill memory. On 26.04 it did not.

**Hypothesis, not verified:** Ubuntu 26.04 ships a different implementation of the core utilities, and its `tail` handles `/dev/zero` differently. I did not run `tail --version` inside the container to confirm this, so I am recording it as a guess. The observed facts above are what I can stand behind.

**Fix for the drill:** use a memory eater that does not depend on `tail` (Fault 3).

**Cleanup:** `docker kill t2 && docker rm t2`.

---

## Fault 3: OOM kill (exit code 137)

**Symptom:** a container ran under a 64 MiB limit and was killed.

**Reproduce:**

```
docker run --memory 64m --name t2 ubuntu:26.04 bash -c 'a=x; while true; do a="$a$a"; done'
docker inspect t2 --format '{{.State.OOMKilled}} {{.State.ExitCode}}'
```

**Result:** `true 137`

- `137` = 128 + 9, meaning the process was killed by signal 9.
- `OOMKilled=true` means the kernel killed it for exceeding its memory limit. A manual `docker kill` also gives 137 but with `OOMKilled=false`, so the exit code alone does not say who sent the signal.

**Control test:** I started a container with no memory limit (`docker run -d --name killtest ubuntu:24.04 sleep 1000`), ran `docker kill killtest`, then `docker inspect killtest --format '{{.State.OOMKilled}} {{.State.ExitCode}}'`. Result: `false 137`. The exit code is the same as the memory kill, but `OOMKilled` is `false` because I sent the signal myself, not the kernel. This is why the exit code alone does not say who ended the process.

(One-letter container names are rejected by Docker, so the test container is named `killtest`.)

**Kernel evidence:** `sudo dmesg | tail -5` showed only network cleanup lines (`veth`, `docker0`), which were written after the OOM message. The OOM lines appeared with a search:

```
sudo dmesg | grep -i -E "oom|killed process"
```

```
bash invoked oom-killer: gfp_mask=0xcc0(GFP_KERNEL), order=0, oom_score_adj=0
oom-kill:constraint=CONSTRAINT_MEMCG,...,oom_memcg=/system.slice/docker-9c009fb9697b...scope,task=bash,pid=3115,uid=0
Memory cgroup out of memory: Killed process 3115 (bash) total-vm:81040kB, anon-rss:65016kB, ...
```

| Field | Meaning |
|---|---|
| `constraint=CONSTRAINT_MEMCG` | The limit that was exceeded belonged to a memory cgroup (the container), not the whole machine |
| `oom_memcg=...docker-9c009fb9697b...` | Which container's cgroup hit its limit |
| `Killed process 3115 (bash)` | The victim |
| `anon-rss:65016kB` | About 63.5 MiB in use, right at the 64 MiB limit |

**Linking the kernel log to the container:** `docker inspect t2 --format '{{.Id}}'` returned `9c009fb9697b3bd2025f2940026667a7e980260e277f14705d4af43c5cbc55e3`, which matches the ID in the kernel log line. The kill belongs to `t2`.

**Fix:** raise `--memory` to a value the application needs, or find out why the application uses more than expected.

**Verify:** `docker stats` shows memory staying under the limit and `docker inspect` shows `OOMKilled=false`.

---

## Fault 4: Web container not reachable (port not published, wrong server answering, port conflict)

### 4a. Unpublished port

**Reproduce:**

```
docker run -d --name web nginx
curl localhost:80
```

**Result:** `curl` returned `hello from lab1`. That is not the container's page. It came from the nginx installed on the instance itself.

**Proof:**

```
sudo ss -tulpn | grep :80      # nginx (pids 777, 778, 779) listening on 0.0.0.0:80 and [::]:80
docker port web                # prints nothing: no ports published
```

**Finding:** the container was healthy but unreachable from the host. A different server answered, so the test looked successful. **Before trusting a response, confirm who sent it.**

**Proving the container itself is fine:**

```
docker inspect web --format '{{.NetworkSettings.Networks.bridge.IPAddress}}'    # 172.17.0.2
curl 172.17.0.2                                                                # "Welcome to nginx!"
```

Note: the older field `.NetworkSettings.IPAddress` does not exist in Docker 29.1.3 (`map has no entry for key "IPAddress"`), so the address has to be read from the network name.

**Fix:** publish the port. Host port 80 was already taken, so I used 8080:

```
docker rm -f web
docker run -d --name web -p 8080:80 nginx
docker port web         # 80/tcp -> 0.0.0.0:8080 and [::]:8080
curl localhost:8080
```

### 4b. `Connection reset by peer` right after starting

The first `curl localhost:8080` came back `curl: (56) Recv failure: Connection reset by peer`. A retry a minute later returned the nginx page.

**Evidence from `docker logs web`:** nginx logged "ready for start up" at 06:59:25. The only request in the access log was my successful retry at 07:00:06, so the failed request never reached nginx. Docker's port forwarder accepted the connection before nginx inside the container was ready, then dropped it.

| Error | Meaning |
|---|---|
| `Connection refused` | Nothing is listening on that port (for example, not published) |
| `Connection reset by peer` | Something accepted the connection, then dropped it (backend not ready or crashed) |
| `Connection timed out` | Packets dropped (firewall or wrong address) |

**Side note:** the access log showed the client as `172.17.0.1` (the Docker bridge gateway), not the address I curled from, because the connection passes through Docker's port forwarding.

### 4c. Port conflict

```
docker run -d --name web2 -p 80:80 nginx
```

```
failed to bind host port 0.0.0.0:80/tcp: address already in use
```

`docker ps -a` showed `web2` as `Created` with an empty PORTS column. The host's nginx owned port 80, as `ss` had shown. Compared with Fault 1, `Created` again meant "never started", but the cause (networking, not the command) was only visible in the `docker run` error text.

**Fix:** use another host port, or stop whatever owns the port. Find the owner with `sudo ss -tulpn | grep :<port>`.

---

## Fault 5: Bind-mount permission denied

**Reproduce:**

```
sudo mkdir /tmp/rootdir
sudo chown root:root /tmp/rootdir && sudo chmod 755 /tmp/rootdir
docker run --rm -u 1000:1000 -v /tmp/rootdir:/data ubuntu:24.04 touch /data/x
```

**Result:** `touch: cannot touch '/data/x': Permission denied`

**Investigation:**

```
ls -ld /tmp/rootdir                                                                  # drwxr-xr-x root root
docker run --rm -u 1000:1000 -v /tmp/rootdir:/data ubuntu:24.04 ls -ld /data        # drwxr-xr-x root root
```

**Cause:** a bind mount shows the host folder with its host owner and mode. The container runs as UID 1000, the folder belongs to root with mode 755, so UID 1000 has no write permission. Same permission logic as on a normal Linux system.

**Fix A (preferred): match the owner.**

```
sudo chown 1000:1000 /tmp/rootdir
docker run --rm -u 1000:1000 -v /tmp/rootdir:/data ubuntu:24.04 touch /data/x
```

Result: `x` created, owned by `ubuntu` on the host.

**Fix B (works but riskier): run as root.**

```
sudo chown root:root /tmp/rootdir
docker run --rm -v /tmp/rootdir:/data ubuntu:24.04 touch /data/y
```

Result: `y` created, owned by `root` on the host. A root process in a container can write root-owned files on the host through a mount, so matching the UID is better.

**Verify:** `ls -l /tmp/rootdir` shows the expected owners.

---

## Inspection tools used

```
docker ps -a                       # all containers, including stopped and Created
docker logs <c>                    # what the process wrote
docker inspect <c> --format '...'  # exit code, OOMKilled, IP address
docker stats --no-stream           # CPU and memory right now
docker exec -it <c> bash           # shell inside a running container
docker port <c>                    # published ports
docker system df                   # disk used by images and containers
```

`docker system df` at the end of the session: 4 images (525.7 MB, 243.5 MB reclaimable), 2 containers.

---

## Customer reply (for Fault 3)

> Hi,
>
> Your container is being stopped with exit code 137. That code means it was force-killed, and in this case the kernel did it because the container reached its memory limit (64 MiB).
>
> We confirmed this in two places: Docker reports that the container was killed for running out of memory, and the system log shows the kernel stopping your process at the container's limit.
>
> To fix it, either raise the limit (for example `--memory 256m`) or look at why the application needs more memory than expected. After the change, run `docker inspect <container> --format '{{.State.OOMKilled}}'`. It should print `false`.
>
> Please let us know if it happens again.

---

## What I learned

1. Read the `docker run` error first. For a container that never started, it is the only evidence.
2. `Created` means it never started, `Exited` means it ran and stopped.
3. An exit code says how a process ended, not who ended it. Check `OOMKilled` and `dmesg`.
4. `dmesg | tail` can miss the line you want. Use `grep`.
5. Check who is answering. A test that succeeds against the wrong server proves nothing.
6. `Refused`, `reset` and `timed out` each point at a different layer.
7. A bind mount keeps the host's permissions. Match the UID instead of running as root.
8. Images and tool versions differ between Ubuntu releases, so the same command can behave differently on a different image.

## Cleanup

```
docker rm -f web2
docker images
sudo rm -rf /tmp/rootdir
```
