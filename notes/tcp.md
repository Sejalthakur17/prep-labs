# TCP notes

## What TCP is
Reliable, ordered delivery between two programs. Used by HTTP, HTTPS, SSH.
Every connection = client (random "ephemeral" port) -> server (fixed port).
Example from my capture: 127.0.0.1.55152 -> 127.0.0.1.80

## The 3-way handshake (opening)
[S]   SYN      client: "want to talk?"
[S.]  SYN-ACK  server: "yes"
[.]   ACK      client: "great"  -> connection is open

## Sending data
[P.]  PUSH+ACK carries data (GET / HTTP/1.1, then HTTP/1.1 200 OK)
[.]   plain ACK = "I received it"
ack number = "I got everything up to this byte"
  (request was bytes 1:74, server answered ack 74)

## Closing (4 packets)
[F.]  client: "I'm done"
[F.]  server: "me too"
[.]   last ACK, connection closed
Each side closes its own direction, so there are two FINs.

## Other flag
[R.]  RST: "reject / reset this connection"

## The three outcomes (this is the key skill)
1. Open:     [S] -> [S.]            service is listening
2. Refused:  [S] -> [R.] instantly  host reachable, nothing listening
             curl: (7) Failed to connect ... Connection refused
3. Dropped:  [S] [S] [S] ... no reply  firewall / security group blocking
             curl hangs until timeout (exit code 28)

## Commands I use
sudo ss -tlnp | grep ':80 '          # who is listening on port 80
sudo ss -tn                          # current established connections
sudo tcpdump -nn -i lo port 80       # watch TCP on port 80 (loopback)
sudo tcpdump -nn -i any host 1.2.3.4 # all traffic to/from one IP
curl -sS http://127.0.0.1; echo $?   # 0 = ok, 7 = refused, 28 = timeout
nc -zv HOST 80                       # quick "is the port open?" test

## ss flags
-t TCP   -l listening   -n numbers   -p show program

## Reading ss output
0.0.0.0:80  = listening on all IPv4 addresses
[::]:80     = listening on all IPv6 addresses
Several nginx PIDs = worker processes sharing one socket

## Support checklist: "I can't reach the server"
1. Is the service running?       systemctl status nginx
2. Is it listening on the port?  ss -tlnp
3. Does it answer locally?       curl -sS http://127.0.0.1
4. From outside: refused or timeout?
   - refused -> service/port problem
   - timeout -> security group, NACL or firewall (ufw/iptables)
