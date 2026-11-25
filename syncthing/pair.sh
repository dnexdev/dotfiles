#!/usr/bin/env bash
# usage: syncthing/pair.sh HOST
# Pair this machine with HOST (an ssh alias, e.g. `us`) in Syncthing and share the
# synced folders both ways. Run install.sh on both machines first. Safe to re-run.
set -euo pipefail

host=${1:?usage: $0 HOST (an ssh alias: us or m2)}
FOLDERS=(code notes Documents) # keep in sync with SYNC_DIRS in install.sh

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
# on local|remote CMD...: run CMD here or on $host (non-login ssh: add brew's bin for macs)
on() {
  local where=$1
  shift
  if [[ $where == local ]]; then
    "$@"
  else
    ssh "$host" "PATH=\$PATH:/opt/homebrew/bin; $(printf '%q ' "$@")"
  fi
}

# introduce <where> <peer id> <peer name>: make <where> know the peer and share every folder with it
introduce() {
  local where=$1 id=$2 name=$3 f
  if ! on "$where" syncthing cli config devices list | grep -qx "$id"; then
    say "$where: adding device $name"
    on "$where" syncthing cli config devices add --device-id "$id" --name "$name" \
      --addresses "tcp://$name:22000" --addresses dynamic
  fi
  for f in "${FOLDERS[@]}"; do
    if ! on "$where" syncthing cli config folders list | grep -qx "$f"; then
      echo "   $where has no folder '$f' (run install.sh there), skipping" >&2
      continue
    fi
    on "$where" syncthing cli config folders "$f" devices list | grep -qx "$id" && continue
    say "$where: sharing $f with $name"
    on "$where" syncthing cli config folders "$f" devices add --device-id "$id"
  done
}

local_id=$(syncthing device-id)
local_name=$(uname -n)
remote_id=$(on remote syncthing device-id)
remote_name=$(on remote uname -n)

introduce local "$remote_id" "$remote_name"
introduce remote "$local_id" "$local_name"
say "paired $local_name <-> $remote_name (status: http://localhost:8384)"
