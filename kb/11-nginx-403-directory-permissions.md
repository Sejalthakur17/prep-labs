# KB article: nginx returns 403 Forbidden because of directory permissions

## Title

nginx returns `403 Forbidden` with `(13: Permission denied)` in the error log

## Environment

- Ubuntu Server (tested on 26.04 LTS), AWS EC2
- nginx 1.28.x serving a static site from `/var/www/html`
- nginx worker processes run as `www-data`

## Symptom

- `curl -I` or a browser shows `HTTP/1.1 403 Forbidden`, both on the server and from other machines.
- `systemctl status nginx` shows `active (running)`.
- `/var/log/nginx/error.log` contains a line like:
  `"/var/www/html/index.html" is forbidden (13: Permission denied)`

## Cause

The nginx worker runs as the user named in the `user` directive (here `www-data`). To serve a file, that user needs **execute** on every directory in the path (permission to enter it) and **read** on the file. If any directory blocks "other" users, for example `drwx------ root root`, nginx cannot reach the file and returns 403. Write permission is not needed.

Not every 403 is this problem. Check the message in the error log first:

1. `(13: Permission denied)`: this article.
2. `directory index of "..." is forbidden`: there is no index file in that folder and directory listing is off.
3. `access forbidden by rule`: a `deny` rule in the nginx configuration.

## Solution

1. Confirm the symptom and that nginx is running.

```bash
curl -I localhost
systemctl status nginx --no-pager
```

2. Read the error log. The message tells you which cause applies.

```bash
sudo tail -n 20 /var/log/nginx/error.log
```

3. Find out which user nginx runs as.

```bash
grep -E '^user' /etc/nginx/nginx.conf
```

4. Check every directory in the path to the file.

```bash
namei -l /var/www/html/index.nginx-debian.html
```

Look for the first line where the owner, group and permission bits would stop that user, such as `drwx------ root root html`.

5. Change only what blocks access. For a web directory:

```bash
sudo chmod 755 /var/www/html
```

Directories are normally `755` and files `644`. Do not use `777`.

## Verification

1. `namei -l /var/www/html/index.nginx-debian.html` shows no `Permission denied`.
2. `curl -I localhost` returns `HTTP/1.1 200 OK`.
3. From another machine, `curl -I http://<server-ip>` returns `200 OK`.

## Notes

- The refusal appears in `/var/log/nginx/error.log`, not in `journalctl -u nginx`.
- A `403` means the request reached nginx. A "connection refused" means nothing is listening, and a long wait ending in a timeout usually means a firewall or security group.
- The file name in the error log may be the first name nginx tries (`index.html`), not the one that exists on disk. `namei -l` on the real file shows the same blocked directory.

## Prevention

- Check the web path with `namei -l` after any deployment, ownership change or permission change.
- Keep directories `755` and files `644`, owned by the deploy user.
- Add an external uptime check that expects `200`, so a `403` raises an alert.