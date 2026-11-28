#!/bin/bash
# restore.sh - return the lab machine to the baseline saved by breakit.sh (in /root/.bk).
# Install as /root/restore.sh (mode 700). Run with sudo on lab1 only.
cp /root/.bk/default /etc/nginx/sites-enabled/default
cp /root/.bk/hosts /etc/hosts
chmod 755 /var/www /var/www/html
chmod 644 /var/www/html/index.nginx-debian.html
systemctl unmask nginx
rm -f /var/fill
find /var/tmp/.spool -delete 2>/dev/null
nginx -t && systemctl restart nginx