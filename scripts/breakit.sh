#!/bin/bash
# breakit.sh - fault injector for capstone tickets.
# Run with sudo on a THROWAWAY lab machine only (lab1). Prints nothing on purpose.
# Usage: sudo ./breakit.sh [fault numbers to exclude]    e.g. sudo ./breakit.sh 3 6
[ "$EUID" -eq 0 ] || exit 1
exec >/dev/null 2>&1

BK=/root/.bk; mkdir -p $BK
[ -f $BK/default ] || cp -L /etc/nginx/sites-enabled/default $BK/default
[ -f $BK/hosts ]   || cp /etc/hosts $BK/hosts
/root/restore.sh                          # always start from a clean state

pool=()
for n in 0 1 2 3 4 5 6 7; do
  case " $* " in *" $n "*) ;; *) pool+=($n) ;; esac
done
pick=${pool[$((RANDOM % ${#pool[@]}))]}
echo "$pick $(date -u +%FT%TZ)" > /root/.fault; chmod 600 /root/.fault

case $pick in
 0) sed -i --follow-symlinks 's/listen 80 /listen 8081 /' /etc/nginx/sites-enabled/default && systemctl reload nginx ;;
 1) chmod 600 /var/www/html/index.nginx-debian.html ;;
 2) echo "127.0.0.1 example.com" >> /etc/hosts ;;
 3) fallocate -l $(( $(df --output=avail -B1 / | tail -1) - 50000000 )) /var/fill ;;
 4) systemctl mask nginx && systemctl stop nginx ;;
 5) mkdir -p /var/tmp/.spool
    n=$(df --output=iavail / | tail -1 | tr -d ' ')
    seq 1 $((n-500)) | (cd /var/tmp/.spool && xargs touch) ;;          # inode exhaustion
 6) sed -i --follow-symlinks '1i this_is_a_typo;' /etc/nginx/sites-enabled/default
    systemctl restart nginx ;;                                          # bad config, site down
 7) chmod 700 /var/www/html ;;                                          # directory permission
esac