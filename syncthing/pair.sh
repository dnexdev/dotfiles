#!/usr/bin/env bash
# usage: syncthing/pair.sh HOST       pair this machine with HOST (an ssh alias: us or m2)
#        syncthing/pair.sh --folders  print the synced folders (install.sh reads them this way)
# Pairs the two machines in Syncthing and shares every folder in syncthing/folders both ways.
# Run install.sh on both machines first. Safe to re-run, and safe to run from both machines
# at once. States and invariants: docs/state-machines.md, M9.
set -euo pipefail

here=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() {
  echo "pair.sh: $*" >&2
  exit 1
}

# the one parser for syncthing/folders: drop comments and blank lines, keep the first word,
# and reject anything that isn't a plain relative path (it becomes a folder ID and ~/<path>)
folders() {
  local f
  grep -vE '^[[:space:]]*(#|$)' "$here/folders" | awk '{print $1}' | while IFS= read -r f; do
    [[ $f =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && $f != *..* ]] ||
      die "bad entry in syncthing/folders: '$f'"
    echo "$f"
  done
}

if [[ ${1:-} == --folders ]]; then
  folders
  exit 0
fi

host=${1:?usage: $0 HOST (an ssh alias: us or m2)}
FOLDERS=()
list=$(folders) || exit 1 # (not `< <(folders)`: that would hide a bad entry)
while IFS= read -r f; do if [[ -n $f ]]; then FOLDERS+=("$f"); fi; done <<<"$list"
((${#FOLDERS[@]})) || die "syncthing/folders lists no folders"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# one ssh connection for the whole run: a passphrase or password is asked once, not ~15 times
ctl=$(mktemp -d)
trap 'ssh -o ControlPath="$ctl/s" -O exit "$host" 2>/dev/null; rm -rf "$ctl"' EXIT
SSH=(ssh -o ControlMaster=auto -o ControlPath="$ctl/s" -o ControlPersist=60)

# on local|remote CMD...: run CMD here or on $host (non-login ssh: add brew's bin for macs)
on() {
  local where=$1
  shift
  if [[ $where == local ]]; then
    "$@"
  else
    "${SSH[@]}" "$host" "PATH=\$PATH:/opt/homebrew/bin; $(printf '%q ' "$@")"
  fi
}

# has WHERE WANT LISTCMD...: 0 if WANT is a line of LISTCMD's output, 1 if it isn't.
# If LISTCMD itself fails (daemon down, ssh dropped) that is NOT "absent": abort the run.
# (Output is captured before grepping: `cmd | grep -q` under pipefail can misreport.)
has() {
  local where=$1 want=$2 out
  shift 2
  out=$(on "$where" "$@") || die "$where: '$*' failed (is syncthing running there?)"
  grep -qxF -- "$want" <<<"$out"
}

# ensure WHERE WANT LISTCMD... -- ADDCMD...: add unless listed. Returns 0 if it added, 1 if
# it was already there. If the add fails but the item is listed afterwards, the other
# machine's pair.sh run added it first: that's fine too.
ensure() {
  local where=$1 want=$2 list=() add=()
  shift 2
  while [[ $1 != -- ]]; do list+=("$1") && shift; done
  shift
  add=("$@")
  has "$where" "$want" "${list[@]}" && return 1
  on "$where" "${add[@]}" && return 0
  has "$where" "$want" "${list[@]}" && return 1
  die "$where: '${add[*]}' failed"
}

# introduce WHERE PEER_ID PEER_NAME: make WHERE know the peer and share every folder with it
introduce() {
  local where=$1 id=$2 name=$3 f
  if ensure "$where" "$id" syncthing cli config devices list -- \
    syncthing cli config devices add --device-id "$id" --name "$name" \
    --addresses "tcp://$name:22000" --addresses dynamic; then
    say "$where: added device $name"
  fi
  for f in "${FOLDERS[@]}"; do
    if ! has "$where" "$f" syncthing cli config folders list; then
      echo "   $where has no folder '$f' (run install.sh there), skipping" >&2
      continue
    fi
    if ensure "$where" "$id" syncthing cli config folders "$f" devices list -- \
      syncthing cli config folders "$f" devices add --device-id "$id"; then
      say "$where: sharing $f with $name"
    fi
  done
}

local_id=$(syncthing device-id) || die "syncthing isn't set up here"
local_name=$(uname -n)
remote_id=$(on remote syncthing device-id) || die "can't reach syncthing on $host"
remote_name=$(on remote uname -n) || die "can't reach $host"
# macOS reports e.g. m2.local; the Tailscale (MagicDNS) name is the part before the dot
local_name=${local_name%%.*} remote_name=${remote_name%%.*}

introduce local "$remote_id" "$remote_name"
introduce remote "$local_id" "$local_name"
say "paired $local_name <-> $remote_name (status: http://localhost:8384)"
