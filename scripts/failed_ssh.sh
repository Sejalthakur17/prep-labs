#!/usr/bin/env bash
set -euo pipefail

LOG="${1:-/var/log/auth.log}"

if [[ ! -r "$LOG" ]]; then
  echo "Error: cannot read $LOG (wrong path, or try sudo)" >&2
  exit 1
fi

# "|| true" stops the script dying when grep finds no matches
result=$(grep -E 'Failed password|Invalid user' "$LOG" \
  | grep -oE 'from [0-9]{1,3}(\.[0-9]{1,3}){3}' \
  | awk '{print $2}' \
  | sort | uniq -c | sort -nr | head -10 || true)

if [[ -z "$result" ]]; then
  echo "No failed SSH attempts found in $LOG"
else
  echo "Top source IPs of failed SSH attempts in $LOG:"
  echo "$result"
fi
