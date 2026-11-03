# Linux permissions

## Reading rwx
Every file and directory has three sets of permissions: owner, group and others. Each set has read (r), write (w) and execute (x), worth r=4, w=2, x=1. Add them up per set.

- `640` = owner 6 (rw-), group 4 (r--), others 0 (---) → `-rw-r-----`
- `2770` = owner 7 (rwx), group 7 (rwx), others 0 (---), plus a leading 2 for setgid → `drwxrws---`

The first character is the type: `-` file, `d` directory. The next nine are the three triples.

Useful commands: `ls -l` (letters), `ls -ld <dir>` (the directory itself), `stat <file>` (numbers, owner, group, timestamps), `id <user>` (which groups a user is in).

## Files vs directories
On a file: r = read contents, w = change contents, x = run it as a program.

On a directory:
- r = list the names inside
- x = enter it and reach things inside by name (cd, open, read details)
- w = create or delete entries (only works together with x)

Permission checks go through every directory on the path. A file with a perfectly fine mode is still unreachable if a directory above it blocks access.

The surprise: with group `x` removed but `r` kept, plain `ls` still showed the names, but `ls -l` showed `?` in every column and `cat` was denied. Plain `ls` only needs the names. `ls -l` and `cat` need to reach each file.

## Users and groups
- `adduser alice` creates the user **and** a private group `alice`, which becomes her primary group. `groupadd devs` creates only a group.
- A user has one primary group (`gid=` in `id`) plus any supplementary groups.
- `usermod -aG devs alice` adds a user to a group. The `-a` means append. Without it, `-G` replaces all supplementary groups and can remove things like `sudo`.
- `gpasswd -d alice devs` removes a user from one group. Adding a user to a new group does not remove them from the old one.
- Group membership changes only apply to new login sessions, so the user must log out and back in.

## chown vs chgrp vs chmod
- `chown owner:group path` changes who the file belongs to.
- `chgrp group path` changes only the group of the file or folder. It does not move a person between groups.
- `chmod` changes what each party is allowed to do (`chmod 2770`, or symbolic `g-w`, `g+x`, `g+s`).
- `-R` makes chown/chgrp/chmod apply to everything inside a folder.
- Changing a folder's group does not change files already inside it.

## setgid
The 2 in `2770` is the setgid bit. On a directory, new files and subdirectories inherit the **directory's group** instead of the creator's primary group.

- It copies the group only, not the permissions. The mode comes from the umask.
- Setgid on: Alice's new file gets group `devs`. Setgid off: it gets `alice`. I confirmed both.
- Turning setgid on or off does not change files that already exist.
- In `ls -l`, setgid shows as `s` where the group's `x` would be. A capital `S` means setgid is set but execute is missing.
- Rule: a new file's owner is the user who creates it. Its group is the creator's primary group, unless the directory has setgid, in which case it is the directory's group.

## umask
The umask lists permissions to remove from new files and directories. Files start at 666 and directories at 777.

- My umask was `0002`. Ubuntu relaxes it because each user has a private group.
- `umask 027` made new files 640 and directories 750.
- It only affects files created afterwards, and only lasts for the current shell session.
- Files created through `sudo` came out 644, because sudo applies its own umask.

## What I broke and how I fixed it
1. **Removed group write (`chmod g-w /srv/project`)**
   - Symptom: `sudo -u alice touch /srv/project/b.txt` failed with Permission denied.
   - Diagnosis: `ls -ld` showed `drwxr-s---`. `sudo -u alice id` showed she was in `devs`, so the group matched but lacked write.
   - Fix: `chmod g+w /srv/project`.

2. **Removed group execute (`chmod g-x /srv/project`)**
   - Symptom: `ls -l` showed question marks, and `cat a.txt` and `touch c.txt` were denied, even though Alice owns `a.txt` and its own mode was fine.
   - Diagnosis: `ls -ld` showed `drwxrwS---` (capital S, no x for the group). The problem was the directory, not the file.
   - Fix: `chmod g+x /srv/project`.

3. **Turned setgid off (`chmod g-s /srv/project`)**
   - Symptom: a new file got group `alice` instead of `devs`.
   - Fix: `chmod g+s /srv/project`. Existing files keep their old group.

## Troubleshooting method
1. Read the exact error.
2. Check who the user is and their groups: `id <user>`.
3. Check the permissions of the file **and every directory above it**: `ls -ld`.
4. Compare, change one thing, and verify.
